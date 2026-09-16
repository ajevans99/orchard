import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OrchardController
    @AppStorage(OrchardLaunchAtStartup.preferenceKey) private var launchOnStartup = true
    @State private var searchText = ""
    @State private var launchOnStartupError: String?

    private var filteredWindows: [WindowRecord] {
        var matchingWindows = controller.windows
        if !searchText.isEmpty {
            matchingWindows = matchingWindows.filter {
                $0.appName.localizedCaseInsensitiveContains(searchText)
                    || $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                    || $0.nativeTitle.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let activeWindowID = controller.activeWindowID,
           let activeIndex = matchingWindows.firstIndex(where: { $0.id == activeWindowID }) {
            let activeWindow = matchingWindows.remove(at: activeIndex)
            matchingWindows.insert(activeWindow, at: 0)
        }
        return matchingWindows
    }

    private var windowListHeight: CGFloat {
        min(max(CGFloat(filteredWindows.count) * 62, 100), 430)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !controller.isAccessibilityTrusted {
                permissionView
            } else if controller.windows.isEmpty {
                ContentUnavailableView(
                    "No Windows Found",
                    systemImage: "macwindow",
                    description: Text("Open an app window, then refresh Orchard.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                TextField("Find a window", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("window-search")
                    .padding(12)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredWindows) { window in
                            WindowRow(window: window, controller: controller)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .frame(height: windowListHeight)
            }

            Divider()
            launchOptions
            Divider()
            footer
        }
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchard-menu")
        .onAppear {
            OrchardTelemetry.track(
                .menuPresented(
                    windowCount: controller.windows.count,
                    labeledWindowCount: controller.windows.filter {
                        $0.customTitle != nil || $0.color != nil
                    }.count,
                    accessibilityTrusted: controller.isAccessibilityTrusted
                )
            )
        }
    }

    private var launchOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch on startup", isOn: $launchOnStartup)
                .onChange(of: launchOnStartup) {
                    launchOnStartupChanged()
                }

            if let launchOnStartupError {
                Text(launchOnStartupError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func launchOnStartupChanged() {
        do {
            try OrchardLaunchAtStartup.setEnabled(launchOnStartup)
            launchOnStartupError = nil
        } catch {
            launchOnStartupError = "Could not update startup setting: \(error.localizedDescription)"
        }
    }

    private var header: some View {
        HStack {
            Text("Orchard")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "accessibility")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("Accessibility Access Required")
                .font(.headline)
            Text("Orchard uses macOS Accessibility to find, outline, and focus windows. It never captures their contents.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Accessibility Settings") {
                controller.requestAccessibilityAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 250)
    }

    private var footer: some View {
        HStack {
            Button {
                controller.refresh(manual: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                controller.showIdentityInspector()
            } label: {
                Label("Inspect", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
            .help("See why Orchard attached or detached a tag")
            .accessibilityIdentifier("inspect-window-identity")

            Spacer()

            Text("\(controller.windows.count) windows")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                OrchardTelemetry.track(.appQuit)
                OrchardTelemetry.flush()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }
}

@MainActor
final class IdentityInspectorWindowController: NSWindowController {
    init(controller: OrchardController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Window Identity"
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WindowIdentityInspector(controller: controller))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct WindowIdentityInspector: View {
    @ObservedObject var controller: OrchardController
    @State private var selectedWindowID: String?

    private var inspectedWindowID: String? {
        selectedWindowID ?? controller.activeWindowID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Inspect", selection: $selectedWindowID) {
                Text("Follow active window").tag(String?.none)
                ForEach(controller.windows) { window in
                    Text("\(window.appName): \(window.displayTitle)").tag(Optional(window.id))
                }
            }
            .accessibilityIdentifier("identity-window-picker")

            if let id = inspectedWindowID,
               let window = controller.windows.first(where: { $0.id == id }),
               let diagnostics = controller.windowDiagnostics[id] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GroupBox("Why this tag?") {
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("Application", value: window.appName)
                                LabeledContent("Native title", value: window.nativeTitle)
                                LabeledContent("Tag", value: window.customTitle ?? "No title tag")
                                LabeledContent("Color", value: window.color?.displayName ?? "None")
                                LabeledContent("Identity source", value: diagnostics.sourceDescription)
                                    .accessibilityIdentifier("identity-source")
                                Text(diagnostics.persistenceDescription)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                        GroupBox("Observed identity") {
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("Orchard ID", value: diagnostics.windowID)
                                LabeledContent("Process ID", value: String(diagnostics.processIdentifier))
                                LabeledContent("Bundle ID", value: window.bundleIdentifier)
                                LabeledContent("AX document", value: diagnostics.document ?? "Not exposed")
                                LabeledContent("Resolved context", value: diagnostics.contextPath ?? "Unavailable")
                                if let head = diagnostics.head {
                                    LabeledContent("Git HEAD", value: head)
                                }
                                LabeledContent("Matching windows", value: String(diagnostics.matchingContextCount))
                                if let error = diagnostics.contextError {
                                    Text(error)
                                        .foregroundStyle(.red)
                                }
                            }
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                        GroupBox("Recent identity decisions") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(diagnostics.transitions.reversed()) { transition in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(transition.date.formatted(date: .omitted, time: .standard))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(transition.summary)
                                        if let previous = transition.previousWindowID,
                                           previous != transition.windowID {
                                            Text("\(previous) -> \(transition.windowID)")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                    .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView(
                    "No Window to Inspect",
                    systemImage: "macwindow",
                    description: Text("Focus another app or choose a live window. A pinned identity may have closed or changed.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Local diagnostics only. The latest 10 decisions per live window are included in Orchard's local snapshot, never telemetry.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 360)
    }
}

private struct WindowRow: View {
    let window: WindowRecord
    @ObservedObject var controller: OrchardController
    @State private var draftTitle: String
    @FocusState private var isTitleFocused: Bool

    private var isActive: Bool {
        controller.activeWindowID == window.id
    }

    private var accentColor: Color {
        window.color?.swiftUIColor ?? .accentColor
    }

    init(window: WindowRecord, controller: OrchardController) {
        self.window = window
        self.controller = controller
        _draftTitle = State(initialValue: window.customTitle ?? "")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                controller.focus(window.id)
            } label: {
                Image(systemName: "scope")
                    .font(.title3)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Focus this window")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .font(.caption)
                        .foregroundStyle(window.color?.swiftUIColor ?? .secondary)
                    TextField("Add a title tag", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .focused($isTitleFocused)
                    if isActive {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.14), in: Capsule())
                            .accessibilityIdentifier("active-window-badge")
                    }
                }
                    .onSubmit {
                        saveTitle()
                    }
                Text("\(window.appName) · \(window.nativeTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                ForEach(OrchardColor.allCases) { color in
                    Button {
                        controller.setColor(window.id, color: color)
                    } label: {
                        Label(color.displayName, systemImage: "circle.fill")
                    }
                }
            } label: {
                Circle()
                    .fill((window.color ?? .green).swiftUIColor)
                    .frame(width: 14, height: 14)
            }
            .menuStyle(.borderlessButton)
            .help("Outline color")

            if window.customTitle != nil || window.color != nil {
                Button {
                    draftTitle = ""
                    controller.clear(window.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear label")
            }
        }
        .padding(10)
        .background(
            isActive ? accentColor.opacity(0.14) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window-row-\(window.id)")
        .onChange(of: window.customTitle) { _, title in
            draftTitle = title ?? ""
        }
        .onChange(of: isTitleFocused) { _, isFocused in
            if !isFocused {
                saveTitle()
            }
        }
    }

    private func saveTitle() {
        let savedTitle = window.customTitle ?? ""
        guard draftTitle != savedTitle else { return }
        controller.rename(window.id, title: draftTitle)
    }
}

private extension OrchardColor {
    var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }
}
