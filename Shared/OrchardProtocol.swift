import Darwin
import Foundation

nonisolated enum OrchardConstants {
    static let discoveryRefreshInterval: TimeInterval = 2
    static let snapshotFreshnessInterval = discoveryRefreshInterval * 3
    static let commandFreshnessInterval = discoveryRefreshInterval * 3
    static let commandWaitInterval = commandFreshnessInterval + discoveryRefreshInterval
    static let commandResultRetentionInterval: TimeInterval = 24 * 60 * 60
    static let maximumRetainedCommandResults = 256
}

nonisolated enum OrchardColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

nonisolated struct AgentSessionMetadata: Codable, Equatable, Sendable {
    let provider: String?
    let sessionID: String?
    let worktreePath: String
}

nonisolated struct WindowLabel: Codable, Equatable, Sendable {
    var title: String?
    var color: OrchardColor?
    var agent: AgentSessionMetadata?

    init(
        title: String?,
        color: OrchardColor?,
        agent: AgentSessionMetadata? = nil
    ) {
        self.title = title
        self.color = color
        self.agent = agent
    }
}

nonisolated struct WindowRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let nativeTitle: String
    let customTitle: String?
    let color: OrchardColor?
    let agent: AgentSessionMetadata?

    init(
        id: String,
        appName: String,
        bundleIdentifier: String,
        nativeTitle: String,
        customTitle: String?,
        color: OrchardColor?,
        agent: AgentSessionMetadata? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.nativeTitle = nativeTitle
        self.customTitle = customTitle
        self.color = color
        self.agent = agent
    }

    var displayTitle: String {
        customTitle?.nilIfBlank ?? nativeTitle
    }
}

nonisolated struct WindowIdentityDiagnostics: Codable, Equatable, Sendable {
    struct Transition: Codable, Equatable, Identifiable, Sendable {
        let id: Int
        let date: Date
        let summary: String
        let previousWindowID: String?
        let windowID: String
    }

    let windowID: String
    let nativeTitle: String
    let processIdentifier: Int32
    let document: String?
    let contextPath: String?
    let head: String?
    let contextError: String?
    let matchingContextCount: Int
    let isRestorable: Bool
    let transitions: [Transition]

    var sourceDescription: String {
        guard contextPath != nil else { return "Live window only" }
        return head == nil ? "Document path or URL" : "Git worktree + HEAD"
    }

    var persistenceDescription: String {
        isRestorable
            ? "Saved context; restored only when unambiguous."
            : "Runtime only; not restored by title or window order."
    }
}

nonisolated struct WindowSnapshot: Codable, Equatable, Sendable {
    let updatedAt: Date
    let windows: [WindowRecord]
    let activeWindowID: String?
    let diagnostics: [String: WindowIdentityDiagnostics]?

    init(
        updatedAt: Date,
        windows: [WindowRecord],
        activeWindowID: String? = nil,
        diagnostics: [String: WindowIdentityDiagnostics]? = nil
    ) {
        self.updatedAt = updatedAt
        self.windows = windows
        self.activeWindowID = activeWindowID
        self.diagnostics = diagnostics
    }
}

