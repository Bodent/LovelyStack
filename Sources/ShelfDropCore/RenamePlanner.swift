import Foundation

public struct RenamePreviewEntry: Hashable, Sendable {
    public let itemID: UUID
    public let sourceURL: URL
    public let destinationURL: URL
    public let newFilename: String
}

public enum RenamePlanner {
    public static func previews(for items: [ShelfItem], pattern: RenamePattern) -> [RenamePreviewEntry] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"

        return items.enumerated().map { offset, item in
            let source = item.url
            let baseName = source.deletingPathExtension().lastPathComponent
            let cleaned = clean(baseName: baseName, using: pattern)

            var components = [String]()
            if !pattern.customPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                components.append(pattern.customPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let dateString = dateComponent(for: item, source: pattern.dateSource, formatter: formatter) {
                components.append(dateString)
            }
            components.append(cleaned)
            if !pattern.customSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                components.append(pattern.customSuffix.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if pattern.includeCounter {
                components.append(String(format: "%03d", pattern.counterStart + offset))
            }

            let joined = components
                .joined(separator: pattern.separator.rawValue)
                .replacingOccurrences(of: "\\s+", with: pattern.separator.rawValue, options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: pattern.separator.rawValue).union(.whitespacesAndNewlines))

            let transformed = applyCaseStyle(joined, style: pattern.caseStyle)
            let filename = item.fileExtension.isEmpty ? transformed : "\(transformed).\(item.fileExtension)"
            return RenamePreviewEntry(
                itemID: item.id,
                sourceURL: source,
                destinationURL: source.deletingLastPathComponent().appendingPathComponent(filename),
                newFilename: filename
            )
        }
    }

    private static func clean(baseName: String, using pattern: RenamePattern) -> String {
        var value = baseName
        for prefix in pattern.prefixesToRemove where !prefix.isEmpty {
            if value.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
                value.removeFirst(prefix.count)
            }
        }

        for text in pattern.textToRemove where !text.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: text)
            value = value.replacingOccurrences(of: escaped, with: "", options: [.caseInsensitive, .regularExpression])
        }

        value = value
            .replacingOccurrences(of: "[\\s]+", with: pattern.separator.rawValue, options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9\\-_]+", with: pattern.separator.rawValue, options: .regularExpression)

        return value.trimmingCharacters(in: CharacterSet(charactersIn: pattern.separator.rawValue).union(.whitespacesAndNewlines))
    }

    private static func applyCaseStyle(_ value: String, style: RenameCaseStyle) -> String {
        switch style {
        case .keep: value
        case .lower: value.lowercased()
        case .upper: value.uppercased()
        case .title:
            value
                .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
                .map { $0.capitalized }
                .joined(separator: "_")
        }
    }

    private static func dateComponent(
        for item: ShelfItem,
        source: RenameDateSource,
        formatter: DateFormatter
    ) -> String? {
        switch source {
        case .none:
            nil
        case .created:
            item.createdAt.map(formatter.string(from:))
        case .modified:
            item.modifiedAt.map(formatter.string(from:))
        }
    }
}
