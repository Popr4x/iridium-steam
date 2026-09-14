# Compile the actual resume block without DEBUG; use macOS for the host check.
from pathlib import Path
import subprocess,tempfile
p=Path(__file__).resolve().parents[1] / 'Iridium/AppViewModel.swift'
s=p.read_text();start=s.index('                #if os(iOS)',s.index('        if autoRefresh {'));end=s.index('            }\n        }\n    }',start)
body=s[start:end].replace('#if os(iOS)', '#if os(macOS)').replace('UserDefaults.standard', 'defaults')
source='''import Foundation
struct GameRecord { let title: String }
enum MadeiraRuntimeAdapter { static let enabled = true }
enum RuntimeLogCapture { static func writeLine(_ value: String) {} }
func check(_ requested: String?, games: [GameRecord], expected: Int) {
 let defaults = UserDefaults(suiteName: "IridiumLaunchResumeCheck")!
 let key = "IridiumPendingMadeiraLaunchTitle"
 defaults.set(requested, forKey: key)
 var launches = 0
 var activityStatusMessage = ""
 func recordLaunchPreparation(for game: GameRecord) { launches += 1 }
 func restore() {
'''+body+'''
 }
 restore()
 assert(launches == expected)
 if requested != nil && expected == 0 {
  assert(UserDefaults.standard.string(forKey: key) == nil)
  assert(!activityStatusMessage.isEmpty)
 }
 defaults.removeObject(forKey: key)
}
check("Test", games: [.init(title: "Test")], expected: 1)
check("Removed", games: [.init(title: "Test")], expected: 0)
check(nil, games: [.init(title: "Test")], expected: 0)
print("Release handoff: pending, removed, and absent requests passed")
'''
with tempfile.TemporaryDirectory() as tmp:
 src=Path(tmp)/'check.swift';src.write_text(source)
 subprocess.run(['xcrun','swift','-D','MADEIRA_RUNTIME',str(src)],check=True)