nonisolated struct OrchardCommand: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case focus
        case setTag
        case setTitle
        case setColor
        case clear
    }

    let id: UUID
    let action: Action
    let windowID: String
    let title: String?
    let color: OrchardColor?
    let agent: AgentSessionMetadata?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case windowID
        case title
        case color
        case agent
        case createdAt
    }

    init(
        id: UUID = UUID(),
        action: Action,
        windowID: String,
        title: String? = nil,
        color: OrchardColor? = nil,
        agent: AgentSessionMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.windowID = windowID
        self.title = title
        self.color = color
        self.agent = agent
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        action = try container.decode(Action.self, forKey: .action)
        windowID = try container.decode(String.self, forKey: .windowID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        color = try container.decodeIfPresent(OrchardColor.self, forKey: .color)
        agent = try container.decodeIfPresent(AgentSessionMetadata.self, forKey: .agent)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func validateFreshness(
        now: Date,
        maximumAge: TimeInterval = OrchardConstants.commandFreshnessInterval
    ) throws {
        let age = now.timeIntervalSince(createdAt)
        guard age >= -OrchardConstants.discoveryRefreshInterval,
              age <= maximumAge else {
            throw OrchardProtocolError.invalidCommand("the queued request is stale")
        }
    }
}

nonisolated struct OrchardCommandResult: Codable, Equatable, Sendable {
    let commandID: UUID
    let succeeded: Bool
    let message: String
    let processedAt: Date
}

nonisolated enum OrchardProtocolError: LocalizedError, Equatable {
    case snapshotMissing
    case snapshotMalformed(String)
    case snapshotStale
    case activeWindowMissing
    case activeWindowInconsistent(String)
    case unknownWindow(String)
    case invalidCommand(String)
    case commandTimedOut
    case commandStatusUnknown
    case commandRejected(String)
    case worktreeUnavailable
    case invalidWorktree(String)
    case skillConflict(String)
    case skillDestinationInvalid(String)
    case skillResourceMissing
    case skillResourceMalformed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotMissing:
            "No Orchard window snapshot found. Launch Orchard and grant Accessibility access first."
        case .snapshotMalformed(let message):
            "Orchard's window snapshot is malformed: \(message)"
        case .snapshotStale:
            "Orchard's window snapshot is stale. Confirm Orchard is running, then try again."
        case .activeWindowMissing:
            "Orchard has no focused current window. Focus the window to tag, then try again."
        case .activeWindowInconsistent(let id):
            "Orchard's focused window '\(id)' is no longer in the current snapshot. Focus it again, then retry."
        case .unknownWindow(let id):
            "No window with ID '\(id)' exists in Orchard's latest snapshot."
        case .invalidCommand(let message):
            "Invalid Orchard command: \(message)"
        case .commandTimedOut:
            "Orchard did not claim the command in time, so it was cancelled. Confirm the app is running, then try again."
        case .commandStatusUnknown:
            "Orchard claimed the command but did not report completion. Its final state is unknown; check the app before retrying."
        case .commandRejected(let message):
            "Orchard rejected the command: \(message)"
        case .worktreeUnavailable:
            "No Git worktree was found for the current directory."
        case .invalidWorktree(let path):
            "The worktree path '\(path)' is not a directory."
        case .skillConflict(let path):
            "A different skill already exists at '\(path)'. Re-run with --force to replace it."
        case .skillDestinationInvalid(let path):
            "The skill destination '\(path)' cannot be created because part of the path is not a directory."
        case .skillResourceMissing:
            "Orchard's bundled window-tag skill is missing. Reinstall Orchard and try again."
        case .skillResourceMalformed(let message):
            "Orchard's bundled window-tag skill is invalid: \(message)"
        }
    }
}

