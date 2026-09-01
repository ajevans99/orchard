import ArgumentParser
import Darwin
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

extension OrchardColor: ExpressibleByArgument {
    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

private extension OrchardColor {
    var ansiCode: String {
        switch self {
        case .red: "31"
        case .orange: "38;5;208"
        case .yellow: "33"
        case .green: "32"
        case .blue: "34"
        case .purple: "35"
        case .pink: "38;5;205"
        }
    }
}

enum CLIError: LocalizedError {
    case appNotRunning
    case unknownWindow(String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            "No Orchard window snapshot found. Launch Orchard and grant Accessibility access first."
        case .unknownWindow(let id):
            "No window with ID '\(id)' exists in Orchard's latest snapshot."
        }
    }
}

@main
struct OrchardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Name, color, and focus your macOS windows.",
        subcommands: [
            ListCommand.self,
            LabelCommand.self,
            ColorCommand.self,
            FocusCommand.self,
            ClearCommand.self,
        ]
    )
}

private struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List windows visible to Orchard."
    )

    @Flag(name: .long, help: "Print the window list as JSON.")
    var json = false

    mutating func run() throws {
        try OrchardOperations.list(json: json)
    }
}

private struct LabelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "Set a title tag for a window."
    )

    @Argument(help: "The window ID shown by 'orchard list'.")
    var windowID: String

    @Argument(parsing: .remaining, help: "The title to display for the window.")
    var title: [String]

    func validate() throws {
        guard !title.isEmpty else {
            throw ValidationError("Provide a title for the window.")
        }
    }

    mutating func run() throws {
        try OrchardOperations.updateLabel(
            windowID: windowID,
            title: title.joined(separator: " ")
        )
    }
}

private struct ColorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "Set a window's outline color."
    )

    @Argument(help: "The window ID shown by 'orchard list'.")
    var windowID: String

    @Argument(
        help: "The outline color.",
        completion: .list(OrchardColor.allCases.map(\.rawValue))
    )
    var color: OrchardColor

    mutating func run() throws {
        try OrchardOperations.updateColor(windowID: windowID, color: color)
    }
}

private struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Bring a window to the front."
    )

    @Argument(help: "The window ID shown by 'orchard list'.")
    var windowID: String

    mutating func run() throws {
        try OrchardOperations.requireWindow(windowID)
        try OrchardFiles.save(
            OrchardCommand(action: .focus, windowID: windowID, createdAt: Date()),
            to: OrchardFiles.command
        )
        print("Focus requested for \(windowID).")
    }
}

private struct ClearCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove a window's title and color."
    )

    @Argument(help: "The window ID shown by 'orchard list'.")
    var windowID: String

    mutating func run() throws {
        try OrchardOperations.requireWindow(windowID)
        var labels = OrchardOperations.loadLabels()
        labels.removeValue(forKey: windowID)
        try OrchardFiles.save(labels, to: OrchardFiles.labels)
        print("Cleared \(windowID).")
    }
}

private enum OrchardOperations {
    static func list(json: Bool) throws {
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
            let name = colorizedName(for: window)
            print(
                "\(pad(window.id, to: idWidth))  "
                    + "\(pad(window.appName, to: appWidth))  "
                    + "\(pad(window.color?.rawValue ?? "-", to: 7))  "
                    + name
            )
        }
    }

    static func updateLabel(windowID: String, title: String) throws {
        try requireWindow(windowID)
        var labels = loadLabels()
        var label = labels[windowID] ?? WindowLabel(title: nil, color: .green)
        label.title = title
        labels[windowID] = label
        try OrchardFiles.save(labels, to: OrchardFiles.labels)
        print("Labeled \(windowID) as '\(title)'.")
    }

    static func updateColor(windowID: String, color: OrchardColor) throws {
        try requireWindow(windowID)
        var labels = loadLabels()
        var label = labels[windowID] ?? WindowLabel(title: nil, color: nil)
        label.color = color
        labels[windowID] = label
        try OrchardFiles.save(labels, to: OrchardFiles.labels)
        print("Set \(windowID) to \(color.rawValue).")
    }

    static func requireWindow(_ windowID: String) throws {
        guard
            let snapshot = try? OrchardFiles.load(WindowSnapshot.self, from: OrchardFiles.snapshot),
            snapshot.windows.contains(where: { $0.id == windowID })
        else {
            throw CLIError.unknownWindow(windowID)
        }
    }

    static func loadLabels() -> [String: WindowLabel] {
        (try? OrchardFiles.load([String: WindowLabel].self, from: OrchardFiles.labels)) ?? [:]
    }

    private static func pad(_ value: String, to width: Int) -> String {
        if value.count >= width {
            return String(value.prefix(width))
        }
        return value + String(repeating: " ", count: width - value.count)
    }

    private static func colorizedName(for window: WindowRecord) -> String {
        guard
            isatty(STDOUT_FILENO) != 0,
            ProcessInfo.processInfo.environment["NO_COLOR"] == nil,
            let color = window.color
        else {
            return window.displayTitle
        }
        return "\u{001B}[\(color.ansiCode)m\(window.displayTitle)\u{001B}[0m"
    }
}
