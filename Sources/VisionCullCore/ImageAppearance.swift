import Foundation
#if os(macOS)
import CoreGraphics
import ImageIO
#endif

public struct ImageAppearance: Codable, Equatable, Sendable {
    /// Mean luma and 10th-to-90th percentile luma range in a small sRGB preview.
    public let brightness: Double
    public let contrast: Double
    public let saturation: Double
    /// Mean red minus mean blue in sRGB. This describes the palette, independent of camera white balance.
    public let warmth: Double
    public let shadowFraction: Double
    public let highlightFraction: Double
    public let palette: [String]
    public let edgeDetail: Double?

    var styleSuggestions: [String] {
        var tags = [String]()
        if brightness <= 0.30 { tags.append("Dark") }
        if brightness >= 0.67 { tags.append("Bright") }
        if contrast <= 0.22 { tags.append("Soft contrast") }
        if contrast >= 0.52 { tags.append("High contrast") }
        if saturation <= 0.08 { tags.append("Near monochrome") }
        else if saturation <= 0.22 { tags.append("Muted colors") }
        else if saturation >= 0.55 { tags.append("Vivid colors") }
        if warmth >= 0.10 { tags.append("Warm tones") }
        if warmth <= -0.10 { tags.append("Cool tones") }
        return tags
    }

    var moodSuggestions: [String] {
        if brightness <= 0.32 && contrast >= 0.42 { return ["Dramatic"] }
        if brightness >= 0.57 && saturation >= 0.55 { return ["Lively"] }
        if contrast <= 0.25 && saturation <= 0.25 { return ["Calm"] }
        if brightness <= 0.29 { return ["Subdued"] }
        return []
    }

    static func measure(premultipliedRGBA pixels: [UInt8], width: Int? = nil) -> ImageAppearance? {
        guard pixels.count.isMultiple(of: 4) else { return nil }
        var lumas = [Double]()
        var grid = [Double?](repeating: nil, count: pixels.count / 4)
        var saturation = 0.0
        var warmth = 0.0
        var shadows = 0
        var highlights = 0
        var colors: [Int: ColorBucket] = [:]

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3])
            guard alpha >= 128 else { continue }
            let red = min(1, Double(pixels[i]) / alpha)
            let green = min(1, Double(pixels[i + 1]) / alpha)
            let blue = min(1, Double(pixels[i + 2]) / alpha)
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            lumas.append(luma)
            grid[i / 4] = luma
            let peak = max(red, green, blue)
            if peak > 0 { saturation += (peak - min(red, green, blue)) / peak }
            warmth += red - blue
            if luma <= 0.05 { shadows += 1 }
            if luma >= 0.95 { highlights += 1 }
            let bucket = Int(red * 255) / 64 * 16 + Int(green * 255) / 64 * 4 + Int(blue * 255) / 64
            colors[bucket, default: ColorBucket()].add(red, green, blue)
        }

        guard !lumas.isEmpty else { return nil }
        let count = Double(lumas.count)
        let brightness = lumas.reduce(0, +) / count
        lumas.sort()
        let last = Double(lumas.count - 1)
        let contrast = lumas[Int((last * 0.9).rounded())] - lumas[Int((last * 0.1).rounded())]
        let palette = colors.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }.prefix(3).map { $0.value.hex }
        return ImageAppearance(
            brightness: brightness, contrast: contrast, saturation: saturation / count, warmth: warmth / count,
            shadowFraction: Double(shadows) / count, highlightFraction: Double(highlights) / count,
            palette: palette, edgeDetail: width.flatMap { detail(in: grid, width: $0) }
        )
    }

    private static func detail(in lumas: [Double?], width: Int) -> Double? {
        guard width > 2, lumas.count.isMultiple(of: width), lumas.count / width > 2 else { return nil }
        var squared = 0.0
        var count = 0
        for row in 1..<(lumas.count / width - 1) {
            for column in 1..<(width - 1) {
                let i = row * width + column
                guard let center = lumas[i], let left = lumas[i - 1], let right = lumas[i + 1],
                      let top = lumas[i - width], let bottom = lumas[i + width] else { continue }
                let laplacian = 4 * center - left - right - top - bottom
                squared += laplacian * laplacian
                count += 1
            }
        }
        return count == 0 ? nil : sqrt(squared / Double(count))
    }

    private struct ColorBucket {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0

        mutating func add(_ red: Double, _ green: Double, _ blue: Double) {
            self.red += red
            self.green += green
            self.blue += blue
            count += 1
        }

        var hex: String {
            let scale = 255 / Double(count)
            return String(format: "#%02X%02X%02X", Int((red * scale).rounded()), Int((green * scale).rounded()), Int((blue * scale).rounded()))
        }
    }

    #if os(macOS)
    static func read(_ file: URL) -> ImageAppearance? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? measure(premultipliedRGBA: pixels, width: width) : nil
    }
    #endif
}
