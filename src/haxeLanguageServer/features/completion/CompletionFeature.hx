package haxeLanguageServer.features.completion;

import haxe.ds.Option;
import haxe.display.Display;
import haxe.display.Display.CompletionParams as HaxeCompletionParams;
import haxe.display.JsonModuleTypes;
import haxe.extern.EitherType;
import tokentree.TokenTree;
import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types.NoData;
import haxeLanguageServer.helper.DocHelper;
import haxeLanguageServer.helper.ImportHelper;
import haxeLanguageServer.protocol.DisplayPrinter;
import haxeLanguageServer.protocol.CompilerMetadata;
import haxeLanguageServer.tokentree.PositionAnalyzer;
import haxeLanguageServer.tokentree.TokenContext;
import languageServerProtocol.protocol.Protocol.CompletionParams;
import languageServerProtocol.Types.CompletionItem;
import languageServerProtocol.Types.CompletionItemKind;

using tokentree.TokenTreeAccessHelper;
using Safety;

enum abstract CompletionItemOrigin(Int) {
	var Haxe;
	var Custom;
}

typedef CompletionItemData = {
	var origin:CompletionItemOrigin;
	var ?index:Int;
}

class CompletionFeature {
	public static final TriggerSuggest = {
		title: "Trigger Suggest",
		command: "editor.action.triggerSuggest",
		arguments: []
	};
	public static final TriggerParameterHints = {
		title: "Trigger Parameter Hints",
		command: "editor.action.triggerParameterHints",
		arguments: []
	};

	final context:Context;
	final legacy:CompletionFeatureLegacy;
	final expectedTypeCompletion:ExpectedTypeCompletion;
	final postfixCompletion:PostfixCompletion;
	final snippetCompletion:SnippetCompletion;
	final printer:DisplayPrinter;
	var previousCompletionData:Null<CompletionContextData>;

	var contextSupport:Bool;
	var markdownSupport:Bool;
	var snippetSupport:Bool;
	var commitCharactersSupport:Bool;
	var deprecatedSupport:Bool;

	public function new(context) {
		this.context = context;
		inline checkCapabilities();
		expectedTypeCompletion = new ExpectedTypeCompletion(context);
		postfixCompletion = new PostfixCompletion(context);
		snippetCompletion = new SnippetCompletion(context);
		printer = new DisplayPrinter(false, Qualified, {
			argumentTypeHints: true,
			returnTypeHint: NonVoid,
			explicitPublic: true,
			explicitPrivate: true,
			explicitNull: true
		});

		legacy = new CompletionFeatureLegacy(context, contextSupport, formatDocumentation);

		context.languageServerProtocol.onRequest(Methods.Completion, onCompletion);
		context.languageServerProtocol.onRequest(Methods.CompletionItemResolve, onCompletionItemResolve);
	}

	function checkCapabilities() {
		var completion = context.capabilities.textDocument!.completion;
		contextSupport = completion!.contextSupport == true;
		markdownSupport = completion!.completionItem!.documentationFormat.let(kinds -> kinds.contains(MarkDown)).or(false);
		snippetSupport = completion!.completionItem!.snippetSupport == true;
		commitCharactersSupport = completion!.completionItem!.commitCharactersSupport == true;
		deprecatedSupport = completion!.completionItem!.deprecatedSupport == true;
	}

	function onCompletion(params:CompletionParams, token:CancellationToken, resolve:CompletionList->Void, reject:ResponseError<NoData>->Void) {
		var uri = params.textDocument.uri;
		if (!uri.isFile()) {
			return reject.notAFile();
		}
		var doc:Null<TextDocument> = context.documents.get(uri);
		if (doc == null) {
			return reject.documentNotFound(uri);
		}
		var offset = doc.offsetAt(params.position);
		var textBefore = doc.content.substring(0, offset);
		var whitespace = textBefore.length - textBefore.rtrim().length;
		var currentToken = new PositionAnalyzer(doc).resolve(params.position.translate(0, -whitespace));
		if (contextSupport && !isValidCompletionPosition(currentToken, doc, params, textBefore)) {
			return resolve({items: [], isIncomplete: false});
		}
		var handle = if (context.haxeServer.supports(DisplayMethods.Completion)) handleJsonRpc else legacy.handle;
		handle(params, token, resolve, reject, doc, offset, textBefore, currentToken);
	}

	static final autoTriggerOnSpacePattern = ~/(\b(import|using|extends|implements|from|to|case|new|cast|override)|(->)) $/;

