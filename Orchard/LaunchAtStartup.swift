import ServiceManagement

@MainActor
enum OrchardLaunchAtStartup {
    static let preferenceKey = "launchOnStartup"

    static func registerDefault(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [preferenceKey: true])
    }

    static func synchronize(
        defaults: UserDefaults = .standard,
        service: SMAppService = .mainApp
    ) throws {
        registerDefault(in: defaults)
        try setEnabled(defaults.bool(forKey: preferenceKey), service: service)
    }

    static func setEnabled(
        _ isEnabled: Bool,
        service: SMAppService = .mainApp
    ) throws {
        if isEnabled {
            guard service.status != .enabled, service.status != .requiresApproval else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
