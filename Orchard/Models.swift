import AppKit
import Foundation

enum OrchardColor: String, Codable, CaseIterable, Identifiable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }
}

struct WindowLabel: Codable, Equatable {
    var title: String?
    var color: OrchardColor?
}

struct WindowRecord: Codable, Identifiable, Equatable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let nativeTitle: String
    let customTitle: String?
    let color: OrchardColor?

    var displayTitle: String {
        customTitle?.nilIfBlank ?? nativeTitle
    }
}

struct WindowSnapshot: Codable {
    let updatedAt: Date
    let windows: [WindowRecord]
}

struct OrchardCommand: Codable {
    enum Action: String, Codable {
        case focus
    }

    let action: Action
    let windowID: String
    let createdAt: Date
}

enum WindowIdentifier {
    static func make(bundleIdentifier: String, nativeTitle: String, occurrence: Int = 0) -> String {
        let source = "\(bundleIdentifier)\u{0}\(nativeTitle)\u{0}\(occurrence)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%08llx", hash & 0xffff_ffff)
    }
}

enum OrchardFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orchard", isDirectory: true)
    }

    static var labels: URL {
        directory.appendingPathComponent("labels.json")
    }

    static var snapshot: URL {
        directory.appendingPathComponent("windows.json")
    }

    static var command: URL {
        directory.appendingPathComponent("command.json")
    }

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
