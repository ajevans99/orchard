import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: OrchardController
    @State private var searchText = ""

    private var filteredWindows: [WindowRecord] {
        guard !searchText.isEmpty else { return controller.windows }
        return controller.windows.filter {
            $0.appName.localizedCaseInsensitiveContains(searchText)
                || $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                || $0.nativeTitle.localizedCaseInsensitiveContains(searchText)
        }
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
                .frame(maxHeight: 430)
            }

            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Orchard")
                    .font(.headline)
                Text("Name, color, and focus your windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
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
                TextField(window.nativeTitle, text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit {
                        controller.rename(window.id, title: draftTitle)
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
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: window.customTitle) { _, title in
            draftTitle = title ?? ""
        }
    }
}

private extension OrchardColor {
    var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }
}
