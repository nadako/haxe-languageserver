package haxeLanguageServer.features;

import haxe.extern.EitherType;
import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types.NoData;

class GotoDefinitionFeature {
    var context:Context;

    public function new(context) {
        this.context = context;
        context.protocol.onRequest(Methods.GotoDefinition, onGotoDefinition);
    }

    public function onGotoDefinition(params:TextDocumentPositionParams, token:CancellationToken, resolve:EitherType<Location,Array<Location>>->Void, reject:ResponseError<NoData>->Void) {
        var doc = context.documents.get(params.textDocument.uri);
        var bytePos = context.displayOffsetConverter.characterOffsetToByteOffset(doc.content, doc.offsetAt(params.position));
        var args = ["--display", '${doc.fsPath}@$bytePos@position'];
        context.callDisplay(args, doc.content, token, function(r) {
            switch (r) {
                case DCancelled:
                    resolve(null);
                case DResult(data):
                    var xml = try Xml.parse(data).firstElement() catch (_:Any) null;
                    if (xml == null) return reject(ResponseError.internalError("Invalid xml data: " + data));

                    var positions = [for (el in xml.elements()) el.firstChild().nodeValue];
                    if (positions.length == 0)
                        return resolve([]);

                    var results = [];
                    for (pos in positions) {
                        var location = HaxePosition.parse(pos, doc, null, context.displayOffsetConverter); // no cache because this right now only returns one position
                        if (location == null) {
                            trace("Got invalid position: " + pos);
                            continue;
                        }
                        results.push(location);
                    }

                    resolve(results);
            }
        }, function(error) reject(ResponseError.internalError(error)));
    }
}
