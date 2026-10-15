//
//  AppleKittyPlaceholderImages.swift
//
//  Kitty unicode-placeholder images for the CoreGraphics draw path: decoded once, resampled once to
//  the size they are drawn at, and reused across frames.
//
//  Why this exists. The draw loop used to make a fresh `TTImage(data:)` per frame (the cache was a local
//  of the draw call) and draw the *whole* image once per placeholder cell, clipped to that cell. Cost
//  grew with the number of cells the image covers: a PlantUML diagram filling a 178×60 pane cost
//  ~120 ms per frame while scrolling past it (`KittyPlaceholderScrollBenchmark`), so holding a key
//  to scroll through an image dropped to single-digit frames per second.
//
//  Now: one decoded `CGImage` per `(imageId, revision)`, one resampled copy at the device-pixel size it
//  is shown at, and the caller draws one rectangle per run of consecutive cells (`KittyPlaceholderRun`)
//  with that copy — a 1:1 blit instead of a full resample per cell.
//
#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
import ImageIO

final class KittyPlaceholderImageCache {
    private struct Entry {
        let revision: UInt64
        let source: CGImage
        var scaled: (width: Int, height: Int, size: CGSize, space: CGColorSpace, image: TTImage)?
    }

    private var entries: [UInt32: Entry] = [:]

    /// The image for `imageId`, resampled to `pixelWidth × pixelHeight` device pixels and sized
    /// `size` points, decoding and resampling only when the stored image or the requested size changed.
    /// A `TTImage` so the platform draw call handles the context's orientation. nil = cannot decode.
    ///
    /// `colorSpace`: the destination's. Resampling straight into it (BGRA, premultiplied, the native
    /// layout) is what makes the per-frame draw a copy — otherwise CoreGraphics converts and resamples
    /// every run on every frame (`argb32_sample_argb32` + vImage colour conversion in a profile).
    func image(imageId: UInt32, stored: KittyGraphicsImage, pixelWidth: Int, pixelHeight: Int, size: CGSize,
               colorSpace: CGColorSpace) -> TTImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        var entry: Entry
        if let cached = entries[imageId], cached.revision == stored.revision {
            entry = cached
        } else {
            guard let source = Self.decode(stored.payload) else {
                entries[imageId] = nil
                return nil
            }
            entry = Entry(revision: stored.revision, source: source, scaled: nil)
        }
        if let scaled = entry.scaled, scaled.width == pixelWidth, scaled.height == pixelHeight, scaled.size == size,
           scaled.space == colorSpace {
            entries[imageId] = entry
            return scaled.image
        }
        let resampled = Self.resample(entry.source, width: pixelWidth, height: pixelHeight, colorSpace: colorSpace)
            ?? entry.source
        let drawable = TTImage(cgImage: resampled, size: size)
        entry.scaled = (pixelWidth, pixelHeight, size, colorSpace, drawable)
        entries[imageId] = entry
        return drawable
    }

    /// Drop entries for images the terminal no longer holds (deleted, evicted, reset), so the cache
    /// cannot outgrow the image store. A re-transmitted image is handled by the revision check in
    /// `image(…)`, not here.
    func prune(keeping state: KittyGraphicsState) {
        guard entries.count > 0 else { return }
        entries = entries.filter { id, _ in state.imagesById[id] != nil }
    }

    var count: Int { entries.count }

    /// The resampled copy of `imageId` the view draws — one image pixel per device pixel (nil = none yet)
    func scaledImage(imageId: UInt32) -> TTImage? {
        entries[imageId]?.scaled?.image
    }

    private static func decode(_ payload: KittyGraphicsPayload) -> CGImage? {
        switch payload {
        case .png(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        case .rgba(let bytes, let width, let height):
            guard width > 0, height > 0, bytes.count >= width * height * 4,
                  let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    private static func resample(_ image: CGImage, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        let space = colorSpace.model == .rgb ? colorSpace : CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
#endif
