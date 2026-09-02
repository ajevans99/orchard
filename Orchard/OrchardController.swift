import AppKit
import ApplicationServices
import Combine
import CoreVideo
import OSLog

private nonisolated(unsafe) let orchardAXObserverCallback: AXObserverCallback = {
    _, _, _, context in
    guard let context else { return }
    let controller = Unmanaged<OrchardController>
        .fromOpaque(context)
        .takeUnretainedValue()
    Task { @MainActor in
        controller.handleAccessibilityNotification()
    }
}

private nonisolated(unsafe) let orchardDisplayLinkCallback: CVDisplayLinkOutputCallback = {
    _, _, _, _, _, context in
    guard let context else { return kCVReturnError }
    let displayLinkContext = Unmanaged<DisplayLinkContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    displayLinkContext.scheduleUpdate()
    return kCVReturnSuccess
}

private nonisolated final class DisplayLinkContext: @unchecked Sendable {
    private weak var controller: OrchardController?
    private let lock = NSLock()
    private var updatePending = false

    init(controller: OrchardController) {
        self.controller = controller
    }

    func scheduleUpdate() {
        let shouldSchedule = lock.withLock {
            guard !updatePending else { return false }
            updatePending = true
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            controller?.handleDisplayLinkTick()
            lock.withLock {
                updatePending = false
            }
        }
    }
}

@MainActor
final class OrchardController: ObservableObject {
    @Published private(set) var windows: [WindowRecord] = []
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var activeWindowID: String?

    private struct TrackedWindow {
        let record: WindowRecord
        let processIdentifier: pid_t
        let element: AXUIElement
        let frame: CGRect
        let windowNumber: CGWindowID?
    }

    private struct HandledCommand {
        let url: URL
        let command: OrchardCommand
        var result: OrchardCommandResult
        let mutatesLabels: Bool
    }

    private struct ProcessedCommandBatch {
        let handled: [HandledCommand]
        let labelsChanged: Bool
        let focusedWindowID: String?
    }

