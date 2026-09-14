"""Run the helper's actual bootstrap against a local anonymous XPC listener."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'Helper/JITRequestHandler.swift').read_text()
body = source[source.index('    func beginRequest('):source.index('\n    func enable(')]
program = '''import Foundation
@objc protocol JITHost { func preparation(_ stage: String) }
@objc protocol JITWorker { func enable(_ pid: Int32, pairing: Data) }
final class Context {
 var inputItems: [Any] = []
 var cancelled = false
 func cancelRequest(withError error: Error) { cancelled = true }
}
typealias NSExtensionContext = Context
final class Helper: NSObject, JITWorker {
 var context: Context?
 var connection: NSXPCConnection?
 var host: JITHost?
 func enable(_ pid: Int32, pairing: Data) {}
''' + body + '''
}
final class Host: NSObject, JITHost, NSXPCListenerDelegate {
 var connections: [NSXPCConnection] = []
 var received = false
 func preparation(_ stage: String) { DispatchQueue.main.async { self.received = !stage.isEmpty } }
 func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
  connection.exportedInterface = NSXPCInterface(with: JITHost.self)
  connection.exportedObject = self
  connection.remoteObjectInterface = NSXPCInterface(with: JITWorker.self)
  connections.append(connection)
  connection.resume()
  return true
 }
}
let host = Host()
let listener = NSXPCListener.anonymous()
listener.delegate = host
listener.resume()
let context = Context()
let item = NSExtensionItem()
item.userInfo = ["IridiumJITEndpoint": listener.endpoint]
context.inputItems = [item]
let helper = Helper()
helper.beginRequest(with: context)
let deadline = Date().addingTimeInterval(3)
while !host.received && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
assert(host.received, "Helper must send the first message; resume alone leaves the host waiting")
let bad = Context()
Helper().beginRequest(with: bad)
assert(bad.cancelled)
helper.connection?.invalidate()
for connection in host.connections { connection.invalidate() }
listener.invalidate()
print("PASS: real XPC bootstrap handshake and missing-endpoint rejection")
'''
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / 'check.swift'
    p.write_text(program)
    subprocess.run(['xcrun', 'swiftc', str(p), '-o', str(p.with_suffix(''))], check=True)
    subprocess.run([str(p.with_suffix(''))], check=True)
