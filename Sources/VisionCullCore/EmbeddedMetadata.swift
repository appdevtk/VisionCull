import Foundation
#if os(macOS)
import ImageIO
#endif

enum EmbeddedMetadata {
    static func read(_ input: PhotoInput) throws -> PhotoMetadata {
        var metadata = PhotoMetadata()
        #if os(macOS)
        if let source = CGImageSourceCreateWithURL(input.file as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            let date = exif["DateTimeOriginal"] as? String ?? tiff["DateTime"] as? String ?? ""
            metadata.capturedAt = exifDate(date, offset: exif["OffsetTimeOriginal"] as? String)
            metadata.subjects = iptc["Keywords"] as? [String] ?? []
            metadata.category = iptc["Category"] as? String ?? ""
            metadata.description = iptc["Caption/Abstract"] as? String ?? tiff["ImageDescription"] as? String ?? ""
            if let lat = gps["Latitude"] as? Double, let lon = gps["Longitude"] as? Double,
               (-90...90).contains(lat), (-180...180).contains(lon) {
                metadata.latitude = gps["LatitudeRef"] as? String == "S" ? -abs(lat) : lat
                metadata.longitude = gps["LongitudeRef"] as? String == "W" ? -abs(lon) : lon
            }
            if let imageMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
               let xmp = CGImageMetadataCreateXMPData(imageMetadata, nil),
               let parsed = try? XMP.read(xmp as Data) {
                apply(parsed, to: &metadata)
            }
        }
        #endif
        if let library = input.libraryMetadata {
            apply(library, to: &metadata)
        } else if let sidecar = try sidecar(for: input.file) {
            let handle = try FileHandle(forReadingFrom: sidecar)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            apply(try XMP.read(data), to: &metadata)
        }
        return metadata
    }

    private static func sidecar(for file: URL) throws -> URL? {
        let manager = FileManager.default
        let specific = file.appendingPathExtension("xmp")
        if (try? FileRevision.read(specific)) != nil { return specific }
        let standard = file.deletingPathExtension().appendingPathExtension("xmp")
        guard (try? FileRevision.read(standard)) != nil else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        let siblings = try manager.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let ambiguous = siblings.contains {
            $0.lastPathComponent != file.lastPathComponent && PhotoScanner.imageExtensions.contains($0.pathExtension.lowercased())
                && $0.deletingPathExtension().lastPathComponent.lowercased() == stem
        }
        return ambiguous ? nil : standard
    }

    private static func apply(_ incoming: PhotoMetadata, to metadata: inout PhotoMetadata) {
        if !incoming.subjects.isEmpty { metadata.subjects = incoming.subjects }
        if !incoming.category.isEmpty { metadata.category = incoming.category }
        if !incoming.description.isEmpty { metadata.description = incoming.description }
        if !incoming.capturedAt.isEmpty { metadata.capturedAt = incoming.capturedAt }
        if let lat = incoming.latitude, let lon = incoming.longitude {
            metadata.latitude = lat
            metadata.longitude = lon
        }
    }

    static func exifDate(_ date: String, offset: String?) -> String {
        guard date.count >= 19, date.contains(" ") else { return date }
        let parts = date.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return date }
        return parts[0].replacingOccurrences(of: ":", with: "-") + "T" + parts[1] + (offset ?? "")
    }
}
