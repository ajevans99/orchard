import AppKit
import ApplicationServices
import Combine

@MainActor
final class OrchardController: ObservableObject {
    @Published private(set) var windows: [WindowRecord] = []
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    private struct TrackedWindow {
        let record: WindowRecord
        let processIdentifier: pid_t
        let element: AXUIElement
        let frame: CGRect
    }

    private var trackedWindows: [String: TrackedWindow] = [:]
    private var labels: [String: WindowLabel] = [:]
    private var refreshTimer: Timer?
    private let outlineController = OutlineController()

    init() {
        loadLabels()
        refresh()

        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        openAccessibilitySettings()
    }

    func refresh() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        loadLabels()

        guard isAccessibilityTrusted else {
            windows = []
            trackedWindows = [:]
            outlineController.hide()
            return
        }

        let tracked = discoverWindows()
        trackedWindows = Dictionary(uniqueKeysWithValues: tracked.map { ($0.record.id, $0) })
        windows = tracked.map(\.record).sorted {
            if $0.appName == $1.appName {
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }

        try? OrchardFiles.save(
            WindowSnapshot(updatedAt: Date(), windows: windows),
            to: OrchardFiles.snapshot
        )
        processPendingCommand()
        updateOutline()
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
        refresh()
    }

    func setColor(_ windowID: String, color: OrchardColor) {
        var label = labels[windowID] ?? WindowLabel(title: nil, color: nil)
        label.color = color
        labels[windowID] = label
        saveLabels()
        refresh()
    }

    func clear(_ windowID: String) {
        labels.removeValue(forKey: windowID)
        saveLabels()
        refresh()
    }

    func focus(_ windowID: String) {
        guard let tracked = trackedWindows[windowID] else { return }
        NSRunningApplication(processIdentifier: tracked.processIdentifier)?
            .activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(tracked.element, kAXRaiseAction as CFString)
    }

    private func discoverWindows() -> [TrackedWindow] {
        var discovered: [TrackedWindow] = []
        var occurrences: [String: Int] = [:]

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
                let id = WindowIdentifier.make(
                    bundleIdentifier: bundleIdentifier,
                    nativeTitle: normalizedTitle,
                    occurrence: occurrence
                )
                let label = labels[id]
                let record = WindowRecord(
                    id: id,
                    appName: appName,
                    bundleIdentifier: bundleIdentifier,
                    nativeTitle: normalizedTitle,
                    customTitle: label?.title,
                    color: label?.color
                )

                guard let frame = copyFrame(from: element), frame.width > 40, frame.height > 40 else {
                    continue
                }
                discovered.append(
                    TrackedWindow(
                        record: record,
                        processIdentifier: application.processIdentifier,
                        element: element,
                        frame: frame
                    )
                )
            }
        }

        return discovered
    }

    private func updateOutline() {
        guard
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let focusedElement = focusedWindow(for: frontmostPID),
            let tracked = trackedWindows.values.first(where: {
                $0.processIdentifier == frontmostPID && CFEqual($0.element, focusedElement)
            }),
            let label = labels[tracked.record.id]
        else {
            outlineController.hide()
            return
        }

        outlineController.show(frame: tracked.frame, color: (label.color ?? .green).nsColor)
    }

    private func processPendingCommand() {
        guard
            let command = try? OrchardFiles.load(OrchardCommand.self, from: OrchardFiles.command)
        else {
            return
        }
        try? FileManager.default.removeItem(at: OrchardFiles.command)

        switch command.action {
        case .focus:
            focus(command.windowID)
        }
    }

    private func loadLabels() {
        labels = (try? OrchardFiles.load([String: WindowLabel].self, from: OrchardFiles.labels)) ?? [:]
    }

    private func saveLabels() {
        try? OrchardFiles.save(labels, to: OrchardFiles.labels)
    }

    private func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
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