    private var trackedWindows: [String: TrackedWindow] = [:]
    private var labels: [String: WindowLabel] = [:]
    private var discoveryTimer: Timer?
    private var trackingTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastFocusedElement: AXUIElement?
    private var accessibilityObserver: AXObserver?
    private var observedProcessIdentifier: pid_t?
    private var observedWindow: AXUIElement?
    private var displayLink: CVDisplayLink?
    private var displayLinkContext: DisplayLinkContext?
    private var activeTrackedWindow: TrackedWindow?
    private let outlineController = OutlineController()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Orchard",
        category: "Accessibility"
    )

    init() {
        outlineController.onRename = { [weak self] windowID, title in
            self?.rename(windowID, title: title)
        }
        outlineController.onSelectColor = { [weak self] windowID, color in
            self?.setColor(windowID, color: color)
        }
        outlineController.onRemoveTag = { [weak self] windowID in
            self?.clear(windowID)
        }

        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            isAccessibilityTrusted = true
            windows = [
                WindowRecord(
                    id: "ui-active",
                    appName: "GitHub Copilot",
                    bundleIdentifier: "com.github.Copilot",
                    nativeTitle: "GitHub Copilot",
                    customTitle: "Hello, Orchard",
                    color: .green
                ),
                WindowRecord(
                    id: "ui-finder",
                    appName: "Finder",
                    bundleIdentifier: "com.apple.finder",
                    nativeTitle: "Documents",
                    customTitle: nil,
                    color: nil
                ),
            ]
            activeWindowID = "ui-active"
            return
        }

        isAccessibilityTrusted = AXIsProcessTrusted()
        loadLabels()
        refresh()

        let discoveryTimer = Timer(
            timeInterval: OrchardConstants.discoveryRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(discoveryTimer, forMode: .common)
        self.discoveryTimer = discoveryTimer

        let trackingTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateOutline()
            }
        }
        RunLoop.main.add(trackingTimer, forMode: .common)
        self.trackingTimer = trackingTimer

        let notificationCenter = NSWorkspace.shared.notificationCenter
        for notification in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(
                notificationCenter.addObserver(
                    forName: notification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refresh()
                    }
                }
            )
        }
    }

    isolated deinit {
        stopDisplayLink()
        stopAccessibilityObserver()
        discoveryTimer?.invalidate()
        trackingTimer?.invalidate()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func requestAccessibilityAccess() {
        OrchardTelemetry.track(.accessibilitySettingsOpened)
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        openAccessibilitySettings()
    }

    func refresh(manual: Bool = false) {
        let accessibilityTrusted = AXIsProcessTrusted()
        if accessibilityTrusted != isAccessibilityTrusted {
            OrchardTelemetry.track(
                .accessibilityStatusChanged(isTrusted: accessibilityTrusted)
            )
        }
        isAccessibilityTrusted = accessibilityTrusted
        loadLabels()

        guard isAccessibilityTrusted else {
            windows = []
            trackedWindows = [:]
            lastFocusedElement = nil
            activeTrackedWindow = nil
            setActiveWindow(nil)
            stopDisplayLink()
            stopAccessibilityObserver()
            outlineController.hide()
            persistSnapshot()
            if manual {
                trackRefresh()
            }
            return
        }

        let tracked = discoverWindows()
        trackedWindows = Dictionary(uniqueKeysWithValues: tracked.map { ($0.record.id, $0) })
        windows = sortedRecords(tracked.map(\.record))
        let processedCommands = processPendingCommands()
        if processedCommands?.labelsChanged == true {
            applyLabelsToTrackedWindows()
        }
        if let focusedWindowID = processedCommands?.focusedWindowID {
            setActiveWindow(focusedWindowID)
        }
        updateOutline(
            preferredActiveWindowID: processedCommands?.focusedWindowID
        )
        let snapshot = currentSnapshot()
        if let processedCommands, !processedCommands.handled.isEmpty {
            complete(processedCommands.handled, observableSnapshot: snapshot)
        } else {
            persistSnapshot(snapshot)
        }
        if manual {
            trackRefresh()
        }
    }

    func rename(_ windowID: String, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = labels[windowID] ?? WindowLabel(title: nil, color: .green)
        label.title = title.isEmpty ? nil : title
        if label.title == nil && label.color == nil {
            labels.removeValue(forKey: windowID)
        } else {
            labels[windowID] = label
        }
        saveLabels()
        OrchardTelemetry.track(.windowTitleChanged(hasTitle: label.title != nil))
        refresh()
    }

    func setColor(_ windowID: String, color: OrchardColor) {
        var label = labels[windowID] ?? WindowLabel(title: nil, color: nil)
        label.color = color
        labels[windowID] = label
        saveLabels()
        OrchardTelemetry.track(.windowColorChanged(color: color))
        refresh()
    }

    func clear(_ windowID: String) {
        labels.removeValue(forKey: windowID)
        saveLabels()
        OrchardTelemetry.track(.windowLabelCleared)
        refresh()
    }

    func focus(_ windowID: String, source: OrchardFocusSource = .menuBar) {
        do {
            try focusWindow(windowID, source: source)
        } catch {
            logger.error(
                "Unable to focus window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func discoverWindows() -> [TrackedWindow] {
        var discovered: [TrackedWindow] = []
        var occurrences: [String: Int] = [:]
        var windowServerWindows = copyWindowServerWindows()
        let previousTrackedWindows = Array(trackedWindows.values)
        let reservedWindowIDs = Set(previousTrackedWindows.map(\.record.id))
        var reusedWindowIDs = Set<String>()

        for application in NSWorkspace.shared.runningApplications {
            guard
                application.activationPolicy == .regular,
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                continue
            }

            let bundleIdentifier = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
            let appName = application.localizedName ?? bundleIdentifier
            let appElement = AXUIElementCreateApplication(application.processIdentifier)

            for element in copyWindows(from: appElement) {
                guard let nativeTitle = copyString(kAXTitleAttribute as CFString, from: element) else {
                    continue
                }

                let normalizedTitle = nativeTitle.isEmpty ? "Untitled" : nativeTitle
                let occurrenceKey = "\(bundleIdentifier)\u{0}\(normalizedTitle)"
                let occurrence = occurrences[occurrenceKey, default: 0]
                occurrences[occurrenceKey] = occurrence + 1
                let existingID = previousTrackedWindows.first {
                    $0.processIdentifier == application.processIdentifier
                        && !reusedWindowIDs.contains($0.record.id)
                        && CFEqual($0.element, element)
                }?.record.id
                let id: String
                if let existingID {
                    id = existingID
                } else {
                    var candidate = WindowIdentifier.make(
                        bundleIdentifier: bundleIdentifier,
                        nativeTitle: normalizedTitle,
                        occurrence: occurrence
                    )
                    var fallbackOccurrence = occurrence
                    while reusedWindowIDs.contains(candidate)
                        || reservedWindowIDs.contains(candidate) {
                        fallbackOccurrence += 1
                        candidate = WindowIdentifier.make(
                            bundleIdentifier: bundleIdentifier,
                            nativeTitle: normalizedTitle,
                            occurrence: fallbackOccurrence
                        )
                    }
                    id = candidate
                }
                reusedWindowIDs.insert(id)
                let label = labels[id]
                let record = WindowRecord(
                    id: id,
                    appName: appName,
                    bundleIdentifier: bundleIdentifier,
                    nativeTitle: normalizedTitle,
                    customTitle: label?.title,
                    color: label?.color,
                    agent: label?.agent
                )

                guard let frame = copyFrame(from: element), frame.width > 40, frame.height > 40 else {
                    continue
                }
                let windowNumber = takeWindowNumber(
                    processIdentifier: application.processIdentifier,
                    frame: frame,
                    from: &windowServerWindows
                )
                if label != nil && windowNumber == nil {
                    logger.warning(
                        "Unable to match labeled window \(id, privacy: .public) to WindowServer"
                    )
                }
                discovered.append(
                    TrackedWindow(
                        record: record,
                        processIdentifier: application.processIdentifier,
                        element: element,
                        frame: frame,
                        windowNumber: windowNumber
                    )
                )
            }
        }

        return discovered
    }

    private func updateOutline(preferredActiveWindowID: String? = nil) {
        if let preferredActiveWindowID,
           let tracked = trackedWindows[preferredActiveWindowID] {
            lastFocusedElement = tracked.element
            observeWindow(
                tracked.element,
                processIdentifier: tracked.processIdentifier
            )
            setActiveWindow(preferredActiveWindowID)
            updateOutline(for: tracked)
            return
        }

        guard isAccessibilityTrusted,
              let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else {
            lastFocusedElement = nil
            setActiveWindow(nil)
            activeTrackedWindow = nil
            stopDisplayLink()
            stopAccessibilityObserver()
            outlineController.hide()
            return
        }

        // Opening Orchard's menu should not discard the window that was active beneath it.
        guard frontmostPID != ProcessInfo.processInfo.processIdentifier else { return }

        guard let focusedElement = focusedWindow(for: frontmostPID) else {
            lastFocusedElement = nil
            setActiveWindow(nil)
            activeTrackedWindow = nil
            stopDisplayLink()
            stopAccessibilityObserver()
            outlineController.hide()
            return
        }

        observeWindow(focusedElement, processIdentifier: frontmostPID)

        let focusedWindowChanged = lastFocusedElement.map {
            !CFEqual($0, focusedElement)
        } ?? true
        lastFocusedElement = focusedElement

        var tracked = trackedWindows.values.first {
            $0.processIdentifier == frontmostPID && CFEqual($0.element, focusedElement)
        }
        if tracked == nil && focusedWindowChanged {
            let discovered = discoverWindows()
            trackedWindows = Dictionary(uniqueKeysWithValues: discovered.map { ($0.record.id, $0) })
            windows = sortedRecords(discovered.map(\.record))
            tracked = trackedWindows.values.first {
                $0.processIdentifier == frontmostPID && CFEqual($0.element, focusedElement)
            }
        }

        setActiveWindow(tracked?.record.id)

        guard let tracked else {
            activeTrackedWindow = nil
            stopDisplayLink()
            outlineController.hide()
            return
        }

        updateOutline(for: tracked)
    }

    private func updateOutline(for tracked: TrackedWindow) {
        guard let label = labels[tracked.record.id],
              let currentFrame = currentFrame(for: tracked) else {
            activeTrackedWindow = nil
            stopDisplayLink()
            outlineController.hide()
            return
        }

        activeTrackedWindow = tracked
        startDisplayLink()
        outlineController.show(
            frame: currentFrame,
            color: label.color ?? .green,
            title: label.title,
            windowID: tracked.record.id
        )
    }

    private func setActiveWindow(_ windowID: String?) {
        guard activeWindowID != windowID else { return }
        activeWindowID = windowID
        persistSnapshot()
    }

    fileprivate func handleAccessibilityNotification() {
        updateOutline()
    }

    fileprivate func handleDisplayLinkTick() {
        guard
            let tracked = activeTrackedWindow,
            let label = labels[tracked.record.id],
            let frame = currentFrame(for: tracked)
        else {
            activeTrackedWindow = nil
            stopDisplayLink()
            outlineController.hide()
            return
        }

        outlineController.show(
            frame: frame,
            color: label.color ?? .green,
            title: label.title,
            windowID: tracked.record.id
        )
    }

    private func currentFrame(for tracked: TrackedWindow) -> CGRect? {
        if let windowNumber = tracked.windowNumber,
           let frame = copyWindowServerFrame(windowNumber) {
            return frame
        }
        return copyFrame(from: tracked.element)
    }

    private func startDisplayLink() {
        if let displayLink {
            guard !CVDisplayLinkIsRunning(displayLink) else { return }
            let result = CVDisplayLinkStart(displayLink)
            if result != kCVReturnSuccess {
                logger.error("Unable to restart display link: \(result)")
            }
            return
        }

        var displayLink: CVDisplayLink?
        let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard createResult == kCVReturnSuccess, let displayLink else {
            logger.error("Unable to create display link: \(createResult)")
            return
        }

        let context = DisplayLinkContext(controller: self)
        let callbackResult = CVDisplayLinkSetOutputCallback(
            displayLink,
            orchardDisplayLinkCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        guard callbackResult == kCVReturnSuccess else {
            logger.error("Unable to configure display link: \(callbackResult)")
            return
        }

        self.displayLink = displayLink
        displayLinkContext = context
        let startResult = CVDisplayLinkStart(displayLink)
        if startResult != kCVReturnSuccess {
            logger.error("Unable to start display link: \(startResult)")
        }
    }

    private func stopDisplayLink() {
        guard let displayLink, CVDisplayLinkIsRunning(displayLink) else { return }
        let result = CVDisplayLinkStop(displayLink)
        if result != kCVReturnSuccess {
            logger.error("Unable to stop display link: \(result)")
        }
    }

    private func observeWindow(_ window: AXUIElement, processIdentifier: pid_t) {
        if observedProcessIdentifier != processIdentifier {
            stopAccessibilityObserver()

            var observer: AXObserver?
            let result = AXObserverCreate(
                processIdentifier,
                orchardAXObserverCallback,
                &observer
            )
            guard result == .success, let observer else {
                logger.error("Unable to observe process \(processIdentifier): \(result.rawValue)")
                return
            }

            accessibilityObserver = observer
            observedProcessIdentifier = processIdentifier
            let application = AXUIElementCreateApplication(processIdentifier)
            let context = Unmanaged.passUnretained(self).toOpaque()
            addNotification(
                kAXFocusedWindowChangedNotification as CFString,
                to: application,
                observer: observer,
                context: context
            )
            addNotification(
                kAXWindowCreatedNotification as CFString,
                to: application,
                observer: observer,
                context: context
            )
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        guard
            let observer = accessibilityObserver,
            observedWindow.map({ !CFEqual($0, window) }) ?? true
        else {
            return
        }

        if let observedWindow {
            AXObserverRemoveNotification(
                observer,
                observedWindow,
                kAXMovedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                observedWindow,
                kAXResizedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                observedWindow,
                kAXUIElementDestroyedNotification as CFString
            )
        }

        observedWindow = window
        let context = Unmanaged.passUnretained(self).toOpaque()
        addNotification(
            kAXMovedNotification as CFString,
            to: window,
            observer: observer,
            context: context
        )
        addNotification(
            kAXResizedNotification as CFString,
            to: window,
            observer: observer,
            context: context
        )
        addNotification(
            kAXUIElementDestroyedNotification as CFString,
            to: window,
            observer: observer,
            context: context
        )
    }

    private func addNotification(
        _ notification: CFString,
        to element: AXUIElement,
        observer: AXObserver,
        context: UnsafeMutableRawPointer
    ) {
        let result = AXObserverAddNotification(
            observer,
            element,
            notification,
            context
        )
        guard result != .success,
              result != .notificationAlreadyRegistered,
              result != .notificationUnsupported
        else {
            return
        }
        logger.error("Unable to register Accessibility notification: \(result.rawValue)")
    }

    private func stopAccessibilityObserver() {
        guard let observer = accessibilityObserver else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = nil
        observedProcessIdentifier = nil
        observedWindow = nil
    }

    private func processPendingCommands() -> ProcessedCommandBatch? {
        let paths = OrchardPaths.current
        migrateLegacyCommand(paths: paths)
        let pendingEntries: [OrchardCommandQueue.PendingEntry]
        do {
            pendingEntries = try OrchardCommandQueue.pendingEntries(paths: paths)
        } catch {
            logger.error("Unable to read command queue: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let recoveredEntries: [OrchardCommandQueue.PendingEntry]
        do {
            recoveredEntries = try OrchardCommandQueue.processingEntries(paths: paths)
        } catch {
            logger.error(
                "Unable to read claimed commands: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        var claimedEntries: [OrchardCommandQueue.PendingEntry] = []
        for entry in pendingEntries {
            do {
                if let claimed = try OrchardCommandQueue.claim(entry, paths: paths) {
                    claimedEntries.append(claimed)
                }
            } catch {
                logger.error(
                    "Unable to claim command \(entry.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let entries = OrchardCommandQueue.ordered(recoveredEntries + claimedEntries)
        guard !entries.isEmpty else { return nil }

        let originalLabels = labels
        let validWindowIDs = Set(trackedWindows.keys)
        var handled: [HandledCommand] = []
        var labelsChanged = false
        var focusedWindowID: String?

        for entry in entries {
            switch entry {
            case .completed(let url, let result):
                do {
                    try OrchardCommandQueue.publishCompleted(
                        result,
                        completionURL: url,
                        paths: paths
                    )
                } catch {
                    logger.error(
                        "Unable to publish completed command \(result.commandID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            case .malformed(let url, let message):
                logger.error(
                    "Discarding malformed queued command \(url.lastPathComponent, privacy: .public): \(message, privacy: .public)"
                )
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    logger.error(
                        "Unable to remove malformed command \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            case .command(let url, let command):
                do {
                    try command.validateFreshness(now: Date())
                    let application = try OrchardCommandApplier.apply(
                        command,
                        validWindowIDs: validWindowIDs,
                        labels: &labels
                    )
                    labelsChanged = labelsChanged || application.labelsChanged
                    if let focusWindowID = application.focusWindowID {
                        try focusWindow(focusWindowID, source: .commandLine)
                        focusedWindowID = focusWindowID
                    }
                    handled.append(
                        HandledCommand(
                            url: url,
                            command: command,
                            result: OrchardCommandResult(
                                commandID: command.id,
                                succeeded: true,
                                message: "Command applied.",
                                processedAt: Date()
                            ),
                            mutatesLabels: command.action != .focus
                        )
                    )
                } catch {
                    handled.append(
                        HandledCommand(
                            url: url,
                            command: command,
                            result: OrchardCommandResult(
                                commandID: command.id,
                                succeeded: false,
                                message: error.localizedDescription,
                                processedAt: Date()
                            ),
                            mutatesLabels: false
                        )
                    )
                    logger.error(
                        "Rejected command \(command.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        if labelsChanged {
            do {
                try OrchardJSON.save(labels, to: paths.labels)
            } catch {
                labels = originalLabels
                labelsChanged = false
                logger.error(
                    "Unable to persist queued label changes: \(error.localizedDescription, privacy: .public)"
                )
                for index in handled.indices where handled[index].mutatesLabels {
                    handled[index].result = OrchardCommandResult(
                        commandID: handled[index].command.id,
                        succeeded: false,
                        message: "Unable to persist labels: \(error.localizedDescription)",
                        processedAt: Date()
                    )
                }
            }
        }

        return ProcessedCommandBatch(
            handled: handled,
            labelsChanged: labelsChanged,
            focusedWindowID: focusedWindowID
        )
    }

    private func complete(
        _ handled: [HandledCommand],
        observableSnapshot: WindowSnapshot
    ) {
        for item in handled {
            do {
                try OrchardCommandQueue.complete(
                    item.result,
                    commandURL: item.url,
                    observableSnapshot: observableSnapshot
                )
            } catch {
                logger.error(
                    "Unable to finish command \(item.command.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
    }

    private func focusWindow(_ windowID: String, source: OrchardFocusSource) throws {
        guard let tracked = trackedWindows[windowID] else {
            OrchardTelemetry.track(.windowFocused(source: source, succeeded: false))
            throw OrchardProtocolError.unknownWindow(windowID)
        }
        guard let application = NSRunningApplication(
            processIdentifier: tracked.processIdentifier
        ), application.activate() else {
            OrchardTelemetry.track(.windowFocused(source: source, succeeded: false))
            throw OrchardProtocolError.invalidCommand(
                "unable to activate the target application"
            )
        }
        let raiseError = AXUIElementPerformAction(
            tracked.element,
            kAXRaiseAction as CFString
        )
        guard raiseError == .success else {
            OrchardTelemetry.track(.windowFocused(source: source, succeeded: false))
            throw OrchardProtocolError.invalidCommand(
                "unable to raise the target window (AX error \(raiseError.rawValue))"
            )
        }
        OrchardTelemetry.track(.windowFocused(source: source, succeeded: true))
    }

    private func migrateLegacyCommand(paths: OrchardPaths) {
        do {
            _ = try OrchardCommandQueue.claimLegacyCommand(paths: paths)
        } catch {
            logger.error(
                "Unable to claim legacy command: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func applyLabelsToTrackedWindows() {
        trackedWindows = trackedWindows.mapValues { tracked in
            let label = labels[tracked.record.id]
            return TrackedWindow(
                record: WindowRecord(
                    id: tracked.record.id,
                    appName: tracked.record.appName,
                    bundleIdentifier: tracked.record.bundleIdentifier,
                    nativeTitle: tracked.record.nativeTitle,
                    customTitle: label?.title,
                    color: label?.color,
                    agent: label?.agent
                ),
                processIdentifier: tracked.processIdentifier,
                element: tracked.element,
                frame: tracked.frame,
                windowNumber: tracked.windowNumber
            )
        }
        windows = sortedRecords(trackedWindows.values.map(\.record))
    }

    private func sortedRecords(_ records: [WindowRecord]) -> [WindowRecord] {
        records.sorted {
            if $0.appName == $1.appName {
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
                    == .orderedAscending
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName)
                == .orderedAscending
        }
    }

    private func currentSnapshot() -> WindowSnapshot {
        WindowSnapshot(
            updatedAt: Date(),
            windows: windows,
            activeWindowID: activeWindowID
        )
    }

    private func persistSnapshot(_ snapshot: WindowSnapshot? = nil) {
        do {
            try OrchardJSON.save(
                snapshot ?? currentSnapshot(),
                to: OrchardPaths.current.snapshot
            )
        } catch {
            logger.error(
                "Unable to persist window snapshot: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func trackRefresh() {
        OrchardTelemetry.track(
            .windowListRefreshed(
                windowCount: windows.count,
                labeledWindowCount: windows.filter {
                    $0.customTitle != nil || $0.color != nil
                }.count,
                accessibilityTrusted: isAccessibilityTrusted
            )
        )
    }

    private func loadLabels() {
        let url = OrchardPaths.current.labels
        guard FileManager.default.fileExists(atPath: url.path) else {
            labels = [:]
            return
        }
        do {
            labels = try OrchardJSON.load([String: WindowLabel].self, from: url)
        } catch {
            labels = [:]
            logger.error(
                "Unable to load labels: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func saveLabels() {
        do {
            try OrchardJSON.save(labels, to: OrchardPaths.current.labels)
        } catch {
            logger.error(
                "Unable to save labels: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}

private struct WindowServerWindow {
    let number: CGWindowID
    let frame: CGRect
}

private func copyWindowServerWindows() -> [pid_t: [WindowServerWindow]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
        let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
    else {
        return [:]
    }

    var windowsByProcess: [pid_t: [WindowServerWindow]] = [:]
    for info in windowInfo {
        guard
            let processNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
            let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
            let layer = info[kCGWindowLayer as String] as? NSNumber,
            layer.intValue == 0,
            let frame = windowServerFrame(from: info)
        else {
            continue
        }

        let processIdentifier = pid_t(processNumber.int32Value)
        windowsByProcess[processIdentifier, default: []].append(
            WindowServerWindow(
                number: CGWindowID(windowNumber.uint32Value),
                frame: frame
            )
        )
    }
    return windowsByProcess
}

private func takeWindowNumber(
    processIdentifier: pid_t,
    frame: CGRect,
    from windowsByProcess: inout [pid_t: [WindowServerWindow]]
) -> CGWindowID? {
    guard var candidates = windowsByProcess[processIdentifier], !candidates.isEmpty else {
        return nil
    }

    let match = candidates.enumerated().min {
        frameDistance($0.element.frame, frame) < frameDistance($1.element.frame, frame)
    }
    guard let match, frameDistance(match.element.frame, frame) <= 32 else {
        return nil
    }

    candidates.remove(at: match.offset)
    windowsByProcess[processIdentifier] = candidates
    return match.element.number
}

private func copyWindowServerFrame(_ windowNumber: CGWindowID) -> CGRect? {
    let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
    guard
        let windowInfo = CGWindowListCopyWindowInfo(options, windowNumber)
            as? [[String: Any]],
        let info = windowInfo.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowNumber
        })
    else {
        return nil
    }
    return windowServerFrame(from: info)
}

private func windowServerFrame(from info: [String: Any]) -> CGRect? {
    guard
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else {
        return nil
    }

    let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(
        x: quartzFrame.minX,
        y: primaryScreenHeight - quartzFrame.minY - quartzFrame.height,
        width: quartzFrame.width,
        height: quartzFrame.height
    )
}

private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    abs(lhs.minX - rhs.minX)
        + abs(lhs.minY - rhs.minY)
        + abs(lhs.width - rhs.width)
        + abs(lhs.height - rhs.height)
}

private func copyWindows(from application: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
        let windows = value as? [AXUIElement]
    else {
        return []
    }
    return windows
}

private func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processIdentifier)
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success
    else {
        return nil
    }
    return (value as! AXUIElement)
}

private func copyString(_ attribute: CFString, from element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

private func copyFrame(from element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue
    else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
        return nil
    }

    let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(
        x: position.x,
        y: primaryScreenHeight - position.y - size.height,
        width: size.width,
        height: size.height
    )
}
