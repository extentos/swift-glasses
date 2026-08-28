# Extentos iOS SDK (`swift-glasses`)

The Swift Package for [Extentos](https://extentos.com) — smart-glasses
primitives for native iOS apps: connection UI, camera capture and raw frames,
microphone and transcription, speech, a voice assistant runtime, on-glasses
display, and a browser simulator you can develop against without hardware.
Meta Ray-Ban glasses are supported in production today.

> **This is a distribution repo.** Source of truth is the Extentos monorepo;
> the contents here are published by its release pipeline. Please don't open
> PRs against this repo. Bug reports are welcome: see [Issues](#issues).

## Install

Xcode: *File → Add Package Dependencies…* → `https://github.com/extentos/swift-glasses`,
dependency rule **Up to Next Major Version** starting at `2.0.0`.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/extentos/swift-glasses", from: "2.7.0"),
],
```

Then link the products your target uses:

| Product | What it is |
|---|---|
| `GlassesCore` | The SDK — connection, camera, audio, voice, assistant, display, toggles, telemetry |
| `GlassesUI` | The drop-in SwiftUI connection page (`ExtentosConnectionPage`) and theming |
| `GlassesLocal` | On-device text models for the local tier. Optional — but its MLX dependency is what sets the package's iOS 17 floor for every product |
| `GlassesLocalVoice` | On-device speech (Kokoro) for the local tier. Optional |
| `GlassesDebug` | Scaffolding today — the debug-console API surface is reserved |
| `GlassesLifecycle` | Scaffolding today — the `extentosListening` scene-phase modifier is a passthrough |
| `GlassesTesting` | Scaffolding today — stub the protocols yourself for unit tests |

The compiled Rust core (`extentos_coreFFI.xcframework`) is a binary target that SPM
resolves automatically from the matching GitHub Release by URL and checksum — device
arm64, a universal arm64/x86_64 simulator slice, and macOS arm64. There is nothing to
download or verify by hand.

## Requirements

| Requirement | Value |
|---|---|
| Deployment target | **iOS 17.0+** / macOS 14.0+, whichever products you link. SwiftPM applies a package's platform floor package-wide, so `GlassesLocal`'s MLX dependency raises it for `GlassesCore` too. An iOS 16 target fails to resolve. |
| Swift toolchain | Swift 6 (`swift-tools-version: 6.0`); `GlassesCore` compiles in Swift 5 language mode |
| Meta DAT | `meta-wearables-dat-ios` 0.8.x, resolved automatically. The range is deliberately capped below 0.9.0 — a published SDK cannot let a vendor's minor release decide whether it builds. |
| Meta credentials | Per-developer, not federated — see the [getting-started guide](https://extentos.com/docs/getting-started/ios) |

Other vendors (Brilliant Labs, Android XR) are in preview at varying stages and are
documented per-vendor at [extentos.com/docs/vendors](https://extentos.com/docs/vendors).
A Meta-only app inherits nothing from them.

## Versioning

Versions are in lockstep with the Android SDK (`com.extentos:glasses` on Maven
Central): the same version number ships the same shared core on both platforms.
Release notes are on the [releases page](https://github.com/extentos/swift-glasses/releases).

## Issues

iOS SDK bugs and questions belong here. Android SDK issues go to
[extentos/android-glasses](https://github.com/extentos/android-glasses), and
MCP server, simulator or docs issues to
[extentos/mcp-server](https://github.com/extentos/mcp-server).

Security issues are the exception: never file those publicly. Email
hello@extentos.com with the subject prefix `[SECURITY]`, see the
[security policy](https://github.com/extentos/.github/blob/main/SECURITY.md).

Before filing, `npx @extentos/mcp-server@latest whoami` prints the versions and
install state a report needs. Full routing and the bug-report checklist:
[extentos.com/docs/resources/support](https://extentos.com/docs/resources/support).

The fastest path to a working integration is agent-driven: install
`@extentos/mcp-server` in your AI coding agent and let it scaffold the app —
see [extentos.com/docs](https://extentos.com/docs/getting-started/with-agent).
