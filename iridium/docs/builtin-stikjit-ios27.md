# Built-in JIT on iOS 18 and later

Built-in JIT runs StikJIT in an app extension. Enable it in Settings > Launch
Support when using standalone Iridium. Iridium targets iOS 18 or later for this
build. It also requires debugging permission, a valid remote-pairing file, and
a connected LocalDevVPN.

Upstream StikJIT documents its helper framework for iOS 17.4 or later. Iridium
keeps an iOS 18 floor because the main app, Madeira runtime, and native iOS build
are already scoped to iOS 18 or later. On devices where TXM/SPTM is absent,
attaching and detaching the debugger is sufficient to enable JIT. Where TXM/SPTM
is present, the existing iOS 26 breakpoint protocol remains responsible for
preparing executable regions before they are used.

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
validation to the system. The Madeira script implements the iOS 26 breakpoint
protocol used for TXM/SPTM executable-region preparation. It reports attachment
readiness; the host then prepares executable memory and detaches before starting
Wine. On systems without TXM/SPTM, debugger attachment and detach do not require
that executable-region preparation protocol. A readiness message alone does not
establish game compatibility.

Use the error shown by the app to correct pairing, VPN, permission, or helper
connection failures. Do not terminate a helper that may own a stopped host thread.

## Build and validation

Use the repository build instructions in [setup](setup.md) and the
[IPA workflow](../../docs/actions-ipa.md). Run
`apps/ios/BuiltinJIT/Tests/check.sh` against the resulting app bundle.
The checks cover pairing validation, XPC decoding, the initial handshake,
launch recovery, iOS 18 deployment metadata, and helper packaging.

No physical-device compatibility is implied by these build checks. Built-in JIT
still needs device validation on the supported iOS 18-25 path and on iOS 26+
TXM/SPTM devices, including helper launch, debugger attachment, executable-region
preparation where required, Wine startup, and rendered gameplay.

## Sources and notices

Pinned sources and component notices are recorded in
[StikJITNotices/SOURCES.md](../apps/ios/BuiltinJIT/StikJITNotices/SOURCES.md).
Preserve the MPL, GPL, AGPL, and dependency notices that apply to distributed
components. Follow the repository's source and binary distribution checks.