	function isValidCompletionPosition(token:TokenTree, doc:TextDocument, params:CompletionParams, text:String):Bool {
		if (token == null) {
			return true;
		}
		var inComment = switch token.tok {
			case Comment(_), CommentLine(_): true;
			case _: false;
		};
		if (inComment) {
			return false;
		}
		if (params.context == null) {
			return true;
		}
		return switch params.context.triggerCharacter {
			case null: true;
			case ">" if (!isAfterArrow(text)): false;
			case " " if (!autoTriggerOnSpacePattern.match(text)): false;
			case "$" if (!isInterpolationPosition(token, doc, params.position, text)): false;
			case _: true;
		}
	}

	inline function isAfterArrow(text:String):Bool {
		return text.trim().endsWith("->");
	}

	static final dollarPattern = ~/(\$+)$/;

	function isInterpolationPosition(token:Null<TokenTree>, doc, pos, text):Bool {
		var inMacroReification = token.access().findParent(t -> t.is(Kwd(KwdMacro)).exists()).exists();
		var stringKind = PositionAnalyzer.getStringKind(token, doc, pos);

		if (stringKind != SingleQuote) {
			return inMacroReification;
		}
		if (!dollarPattern.match(text)) {
			return false;
		}
		var escaped = dollarPattern.matched(1).length % 2 == 0;
		return !escaped;
	}

	function onCompletionItemResolve(item:CompletionItem, token:CancellationToken, resolve:CompletionItem->Void, reject:ResponseError<NoData>->Void) {
		var data:Null<CompletionItemData> = item.data;
		if (!context.haxeServer.supports(DisplayMethods.CompletionItemResolve)
			|| previousCompletionData == null
			|| (data != null && data.origin == Custom)) {
			return resolve(item);
		}
		previousCompletionData.isResolve = true;
		context.callHaxeMethod(DisplayMethods.CompletionItemResolve, {index: item.data.index}, token, result -> {
			resolve(createCompletionItem(data.index, result.item, previousCompletionData));
			return null;
		}, reject.handler());
	}

	function handleJsonRpc(params:CompletionParams, token:CancellationToken, resolve:CompletionList->Void, reject:ResponseError<NoData>->Void,
			doc:TextDocument, offset:Int, textBefore:String, currentToken:TokenTree) {
		var wasAutoTriggered = true;
		if (params.context != null) {
			wasAutoTriggered = params.context.triggerKind == TriggerCharacter;
			if (params.context.triggerCharacter == "$") {
				wasAutoTriggered = false;
			}
		}
		var haxeParams:HaxeCompletionParams = {
			file: doc.uri.toFsPath(),
			contents: doc.content,
			offset: offset,
			wasAutoTriggered: wasAutoTriggered,
			meta: [CompilerMetadata.Deprecated]
		};
		var tokenContext = PositionAnalyzer.getContext(currentToken, doc, params.position);
		var position = params.position;
		var lineAfter = doc.getText({
			start: position,
			end: position.translate(1, 0)
		});
		// scan back to the dot for `expr.ident|` manually - we ignore replaceRanges sent by Haxe in most cases
		// because of a bug in rc.3 and generally inconsistent results (sometimes replaceRange is null)
		var wordPattern = ~/\w*$/;
		wordPattern.match(textBefore);
		var replaceRange = {
			start: params.position.translate(0, -wordPattern.matched(0).length),
			end: params.position
		};
		context.callHaxeMethod(DisplayMethods.Completion, haxeParams, token, function(result) {
			var hasResult = result != null;
			var mode = if (hasResult) result.mode.kind else null;
			if (mode != TypeHint && wasAutoTriggered && isAfterArrow(textBefore)) {
				resolve({items: [], isIncomplete: false}); // avoid auto-popup after -> in arrow functions
				return null;
			}
			var importPosition = ImportHelper.getImportPosition(doc);
			var indent = doc.indentAt(params.position.line);
			var data:CompletionContextData = {
				replaceRange: if (mode == Metadata || mode == Toplevel || mode == TypeHint) result.replaceRange else replaceRange,
				mode: if (hasResult) result.mode else null,
				doc: doc,
				indent: indent,
				lineAfter: lineAfter,
				params: params,
				importPosition: importPosition,
				tokenContext: tokenContext,
				isResolve: false
			};
			var displayItems = if (hasResult) result.items else [];
			var items = [];
			if (hasResult) {
				items = items.concat(postfixCompletion.createItems(data, displayItems));
				items = items.concat(expectedTypeCompletion.createItems(data));
			}
			items = items.concat(createFieldKeywordItems(tokenContext, replaceRange, lineAfter));

			function resolveItems() {
				for (i in 0...displayItems.length) {
					var displayItem = displayItems[i];
					var index = if (displayItem.index == null) i else displayItem.index;
					var completionItem = createCompletionItem(index, displayItem, data);
					if (completionItem != null) {
						items.push(completionItem);
					}
				}
				items = items.filter(i -> i != null);
				resolve({
					items: items,
					isIncomplete: if (result.isIncomplete == null) false else result.isIncomplete
				});
			}
			if (snippetSupport && mode != Import && mode != Field) {
				snippetCompletion.createItems(data, displayItems).then(result -> {
					items = items.concat(result.items);
					displayItems = result.displayItems;
					resolveItems();
				});
			} else {
				resolveItems();
			}
			previousCompletionData = data;
			return displayItems.length + " items";
		}, function(error) {
			if (snippetSupport) {
				snippetCompletion.createItems({
					doc: doc,
					params: params,
					replaceRange: replaceRange,
					tokenContext: tokenContext
				}, []).then(result -> {
					var keywords = createFieldKeywordItems(tokenContext, replaceRange, lineAfter);
					resolve({items: keywords.concat(result.items), isIncomplete: false});
				});
			}
		});
	}

