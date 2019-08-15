package haxeLanguageServer.features.completion;

import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types.NoData;
import haxeLanguageServer.helper.TypeHelper.prepareSignature;
import haxeLanguageServer.helper.TypeHelper.parseDisplayType;
import haxe.extern.EitherType;
import String.fromCharCode;

class CompletionFeatureLegacy {
	final context:Context;
	final contextSupport:Bool;
	final formatDocumentation:(doc:String) -> EitherType<String, MarkupContent>;

	public function new(context, contextSupport, formatDocumentation) {
		this.context = context;
		this.contextSupport = contextSupport;
		this.formatDocumentation = formatDocumentation;
	}

	public function handle(params:CompletionParams, token:CancellationToken, resolve:CompletionList->Void, reject:ResponseError<NoData>->Void,
			doc:TextDocument, offset:Int, textBefore:String, _) {
		if (contextSupport && isInvalidCompletionPosition(params.context, textBefore)) {
			return resolve({items: [], isIncomplete: false});
		}
		var r = calculateCompletionPosition(textBefore, offset);
		var bytePos = context.displayOffsetConverter.characterOffsetToByteOffset(doc.content, r.pos);
		var args = ['${doc.uri.toFsPath()}@$bytePos' + (if (r.toplevel) "@toplevel" else "")];
		context.callDisplay(if (r.toplevel) "@toplevel" else "field completion", args, doc.content, token, function(result) {
			switch result {
				case DCancelled:
					resolve(null);
				case DResult(data):
					var xml = try Xml.parse(data).firstElement() catch (_:Any) null;
					if (xml == null)
						return reject.invalidXml(data);

					var items = if (r.toplevel) parseToplevelCompletion(xml, params.position, textBefore,
						doc) else parseFieldCompletion(xml, textBefore, params.position);
					resolve({items: items, isIncomplete: false});
			}
		}, reject.handler());
	}

	static final reCaseOrDefault = ~/\b(case|default)\b[^:]*:$/;

	static function isInvalidCompletionPosition(context:CompletionContext, text:String):Bool {
		return context.triggerCharacter == ":" && reCaseOrDefault.match(text);
	}

	static final reFieldPart = ~/(\.|@(:?))(\w*)$/;

	static function calculateCompletionPosition(text:String, index:Int):CompletionPosition {
		if (reFieldPart.match(text))
			return {
				pos: index - reFieldPart.matched(3).length,
				toplevel: false,
			};

		var whitespaceAmount = text.length - text.rtrim().length;
		return {
			pos: index - whitespaceAmount,
			toplevel: true,
		};
	}

	function parseToplevelCompletion(x:Xml, position:Position, textBefore:String, doc:TextDocument):Array<CompletionItem> {
		var result = [];
		var timers = [];
		for (el in x.elements()) {
			var kind = el.get("k");
			var type = el.get("t");
			var name = el.firstChild().nodeValue;

			if (kind == "local" && name == "_") {
				continue;
			}

			var item:CompletionItem = {label: name, detail: ""};

			var displayKind = toplevelKindToCompletionItemKind(kind, type);
			if (displayKind != null)
				item.kind = displayKind;

			if (isTimerDebugFieldCompletion(name)) {
				var info = name.split(":");
				timers.push(getTimerCompletionItem(info[0], info[1], position));
				continue;
			}

			var fullName = name;
			if (kind == "global")
				fullName = el.get("p") + "." + name;
			else if (kind == "type")
				fullName = el.get("p");

			if (type != null || fullName != name) {
				var parts = [];
				if (fullName != name)
					parts.push(fullName);
				if (type != null)
					parts.push(type); // todo format functions?
				item.detail = parts.join(" ");
			}

			var documentation = el.get("d");
			if (documentation != null)
				item.documentation = formatDocumentation(documentation);

			result.push(item);
		}
		sortTimers(timers);
		return result.concat(timers);
	}

	static function toplevelKindToCompletionItemKind(kind:String, type:String):CompletionItemKind {
		function isFunction()
			return type != null && parseDisplayType(type).match(DTFunction(_));

		return switch kind {
			case "local": if (isFunction()) Method else Variable;
			case "member" | "static": if (isFunction()) Method else Field;
			case "enum" | "enumabstract": Enum;
			case "global": Variable;
			case "type": Class;
			case "package": Module;
			case "literal": Keyword;
			case "timer": Value;
			default:
				trace("unknown toplevel item kind: " + kind);
				null;
		}
	}

