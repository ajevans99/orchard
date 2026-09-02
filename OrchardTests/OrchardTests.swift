import Foundation
import Testing
@testable import Orchard

struct OrchardTests {
    @Test @MainActor func windowIdentifiersAreStableAndDistinct() {
        let first = WindowIdentifier.make(
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard"
        )
        let repeated = WindowIdentifier.make(
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard"
        )
        let secondWindow = WindowIdentifier.make(
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard",
            occurrence: 1
        )

        #expect(first == repeated)
        #expect(first != secondWindow)
        #expect(first.count == 8)
    }

    @Test @MainActor func customTitleOverridesNativeTitle() {
        let record = Self.makeRecord(customTitle: "CLI work")
        #expect(record.displayTitle == "CLI work")
    }

    @Test func oldLabelsAndSnapshotsRemainDecodable() throws {
        let labelData = Data(#"{"title":"Existing","color":"green"}"#.utf8)
        let label = try JSONDecoder().decode(WindowLabel.self, from: labelData)
        #expect(label.title == "Existing")
        #expect(label.color == .green)
        #expect(label.agent == nil)

        let snapshotData = Data(
            """
            {
              "updatedAt": 0,
              "windows": [{
                "id": "12345678",
                "appName": "Xcode",
                "bundleIdentifier": "com.apple.dt.Xcode",
                "nativeTitle": "Orchard",
                "customTitle": null,
                "color": null
              }]
            }
            """.utf8
        )
        let snapshot = try JSONDecoder().decode(WindowSnapshot.self, from: snapshotData)
        #expect(snapshot.activeWindowID == nil)
        #expect(snapshot.windows.first?.agent == nil)

        let commandData = Data(
            #"{"action":"focus","windowID":"12345678","createdAt":0}"#.utf8
        )
        let command = try JSONDecoder().decode(OrchardCommand.self, from: commandData)
        #expect(command.action == .focus)
        #expect(command.windowID == "12345678")
    }

    @Test func currentWindowResolutionRequiresFreshConsistentFocus() throws {
        let now = Date()
        let record = Self.makeRecord()
        let snapshot = WindowSnapshot(
            updatedAt: now,
            windows: [record],
            activeWindowID: record.id
        )
        #expect(
            try CurrentWindowResolver.resolve(
                snapshot: snapshot,
                now: now,
                freshnessInterval: 6
            ) == record
        )

        Self.expectProtocolError(.snapshotStale) {
            try CurrentWindowResolver.resolve(
                snapshot: WindowSnapshot(
                    updatedAt: now.addingTimeInterval(-7),
                    windows: [record],
                    activeWindowID: record.id
                ),
                now: now,
                freshnessInterval: 6
            )
        }
        Self.expectProtocolError(.activeWindowMissing) {
            try CurrentWindowResolver.resolve(
                snapshot: WindowSnapshot(updatedAt: now, windows: [record]),
                now: now,
                freshnessInterval: 6
            )
        }
        Self.expectProtocolError(.activeWindowInconsistent("missing")) {
            try CurrentWindowResolver.resolve(
                snapshot: WindowSnapshot(
                    updatedAt: now,
                    windows: [record],
                    activeWindowID: "missing"
                ),
                now: now,
                freshnessInterval: 6
            )
        }
    }