	function createFieldKeywordItems(tokenContext:TokenContext, replaceRange:Range, lineAfter:String):Array<CompletionItem> {
		var isFieldLevel = switch tokenContext {
			case Type(type) if (type.field == null): true;
			case _: false;
		}
		if (!isFieldLevel) {
			return [];
		}
		var results:Array<CompletionItem> = [];
		function create(keyword:KeywordKind):CompletionItem {
			return {
				label: keyword,
				kind: Keyword,
				textEdit: {
					newText: maybeInsert(keyword, " ", lineAfter),
					range: replaceRange
				},
				command: TriggerSuggest,
				sortText: "~~~",
				data: {
					origin: Custom
				}
			}
		}
		var keywords:Array<KeywordKind> = [Public, Private, Extern, Final, Static, Dynamic, Override, Inline, Macro];
		for (keyword in keywords) {
			results.push(create(keyword));
		}
		return results;
	}

	function createCompletionItem<T>(index:Int, item:Null<DisplayItem<T>>, data:CompletionContextData):Null<CompletionItem> {
		if (item == null) {
			return null;
		}
		var completionItem:CompletionItem = switch item.kind {
			case ClassField | EnumAbstractField: createClassFieldCompletionItem(item, data);
			case EnumField: createEnumFieldCompletionItem(item, data);
			case Type: createTypeCompletionItem(item.args, data);
			case Package: createPackageCompletionItem(item.args, data);
			case Keyword: createKeywordCompletionItem(item.args, data);
			case Local: createLocalCompletionItem(item, data);
			case Module: createModuleCompletionItem(item.args, data);
			case Literal: createLiteralCompletionItem(item, data);
			case Metadata:
				if (item.args.internal) {
					null;
				} else {
					label: item.args.name,
					kind: Function
				}
			case TypeParameter: {
					label: item.args.name,
					kind: TypeParameter
				}
			// these never appear during `display/completion` right now
			case Expression: null;
			case AnonymousStructure: null;
		}

		if (completionItem == null) {
			return null;
		}

		if (completionItem.textEdit == null && data.replaceRange != null) {
			completionItem.textEdit = {range: data.replaceRange, newText: completionItem.label};
		}

		if (completionItem.documentation == null) {
			completionItem.documentation = formatDocumentation(item.getDocumentation());
		}

		if (completionItem.detail != null) {
			completionItem.detail = completionItem.detail.rtrim();
		}

		if (commitCharactersSupport) {
			var mode = data.mode.kind;
			if ((item.type != null && item.type.kind == TFun && mode != Pattern) || mode == New) {
				completionItem.commitCharacters = ["("];
			}
		}

		if (completionItem.sortText == null) {
			completionItem.sortText = "";
		}
		completionItem.sortText += Std.string(index + 1).lpad("0", 10);

		completionItem.data = {origin: Haxe, index: index};
		return completionItem;
	}

