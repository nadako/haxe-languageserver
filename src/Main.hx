import js.Node.process;
import jsonrpc.node.MessageReader;
import jsonrpc.node.MessageWriter;

class Main {
    static function main() {
        var reader = new MessageReader(process.stdin);
        var writer = new MessageWriter(process.stdout);

        var proto = new vscode.Protocol(writer.write);

        proto.onInitialize = function(params, resolve, reject) {
            proto.sendShowMessage({type: Info, message: "Welcome to Haxe!"});
            resolve({
                capabilities: {
                    textDocumentSync: Full,
                    completionProvider: {
                        triggerCharacters: ["."]
                    }
                }
            });
        };

        proto.onCompletion = function(params, resolve, reject) {
            resolve([{label: "foo"}, {label: "bar"}]);
        };

        reader.listen(proto.handleMessage);
    }
}