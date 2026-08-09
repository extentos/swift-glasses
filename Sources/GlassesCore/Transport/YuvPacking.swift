import Accelerate
import Foundation

/// Normalises a camera buffer's luma + chroma planes into tightly packed I420.
///
/// Deliberately NOT gated on `os(iOS)` and deliberately free of CoreVideo: the
/// packing rules are where the bugs live, and this way they are testable under
/// `swift test` on macOS, which compiles out every `#if os(iOS)` path.
///
/// Two things have to be normalised, and neither is discoverable by a consumer
/// because `VideoFrame` carries no stride or format field:
///
/// 1. **Stride.** CoreVideo aligns rows to a 16-byte boundary, so a plane's
///    `bytesPerRow` is usually wider than its pixel width (504 -> 512).
/// 2. **Chroma layout.** Meta hardware delivers NV12 — two planes, with U and V
///    interleaved in the second. Android and the browser simulator both deliver
///    three-plane I420, which is what the capability guide documents. NV12 and
///    I420 are the same total size, so a size check cannot tell them apart: a
///    consumer following the docs gets a correctly-sized buffer and garbage
///    colour, with no error at any layer.
enum YuvPacking {

    /// Where the chroma samples live in the source buffer.
    enum ChromaSource {
        /// Two planes, U and V interleaved (NV12) — Meta hardware.
        case interleaved(uv: UnsafeRawPointer, stride: Int)
        /// Three planes, U then V (I420) — Android and the browser simulator.
        case planar(u: UnsafeRawPointer, uStride: Int, v: UnsafeRawPointer, vStride: Int)
    }

    /// Packed I420: Y (w*h), then U, then V (each w/2 * h/2).
    /// Always exactly `width * height * 3 / 2` bytes.
    static func packToI420(
        y: UnsafeRawPointer,
        yStride: Int,
        chroma: ChromaSource,
        width: Int,
        height: Int
    ) -> Data {
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        var out = Data()
        out.reserveCapacity(width * height * 3 / 2)

        appendPlane(to: &out, base: y, stride: yStride, width: width, height: height)

        switch chroma {
        case let .planar(u, uStride, v, vStride):
            appendPlane(to: &out, base: u, stride: uStride, width: chromaWidth, height: chromaHeight)
            appendPlane(to: &out, base: v, stride: vStride, width: chromaWidth, height: chromaHeight)

        case let .interleaved(uv, uvStride):
            // vImage rather than a per-pixel loop: this runs on every frame and
            // a 252x448 chroma plane is ~113k iterations.
            let count = chromaWidth * chromaHeight
            var u = [UInt8](repeating: 0, count: count)
            var v = [UInt8](repeating: 0, count: count)
            u.withUnsafeMutableBytes { uRaw in
                v.withUnsafeMutableBytes { vRaw in
                    var uBuf = vImage_Buffer(
                        data: uRaw.baseAddress, height: vImagePixelCount(chromaHeight),
                        width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    var vBuf = vImage_Buffer(
                        data: vRaw.baseAddress, height: vImagePixelCount(chromaHeight),
                        width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    withUnsafePointer(to: &uBuf) { uPtr in
                        withUnsafePointer(to: &vBuf) { vPtr in
                            var dests: [UnsafePointer<vImage_Buffer>?] = [uPtr, vPtr]
                            var srcs: [UnsafeRawPointer?] = [uv, uv.advanced(by: 1)]
                            // srcStrideBytes 2: U and V alternate byte by byte.
                            _ = vImageConvert_ChunkyToPlanar8(
                                &srcs, &dests, 2, 2,
                                vImagePixelCount(chromaWidth), vImagePixelCount(chromaHeight),
                                uvStride, vImage_Flags(kvImageDoNotTile))
                        }
                    }
                }
            }
            out.append(contentsOf: u)
            out.append(contentsOf: v)
        }
        return out
    }

    /// Copies a plane row by row at its pixel WIDTH, dropping any row padding.
    private static func appendPlane(
        to out: inout Data, base: UnsafeRawPointer, stride: Int, width: Int, height: Int
    ) {
        if stride == width {
            out.append(Data(bytes: base, count: width * height))
            return
        }
        for row in 0..<height {
            out.append(Data(bytes: base.advanced(by: row * stride), count: width))
        }
    }
}