	function createClassFieldCompletionItem<T>(item:DisplayItem<Dynamic>, data:CompletionContextData):CompletionItem {
		var occurrence:ClassFieldOccurrence<T> = item.args;
		var concreteType = item.type;
		var field = occurrence.field;
		var resolution = occurrence.resolution;
		var printedOrigin = printer.printClassFieldOrigin(occurrence.origin, item.kind, "'");

		if (data.mode.kind == Override) {
			return createOverrideCompletionItem(item, data, printedOrigin);
		}

		var item:CompletionItem = {
			label: field.name,
			kind: getKindForField(field, item.kind),
			detail: {
				var overloads = if (occurrence.field.overloads == null) 0 else occurrence.field.overloads.length;
				var detail = printer.printClassFieldDefinition(occurrence, concreteType, item.kind == EnumAbstractField);
				if (overloads > 0) {
					detail += ' (+$overloads overloads)';
				}
				var shadowed = if (!resolution.isQualified) " (shadowed)" else "";
				switch printedOrigin {
					case Some(v): detail + "\n" + v + shadowed;
					case None: detail + "\n" + shadowed;
				}
			},
			textEdit: {
				newText: {
					var qualifier = if (resolution.isQualified) "" else resolution.qualifier + ".";
					qualifier + switch data.mode.kind {
						case StructureField: maybeInsert(field.name, ": ", data.lineAfter);
						case Pattern: maybeInsert(field.name, ":", data.lineAfter);
						case _: field.name;
					}
				},
				range: data.replaceRange
			}
		}

		switch data.mode.kind {
			case StructureField:
				if (field.meta.hasMeta(Optional)) {
					item.label = "?" + field.name;
					item.filterText = field.name;
				}
			case _:
		}

		handleDeprecated(item, field.meta);
		return item;
	}

	function createOverrideCompletionItem<T>(item:DisplayItem<Dynamic>, data:CompletionContextData, printedOrigin:Option<String>):Null<CompletionItem> {
		var occurrence:ClassFieldOccurrence<T> = item.args;
		var concreteType = item.type;
		var field = occurrence.field;
		var importConfig = context.config.user.codeGeneration.imports;

		if (concreteType == null || concreteType.kind != TFun || field.isFinalField()) {
			return null;
		}
		switch field.kind.kind {
			case FMethod if (field.kind.args == MethInline):
				return null;
			case _:
		}

		var fieldFormatting = context.config.user.codeGeneration.functions.field;
		var printer = new DisplayPrinter(false, if (importConfig.enableAutoImports) Shadowed else Qualified, fieldFormatting);

		var item:CompletionItem = {
			label: field.name,
			kind: getKindForField(field, item.kind),
			textEdit: {
				newText: printer.printOverrideDefinition(field, concreteType, data.indent, true),
				range: data.replaceRange
			},
			insertTextFormat: Snippet,
			detail: "Auto-generate override" + switch printedOrigin {
				case Some(v): "\n" + v;
				case None: "";
			},
			documentation: {
				kind: MarkDown,
				value: DocHelper.printCodeBlock("override " + printer.printOverrideDefinition(field, concreteType, data.indent, false), Haxe)
			},
			additionalTextEdits: ImportHelper.createFunctionImportsEdit(data.doc, data.importPosition, context, concreteType, fieldFormatting)
		}
		handleDeprecated(item, field.meta);
		return item;
	}

	function getKindForField<T>(field:JsonClassField, kind:DisplayItemKind<Dynamic>):CompletionItemKind {
		if (kind == EnumAbstractField) {
			return EnumMember;
		}
		var fieldKind:JsonFieldKind<T> = field.kind;
		return switch fieldKind.kind {
			case FVar:
				if (field.isFinalField()) {
					return Field;
				}
				var read = fieldKind.args.read.kind;
				var write = fieldKind.args.write.kind;
				switch [read, write] {
					case [AccNormal, AccNormal]: Field;
					case [AccInline, _]: Constant;
					case _: Property;
				}
			case FMethod if (field.isOperator()): Operator;
			case FMethod if (field.scope == Static): Function;
			case FMethod if (field.scope == Constructor): Constructor;
			case FMethod: Method;
		}
	}

	function getKindForType<T>(type:JsonType<T>):CompletionItemKind {
		return switch type.kind {
			case TFun: Function;
			case _: Field;
		}
	}

