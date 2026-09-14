# Built-in JIT on iOS 26 and later

Built-in JIT runs StikJIT in an app extension. Enable it in Settings > Launch
Support when using standalone Iridium. Iridium now targets iOS 26 or later for
this build. It also requires debugging permission, a valid remote-pairing file,
and a connected LocalDevVPN.

Upstream StikJIT documents its helper framework for iOS 17.4 or later and its
current integration guide explicitly covers the iOS 26 JIT protocol. Iridium
keeps a higher iOS 26 floor because this app's current TXM/SPTM integration and
release build are scoped to iOS 26 and later rather than claiming support for
every older StikJIT-compatible system.

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
Wine. A readiness message alone does not establish game compatibility.

Use the error shown by the app to correct pairing, VPN, permission, or helper
connection failures. Do not terminate a helper that may own a stopped host thread.

## Build and validation

Use the repository build instructions in [setup](setup.md) and the
[IPA workflow](../../docs/actions-ipa.md). Run
`apps/ios/BuiltinJIT/Tests/check.sh` against the resulting app bundle.
The checks cover pairing validation, XPC decoding, the initial handshake,
launch recovery, iOS 26 deployment metadata, and helper packaging.

No physical iOS 26 device validation is implied by these build checks. Attachment,
TXM/SPTM executable-region preparation, game startup, and rendered gameplay still
need physical-device testing when hardware is available.

## Sources and notices

Pinned sources and component notices are recorded in
[StikJITNotices/SOURCES.md](../apps/ios/BuiltinJIT/StikJITNotices/SOURCES.md).
Preserve the MPL, GPL, AGPL, and dependency notices that apply to distributed
components. Follow the repository's source and binary distribution checks.
