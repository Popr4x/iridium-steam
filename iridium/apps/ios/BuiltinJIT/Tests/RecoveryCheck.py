"""Exercise the production helper completion without starting an iOS extension."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Host/BuiltinJIT.swift').read_text()
start = source.index('            guard let self, !self.operationFinished')
end = source.index('\n        }\n        let deadline', start)
completion = source[start:end]
adapter = (root.parent / 'MadeiraSupport/MadeiraRuntimeAdapter.swift').read_text()
selection = adapter.split('var useBuiltinJIT = ', 1)[1].splitlines()[0]
program = '''import Foundation
var debugged = false
func jit_check_debugged() -> Bool { debugged }
class JITWorker { var enabled = false; func enable(_ pid: Int32, pairing: Data) { enabled = true } }
class Launcher { var failureHandler: (() -> Void)?; var invalidated = false; func invalidate() { invalidated = true } }
class Group { var leaves = 0; func leave() { leaves += 1; assert(leaves == 1) } }
enum RuntimeLogCapture { static func writeLine(_ s: String) {} }
class Host {
 var listening = false, operationFinished = false
 var worker: JITWorker?
 var deadline: DispatchWorkItem?
 var onListening: (() -> Void)?
 let detached = Group()
 var launcher: Launcher? = Launcher()
 var errors = 0
 func finished(_ message: String) { errors += 1 }
 func complete(_ worker: Any?, onUnavailable: (() -> Void)?) {
 let data = Data()
 let error: NSError? = nil
 let callback: () -> Void = { [weak self] in
''' + completion + '''
 }
 callback()
 }
}
var fallbacks = 0
let host = Host()
host.complete(nil) { fallbacks += 1 }
host.complete(nil) { fallbacks += 1 }
assert(fallbacks == 1 && host.detached.leaves == 1 && host.launcher!.invalidated)
let attached = Host()
debugged = true
attached.complete(nil) { fallbacks += 1 }
assert(fallbacks == 1 && attached.errors == 1 && !attached.launcher!.invalidated)
debugged = false
let connected = Host()
let worker = JITWorker()
connected.complete(worker) { fallbacks += 1 }
assert(worker.enabled)
connected.complete(nil) { fallbacks += 1 }
assert(fallbacks == 1 && connected.errors == 1)
enum BuiltinJIT { static var selected = true }
enum StikJITHelper { static var persistentScriptRequested = true }
func selected() -> Bool { ''' + selection + ''' }
assert(!selected()) // A restarted external handoff must not enter built-in JIT again.
StikJITHelper.persistentScriptRequested = false
assert(selected())
print("JIT recovery: bootstrap failure, duplicate callback, attached debugger, connected worker, restart passed")
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'check.swift'
    path.write_text(program)
    subprocess.run(['xcrun', 'swift', str(path)], check=True)