	function createEnumFieldCompletionItem<T>(item:DisplayItem<Dynamic>, data:CompletionContextData):CompletionItem {
		var occurrence:EnumFieldOccurrence<T> = item.args;
		var field:JsonEnumField = occurrence.field;
		var name = field.name;
		var result:CompletionItem = {
			label: name,
			kind: EnumMember,
			detail: {
				var definition = printer.printEnumFieldDefinition(field, item.type);
				var origin = printer.printEnumFieldOrigin(occurrence.origin, "'");
				switch origin {
					case Some(v): definition += "\n" + v;
					case None:
				}
				definition;
			},
			textEdit: {
				newText: name,
				range: data.replaceRange
			}
		};

		if (data.mode.kind == Pattern) {
			var field = printer.printEnumField(field, item.type, true, false);
			field = maybeInsertPatternColon(field, data);
			result.textEdit.newText = field;
			result.insertTextFormat = Snippet;
			result.command = TriggerParameterHints;
		}

		return result;
	}

	function createTypeCompletionItem(type:DisplayModuleType, data:CompletionContextData):Null<CompletionItem> {
		if (!data.isResolve && type.meta.hasMeta(Deprecated)) {
			return null;
		}

		var isImportCompletion = data.mode.kind == Import || data.mode.kind == Using;
		var importConfig = context.config.user.codeGeneration.imports;
		var autoImport = importConfig.enableAutoImports;
		if (isImportCompletion || type.path.importStatus == Shadowed) {
			autoImport = false; // need to insert the qualified name
		}

		var dotPath = new DisplayPrinter(PathPrinting.Always).printPath(type.path); // pack.Foo | pack.Foo.SubType
		if (isExcluded(dotPath)) {
			return null;
		}
		var unqualifiedName = type.path.typeName; // Foo | SubType
		var containerName = if (dotPath.contains(".")) dotPath.untilLastDot() else ""; // pack | pack.Foo

		var pathPrinting = if (isImportCompletion) Always else Qualified;
		var qualifiedName = new DisplayPrinter(pathPrinting).printPath(type.path); // unqualifiedName or dotPath depending on importStatus

		var item:CompletionItem = {
			label: unqualifiedName + if (containerName == "") "" else " - " + dotPath,
			kind: getKindForModuleType(type),
			textEdit: {
				range: data.replaceRange,
				newText: if (autoImport) unqualifiedName else qualifiedName
			},
			sortText: unqualifiedName
		};

		if (isImportCompletion) {
			item.textEdit.newText = maybeInsert(item.textEdit.newText, ";", data.lineAfter);
		} else if (importConfig.enableAutoImports && type.path.importStatus == Unimported) {
			var edit = ImportHelper.createImportsEdit(data.doc, data.importPosition, [dotPath], importConfig.style);
			item.additionalTextEdits = [edit];
		}

		if (snippetSupport) {
			switch data.mode.kind {
				case TypeHint | Extends | Implements | StructExtension if (type.hasMandatoryTypeParameters()):
					item.textEdit.newText += "<$1>";
					item.insertTextFormat = Snippet;
					item.command = TriggerSuggest;
				case _:
			}
		}

		if (data.mode.kind == StructExtension && data.mode.args != null) {
			var completionData:StructExtensionCompletion = data.mode.args;
			if (!completionData.isIntersectionType) {
				item.textEdit.newText = maybeInsert(item.textEdit.newText, ",", data.lineAfter);
			}
		}

		if (type.params != null) {
			item.detail = printTypeDetail(type, containerName);
		}

		handleDeprecated(item, type.meta);
		return item;
	}

	function getKindForModuleType(type:DisplayModuleType):CompletionItemKind {
		return switch type.kind {
			case Class: Class;
			case Interface: Interface;
			case Enum: Enum;
			case Abstract: Class;
			case EnumAbstract: Enum;
			case TypeAlias: Interface;
			case Struct: Struct;
		}
	}

	function formatDocumentation(doc:String):Null<EitherType<String, MarkupContent>> {
		if (doc == null) {
			return null;
		}
		if (markdownSupport) {
			return {
				kind: MarkupKind.MarkDown,
				value: DocHelper.markdownFormat(doc)
			};
		}
		return DocHelper.extractText(doc);
	}

	function printTypeDetail(type:DisplayModuleType, containerName:String):String {
		var detail = printer.printEmptyTypeDefinition(type) + "\n";
		switch type.path.importStatus {
			case Imported:
				detail += "(imported)";
			case Unimported:
				detail += "Auto-import from '" + containerName + "'";
			case Shadowed:
				detail += "(shadowed)";
		}
		return detail;
	}

