import ArgumentParser
import Darwin
import Foundation

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

private struct TagColorOption: ExpressibleByArgument {
    let color: OrchardColor?

    static let automatic = TagColorOption(color: nil)

    init?(argument: String) {
        if argument.lowercased() == "auto" {
            color = nil
        } else if let color = OrchardColor(rawValue: argument.lowercased()) {
            self.color = color
        } else {
            return nil
        }
    }

    private init(color: OrchardColor?) {
        self.color = color
    }
}

private enum AgentSelection: String, ExpressibleByArgument {
    case copilot
    case claude
    case codex
    case all

    var agents: [AgentSkill] {
        switch self {
        case .copilot: [.copilot]
        case .claude: [.claude]
        case .codex: [.codex]
        case .all: AgentSkill.allCases
        }
    }
}

extension SkillScope: ExpressibleByArgument {}

@main
struct OrchardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Name, color, and focus your macOS windows.",
        subcommands: [
            ListCommand.self,
            TagCommand.self,
            LabelCommand.self,
            ColorCommand.self,
            FocusCommand.self,
            ClearCommand.self,
            SkillCommand.self,
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

private struct TagCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Tag Orchard's currently focused window."
    )

    @Flag(name: .long, help: "Target Orchard's currently focused window.")
    var current = false

    @Option(name: .long, help: "The exact title to display.")
    var title: String

    @Option(
        name: .long,
        help: "Automatic or explicit outline color (auto, red, orange, yellow, green, blue, purple, pink)."
    )
    var color: TagColorOption = .automatic

    @Option(name: .long, help: "Open-ended lowercase agent provider name.")
    var provider: String?

    @Option(name: .long, help: "Opaque provider session identifier.")
    var session: String?

    @Option(name: .long, help: "Override automatic Git worktree discovery.")
    var worktree: String?

    func validate() throws {
        guard current else {
            throw ValidationError("--current is required.")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--title cannot be empty.")
        }
    }

    mutating func run() throws {
        let window = try CurrentWindowResolver.loadCurrentWindow()
        let worktreeURL = try WorktreeResolver.resolve(
            override: worktree,
            currentDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )
        let provider = OrchardColorAssignment.normalizedProvider(provider)
        let session = OrchardColorAssignment.normalizedSessionID(session)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let concreteColor = color.color ?? OrchardColorAssignment.automatic(
            provider: provider,
            sessionID: session,
            worktreePath: worktreeURL.path
        )
        let metadata = AgentSessionMetadata(
            provider: provider,
            sessionID: session,
            worktreePath: worktreeURL.path
        )
        try OrchardOperations.enqueue(
            OrchardCommand(
                action: .setTag,
                windowID: window.id,
                title: title,
                color: concreteColor,
                agent: metadata
            )
        )
        print(
            "Tagged current window as '\(title)' with \(concreteColor.rawValue)."
        )
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
        guard !title.isEmpty,
              !title.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ValidationError("Provide a title for the window.")
        }
    }

    mutating func run() throws {
        try OrchardOperations.requireWindow(windowID)
        let title = title.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try OrchardOperations.enqueue(
            OrchardCommand(action: .setTitle, windowID: windowID, title: title)
        )
        print("Labeled \(windowID) as '\(title)'.")
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
        try OrchardOperations.requireWindow(windowID)
        try OrchardOperations.enqueue(
            OrchardCommand(action: .setColor, windowID: windowID, color: color)
        )
        print("Set \(windowID) to \(color.rawValue).")
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
        try OrchardOperations.enqueue(
            OrchardCommand(action: .focus, windowID: windowID)
        )
        print("Focused \(windowID).")
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
        try OrchardOperations.enqueue(
            OrchardCommand(action: .clear, windowID: windowID)
        )
        print("Cleared \(windowID).")
    }
}

private struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Manage Orchard's portable agent skill.",
        subcommands: [InstallSkillCommand.self]
    )
}

