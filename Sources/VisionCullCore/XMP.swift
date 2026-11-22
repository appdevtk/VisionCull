import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SidecarTarget: Sendable {
    case alongside
    case folder(URL)
}

public enum XMP {
    public static func document(for metadata: PhotoMetadata) throws -> Data {
        let value = try metadata.validated()
        let keywords = try value.subjects.map { "<rdf:li>\(try escape($0))</rdf:li>" }.joined()
        let category = try escape(value.category)
        let description = try escape(value.description)
        let date = try escape(value.capturedAt)
        let gps: String
        if let lat = value.latitude, let lon = value.longitude {
            gps = "<exif:GPSLatitude>\(coordinate(lat, positive: "N", negative: "S"))</exif:GPSLatitude>"
                + "<exif:GPSLongitude>\(coordinate(lon, positive: "E", negative: "W"))</exif:GPSLongitude>"
        } else {
            gps = ""
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:exif="http://ns.adobe.com/exif/1.0/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:vc="https://visioncull.dev/ns/1.0/">
              \(keywords.isEmpty ? "" : "<dc:subject><rdf:Bag>\(keywords)</rdf:Bag></dc:subject>")
              \(description.isEmpty ? "" : "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(description)</rdf:li></rdf:Alt></dc:description>")
              \(category.isEmpty ? "" : "<vc:Category>\(category)</vc:Category>")
              \(category.isEmpty ? "" : "<photoshop:SupplementalCategories><rdf:Bag><rdf:li>\(category)</rdf:li></rdf:Bag></photoshop:SupplementalCategories>")
              \(date.isEmpty ? "" : "<exif:DateTimeOriginal>\(date)</exif:DateTimeOriginal><xmp:CreateDate>\(date)</xmp:CreateDate>")
              \(gps)
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>

        """.utf8)
    }

    public static func read(_ data: Data) throws -> PhotoMetadata {
        guard data.count <= 4 * 1024 * 1024 else {
            throw WorkflowError.message("XMP exceeded the 4 MiB metadata limit.")
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let reader = XMPReader()
        parser.delegate = reader
        guard parser.parse() else {
            throw WorkflowError.message("Could not read existing XMP: \(parser.parserError?.localizedDescription ?? "invalid XML")")
        }
        return reader.result
    }

    /// Validate the entire approved batch before writing. Existing sidecars are preserved.
    @discardableResult
    public static func export(_ review: Review, to target: SidecarTarget) throws -> [URL] {
        let approved = review.photos.filter(\.approved)
        guard !approved.isEmpty else { throw WorkflowError.message("Approve at least one photo before exporting.") }
        let targets = Dictionary(grouping: try review.photos.compactMap { photo -> (PhotoEntry, URL)? in
            if case .alongside = target, photo.fromApplePhotos {
                if photo.approved { throw WorkflowError.message("Choose an export folder for Apple Photos items.") }
                return nil
            }
            return (photo, try destination(for: photo, target: target))
        }, by: { $0.1.path.precomposedStringWithCanonicalMapping.lowercased() })
        let planned = try approved.map { photo -> (URL, Data) in
            guard try FileRevision.read(photo.file) == photo.revision else {
                throw WorkflowError.message("Image changed after review: \(photo.relativePath). Rescan before exporting.")
            }
            let url = try destination(for: photo, target: target)
            let key = url.path.precomposedStringWithCanonicalMapping.lowercased()
            guard targets[key]?.count == 1 else {
                throw WorkflowError.message("Multiple images would use \(url.lastPathComponent). Rename the conflicting inputs or use distinct folders.")
            }
            if case .alongside = target {
                let siblings = try FileManager.default.contentsOfDirectory(
                    at: photo.file.deletingLastPathComponent(), includingPropertiesForKeys: nil
                )
                let stem = photo.file.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                guard !siblings.contains(where: {
                    $0.path != photo.file.path
                        && PhotoScanner.imageExtensions.contains($0.pathExtension.lowercased())
                        && $0.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() == stem
                }) else {
                    throw WorkflowError.message("Ambiguous sibling images share the name \(stem).")
                }
            }
            let data = try document(for: photo.metadata)
            try checkExisting(url, data: data)
            return (url, data)
        }
        for (url, data) in planned {
            try writeNew(data, to: url)
        }
        return planned.map(\.0)
    }

    private static func destination(for photo: PhotoEntry, target: SidecarTarget) throws -> URL {
        switch target {
        case .alongside:
            return photo.file.deletingPathExtension().appendingPathExtension("xmp")
        case .folder(let root):
            let path = photo.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw WorkflowError.message("Invalid relative image path: \(photo.relativePath)")
            }
            var parent = root.standardizedFileURL.resolvingSymlinksInPath()
            for component in path.dropLast() {
                parent.appendPathComponent(component, isDirectory: true)
                guard !isSymlink(parent) else {
                    throw WorkflowError.message("Export path contains a symbolic link: \(parent.path)")
                }
            }
            return parent.appendingPathComponent(path[path.count - 1], isDirectory: false)
                .deletingPathExtension().appendingPathExtension("xmp")
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func checkExisting(_ url: URL, data: Data) throws {
        guard !isSymlink(url) else {
            throw WorkflowError.message("Sidecar is a symbolic link: \(url.path)")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  (try? Data(contentsOf: url)) == data else {
                throw WorkflowError.message("A different sidecar exists at \(url.path). Choose a fresh export folder.")
            }
        }
    }

    private static func writeNew(_ data: Data, to url: URL) throws {
        try checkExisting(url, data: data)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return }
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".visioncull-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        do {
            try manager.linkItem(at: temporary, to: url)
        } catch {
            // Another exporter may have completed the same write.
            if manager.fileExists(atPath: url.path) {
                try checkExisting(url, data: data)
            } else {
                // External filesystems such as exFAT may not support hard links.
                try data.write(to: url, options: .withoutOverwriting)
            }
        }
    }

    private static func coordinate(_ value: Double, positive: String, negative: String) -> String {
        let total = Int((abs(value) * 60_000_000).rounded())
        let degrees = total / 60_000_000
        let minutes = Double(total % 60_000_000) / 1_000_000
        return "\(degrees)," + String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), minutes)
            + (value < 0 ? negative : positive)
    }

    private static func escape(_ string: String) throws -> String {
        guard string.unicodeScalars.allSatisfy({
            let value = $0.value
            return value == 9 || value == 10 || value == 13 || (32...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        }) else { throw WorkflowError.message("Metadata contains invalid XML characters.") }
        return string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }
}

private final class XMPReader: NSObject, XMLParserDelegate {
    private var stack: [(namespace: String, name: String, text: String)] = []
    private let dc = "http://purl.org/dc/elements/1.1/"
    private let exif = "http://ns.adobe.com/exif/1.0/"
    private let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private var preferredDescription = false
    private var defaultLanguage = false
    private var latitude: Double?
    private var longitude: Double?
    var metadata = PhotoMetadata()

    var result: PhotoMetadata {
        var result = metadata
        if let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude) {
            result.latitude = latitude
            result.longitude = longitude
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        stack.append((namespaceURI ?? "", name, ""))
        if name == "li" && namespaceURI == rdf { defaultLanguage = attributes["xml:lang"] == "x-default" }
        if name == "Description" && namespaceURI == rdf {
            for (name, value) in attributes {
                let fields = name.split(separator: ":").map(String.init)
                if fields.count == 2, let namespace = namespaces[fields[0]] {
                    store(value, name: fields[1], namespace: namespace)
                }
            }
        }
    }

    private var namespaces: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let value = stack.popLast() else { return }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if value.namespace == rdf && name == "li" {
            if stack.contains(where: { $0.namespace == dc && $0.name == "subject" }) {
                metadata.subjects.append(text)
            } else if stack.contains(where: { $0.namespace == dc && $0.name == "description" }),
                      defaultLanguage || (!preferredDescription && metadata.description.isEmpty) {
                metadata.description = text
                preferredDescription = preferredDescription || defaultLanguage
            } else if metadata.category.isEmpty, stack.contains(where: {
                $0.namespace == "http://ns.adobe.com/photoshop/1.0/" && $0.name == "SupplementalCategories"
            }) {
                metadata.category = text
            }
        } else {
            store(text, name: name, namespace: value.namespace)
        }
    }

    private func store(_ text: String, name: String, namespace: String) {
        switch (namespace, name) {
        case (exif, "DateTimeOriginal"): metadata.capturedAt = text
        case ("http://ns.adobe.com/xap/1.0/", "CreateDate") where metadata.capturedAt.isEmpty: metadata.capturedAt = text
        case (exif, "GPSLatitude"): latitude = Self.parseCoordinate(text, positive: "N", negative: "S")
        case (exif, "GPSLongitude"): longitude = Self.parseCoordinate(text, positive: "E", negative: "W")
        case ("https://visioncull.dev/ns/1.0/", "Category"),
             ("http://ns.adobe.com/photoshop/1.0/", "Category"): metadata.category = text
        case (dc, "description") where !preferredDescription: metadata.description = text
        default: break
        }
    }

    private static func parseCoordinate(_ text: String, positive: Character, negative: Character) -> Double? {
        if let decimal = Double(text) { return decimal }
        guard let direction = text.last?.uppercased().first, direction == positive || direction == negative else { return nil }
        let parts = text.dropLast().split(separator: ",")
        guard parts.count == 2 || parts.count == 3, let degrees = Double(parts[0]),
              let minutes = Double(parts[1]), degrees >= 0, (0..<60).contains(minutes) else { return nil }
        let seconds = parts.count == 3 ? Double(parts[2]) : 0
        guard let seconds, (0..<60).contains(seconds) else { return nil }
        let value = degrees + minutes / 60 + seconds / 3600
        return direction == negative ? -value : value
    }
}
