# Extentos iOS SDK (`swift-glasses`)

The Swift Package for [Extentos](https://extentos.com) — smart-glasses
primitives (camera, audio, voice assistant, connection UI, browser simulator)
for native iOS apps. Meta Ray-Ban glasses are supported in production today.

> **This is a distribution repo.** Source of truth is the Extentos monorepo;
> the contents here are published by its release pipeline. Please don't open
> PRs against this repo — report issues via [extentos.com/docs](https://extentos.com/docs).

## Install

Xcode: *File → Add Package Dependencies…* → `https://github.com/extentos/swift-glasses`

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/extentos/swift-glasses", from: "1.7.0"),
],
```

Products: `GlassesCore` (the SDK), `GlassesUI` (drop-in connection page),
`GlassesDebug` (debug console — debug builds only), `GlassesLifecycle`,
`GlassesTesting`.

## Requirements

- iOS 16+, Swift tools 6.0 (the core bindings compile in Swift 5 language mode)
- Meta Wearables Device Access Toolkit ≥ 0.8.0 (resolved automatically)
- Per-developer Meta DAT credentials — see the
  [getting-started guide](https://extentos.com/docs/getting-started/ios)

## Versioning

Versions are in lockstep with the Android SDK (`com.extentos:glasses` on Maven
Central): the same version number ships the same shared core on both platforms.

The fastest path to a working integration is agent-driven: install
`@extentos/mcp-server` in your AI coding agent and let it scaffold the app —
see [extentos.com/docs](https://extentos.com/docs/getting-started/with-agent).
