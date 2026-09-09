import AppKit

nonisolated struct WindowContext: Equatable, Hashable {
    let path: String
    let head: String?

    static func resolve(document: String?) throws -> Self? {
        guard let document, !document.isEmpty else { return nil }
        let url: URL
        if document.hasPrefix("/") {
            url = URL(fileURLWithPath: document)
        } else {
            guard let parsed = URL(string: document), parsed.scheme != nil else { return nil }
            guard parsed.isFileURL else {
                // Opaque placeholders such as "untitled:Untitled-1" are reused
                // across launches and do not identify a persistent document.
                guard let host = parsed.host, !host.isEmpty else { return nil }
                return Self(path: parsed.absoluteString, head: nil)
            }
            url = parsed
        }
        let canonical = WorktreeResolver.canonicalURL(url)
        var directory = canonical
        while true {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = git
                } else {
                    let contents = try String(contentsOf: git, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard contents.hasPrefix("gitdir: ") else {
                        throw OrchardProtocolError.invalidWorktree(directory.path)
                    }
                    let path = String(contents.dropFirst("gitdir: ".count))
                    guard !path.isEmpty else {
                        throw OrchardProtocolError.invalidWorktree(directory.path)
                    }
                    gitDirectory = URL(fileURLWithPath: path, relativeTo: directory)
                }
                // Read this worktree's HEAD, not the common Git directory: linked
                // worktrees can share a repository while checking out different branches.
                let head = try String(
                    contentsOf: gitDirectory.appendingPathComponent("HEAD"),
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !head.isEmpty else {
                    throw OrchardProtocolError.invalidWorktree(directory.path)
                }
                return Self(path: directory.path, head: head)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return Self(path: canonical.path, head: nil)
    }

    func windowID(bundleIdentifier: String) -> String {
        WindowIdentifier.makeContext(
            bundleIdentifier: bundleIdentifier,
            path: path,
            head: head
        )
    }
}

extension WindowIdentityDiagnostics {
    nonisolated init(
        previous: Self?,
        windowID: String,
        bundleIdentifier: String,
        nativeTitle: String,
        processIdentifier: Int32,
        document: String?,
        context: WindowContext?,
        contextError: String?,
        matchingContextCount: Int,
        hasSavedLabel: Bool,
        now: Date
    ) {
        let isRestorable = context.map { $0.windowID(bundleIdentifier: bundleIdentifier) == windowID } ?? false

        let summary: String?
        if let previous {
            if previous.windowID != windowID {
                let cause = previous.contextPath != context?.path || previous.head != context?.head
                    ? "Document/worktree context changed"
                    : "Title changed without a document identity"
                summary = hasSavedLabel
                    ? "\(cause); saved tag restored."
                    : "\(cause); old tag detached, no saved tag for this identity."
            } else if previous.contextError != contextError, contextError != nil {
                summary = "Document context could not be resolved."
            } else if previous.document != document || previous.nativeTitle != nativeTitle {
                summary = "Document or title changed; identity preserved."
            } else if previous.matchingContextCount != matchingContextCount {
                summary = "Matching-window count changed; live identity preserved."
            } else {
                summary = nil
            }
        } else if contextError != nil {
            summary = "Document context could not be resolved; assigned a runtime identity."
        } else if isRestorable {
            summary = hasSavedLabel
                ? "Unique document/worktree identified; saved tag restored."
                : "Unique document/worktree identified; no saved tag."
        } else {
            summary = context == nil
                ? "No persistent document identity; assigned a new runtime identity."
                : "Document context is ambiguous or reserved; assigned a runtime identity."
        }
        var history = previous?.transitions ?? []
        if let summary {
            history.append(
                Transition(
                    id: (history.last?.id ?? 0) + 1,
                    date: now,
                    summary: summary,
                    previousWindowID: previous?.windowID,
                    windowID: windowID
                )
            )
        }
        self.init(
            windowID: windowID, nativeTitle: nativeTitle,
            processIdentifier: processIdentifier, document: document,
            contextPath: context?.path, head: context?.head, contextError: contextError,
            matchingContextCount: matchingContextCount, isRestorable: isRestorable,
            transitions: Array(history.suffix(10))
        )
    }
}

nonisolated enum WindowIdentity {
    struct Previous {
        let id: String
        let nativeTitle: String
        let context: WindowContext?
    }

    static func resolve(
        bundleIdentifier: String,
        nativeTitle: String,
        context: WindowContext?,
        previous: Previous?,
        matchingContextCount: Int,
        unavailableIDs: Set<String>,
        makeRuntimeID: () -> String = { "runtime-\(UUID().uuidString.lowercased())" }
    ) -> String {
        if let previous,
           previous.context == context,
           context != nil || previous.nativeTitle == nativeTitle {
            return previous.id
        }
        if let context, matchingContextCount == 1 {
            let id = context.windowID(bundleIdentifier: bundleIdentifier)
            if !unavailableIDs.contains(id) {
                return id
            }
        }
        // A title or duplicate ordinal is not proof of workspace identity.
        return makeRuntimeID()
    }
}

extension OrchardColor {
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