    @Test func automaticColorsAreStableAndNormalizeProviders() {
        #expect(
            OrchardColorAssignment.automatic(
                provider: "  COPILOT ",
                sessionID: "session-123",
                worktreePath: "/ignored"
            ) == .purple
        )
        #expect(
            OrchardColorAssignment.automatic(
                provider: "claude",
                sessionID: "abc",
                worktreePath: "/ignored"
            ) == .red
        )
        #expect(
            OrchardColorAssignment.automatic(
                provider: "copilot",
                sessionID: nil,
                worktreePath: "/tmp/worktree"
            ) == .yellow
        )
        #expect(
            OrchardColor.allCases == [
                .red, .orange, .yellow, .green, .blue, .purple, .pink,
            ]
        )
    }

    @Test func worktreeFallbackUsesCanonicalCurrentDirectory() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )

        let resolved = try WorktreeResolver.resolve(
            override: nil,
            currentDirectory: nested
        )
        #expect(resolved == WorktreeResolver.canonicalURL(nested))
    }

    @Test func queueSupportsConcurrentWritersAndCreationOrder() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OrchardPaths(directory: root)
        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let commands = (0..<40).map {
            OrchardCommand(
                action: .setTitle,
                windowID: "window",
                title: "Title \($0)",
                createdAt: baseDate.addingTimeInterval(Double($0))
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for command in commands.reversed() {
                group.addTask {
                    try OrchardCommandQueue.enqueue(command, paths: paths)
                }
            }
            try await group.waitForAll()
        }

        let entries = try OrchardCommandQueue.pendingEntries(paths: paths)
        let queuedCommands = entries.compactMap {
            if case .command(_, let command) = $0 { return command }
            return nil
        }
        #expect(queuedCommands.map(\.id) == commands.map(\.id))
        #expect(Set(queuedCommands.map(\.id)).count == commands.count)
    }

    @Test func malformedQueueEntriesDoNotHideValidSiblings() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OrchardPaths(directory: root)
        let valid = OrchardCommand(action: .clear, windowID: "window")
        try OrchardCommandQueue.enqueue(valid, paths: paths)
        try FileManager.default.createDirectory(
            at: paths.commandQueue,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: paths.commandQueue.appendingPathComponent("malformed.json")
        )

        let entries = try OrchardCommandQueue.pendingEntries(paths: paths)
        #expect(entries.count == 2)
        #expect(entries.contains {
            if case .command(_, let command) = $0 { return command.id == valid.id }
            return false
        })
        #expect(entries.contains {
            if case .malformed = $0 { return true }
            return false
        })
    }

    @Test func pendingCommandsAreAtomicallyClaimedOrCancelled() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OrchardPaths(directory: root)
        let claimedCommand = OrchardCommand(action: .clear, windowID: "claimed")
        try OrchardCommandQueue.enqueue(claimedCommand, paths: paths)
        let entry = try #require(
            OrchardCommandQueue.pendingEntries(paths: paths).first
        )
        let claimedResult = try OrchardCommandQueue.claim(entry, paths: paths)
        let claimed = try #require(claimedResult)
        #expect(
            FileManager.default.fileExists(
                atPath: paths.processingURL(for: claimedCommand.id).path
            )
        )
        #expect(
            try !OrchardCommandQueue.cancelPending(claimedCommand, paths: paths)
        )
        if case .command(let url, let command) = claimed {
            #expect(url == paths.processingURL(for: claimedCommand.id))
            #expect(command == claimedCommand)
        } else {
            Issue.record("Expected a claimed command.")
        }

        let cancelledCommand = OrchardCommand(action: .clear, windowID: "cancelled")
        try OrchardCommandQueue.enqueue(cancelledCommand, paths: paths)
        #expect(
            try OrchardCommandQueue.cancelPending(cancelledCommand, paths: paths)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.commandURL(for: cancelledCommand.id).path
            )
        )
    }

    @Test func commandCompletionPublishesObservableSnapshotFirst() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OrchardPaths(directory: root)
        let command = OrchardCommand(
            action: .setTag,
            windowID: "window",
            title: "Completed title",
            color: .blue
        )
        try OrchardCommandQueue.enqueue(command, paths: paths)
        let pending = try #require(
            OrchardCommandQueue.pendingEntries(paths: paths).first
        )
        let claimedResult = try OrchardCommandQueue.claim(pending, paths: paths)
        let claimed = try #require(claimedResult)
        let commandURL: URL
        if case .command(let url, _) = claimed {
            commandURL = url
        } else {
            Issue.record("Expected a claimed command.")
            return
        }
        let snapshot = WindowSnapshot(
            updatedAt: Date(),
            windows: [
                WindowRecord(
                    id: "window",
                    appName: "Terminal",
                    bundleIdentifier: "example.terminal",
                    nativeTitle: "Shell",
                    customTitle: "Completed title",
                    color: .blue
                ),
            ],
            activeWindowID: "window"
        )
        let result = OrchardCommandResult(
            commandID: command.id,
            succeeded: true,
            message: "Command applied.",
            processedAt: Date()
        )

        try OrchardCommandQueue.complete(
            result,
            commandURL: commandURL,
            observableSnapshot: snapshot,
            paths: paths
        )

        #expect(FileManager.default.fileExists(atPath: paths.resultURL(for: command.id).path))
        let observable = try OrchardJSON.load(WindowSnapshot.self, from: paths.snapshot)
        #expect(observable.activeWindowID == "window")
        #expect(observable.windows.first?.customTitle == "Completed title")
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.processingURL(for: command.id).path
            )
        )
    }

    @Test func commandCompletionDoesNotPublishBeforeSnapshotPersistence() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OrchardPaths(directory: root)
        let command = OrchardCommand(action: .focus, windowID: "window-b")
        try OrchardCommandQueue.enqueue(command, paths: paths)
        let pending = try #require(
            OrchardCommandQueue.pendingEntries(paths: paths).first
        )
        let claimedResult = try OrchardCommandQueue.claim(pending, paths: paths)
        let claimed = try #require(claimedResult)
        let commandURL: URL
        if case .command(let url, _) = claimed {
            commandURL = url
        } else {
            Issue.record("Expected a claimed command.")
            return
        }
        try FileManager.default.createDirectory(
            at: paths.snapshot,
            withIntermediateDirectories: true
        )
        let result = OrchardCommandResult(
            commandID: command.id,
            succeeded: true,
            message: "Command applied.",
            processedAt: Date()
        )
        let snapshot = WindowSnapshot(
            updatedAt: Date(),
            windows: [
                WindowRecord(
                    id: "window-b",
                    appName: "Terminal",
                    bundleIdentifier: "example.terminal",
                    nativeTitle: "B",
                    customTitle: nil,
                    color: nil
                ),
            ],
            activeWindowID: "window-b"
        )

        #expect(throws: (any Error).self) {
            try OrchardCommandQueue.complete(
                result,
                commandURL: commandURL,
                observableSnapshot: snapshot,
                paths: paths
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: paths.resultURL(for: command.id).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: paths.processingURL(for: command.id).path
            )
        )
    }

    @Test func completedCommandMarkerRecoversAResultWriteFailure() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OrchardPaths(directory: root)
        let command = OrchardCommand(action: .clear, windowID: "window")
        try OrchardCommandQueue.enqueue(command, paths: paths)
        let pending = try #require(
            OrchardCommandQueue.pendingEntries(paths: paths).first
        )
        let claimedResult = try OrchardCommandQueue.claim(pending, paths: paths)
        let claimed = try #require(claimedResult)
        let commandURL: URL
        if case .command(let url, _) = claimed {
            commandURL = url
        } else {
            Issue.record("Expected a claimed command.")
            return
        }
        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: paths.commandResults)
        let result = OrchardCommandResult(
            commandID: command.id,
            succeeded: true,
            message: "Command applied.",
            processedAt: Date()
        )

        #expect(throws: (any Error).self) {
            try OrchardCommandQueue.complete(
                result,
                commandURL: commandURL,
                observableSnapshot: WindowSnapshot(
                    updatedAt: Date(),
                    windows: [],
                    activeWindowID: nil
                ),
                paths: paths
            )
        }
        let recovered = try #require(
            OrchardCommandQueue.processingEntries(paths: paths).first
        )
        if case .completed(let url, let recoveredResult) = recovered {
            #expect(recoveredResult == result)
            try FileManager.default.removeItem(at: paths.commandResults)
            try OrchardCommandQueue.publishCompleted(
                recoveredResult,
                completionURL: url,
                paths: paths
            )
        } else {
            Issue.record("Expected a durable completed-command marker.")
        }
        #expect(
            FileManager.default.fileExists(
                atPath: paths.resultURL(for: command.id).path
            )
        )
        #expect(try OrchardCommandQueue.processingEntries(paths: paths).isEmpty)
    }

    @Test func staleQueuedCommandsAreRejected() {
        let command = OrchardCommand(
            action: .clear,
            windowID: "window",
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        Self.expectProtocolError(
            .invalidCommand("the queued request is stale")
        ) {
            try command.validateFreshness(
                now: Date(timeIntervalSinceReferenceDate: 200),
                maximumAge: 12
            )
        }
    }

    @Test func queuedLabelMutationsMergeInOrderAndAreIdempotent() throws {
        let windowID = "window"
        let validIDs = Set([windowID])
        var labels: [String: WindowLabel] = [:]
        let title = OrchardCommand(
            action: .setTitle,
            windowID: windowID,
            title: "Exact title"
        )
        let color = OrchardCommand(
            action: .setColor,
            windowID: windowID,
            color: .purple
        )

        #expect(
            try OrchardCommandApplier.apply(
                title,
                validWindowIDs: validIDs,
                labels: &labels
            ).labelsChanged
        )
        #expect(
            try OrchardCommandApplier.apply(
                color,
                validWindowIDs: validIDs,
                labels: &labels
            ).labelsChanged
        )
        #expect(labels[windowID]?.title == "Exact title")
        #expect(labels[windowID]?.color == .purple)
        #expect(
            try !OrchardCommandApplier.apply(
                color,
                validWindowIDs: validIDs,
                labels: &labels
            ).labelsChanged
        )
    }

    @Test func completeTagPersistsConcreteColorAndMetadata() throws {
        let metadata = AgentSessionMetadata(
            provider: "copilot",
            sessionID: "opaque",
            worktreePath: "/tmp/worktree"
        )
        let command = OrchardCommand(
            action: .setTag,
            windowID: "window",
            title: "Exact title",
            color: .blue,
            agent: metadata
        )
        var labels: [String: WindowLabel] = [:]
        _ = try OrchardCommandApplier.apply(
            command,
            validWindowIDs: ["window"],
            labels: &labels
        )
        #expect(
            labels["window"] == WindowLabel(
                title: "Exact title",
                color: .blue,
                agent: metadata
            )
        )
    }

    @Test func skillDestinationsMatchProviderConventions() throws {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        #expect(
            try OrchardSkillInstaller.destination(
                agent: .copilot,
                scope: .personal,
                homeDirectory: home,
                projectRoot: nil
            ).path == "/tmp/home/.copilot/skills/orchard-window-tag/SKILL.md"
        )
        #expect(
            try OrchardSkillInstaller.destination(
                agent: .claude,
                scope: .project,
                homeDirectory: home,
                projectRoot: project
            ).path == "/tmp/project/.claude/skills/orchard-window-tag/SKILL.md"
        )
        #expect(
            try OrchardSkillInstaller.destination(
                agent: .codex,
                scope: .project,
                homeDirectory: home,
                projectRoot: project
            ).path == "/tmp/project/.agents/skills/orchard-window-tag/SKILL.md"
        )
    }

    @Test func skillInstallIsIdenticalAndIdempotentAcrossAgents() throws {
        let home = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = try OrchardSkill.load()
        let installed = try OrchardSkillInstaller.install(
            agents: AgentSkill.allCases,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil,
            force: false
        )
        #expect(installed.allSatisfy { $0.status == .installed })
        #expect(installed.allSatisfy { $0.version == skill.version })
        let contents = try installed.map { try String(contentsOf: $0.url, encoding: .utf8) }
        #expect(Set(contents) == [skill.content])

        let unchanged = try OrchardSkillInstaller.install(
            agents: AgentSkill.allCases,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil,
            force: false
        )
        #expect(unchanged.allSatisfy { $0.status == .unchanged })
    }

    @Test func concurrentSkillInstallsDoNotOverwriteEachOther() async throws {
        let home = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = try OrchardSkill.load()

        async let first = OrchardSkillInstaller.install(
            agents: [.copilot],
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil,
            force: false
        )
        async let second = OrchardSkillInstaller.install(
            agents: [.copilot],
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil,
            force: false
        )
        let outcomes = try await first + second
        #expect(outcomes.contains { $0.status == .installed })
        #expect(
            outcomes.allSatisfy {
                $0.status == .installed || $0.status == .unchanged
            }
        )
        let destination = try OrchardSkillInstaller.destination(
            agent: .copilot,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil
        )
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == skill.content
        )
    }

    @Test func skillInstallPreflightsConflictsAndForceReplaces() throws {
        let home = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = try OrchardSkill.load()
        let conflict = try OrchardSkillInstaller.destination(
            agent: .claude,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil
        )
        try FileManager.default.createDirectory(
            at: conflict.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("different".utf8).write(to: conflict)

        Self.expectProtocolError(.skillConflict(conflict.path)) {
            try OrchardSkillInstaller.install(
                agents: AgentSkill.allCases,
                scope: .personal,
                homeDirectory: home,
                projectRoot: nil,
                force: false
            )
        }
        let copilot = try OrchardSkillInstaller.destination(
            agent: .copilot,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil
        )
        #expect(!FileManager.default.fileExists(atPath: copilot.path))

        let forced = try OrchardSkillInstaller.install(
            agents: AgentSkill.allCases,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil,
            force: true
        )
        #expect(forced.count == 3)
        #expect(try String(contentsOf: conflict, encoding: .utf8) == skill.content)
    }

    @Test func projectSkillInstallRequiresAProjectRoot() {
        Self.expectProtocolError(.worktreeUnavailable) {
            try OrchardSkillInstaller.install(
                agents: [.copilot],
                scope: .project,
                homeDirectory: URL(fileURLWithPath: "/tmp/home"),
                projectRoot: nil,
                force: false
            )
        }
    }

    @Test func projectSkillInstallRejectsSymlinkEscapes() throws {
        let root = try Self.temporaryDirectory()
        let outside = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".github"),
            withDestinationURL: outside
        )

        Self.expectProtocolError(
            .skillDestinationInvalid(root.appendingPathComponent(".github").path)
        ) {
            try OrchardSkillInstaller.install(
                agents: [.copilot],
                scope: .project,
                homeDirectory: root,
                projectRoot: root,
                force: true
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(
                    "skills/orchard-window-tag/SKILL.md"
                ).path
            )
        )
    }

    @Test func skillInstallRejectsConcurrentParentSymlinkSwap() throws {
        for force in [false, true] {
            let home = try Self.temporaryDirectory()
            let outside = try Self.temporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: home)
                try? FileManager.default.removeItem(at: outside)
            }
            let destination = try OrchardSkillInstaller.destination(
                agent: .copilot,
                scope: .personal,
                homeDirectory: home,
                projectRoot: nil
            )
            let parent = destination.deletingLastPathComponent()
            let displaced = outside.appendingPathComponent("verified-parent")
            let outsideSkill = outside.appendingPathComponent("SKILL.md")
            let sentinel = Data("outside sentinel".utf8)
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try sentinel.write(to: outsideSkill)

            Self.expectProtocolError(.skillDestinationInvalid(parent.path)) {
                try OrchardSkillInstaller.install(
                    agents: [.copilot],
                    scope: .personal,
                    homeDirectory: home,
                    projectRoot: nil,
                    force: force,
                    beforeCommit: {
                        try FileManager.default.moveItem(at: parent, to: displaced)
                        try FileManager.default.createSymbolicLink(
                            at: parent,
                            withDestinationURL: outside
                        )
                    }
                )
            }
            #expect(try Data(contentsOf: outsideSkill) == sentinel)
            #expect(
                !FileManager.default.fileExists(
                    atPath: displaced.appendingPathComponent("SKILL.md").path
                )
            )
        }
    }

    @Test func skillInstallRollsBackIfParentSwapsDuringCommit() throws {
        let home = try Self.temporaryDirectory()
        let outside = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let destination = try OrchardSkillInstaller.destination(
            agent: .copilot,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil
        )
        let parent = destination.deletingLastPathComponent()
        let displaced = outside.appendingPathComponent("verified-parent")
        let outsideSkill = outside.appendingPathComponent("SKILL.md")
        let original = Data("original skill".utf8)
        let sentinel = Data("outside sentinel".utf8)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try original.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        try sentinel.write(to: outsideSkill)

        Self.expectProtocolError(.skillDestinationInvalid(destination.path)) {
            try OrchardSkillInstaller.install(
                agents: [.copilot],
                scope: .personal,
                homeDirectory: home,
                projectRoot: nil,
                force: true,
                afterCommit: {
                    try FileManager.default.moveItem(at: parent, to: displaced)
                    try FileManager.default.createSymbolicLink(
                        at: parent,
                        withDestinationURL: outside
                    )
                }
            )
        }
        #expect(try Data(contentsOf: outsideSkill) == sentinel)
        #expect(
            try Data(contentsOf: displaced.appendingPathComponent("SKILL.md"))
                == original
        )
        let restoredAttributes = try FileManager.default.attributesOfItem(
            atPath: displaced.appendingPathComponent("SKILL.md").path
        )
        #expect(restoredAttributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func skillInstallRollbackDoesNotOverwriteConcurrentReplacement() throws {
        let home = try Self.temporaryDirectory()
        let outside = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let destination = try OrchardSkillInstaller.destination(
            agent: .copilot,
            scope: .personal,
            homeDirectory: home,
            projectRoot: nil
        )
        let parent = destination.deletingLastPathComponent()
        let displaced = outside.appendingPathComponent("verified-parent")
        let original = Data("original skill".utf8)
        let concurrent = Data("concurrent replacement".utf8)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try original.write(to: destination)

        Self.expectProtocolError(.skillDestinationInvalid(destination.path)) {
            try OrchardSkillInstaller.install(
                agents: [.copilot],
                scope: .personal,
                homeDirectory: home,
                projectRoot: nil,
                force: true,
                afterCommit: {
                    try FileManager.default.moveItem(at: parent, to: displaced)
                    try FileManager.default.createSymbolicLink(
                        at: parent,
                        withDestinationURL: outside
                    )
                },
                beforeRollbackRestore: {
                    try concurrent.write(
                        to: displaced.appendingPathComponent("SKILL.md")
                    )
                }
            )
        }
        #expect(
            try Data(contentsOf: displaced.appendingPathComponent("SKILL.md"))
                == concurrent
        )
    }

    @Test func bundledSkillIsVersionedAndUsesCommonFrontmatter() throws {
        let skill = try OrchardSkill.load()
        #expect(skill.version == "1.0.0")
        #expect(
            skill.content.contains(
                "<!-- orchard-skill-version: \(skill.version) -->"
            )
        )
        let lines = skill.content.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "---")
        let closingIndex = lines.dropFirst().firstIndex(of: "---")
        #expect(closingIndex != nil)
        guard let closingIndex else { return }
        let keys = lines[1..<closingIndex].compactMap {
            $0.split(separator: ":", maxSplits: 1).first.map(String.init)
        }
        #expect(keys == ["name", "description"])
        #expect(
            skill.content.contains(
                "multiple coding-agent sessions and worktrees at once"
            )
        )
        #expect(
            skill.content.contains(
                "running commands in the wrong agent session or worktree"
            )
        )
        #expect(
            skill.content.contains(
                "rejects missing or stale focus instead of guessing"
            )
        )
        #expect(skill.content.contains("exact session title"))
        #expect(skill.content.contains("Never invent or infer a session ID"))
        #expect(skill.content.contains("Do not parse `orchard list`"))
        #expect(skill.content.contains("best effort"))
    }

    @Test func bundledSkillRejectsDocumentVersionDrift() throws {
        guard let sourceBundle = Bundle.main.url(
            forResource: OrchardSkill.resourceBundleName,
            withExtension: "bundle"
        ) else {
            Issue.record("The Orchard skill resource bundle was not built.")
            return
        }
        let temporaryDirectory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let copiedBundle = temporaryDirectory.appendingPathComponent(
            "\(OrchardSkill.resourceBundleName).bundle",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: sourceBundle, to: copiedBundle)
        let copiedSkill = copiedBundle.appendingPathComponent(
            "Contents/Resources/SKILL.md"
        )
        var content = try String(contentsOf: copiedSkill, encoding: .utf8)
        content = content.replacingOccurrences(
            of: "orchard-skill-version: 1.0.0",
            with: "orchard-skill-version: 1.0.1"
        )
        try content.write(to: copiedSkill, atomically: true, encoding: .utf8)

        Self.expectProtocolError(
            .skillResourceMalformed(
                "SKILL.md does not match bundle version 1.0.0"
            )
        ) {
            try OrchardSkill.load(from: copiedBundle)
        }
    }

    @Test func bundledSkillVersionUsesSemanticVersioning() {
        for version in [
            "0.0.0",
            "1.2.3",
            "1.2.3-beta.1",
            "1.2.3+build.42",
            "1.2.3-rc.1+build.42",
        ] {
            #expect(OrchardSkill.isSemanticVersion(version))
        }
        for version in [
            "1",
            "1.2",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2.3-01",
            "1.2.3+",
            "١.٢.٣",
        ] {
            #expect(!OrchardSkill.isSemanticVersion(version))
        }
    }

    private static func makeRecord(customTitle: String? = nil) -> WindowRecord {
        WindowRecord(
            id: "12345678",
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            nativeTitle: "Orchard",
            customTitle: customTitle,
            color: .green
        )
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func expectProtocolError<T>(
        _ expected: OrchardProtocolError,
        performing operation: () throws -> T
    ) {
        do {
            _ = try operation()
            Issue.record("Expected \(expected), but the operation succeeded.")
        } catch let error as OrchardProtocolError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), but received \(error).")
        }
    }

    @Test @MainActor func telemetryEventsHaveStablePrivacySafePayloads() {
        let menuEvent = OrchardTelemetryEvent.menuPresented(
            windowCount: 4,
            labeledWindowCount: 2,
            accessibilityTrusted: true
        )
        let focusEvent = OrchardTelemetryEvent.windowFocused(
            source: .commandLine,
            succeeded: false
        )

        #expect(menuEvent.signalName == "menu.presented")
        #expect(
            menuEvent.parameters == [
                "windowCount": "4",
                "labeledWindowCount": "2",
                "accessibilityTrusted": "true",
            ]
        )
        #expect(focusEvent.signalName == "window.focused")
        #expect(
            focusEvent.parameters == [
                "source": "commandLine",
                "succeeded": "false",
            ]
        )
        #expect(
            OrchardTelemetryEvent.windowColorChanged(color: .purple).parameters
                == ["color": "purple"]
        )
    }
}
