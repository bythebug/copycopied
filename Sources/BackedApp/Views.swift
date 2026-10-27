import AppKit
import BackedCore
import ServiceManagement
import SwiftUI

extension Verdict.Orb {
    var color: Color {
        switch self {
        case .red: Color(red: 1, green: 0.27, blue: 0.23)
        case .grey: Color(white: 0.82)
        case .green: Color(red: 0.2, green: 0.84, blue: 0.42)
        }
    }

    var nsColor: NSColor { NSColor(color) }
}

/// Placeholder orb: a soft sphere that breathes while working. The particle orb is Phase 8.
struct Orb: View {
    var verdict: Verdict
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var working: Bool {
        switch verdict {
        case .reading, .copying, .verifying: true
        default: false
        }
    }

    var body: some View {
        let c = verdict.orb.color
        Circle()
            .fill(RadialGradient(colors: [c.opacity(0.95), c.opacity(0.35), c.opacity(0.05)],
                                 center: .center, startRadius: 2, endRadius: 26))
            .frame(width: 48, height: 48)
            .phaseAnimator(working && !reduceMotion ? [0.88, 1.0] : [1.0]) { view, scale in
                view.scaleEffect(scale)
            } animation: { _ in .easeInOut(duration: 1.2) }
            .accessibilityHidden(true)
    }
}

struct CardRow: View {
    var card: AppModel.Card
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Orb(verdict: card.verdict)
                VStack(alignment: .leading, spacing: 3) {
                    Label(card.name, systemImage: "sdcard").font(.headline)
                    ForEach(Array(card.verdict.lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(i == 0 ? .callout : .caption)
                            .foregroundStyle(i == 0 ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .contextMenu {
                Button("Not a card") { model.setRole(.ignored, id: card.id, name: card.name) }
            }
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch card.verdict {
        case .notBacked, .partiallyBacked, .problem:
            HStack {
                Spacer()
                // "New shoot…" (the primary action) arrives with shoots and folders in Phase 4.
                Button("Choose folder…") { chooseFolder() }
            }
        case let .fromMemory(_, drive, _):
            Text("Plug in \(drive) to copy.").font(.caption).foregroundStyle(.secondary)
        case .backed:
            if let folder = card.lastFolder {
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
            }
        default:
            EmptyView()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy here"
        panel.message = "Choose where \(card.name)'s files should go. Only files that aren't already on that drive are copied."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.copy(card.id, to: url)
    }
}

struct PopoverView: View {
    var model: AppModel
    var openMain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.startupError {
                Text(error).foregroundStyle(.red)
            }
            if model.cards.isEmpty {
                Text("No card plugged in.").foregroundStyle(.secondary)
            }
            ForEach(model.cards) { card in
                CardRow(card: card, model: model)
                if card.id != model.cards.last?.id { Divider() }
            }

            Divider()
            Text("Also plugged in").font(.caption).foregroundStyle(.secondary)
            if model.others.isEmpty {
                Text("No drives").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.others) { v in
                HStack {
                    Label(v.name, systemImage: "externaldrive")
                    Spacer()
                    Menu(roleName(v.role)) {
                        Button("Working drive") { model.setRole(.workingDrive, id: v.id, name: v.name) }
                        Button("Backup") { model.setRole(.backupDrive, id: v.id, name: v.name) }
                        Button("Not used") { model.setRole(.ignored, id: v.id, name: v.name) }
                        Divider()
                        Button("Treat as a card") { model.setRole(.card, id: v.id, name: v.name) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("Open backed", action: openMain).buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func roleName(_ role: VolumeRole?) -> String {
        switch role {
        case .workingDrive: "Working drive"
        case .backupDrive: "Backup"
        case .card: "Card"
        case .ignored, nil: "Not used"
        }
    }
}

/// The main window for now: launch at login and the logs. Shoots, drives and cameras come in Phases 4–5.
struct MainView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Open backed. when you log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = "Couldn't change this: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Button("Show copy logs in Finder") {
                if let dir = try? Store.defaultURL().deletingLastPathComponent().appendingPathComponent("logs") {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