nonisolated struct OrchardPaths: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    static var current: OrchardPaths {
        if let override = ProcessInfo.processInfo.environment["ORCHARD_DATA_DIRECTORY"],
           !override.isEmpty {
            return OrchardPaths(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return OrchardPaths(
            directory: applicationSupport.appendingPathComponent("Orchard", isDirectory: true)
        )
    }

    var labels: URL { directory.appendingPathComponent("labels.json") }
    var snapshot: URL { directory.appendingPathComponent("windows.json") }
    var commandQueue: URL { directory.appendingPathComponent("commands", isDirectory: true) }
    var commandProcessing: URL {
        directory.appendingPathComponent("commands-processing", isDirectory: true)
    }
    var commandCancellations: URL {
        directory.appendingPathComponent("commands-cancelled", isDirectory: true)
    }
    var commandResults: URL {
        directory.appendingPathComponent("command-results", isDirectory: true)
    }
    var legacyCommand: URL { directory.appendingPathComponent("command.json") }
    var legacyProcessingCommand: URL {
        commandProcessing.appendingPathComponent("legacy-command.json")
    }

    func commandURL(for id: UUID) -> URL {
        commandQueue.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    func resultURL(for id: UUID) -> URL {
        commandResults.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    func processingURL(for id: UUID) -> URL {
        commandProcessing.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }
}

nonisolated enum OrchardJSON {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

nonisolated enum OrchardCommandWaitPolicy {
    static func interval(environmentValue: String?) throws -> TimeInterval {
        guard let environmentValue else {
            return OrchardConstants.commandWaitInterval
        }
        let value = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let interval = TimeInterval(value), interval.isFinite, interval > 0 else {
            throw OrchardProtocolError.invalidCommand(
                "ORCHARD_COMMAND_WAIT_TIMEOUT must be a finite number greater than zero"
            )
        }
        return interval
    }
}

nonisolated enum CurrentWindowResolver {
    static func loadCurrentWindow(
        paths: OrchardPaths = .current,
        now: Date = Date(),
        freshnessInterval: TimeInterval = OrchardConstants.snapshotFreshnessInterval
    ) throws -> WindowRecord {
        let snapshot: WindowSnapshot
        do {
            snapshot = try OrchardJSON.load(WindowSnapshot.self, from: paths.snapshot)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw OrchardProtocolError.snapshotMissing
        } catch {
            throw OrchardProtocolError.snapshotMalformed(error.localizedDescription)
        }
        return try resolve(
            snapshot: snapshot,
            now: now,
            freshnessInterval: freshnessInterval
        )
    }

    static func resolve(
        snapshot: WindowSnapshot,
        now: Date,
        freshnessInterval: TimeInterval
    ) throws -> WindowRecord {
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -OrchardConstants.discoveryRefreshInterval,
              age <= freshnessInterval else {
            throw OrchardProtocolError.snapshotStale
        }
        guard let activeWindowID = snapshot.activeWindowID else {
            throw OrchardProtocolError.activeWindowMissing
        }
        guard let window = snapshot.windows.first(where: { $0.id == activeWindowID }) else {
            throw OrchardProtocolError.activeWindowInconsistent(activeWindowID)
        }
        return window
    }
}

nonisolated enum OrchardColorAssignment {
    static func normalizedProvider(_ provider: String?) -> String? {
        guard let provider else { return nil }
        let words = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func normalizedSessionID(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func automatic(
        provider: String?,
        sessionID: String?,
        worktreePath: String
    ) -> OrchardColor {
        let source: String
        if let provider = normalizedProvider(provider),
           let sessionID = normalizedSessionID(sessionID) {
            source = "\(provider)\u{0}\(sessionID)"
        } else {
            source = worktreePath
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return OrchardColor.allCases[Int(hash % UInt64(OrchardColor.allCases.count))]
    }
}

nonisolated enum WorktreeResolver {
    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func resolve(
        override: String?,
        currentDirectory: URL
    ) throws -> URL {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = canonicalURL(URL(fileURLWithPath: trimmed, isDirectory: true))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw OrchardProtocolError.invalidWorktree(trimmed)
            }
            return url
        }
        return try gitRoot(startingAt: currentDirectory) ?? canonicalURL(currentDirectory)
    }

    static func gitRoot(startingAt directory: URL) throws -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "rev-parse", "--show-toplevel"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
    }
}

nonisolated enum OrchardCommandQueue {
    enum PendingEntry {
        case command(URL, OrchardCommand)
        case completed(URL, OrchardCommandResult)
        case malformed(URL, String)

        var url: URL {
            switch self {
            case .command(let url, _),
                 .completed(let url, _),
                 .malformed(let url, _):
                url
            }
        }

        fileprivate var sortDate: Date {
            switch self {
            case .command(_, let command):
                return command.createdAt
            case .completed(_, let result):
                return result.processedAt
            case .malformed(let url, _):
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                )
                return values?.contentModificationDate ?? .distantPast
            }
        }
    }

    @discardableResult
    static func enqueue(
        _ command: OrchardCommand,
        paths: OrchardPaths = .current
    ) throws -> URL {
        let url = paths.commandURL(for: command.id)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw OrchardProtocolError.invalidCommand(
                "command identifier \(command.id.uuidString) already exists"
            )
        }
        try OrchardJSON.save(command, to: url)
        return url
    }

    static func pendingEntries(paths: OrchardPaths = .current) throws -> [PendingEntry] {
        try entries(in: paths.commandQueue)
    }

    static func processingEntries(paths: OrchardPaths = .current) throws -> [PendingEntry] {
        try entries(in: paths.commandProcessing)
    }

    static func claimLegacyCommand(paths: OrchardPaths = .current) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.legacyCommand.path) else {
            return false
        }
        try fileManager.createDirectory(
            at: paths.commandProcessing,
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: paths.legacyProcessingCommand.path) else {
            return false
        }
        do {
            try fileManager.moveItem(
                at: paths.legacyCommand,
                to: paths.legacyProcessingCommand
            )
            return true
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    static func claim(
        _ entry: PendingEntry,
        paths: OrchardPaths = .current
    ) throws -> PendingEntry? {
        try FileManager.default.createDirectory(
            at: paths.commandProcessing,
            withIntermediateDirectories: true
        )
        let destination = paths.commandProcessing
            .appendingPathComponent(entry.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: entry.url, to: destination)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        switch entry {
        case .command(_, let command):
            return .command(destination, command)
        case .completed(_, let result):
            return .completed(destination, result)
        case .malformed(_, let message):
            return .malformed(destination, message)
        }
    }

    static func cancelPending(
        _ command: OrchardCommand,
        paths: OrchardPaths = .current
    ) throws -> Bool {
        try FileManager.default.createDirectory(
            at: paths.commandCancellations,
            withIntermediateDirectories: true
        )
        let source = paths.commandURL(for: command.id)
        let destination = paths.commandCancellations
            .appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
        try FileManager.default.removeItem(at: destination)
        return true
    }

    static func complete(
        _ result: OrchardCommandResult,
        commandURL: URL,
        observableSnapshot: WindowSnapshot,
        paths: OrchardPaths = .current
    ) throws {
        try OrchardJSON.save(observableSnapshot, to: paths.snapshot)
        try OrchardJSON.save(result, to: commandURL)
        try publishCompleted(result, completionURL: commandURL, paths: paths)
    }

    static func publishCompleted(
        _ result: OrchardCommandResult,
        completionURL: URL,
        paths: OrchardPaths = .current
    ) throws {
        try pruneCommandResults(paths: paths)
        try OrchardJSON.save(result, to: paths.resultURL(for: result.commandID))
        try FileManager.default.removeItem(at: completionURL)
    }

    static func pruneCommandResults(
        paths: OrchardPaths = .current,
        now: Date = Date()
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.commandResults.path) else {
            return
        }
        let urls = try fileManager.contentsOfDirectory(
            at: paths.commandResults,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var retained: [(url: URL, modifiedAt: Date)] = []
        for url in urls {
            do {
                let modifiedAt = try url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modifiedAt)
                    > OrchardConstants.commandResultRetentionInterval {
                    try removeResultIfPresent(at: url)
                } else {
                    retained.append((url, modifiedAt))
                }
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                continue
            }
        }

        retained.sort {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.modifiedAt < $1.modifiedAt
        }
        let maximumBeforePublication = OrchardConstants.maximumRetainedCommandResults - 1
        for entry in retained.prefix(max(0, retained.count - maximumBeforePublication)) {
            try removeResultIfPresent(at: entry.url)
        }
    }

    static func ordered(_ entries: [PendingEntry]) -> [PendingEntry] {
        entries.sorted {
            if $0.sortDate == $1.sortDate {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.sortDate < $1.sortDate
        }
    }

    private static func entries(in directory: URL) throws -> [PendingEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        let entries: [PendingEntry] = urls.map { url in
            do {
                return .command(
                    url,
                    try OrchardJSON.load(OrchardCommand.self, from: url)
                )
            } catch {
                do {
                    return .completed(
                        url,
                        try OrchardJSON.load(OrchardCommandResult.self, from: url)
                    )
                } catch {
                    return .malformed(url, error.localizedDescription)
                }
            }
        }
        return ordered(entries)
    }

    private static func removeResultIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }
}

nonisolated struct OrchardCommandApplication {
    let labelsChanged: Bool
    let focusWindowID: String?
}

nonisolated enum OrchardCommandApplier {
    static func apply(
        _ command: OrchardCommand,
        validWindowIDs: Set<String>,
        labels: inout [String: WindowLabel]
    ) throws -> OrchardCommandApplication {
        guard validWindowIDs.contains(command.windowID) else {
            throw OrchardProtocolError.unknownWindow(command.windowID)
        }

        let before = labels
        var focusWindowID: String?
        switch command.action {
        case .focus:
            focusWindowID = command.windowID
        case .setTag:
            let title = try validatedTitle(command.title)
            guard let color = command.color else {
                throw OrchardProtocolError.invalidCommand("setTag requires a color")
            }
            if let agent = command.agent,
               agent.worktreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OrchardProtocolError.invalidCommand(
                    "agent metadata requires a worktree path"
                )
            }
            labels[command.windowID] = WindowLabel(
                title: title,
                color: color,
                agent: command.agent
            )
        case .setTitle:
            let title = try validatedTitle(command.title)
            var label = labels[command.windowID] ?? WindowLabel(title: nil, color: .green)
            label.title = title
            labels[command.windowID] = label
        case .setColor:
            guard let color = command.color else {
                throw OrchardProtocolError.invalidCommand("setColor requires a color")
            }
            var label = labels[command.windowID] ?? WindowLabel(title: nil, color: nil)
            label.color = color
            labels[command.windowID] = label
        case .clear:
            labels.removeValue(forKey: command.windowID)
        }
        return OrchardCommandApplication(
            labelsChanged: labels != before,
            focusWindowID: focusWindowID
        )
    }

    private static func validatedTitle(_ title: String?) throws -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            throw OrchardProtocolError.invalidCommand("the title cannot be empty")
        }
        return title
    }
}

