import Foundation

enum OrchardColor: String, Codable, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
}

struct WindowLabel: Codable {
    var title: String?
    var color: OrchardColor?
}

struct WindowRecord: Codable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let nativeTitle: String
    let customTitle: String?
    let color: OrchardColor?

    var displayTitle: String {
        customTitle ?? nativeTitle
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

enum OrchardFiles {
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Orchard", isDirectory: true)
    static let labels = directory.appendingPathComponent("labels.json")
    static let snapshot = directory.appendingPathComponent("windows.json")
    static let command = directory.appendingPathComponent("command.json")

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
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

enum CLIError: LocalizedError {
    case usage(String)
    case appNotRunning
    case unknownWindow(String)
    case unknownColor(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .appNotRunning:
            "No Orchard window snapshot found. Launch Orchard and grant Accessibility access first."
        case .unknownWindow(let id):
            "No window with ID '\(id)' exists in Orchard's latest snapshot."
        case .unknownColor(let color):
            "Unknown color '\(color)'. Use: \(OrchardColor.allCases.map(\.rawValue).joined(separator: ", "))."
        }
    }
}

@main
struct OrchardCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("orchard: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "list":
            try list(json: arguments.dropFirst().first == "--json")
        case "label":
            guard arguments.count >= 3 else {
                throw CLIError.usage("Usage: orchard label <window-id> <name>")
            }
            try updateLabel(
                windowID: arguments[1],
                title: arguments.dropFirst(2).joined(separator: " ")
            )
        case "color":
            guard arguments.count == 3 else {
                throw CLIError.usage("Usage: orchard color <window-id> <color>")
            }
            guard let color = OrchardColor(rawValue: arguments[2].lowercased()) else {
                throw CLIError.unknownColor(arguments[2])
            }
            try updateColor(windowID: arguments[1], color: color)
        case "focus":
            guard arguments.count == 2 else {
                throw CLIError.usage("Usage: orchard focus <window-id>")
            }
            try requireWindow(arguments[1])
            try OrchardFiles.save(
                OrchardCommand(action: .focus, windowID: arguments[1], createdAt: Date()),
                to: OrchardFiles.command
            )
            print("Focus requested for \(arguments[1]).")
        case "clear":
            guard arguments.count == 2 else {
                throw CLIError.usage("Usage: orchard clear <window-id>")
            }
            try requireWindow(arguments[1])
            var labels = loadLabels()
            labels.removeValue(forKey: arguments[1])
            try OrchardFiles.save(labels, to: OrchardFiles.labels)
            print("Cleared \(arguments[1]).")
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage("Unknown command '\(command)'. Run orchard help.")
        }
    }

    private static func list(json: Bool) throws {
        guard let snapshot = try? OrchardFiles.load(WindowSnapshot.self, from: OrchardFiles.snapshot) else {
            throw CLIError.appNotRunning
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(snapshot.windows), as: UTF8.self))
            return
        }

        if snapshot.windows.isEmpty {
            print("No windows found.")
            return
        }

        let idWidth = max(8, snapshot.windows.map(\.id.count).max() ?? 8)
        let appWidth = min(22, max(3, snapshot.windows.map(\.appName.count).max() ?? 3))
        print(
            "\(pad("ID", to: idWidth))  "
                + "\(pad("APP", to: appWidth))  "
                + "\(pad("COLOR", to: 7))  NAME"
        )
        for window in snapshot.windows {
            print(
                "\(pad(window.id, to: idWidth))  "
                    + "\(pad(window.appName, to: appWidth))  "
                    + "\(pad(window.color?.rawValue ?? "-", to: 7))  "
                    + window.displayTitle
            )
        }
    }

    private static func updateLabel(windowID: String, title: String) throws {
        try requireWindow(windowID)
        var labels = loadLabels()
        var label = labels[windowID] ?? WindowLabel(title: nil, color: .green)
        label.title = title
        labels[windowID] = label
        try OrchardFiles.save(labels, to: OrchardFiles.labels)
        print("Labeled \(windowID) as '\(title)'.")
    }

    private static func updateColor(windowID: String, color: OrchardColor) throws {
        try requireWindow(windowID)
        var labels = loadLabels()
        var label = labels[windowID] ?? WindowLabel(title: nil, color: nil)
        label.color = color
        labels[windowID] = label
        try OrchardFiles.save(labels, to: OrchardFiles.labels)
        print("Set \(windowID) to \(color.rawValue).")
    }

    private static func requireWindow(_ windowID: String) throws {
        guard
            let snapshot = try? OrchardFiles.load(WindowSnapshot.self, from: OrchardFiles.snapshot),
            snapshot.windows.contains(where: { $0.id == windowID })
        else {
            throw CLIError.unknownWindow(windowID)
        }
    }

    private static func loadLabels() -> [String: WindowLabel] {
        (try? OrchardFiles.load([String: WindowLabel].self, from: OrchardFiles.labels)) ?? [:]
    }

    private static func pad(_ value: String, to width: Int) -> String {
        if value.count >= width {
            return String(value.prefix(width))
        }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static func printUsage() {
        print(
            """
            Orchard window labels

            Usage:
              orchard list [--json]
              orchard label <window-id> <name>
              orchard color <window-id> <red|orange|yellow|green|blue|purple|pink>
              orchard focus <window-id>
              orchard clear <window-id>
            """
        )
    }
}
