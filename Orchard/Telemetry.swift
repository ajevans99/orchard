import Foundation
import OSLog
import TelemetryDeck

enum OrchardFocusSource: String, Equatable {
    case commandLine
    case menuBar
}

enum OrchardTelemetryEvent: Equatable {
    case appLaunched(accessibilityTrusted: Bool)
    case appQuit
    case menuPresented(windowCount: Int, labeledWindowCount: Int, accessibilityTrusted: Bool)
    case accessibilitySettingsOpened
    case accessibilityStatusChanged(isTrusted: Bool)
    case windowListRefreshed(windowCount: Int, labeledWindowCount: Int, accessibilityTrusted: Bool)
    case windowTitleChanged(hasTitle: Bool)
    case windowColorChanged(color: OrchardColor)
    case windowLabelCleared
    case windowFocused(source: OrchardFocusSource, succeeded: Bool)

    var signalName: String {
        switch self {
        case .appLaunched:
            "app.launched"
        case .appQuit:
            "app.quit"
        case .menuPresented:
            "menu.presented"
        case .accessibilitySettingsOpened:
            "accessibility.settings.opened"
        case .accessibilityStatusChanged:
            "accessibility.status.changed"
        case .windowListRefreshed:
            "windowList.refreshed"
        case .windowTitleChanged:
            "window.title.changed"
        case .windowColorChanged:
            "window.color.changed"
        case .windowLabelCleared:
            "window.label.cleared"
        case .windowFocused:
            "window.focused"
        }
    }

    var parameters: [String: String] {
        switch self {
        case .appLaunched(let accessibilityTrusted):
            ["accessibilityTrusted": String(accessibilityTrusted)]
        case .appQuit, .accessibilitySettingsOpened, .windowLabelCleared:
            [:]
        case let .menuPresented(windowCount, labeledWindowCount, accessibilityTrusted),
             let .windowListRefreshed(windowCount, labeledWindowCount, accessibilityTrusted):
            [
                "windowCount": String(windowCount),
                "labeledWindowCount": String(labeledWindowCount),
                "accessibilityTrusted": String(accessibilityTrusted),
            ]
        case .accessibilityStatusChanged(let isTrusted):
            ["isTrusted": String(isTrusted)]
        case .windowTitleChanged(let hasTitle):
            ["hasTitle": String(hasTitle)]
        case .windowColorChanged(let color):
            ["color": color.rawValue]
        case let .windowFocused(source, succeeded):
            [
                "source": source.rawValue,
                "succeeded": String(succeeded),
            ]
        }
    }
}

enum OrchardTelemetry {
    private static let appIDKey = "OrchardTelemetryAppID"
    private static var isConfigured = false
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Orchard",
        category: "Telemetry"
    )

    static func configure() {
        let rawAppID = Bundle.main.object(forInfoDictionaryKey: appIDKey) as? String ?? ""
        let appID = rawAppID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !appID.isEmpty else {
            logger.warning("Telemetry not configured: \(appIDKey, privacy: .public) is missing")
            return
        }
        guard UUID(uuidString: appID) != nil else {
            logger.error("Telemetry not configured: \(appIDKey, privacy: .public) is not a UUID")
            return
        }

        let config = TelemetryDeck.Config(appID: appID)
        config.defaultSignalPrefix = "Orchard."
        config.analyticsDisabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        TelemetryDeck.initialize(config: config)
        isConfigured = true
    }

    static func track(_ event: OrchardTelemetryEvent) {
        guard isConfigured else { return }
        TelemetryDeck.signal(event.signalName, parameters: event.parameters)
    }

    static func flush() {
        guard isConfigured else { return }
        TelemetryDeck.requestImmediateSync()
    }
}