nonisolated enum AgentSkill: String, CaseIterable, Sendable {
    case copilot
    case claude
    case codex

    var personalDirectoryComponents: [String] {
        switch self {
        case .copilot: [".copilot", "skills", OrchardSkill.name]
        case .claude: [".claude", "skills", OrchardSkill.name]
        case .codex: [".agents", "skills", OrchardSkill.name]
        }
    }

    var projectDirectoryComponents: [String] {
        switch self {
        case .copilot: [".github", "skills", OrchardSkill.name]
        case .claude: [".claude", "skills", OrchardSkill.name]
        case .codex: [".agents", "skills", OrchardSkill.name]
        }
    }
}

nonisolated enum SkillScope: String, Sendable {
    case personal
    case project
}

nonisolated struct OrchardSkillDocument: Equatable, Sendable {
    let version: String
    let contents: Data

    var content: String {
        String(decoding: contents, as: UTF8.self)
    }
}

nonisolated enum OrchardSkill {
    static let name = "orchard-window-tag"
    static let resourceBundleName = "OrchardWindowTagSkill"

    static func load() throws -> OrchardSkillDocument {
        for url in candidateBundleURLs() where FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        throw OrchardProtocolError.skillResourceMissing
    }

    static func load(from bundleURL: URL) throws -> OrchardSkillDocument {
        guard let bundle = Bundle(url: bundleURL) else {
            throw OrchardProtocolError.skillResourceMalformed(
                "the resource bundle could not be opened"
            )
        }
        guard let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        isSemanticVersion(version) else {
            throw OrchardProtocolError.skillResourceMalformed(
                "CFBundleShortVersionString must be a semantic version"
            )
        }
        guard let skillURL = bundle.url(
            forResource: "SKILL",
            withExtension: "md"
        ) else {
            throw OrchardProtocolError.skillResourceMalformed(
                "SKILL.md is missing"
            )
        }
        let contents: Data
        do {
            contents = try Data(contentsOf: skillURL)
        } catch {
            throw OrchardProtocolError.skillResourceMalformed(
                "SKILL.md could not be read: \(error.localizedDescription)"
            )
        }
        guard let content = String(data: contents, encoding: .utf8),
              !content.isEmpty else {
            throw OrchardProtocolError.skillResourceMalformed(
                "SKILL.md is not non-empty UTF-8"
            )
        }
        guard content.contains("<!-- orchard-skill-version: \(version) -->") else {
            throw OrchardProtocolError.skillResourceMalformed(
                "SKILL.md does not match bundle version \(version)"
            )
        }
        return OrchardSkillDocument(version: version, contents: contents)
    }

    private static func candidateBundleURLs() -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment[
            "ORCHARD_SKILL_RESOURCE_BUNDLE"
        ], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let bundled = Bundle.main.url(
            forResource: resourceBundleName,
            withExtension: "bundle"
        ) {
            urls.append(bundled)
        }
        if let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent() {
            urls.append(
                executableDirectory.appendingPathComponent(
                    "\(resourceBundleName).bundle",
                    isDirectory: true
                )
            )
            urls.append(
                executableDirectory
                    .appendingPathComponent("Orchard.app", isDirectory: true)
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                    .appendingPathComponent(
                        "\(resourceBundleName).bundle",
                        isDirectory: true
                    )
            )
        }
        for applicationsDirectory in [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ] {
            urls.append(
                applicationsDirectory
                    .appendingPathComponent("Orchard.app", isDirectory: true)
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                    .appendingPathComponent(
                        "\(resourceBundleName).bundle",
                        isDirectory: true
                    )
            )
        }
        return urls.reduce(into: []) { unique, url in
            let standardized = url.standardizedFileURL
            if !unique.contains(standardized) {
                unique.append(standardized)
            }
        }
    }

    static func isSemanticVersion(_ value: String) -> Bool {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

nonisolated struct SkillInstallOutcome: Equatable {
    enum Status: Equatable {
        case installed
        case unchanged
    }

    let agent: AgentSkill
    let url: URL
    let version: String
    let status: Status
}

nonisolated enum OrchardSkillInstaller {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct StagingFile {
        let name: String
        let identity: FileIdentity
    }

    private struct InstallationResult {
        let status: SkillInstallOutcome.Status
        let installedIdentity: FileIdentity?
    }

    private struct ExistingFile {
        let contents: Data
        let mode: mode_t
    }

    static func destination(
        agent: AgentSkill,
        scope: SkillScope,
        homeDirectory: URL,
        projectRoot: URL?
    ) throws -> URL {
        let root: URL
        let components: [String]
        switch scope {
        case .personal:
            root = homeDirectory
            components = agent.personalDirectoryComponents
        case .project:
            guard let projectRoot else {
                throw OrchardProtocolError.worktreeUnavailable
            }
            root = projectRoot
            components = agent.projectDirectoryComponents
        }
        let directory = components.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        return directory.appendingPathComponent("SKILL.md")
    }

    static func install(
        agents: [AgentSkill],
        scope: SkillScope,
        homeDirectory: URL,
        projectRoot: URL?,
        force: Bool,
        beforeCommit: (() throws -> Void)? = nil,
        afterCommit: (() throws -> Void)? = nil,
        beforeRollbackRestore: (() throws -> Void)? = nil
    ) throws -> [SkillInstallOutcome] {
        let requestedRoot: URL
        switch scope {
        case .personal:
            requestedRoot = homeDirectory
        case .project:
            guard let projectRoot else {
                throw OrchardProtocolError.worktreeUnavailable
            }
            requestedRoot = projectRoot
        }

        let installationRoot = WorktreeResolver.canonicalURL(requestedRoot)
        let rootDescriptor = open(
            installationRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw OrchardProtocolError.skillDestinationInvalid(installationRoot.path)
        }
        defer { Darwin.close(rootDescriptor) }

        var destinations: [
            (
                agent: AgentSkill,
                url: URL,
                components: [String]
            )
        ] = []

        for agent in agents {
            let components: [String]
            switch scope {
            case .personal:
                components = agent.personalDirectoryComponents
            case .project:
                components = agent.projectDirectoryComponents
            }
            let parentURL = components.reduce(installationRoot) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            destinations.append(
                (
                    agent: agent,
                    url: parentURL.appendingPathComponent("SKILL.md"),
                    components: components
                )
            )
        }

        let skill = try OrchardSkill.load()
        let expected = skill.contents
        for destination in destinations {
            if let parentDescriptor = try openVerifiedDirectory(
                rootDescriptor: rootDescriptor,
                rootURL: installationRoot,
                components: destination.components,
                createIfMissing: false
            ) {
                defer { Darwin.close(parentDescriptor) }
                if let existing = try existingContents(
                    parentDescriptor: parentDescriptor,
                    path: destination.url.path
                ), existing != expected, !force {
                    throw OrchardProtocolError.skillConflict(destination.url.path)
                }
            }
        }

        try beforeCommit?()

        return try destinations.map { destination in
            guard let parentDescriptor = try openVerifiedDirectory(
                rootDescriptor: rootDescriptor,
                rootURL: installationRoot,
                components: destination.components,
                createIfMissing: true
            ) else {
                throw OrchardProtocolError.skillDestinationInvalid(destination.url.path)
            }
            defer { Darwin.close(parentDescriptor) }

            guard descriptorIsReachable(
                parentDescriptor,
                from: rootDescriptor,
                components: destination.components
            ) else {
                throw OrchardProtocolError.skillDestinationInvalid(destination.url.path)
            }
            let previousFile = try existingFile(
                parentDescriptor: parentDescriptor,
                path: destination.url.path
            )
            let installation: InstallationResult
            if force {
                installation = InstallationResult(
                    status: .installed,
                    installedIdentity: try replace(
                        expected,
                        parentDescriptor: parentDescriptor,
                        path: destination.url.path
                    )
                )
            } else {
                installation = try installWithoutOverwriting(
                    expected,
                    parentDescriptor: parentDescriptor,
                    path: destination.url.path
                )
            }
            do {
                guard fsync(parentDescriptor) == 0 else {
                    throw posixError(errno)
                }
                try afterCommit?()
            } catch {
                try rollback(
                    previousFile: previousFile,
                    installedIdentity: installation.installedIdentity,
                    parentDescriptor: parentDescriptor,
                    path: destination.url.path,
                    beforeRestore: beforeRollbackRestore
                )
                throw error
            }
            guard descriptorIsReachable(
                parentDescriptor,
                from: rootDescriptor,
                components: destination.components
            ) else {
                try rollback(
                    previousFile: previousFile,
                    installedIdentity: installation.installedIdentity,
                    parentDescriptor: parentDescriptor,
                    path: destination.url.path,
                    beforeRestore: beforeRollbackRestore
                )
                throw OrchardProtocolError.skillDestinationInvalid(destination.url.path)
            }
            return SkillInstallOutcome(
                agent: destination.agent,
                url: destination.url,
                version: skill.version,
                status: installation.status
            )
        }
    }

    private static func rollback(
        previousFile: ExistingFile?,
        installedIdentity: FileIdentity?,
        parentDescriptor: Int32,
        path: String,
        beforeRestore: (() throws -> Void)?
    ) throws {
        guard let installedIdentity else {
            return
        }

        let previousStaging = try previousFile.map {
            try writeStagingFile(
                $0.contents,
                parentDescriptor: parentDescriptor,
                mode: $0.mode
            )
        }
        var previousStagingNeedsRemoval = previousStaging != nil
        defer {
            if previousStagingNeedsRemoval, let previousStaging {
                try? removeStagingFile(
                    previousStaging.name,
                    parentDescriptor: parentDescriptor
                )
            }
        }

        let quarantineName = ".orchard-skill-rollback-\(UUID().uuidString).tmp"
        guard renameatx_np(
            parentDescriptor,
            "SKILL.md",
            parentDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == ENOENT {
                return
            }
            throw posixError(errno)
        }

        let quarantinedIdentity = try fileIdentity(
            named: quarantineName,
            parentDescriptor: parentDescriptor,
            path: path
        )
        guard quarantinedIdentity == installedIdentity else {
            if renameatx_np(
                parentDescriptor,
                quarantineName,
                parentDescriptor,
                "SKILL.md",
                UInt32(RENAME_EXCL)
            ) == 0 {
                guard fsync(parentDescriptor) == 0 else {
                    throw posixError(errno)
                }
            } else if errno != EEXIST {
                throw posixError(errno)
            }
            return
        }

        try beforeRestore?()

        if let previousStaging {
            if renameatx_np(
                parentDescriptor,
                previousStaging.name,
                parentDescriptor,
                "SKILL.md",
                UInt32(RENAME_EXCL)
            ) == 0 {
                previousStagingNeedsRemoval = false
            } else if errno != EEXIST {
                throw posixError(errno)
            }
        }

        try removeStagingFile(
            quarantineName,
            parentDescriptor: parentDescriptor
        )
        guard fsync(parentDescriptor) == 0 else {
            throw posixError(errno)
        }
    }

    private static func installWithoutOverwriting(
        _ contents: Data,
        parentDescriptor: Int32,
        path: String
    ) throws -> InstallationResult {
        if let existing = try existingContents(
            parentDescriptor: parentDescriptor,
            path: path
        ) {
            guard existing == contents else {
                throw OrchardProtocolError.skillConflict(path)
            }
            return InstallationResult(status: .unchanged, installedIdentity: nil)
        }

        let staging = try writeStagingFile(
            contents,
            parentDescriptor: parentDescriptor
        )
        if linkat(parentDescriptor, staging.name, parentDescriptor, "SKILL.md", 0) == 0 {
            try removeStagingFile(staging.name, parentDescriptor: parentDescriptor)
            return InstallationResult(
                status: .installed,
                installedIdentity: staging.identity
            )
        }

        let linkError = errno
        try removeStagingFile(staging.name, parentDescriptor: parentDescriptor)
        if linkError == EEXIST,
           let existing = try existingContents(
               parentDescriptor: parentDescriptor,
               path: path
           ) {
            guard existing == contents else {
                throw OrchardProtocolError.skillConflict(path)
            }
            return InstallationResult(status: .unchanged, installedIdentity: nil)
        }
        throw posixError(linkError)
    }

    private static func replace(
        _ contents: Data,
        parentDescriptor: Int32,
        path: String
    ) throws -> FileIdentity {
        let staging = try writeStagingFile(
            contents,
            parentDescriptor: parentDescriptor
        )
        guard renameat(
            parentDescriptor,
            staging.name,
            parentDescriptor,
            "SKILL.md"
        ) == 0 else {
            let renameError = errno
            try removeStagingFile(staging.name, parentDescriptor: parentDescriptor)
            if renameError == EISDIR || renameError == ENOTDIR {
                throw OrchardProtocolError.skillDestinationInvalid(path)
            }
            throw posixError(renameError)
        }
        return staging.identity
    }

    private static func writeStagingFile(
        _ contents: Data,
        parentDescriptor: Int32,
        mode: mode_t = mode_t(0o644)
    ) throws -> StagingFile {
        let stagingName = ".orchard-skill-\(UUID().uuidString).tmp"
        let descriptor = openat(
            parentDescriptor,
            stagingName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw posixError(errno)
        }

        var descriptorIsOpen = true
        var stagingIsReady = false
        defer {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if !stagingIsReady {
                unlinkat(parentDescriptor, stagingName, 0)
            }
        }

        try contents.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError(errno)
                }
                offset += written
            }
        }
        guard fchmod(descriptor, mode) == 0,
              fsync(descriptor) == 0 else {
            throw posixError(errno)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw posixError(errno)
        }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw posixError(errno)
        }
        stagingIsReady = true
        return StagingFile(
            name: stagingName,
            identity: FileIdentity(
                device: metadata.st_dev,
                inode: metadata.st_ino
            )
        )
    }

    private static func removeStagingFile(
        _ name: String,
        parentDescriptor: Int32
    ) throws {
        guard unlinkat(parentDescriptor, name, 0) == 0 else {
            throw posixError(errno)
        }
    }

    private static func existingContents(
        parentDescriptor: Int32,
        path: String
    ) throws -> Data? {
        try existingFile(
            parentDescriptor: parentDescriptor,
            path: path
        )?.contents
    }

    private static func existingFile(
        parentDescriptor: Int32,
        path: String
    ) throws -> ExistingFile? {
        var metadata = stat()
        guard fstatat(
            parentDescriptor,
            "SKILL.md",
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw OrchardProtocolError.skillDestinationInvalid(path)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw OrchardProtocolError.skillDestinationInvalid(path)
        }

        let descriptor = openat(
            parentDescriptor,
            "SKILL.md",
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw OrchardProtocolError.skillDestinationInvalid(path)
        }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_mode & S_IFMT == S_IFREG else {
            throw OrchardProtocolError.skillDestinationInvalid(path)
        }
        let contents = try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).readToEnd() ?? Data()
        return ExistingFile(
            contents: contents,
            mode: openedMetadata.st_mode & mode_t(0o7777)
        )
    }

    private static func fileIdentity(
        named name: String = "SKILL.md",
        parentDescriptor: Int32,
        path: String
    ) throws -> FileIdentity {
        var metadata = stat()
        guard fstatat(
            parentDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        metadata.st_mode & S_IFMT == S_IFREG else {
            throw OrchardProtocolError.skillDestinationInvalid(path)
        }
        return FileIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private static func openVerifiedDirectory(
        rootDescriptor: Int32,
        rootURL: URL,
        components: [String],
        createIfMissing: Bool
    ) throws -> Int32? {
        var currentDescriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        var currentURL = rootURL
        guard currentDescriptor >= 0 else {
            throw posixError(errno)
        }

        for component in components {
            currentURL.appendPathComponent(component, isDirectory: true)
            var nextDescriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if nextDescriptor < 0, errno == ENOENT {
                guard createIfMissing else {
                    Darwin.close(currentDescriptor)
                    return nil
                }
                if mkdirat(currentDescriptor, component, mode_t(0o755)) != 0,
                   errno != EEXIST {
                    let creationError = errno
                    Darwin.close(currentDescriptor)
                    throw posixError(creationError)
                }
                nextDescriptor = openat(
                    currentDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(currentDescriptor)
                throw OrchardProtocolError.skillDestinationInvalid(currentURL.path)
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func descriptorIsReachable(
        _ expectedDescriptor: Int32,
        from rootDescriptor: Int32,
        components: [String]
    ) -> Bool {
        var currentDescriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard currentDescriptor >= 0 else { return false }

        for component in components {
            let nextDescriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            Darwin.close(currentDescriptor)
            guard nextDescriptor >= 0 else { return false }
            currentDescriptor = nextDescriptor
        }
        defer { Darwin.close(currentDescriptor) }

        var expectedMetadata = stat()
        var currentMetadata = stat()
        guard fstat(expectedDescriptor, &expectedMetadata) == 0,
              fstat(currentDescriptor, &currentMetadata) == 0 else {
            return false
        }
        return expectedMetadata.st_dev == currentMetadata.st_dev
            && expectedMetadata.st_ino == currentMetadata.st_ino
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

nonisolated enum WindowIdentifier {
    static func makeContext(bundleIdentifier: String, path: String, head: String?) -> String {
        let source = "\(bundleIdentifier)\u{0}\(path)\u{0}\(head ?? "")"
        return "workspace-" + String(format: "%016llx", hash(source))
    }

    static func make(bundleIdentifier: String, nativeTitle: String, occurrence: Int = 0) -> String {
        let source = "\(bundleIdentifier)\u{0}\(nativeTitle)\u{0}\(occurrence)"
        return String(format: "%08llx", hash(source) & 0xffff_ffff)
    }

    private static func hash(_ source: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
