# Built-in JIT on iOS 27

Built-in JIT runs StikJIT in an app extension. Enable it in Settings > Launch
Support when using standalone Iridium. It requires iOS 27, debugging permission,
a valid remote-pairing file, and a connected LocalDevVPN.

Import the pairing file in Launch Support, connect LocalDevVPN, then play a game.
When using Iridium inside LiveContainer, use external StikDebug through
LiveContainer2.

## Implementation

The host launches `IridiumJITHelper.appex` and accepts an XPC connection only from
its extension process. The helper validates the target host process and sends
an initial connection message before attachment. StikJIT runs on a serial queue.

The pairing file is protected and excluded from backups. Its bytes pass over
XPC to a temporary protected file, which the helper removes after use. Pairing
contents must not appear in application logs.

The extension decoder permits `NSXPCListenerEndpoint` and delegates other class
validation to the system. The Madeira script reports attachment readiness;
the host then prepares executable memory and detaches before starting Wine.
A readiness message alone does not establish game compatibility.

Use the error shown by the app to correct pairing, VPN, permission, or helper
connection failures. Do not terminate a helper that may own a stopped host thread.

## Build and validation

Use the repository build instructions in [setup](setup.md) and the
[IPA workflow](../../docs/actions-ipa.md). Run
`apps/ios/BuiltinJIT/Tests/check.sh` against the resulting app bundle.
The checks cover pairing validation, XPC decoding, the initial handshake,
launch recovery, and helper packaging. Test attachment and game startup on the
target iOS version as well.

## Sources and notices

Pinned sources and component notices are recorded in
[StikJITNotices/SOURCES.md](../apps/ios/BuiltinJIT/StikJITNotices/SOURCES.md).
Preserve the MPL, GPL, AGPL, and dependency notices that apply to distributed
components. Follow the repository's source and binary distribution checks.