private struct InstallSkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Orchard window-tagging skill."
    )

    @Option(name: .long, help: "Agent target: copilot, claude, codex, or all.")
    var agent: AgentSelection = .all

    @Option(name: .long, help: "Installation scope: personal or project.")
    var scope: SkillScope = .personal

    @Flag(name: .long, help: "Replace differing skill files.")
    var force = false

    mutating func run() throws {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let projectRoot: URL?
        if scope == .project {
            projectRoot = try WorktreeResolver.gitRoot(startingAt: currentDirectory)
            guard projectRoot != nil else {
                throw OrchardProtocolError.worktreeUnavailable
            }
        } else {
            projectRoot = nil
        }

        let homeDirectory: URL
        if let override = ProcessInfo.processInfo.environment["ORCHARD_HOME_DIRECTORY"],
           !override.isEmpty {
            homeDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        }
        let outcomes = try OrchardSkillInstaller.install(
            agents: agent.agents,
            scope: scope,
            homeDirectory: homeDirectory,
            projectRoot: projectRoot,
            force: force
        )
        for outcome in outcomes {
            switch outcome.status {
            case .installed:
                print(
                    "Installed \(outcome.agent.rawValue) skill "
                        + "v\(outcome.version): \(outcome.url.path)"
                )
            case .unchanged:
                print(
                    "Already installed \(outcome.agent.rawValue) skill "
                        + "v\(outcome.version): \(outcome.url.path)"
                )
            }
        }
        print("Restart or reload the selected agent to discover the skill.")
    }
}

private enum OrchardOperations {
    static func list(json: Bool) throws {
        let snapshot = try loadSnapshot(requireFresh: false)
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

    static func requireWindow(_ windowID: String) throws {
        let snapshot = try loadSnapshot(requireFresh: true)
        guard snapshot.windows.contains(where: { $0.id == windowID }) else {
            throw OrchardProtocolError.unknownWindow(windowID)
        }
    }

    static func enqueue(_ command: OrchardCommand) throws {
        let paths = OrchardPaths.current
        try OrchardCommandQueue.enqueue(command, paths: paths)
        let waitInterval = ProcessInfo.processInfo.environment[
            "ORCHARD_COMMAND_WAIT_TIMEOUT"
        ].flatMap(TimeInterval.init) ?? OrchardConstants.commandWaitInterval
        guard waitInterval > 0 else { return }

        let deadline = Date().addingTimeInterval(waitInterval)
        let resultURL = paths.resultURL(for: command.id)
        while Date() < deadline {
            if try consumeResult(at: resultURL) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if try OrchardCommandQueue.cancelPending(command, paths: paths) {
            throw OrchardProtocolError.commandTimedOut
        }

        let processingDeadline = Date().addingTimeInterval(waitInterval)
        while Date() < processingDeadline {
            if try consumeResult(at: resultURL) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw OrchardProtocolError.commandStatusUnknown
    }

    private static func consumeResult(at resultURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            return false
        }
        let result: OrchardCommandResult
        do {
            result = try OrchardJSON.load(OrchardCommandResult.self, from: resultURL)
        } catch {
            throw OrchardProtocolError.commandRejected(
                "the command result was malformed: \(error.localizedDescription)"
            )
        }
        do {
            try FileManager.default.removeItem(at: resultURL)
        } catch {
            FileHandle.standardError.write(
                Data("warning: unable to remove command result: \(error.localizedDescription)\n".utf8)
            )
        }
        guard result.succeeded else {
            throw OrchardProtocolError.commandRejected(result.message)
        }
        return true
    }

    private static func loadSnapshot(requireFresh: Bool) throws -> WindowSnapshot {
        let paths = OrchardPaths.current
        let snapshot: WindowSnapshot
        do {
            snapshot = try OrchardJSON.load(WindowSnapshot.self, from: paths.snapshot)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw OrchardProtocolError.snapshotMissing
        } catch {
            throw OrchardProtocolError.snapshotMalformed(error.localizedDescription)
        }
        if requireFresh {
            let age = Date().timeIntervalSince(snapshot.updatedAt)
            guard age >= -OrchardConstants.discoveryRefreshInterval,
                  age <= OrchardConstants.snapshotFreshnessInterval else {
                throw OrchardProtocolError.snapshotStale
            }
        }
        return snapshot
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
