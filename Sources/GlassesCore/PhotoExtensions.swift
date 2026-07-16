import Foundation
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

// Photo.loadImage — closes F-R2-6 on the iOS side. Mirrors the Android
// counterpart in glasses-core/.../PhotoExtensions.kt.
//
// `Photo.uri` is an optional `String` (the core type, post Phase 2.0); the
// scheme still varies across transports — `file://` from RealMeta and
// LocalSim, `data:` (base64-inlined image) from BrowserSim. SwiftUI's
// `AsyncImage` works for `https://` but not for in-app file:// or data:
// URLs without a custom loader. Every consumer ended up writing the same
// branch-on-scheme bridge — ship it once.
//
// Decoding runs on a detached high-priority Task because the data-URI
// branch base64-decodes a potentially-1MB payload and ImageIO is
// blocking. Returns nil on unrecognized scheme, missing file, or
// decode failure.

extension Photo {
    /// Decode this photo into a platform image (`UIImage` on iOS,
    /// `NSImage` on macOS) regardless of which transport produced it.
    /// Handles `file://` and `data:` URLs uniformly. Returns nil if the
    /// scheme is unrecognized, the file doesn't exist, or decode fails.
    public func loadImage() async -> PlatformImage? {
        guard let uri = self.uri, let url = URL(string: uri) else { return nil }
        let box = await Task.detached(priority: .userInitiated) { () -> _PlatformImageBox in
            switch url.scheme {
            case "file":
                return _PlatformImageBox(image: PlatformImage(contentsOfFile: url.path))
            case "data":
                let s = url.absoluteString
                guard let comma = s.firstIndex(of: ",") else { return _PlatformImageBox(image: nil) }
                let payload = String(s[s.index(after: comma)...])
                guard let data = Data(base64Encoded: payload) else { return _PlatformImageBox(image: nil) }
                return _PlatformImageBox(image: PlatformImage(data: data))
            default:
                return _PlatformImageBox(image: nil)
            }
        }.value
        return box.image
    }
}

// PlatformImage (UIImage on iOS, NSImage on macOS) is non-Sendable per
// the SDK's nullability annotations. Decoding has to cross the detached
// Task boundary, so we wrap in a single-property `@unchecked Sendable`
// box. This is sound because the box's only field is the freshly-decoded
// image which has no shared mutable state at the call site.
private struct _PlatformImageBox: @unchecked Sendable {
    let image: PlatformImage?
}
