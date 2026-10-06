import AppKit
import CoreImage
import ImageIO

enum LauncherImageRenderer {
    static func rasterize(_ image: NSImage, size: NSSize, pixelScale: CGFloat, fill: Bool) -> NSImage? {
        let width = max(1, Int((size.width * pixelScale).rounded()))
        let height = max(1, Int((size.height * pixelScale).rounded()))
        guard image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let ratioX = CGFloat(width) / image.size.width
        let ratioY = CGFloat(height) / image.size.height
        let ratio = fill ? max(ratioX, ratioY) : min(ratioX, ratioY)
        let rect = NSRect(x: (CGFloat(width) - image.size.width * ratio) / 2,
                          y: (CGFloat(height) - image.size.height * ratio) / 2,
                          width: image.size.width * ratio, height: image.size.height * ratio)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard bitmap.cgImage != nil else { return nil }
        let result = NSImage(size: size)
        bitmap.size = size
        result.addRepresentation(bitmap)
        return result
    }
}

/// A static, preblurred wallpaper texture. Rendering happens off the main thread
/// once per wallpaper revision/display size and never during page animation.
enum LauncherWallpaperCache {
    private static let images = NSCache<NSString, NSImage>()
    private static let lock = NSLock()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(for url: URL, size: NSSize) -> NSImage? {
        let revision = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(revision)|\(Int(size.width))x\(Int(size.height))" as NSString
        lock.lock()
        defer { lock.unlock() }
        if let image = images.object(forKey: key) { return image }
        let scale = min(1, 1280 / max(size.width, size.height))
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let original = NSImage(cgImage: thumbnail, size: .zero)
        guard let raster = LauncherImageRenderer.rasterize(original, size: size, pixelScale: scale, fill: true),
              let source = (raster.representations.first as? NSBitmapImageRep)?.cgImage else { return nil }
        defer { context.clearCaches() }
        let input = CIImage(cgImage: source)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 30 * scale])
            .cropped(to: input.extent)
        guard let cgImage = context.createCGImage(output, from: input.extent) else { return nil }
        let result = NSImage(size: size)
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = size
        result.addRepresentation(representation)
        images.setObject(result, forKey: key, cost: source.width * source.height * 4)
        images.countLimit = 1
        images.totalCostLimit = 8 * 1024 * 1024
        return result
    }
}