	function parseFieldCompletion(x:Xml, textBefore:String, position:Position):Array<CompletionItem> {
		var result = [];
		var timers = [];
		var methods = new Map<String, {item:CompletionItem, overloads:Int}>();
		for (el in x.elements()) {
			var rawKind = el.get("k");
			var kind = fieldKindToCompletionItemKind(rawKind);
			var name = el.get("n");
			if (kind == Method && methods[name] != null) {
				// only show an overloaded method once
				methods[name].overloads++;
				continue;
			}

			var type = null, doc = null;
			inline function getOrNull(s)
				return if (s == "") null else s;
			for (child in el.elements()) {
				switch child.nodeName {
					case "t":
						type = getOrNull(child.firstChild().nodeValue);
					case "d":
						doc = getOrNull(child.firstChild().nodeValue);
				}
			}
			var textEdit = null;
			if (rawKind == "metadata") {
				name = name.substr(1); // remove the @
				// if there's already a colon, don't duplicate it
				reFieldPart.match(textBefore);
				if (reFieldPart.matched(2) == ":") {
					textEdit = {newText: name, range: {start: position.translate(0, -1), end: position}};
				}
			} else if (isTimerDebugFieldCompletion(name)) {
				timers.push(getTimerCompletionItem(name, type, position));
				continue;
			}
			var item:CompletionItem = {label: name};
			if (doc != null)
				item.documentation = formatDocumentation(doc);
			if (kind != null)
				item.kind = kind;
			if (type != null)
				item.detail = formatType(type, name, kind);
			if (textEdit != null)
				item.textEdit = textEdit;

			if (kind == Method) {
				methods[name] = {item: item, overloads: 0};
			}

			result.push(item);
		}

		for (method in methods) {
			var overloads = method.overloads;
			if (overloads > 0) {
				method.item.detail += ' (+$overloads overloads)';
			}
		}

		sortTimers(timers);
		return result.concat(timers);
	}

	static function sortTimers(items:Array<CompletionItem>) {
		items.sort(function(a, b) {
			var time1:Float = cast a.data;
			var time2:Float = cast b.data;
			if (time1 < time2)
				return 1;
			if (time1 > time2)
				return -1;
			return 0;
		});

		for (i in 0...items.length) {
			items[i].sortText = "_" + fromCharCode(65 + i);
		}
	}

	static function getTimerCompletionItem(name:String, time:String, position:Position):CompletionItem {
		// avert your eyes...
		var timeRegex = ~/([0-9.]*)s(?: \(([0-9]*)%\))?/;
		var seconds = 0.0;
		var percentage = "--";
		try {
			timeRegex.match(time);
			seconds = Std.parseFloat(timeRegex.matched(1));
			percentage = timeRegex.matched(2);
		} catch (e:Dynamic) {}

		var doc = null;
		if (name.startsWith("@TIME @TOTAL")) {
			name = "@Total time: " + time;
		} else {
			name = name.replace("@TIME ", '${percentage}% ');
			doc = seconds + "s";
		}

		return {
			label: name,
			kind: Value,
			documentation: {
				kind: MarkupKind.PlainText,
				value: doc
			},
			textEdit: {
				range: {start: position, end: position},
				newText: ""
			},
			data: seconds
		};
	}

	static inline function isTimerDebugFieldCompletion(name:String):Bool {
		return name.startsWith("@TIME") || name.startsWith("@TOTAL");
	}

	static function formatType(type:String, name:String, kind:CompletionItemKind):String {
		return switch kind {
			case Method: name + prepareSignature(type);
			default: type;
		}
	}

	static function fieldKindToCompletionItemKind(kind:String):CompletionItemKind {
		return switch kind {
			case "var": Field;
			case "method": Method;
			case "type": Class;
			case "package": Module;
			case "metadata": Function;
			case "timer": Value;
			default:
				trace("unknown field item kind: " + kind);
				null;
		}
	}
}

private typedef CompletionPosition = {
	var pos:Int;
	var toplevel:Bool;
}