	function createPackageCompletionItem(pack:Package, data:CompletionContextData):Null<CompletionItem> {
		var path = pack.path;
		var dotPath = path.pack.join(".");
		if (isExcluded(dotPath)) {
			return null;
		}
		var text = if (data.mode.kind == Field) path.pack[path.pack.length - 1] else dotPath;
		return {
			label: text,
			kind: Module,
			detail: 'package $dotPath',
			textEdit: {
				newText: maybeInsert(text, ".", data.lineAfter),
				range: data.replaceRange
			},
			command: TriggerSuggest
		};
	}

	function createKeywordCompletionItem(keyword:Keyword, data:CompletionContextData):CompletionItem {
		var item:CompletionItem = {
			label: keyword.name,
			kind: Keyword,
			textEdit: {
				newText: keyword.name,
				range: data.replaceRange
			}
		}

		if (data.mode.kind == TypeRelation || keyword.name == New || keyword.name == Inline) {
			item.command = TriggerSuggest;
		}
		if (data.mode.kind == TypeDeclaration) {
			switch keyword.name {
				case Import | Using | Final | Extern | Private:
					item.command = TriggerSuggest;
				case _:
			}
		}

		inline function maybeAddSpace() {
			item.textEdit.newText = maybeInsert(item.textEdit.newText, " ", data.lineAfter);
		}

		switch keyword.name {
			case Extends | Implements:
				item.textEdit.newText += " ";
			// TODO: make it configurable for these, since not all code styles want spaces there
			case Else | Do | Switch:
				maybeAddSpace();
			case If | For | While | Catch:
				if (snippetSupport) {
					item.insertTextFormat = Snippet;
					item.textEdit.newText = '${keyword.name} ($1)';
				} else {
					maybeAddSpace();
				}
			// do nothing for these, you might not want a space after
			case Break | Cast | Continue | Default | Return | Package:
			// assume a space is needed for all the rest
			case _:
				maybeAddSpace();
		}

		return item;
	}

	function createLocalCompletionItem<T>(item:DisplayItem<Dynamic>, data:CompletionContextData):Null<CompletionItem> {
		var local:DisplayLocal<T> = item.args;
		if (local.name == "_") {
			return null; // naming vars "_" is a common convention for ignoring them
		}
		return {
			label: local.name,
			kind: if (local.origin == LocalFunction) Method else Variable,
			detail: {
				var type = printer.printLocalDefinition(local, item.type);
				var origin = printer.printLocalOrigin(local.origin);
				'$type \n($origin)';
			}
		};
	}

	function createModuleCompletionItem(module:Module, data:CompletionContextData):Null<CompletionItem> {
		var path = module.path;
		var dotPath = path.pack.concat([path.moduleName]).join(".");
		return if (isExcluded(dotPath)) {
			null;
		} else {
			{
				label: path.moduleName,
				kind: Folder,
				detail: 'module $dotPath'
			}
		}
	}

	function createLiteralCompletionItem<T>(item:DisplayItem<Dynamic>, data:CompletionContextData):CompletionItem {
		var literal:DisplayLiteral<T> = item.args;
		var result:CompletionItem = {
			label: literal.name,
			kind: Keyword,
			detail: printer.printType(item.type)
		};
		switch (literal.name) {
			case "null" | "true" | "false":
				result.textEdit = {
					range: data.replaceRange,
					newText: maybeInsertPatternColon(literal.name, data)
				};
			case _:
		}
		return result;
	}

	function maybeInsert(text:String, token:String, lineAfter:String):String {
		return if (lineAfter.charAt(0) == token.charAt(0)) text else text + token;
	}

	function maybeInsertPatternColon(text:String, data:CompletionContextData):String {
		var info:PatternCompletion<Dynamic> = data.mode.args;
		if (info == null || info.isOutermostPattern) {
			return maybeInsert(text, ":", data.lineAfter);
		}
		return text;
	}

	function handleDeprecated(item:CompletionItem, meta:JsonMetadata) {
		if (deprecatedSupport && meta.hasMeta(Deprecated)) {
			item.deprecated = true;
		}
	}

	function isExcluded(dotPath:String):Bool {
		var excludes = context.config.user.exclude;
		if (excludes == null) {
			return false;
		}
		for (exclude in excludes) {
			if (dotPath.startsWith(exclude)) {
				return true;
			}
		}
		return false;
	}
}
