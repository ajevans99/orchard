import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OrchardController
    @State private var searchText = ""

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
            footer
        }
        .frame(width: 420)
        .accessibilityIdentifier("orchard-menu")
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
                controller.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(controller.windows.count) windows")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
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
