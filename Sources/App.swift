// App.swift - one window listing every skill and what, if anything, to do about it.

import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let invokedAs = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        // package-skills: the command's name before the app was renamed.
        if invokedAs == "skill-bridge" || invokedAs == "package-skills" || args.first == "--cli" {
            exit(CLI.run(args.filter { $0 != "--cli" }))
        }
        SkillBridgeApp.main()
    }
}

struct SkillBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Skill Bridge", id: "main") {
            ContentView()
        }
        .defaultSize(width: 640, height: 680)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Keeps `skill-bridge` in ~/.local/bin pointing at this copy of the app, so the
    /// Terminal command follows the app wherever it is moved. Never replaces a real file.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bin = Skills.home.appendingPathComponent(".local/bin")
        guard let exe = Bundle.main.executableURL, FileManager.default.fileExists(atPath: bin.path) else { return }
        link(bin.appendingPathComponent("skill-bridge"), to: exe, create: true)
        // The command's name before the rename keeps working where it already exists.
        link(bin.appendingPathComponent("package-skills"), to: exe, create: false)
    }

    private func link(_ link: URL, to exe: URL, create: Bool) {
        let fm = FileManager.default
        let existing = try? fm.destinationOfSymbolicLink(atPath: link.path)
        if existing == exe.path { return }
        let absent = existing == nil && !fm.fileExists(atPath: link.path)
        guard existing != nil || (absent && create) else { return }
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: exe)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var report: Report?
    @Published var busy = false
    @Published var error: String?

    func refresh() { run { } }
    func add(_ name: String) { run(adding: [name]) { } }
    func setUp(_ name: String) { run { try Skills.setUp(name) } }
    func hide(_ name: String, _ hide: Bool) { run { try Skills.setHidden(name, hide) } }
    func discard(_ name: String) { run { Skills.discard(name) } }

    /// Does `action`, then checks everything again, off the main thread.
    private func run(adding: [String] = [], _ action: @escaping @Sendable () throws -> Void) {
        guard !busy else { return }
        busy = true
        Task.detached {
            let failure: String?
            do { try action(); failure = nil } catch { failure = error.localizedDescription }
            let report = Skills.check(adding: adding)
            await MainActor.run {
                self.report = report
                self.error = failure
                self.busy = false
            }
        }
    }

    func openFolderAndClaude() {
        NSWorkspace.shared.open(Skills.outDir)
        if let claude = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: claude, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @AppStorage("showLocal") private var showLocal = false
    @AppStorage("showHidden") private var showHidden = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = model.report {
                if report.noSync { noSync } else { content(report) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        .onAppear { model.refresh() }
        // Back from uploading in the Claude app: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.report != nil { model.refresh() }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Skill Bridge").font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.busy)
                .keyboardShortcut("r")
        }
        .padding(16)
    }

    private var subtitle: String {
        guard let at = model.report?.syncedAt else { return "Your skills compared with your Claude account" }
        return "Compared with your Claude account as of \(at.formatted(date: .abbreviated, time: .shortened))"
    }

    private var noSync: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Can't find your Claude account's skills on this Mac").font(.headline)
            Text("Open Claude Code once and sign in. It downloads your skills, then press Refresh.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ report: Report) -> some View {
        let upload = report.rows.filter { if case .upload = $0.state { return true }; if case .failed = $0.state { return true }; return false }
        let onlyClaude = report.rows.filter { if case .onlyInClaude = $0.state { return true }; return false }
        let upToDate = report.rows.filter { if case .upToDate = $0.state { return true }; return false }
        let onlyMac = report.rows.filter { if case .onlyOnMac = $0.state { return true }; return false }
        let hidden = report.rows.filter { if case .hidden = $0.state { return true }; return false }

        banner(uploads: upload.filter { if case .upload = $0.state { return true }; return false }.count)
        List {
            if !upload.isEmpty {
                Section("To upload") { ForEach(upload) { row($0) } }
            }
            if !onlyClaude.isEmpty {
                Section("In your Claude account, not on this Mac") { ForEach(onlyClaude) { row($0) } }
            }
            if !upToDate.isEmpty {
                Section("Up to date") { ForEach(upToDate) { row($0) } }
            }
            if !onlyMac.isEmpty {
                Section {
                    if showLocal { ForEach(onlyMac) { row($0) } }
                } header: {
                    foldingHeader("On this Mac, not in Claude (\(onlyMac.count))", isOpen: $showLocal)
                }
            }
            if !hidden.isEmpty {
                Section {
                    if showHidden { ForEach(hidden) { row($0) } }
                } header: {
                    foldingHeader("Hidden (\(hidden.count))", isOpen: $showHidden)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    /// A section header that opens and closes its section; the whole line is the click target.
    private func foldingHeader(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func banner(uploads: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if uploads > 0 {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(uploads == 1 ? "1 skill to upload" : "\(uploads) skills to upload").font(.headline)
                    Text("In the Claude app: Settings → Capabilities → Skills. Replace the old version.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Folder & Claude") { model.openFolderAndClaude() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything matches your Claude account").font(.headline)
                    Text("Nothing to upload.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(uploads > 0 ? Color.orange.opacity(0.08) : Color.green.opacity(0.06))
    }

    private func row(_ row: SkillRow) -> some View {
        let (icon, color, detail) = describe(row.state)
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                ForEach(row.notes.filter { $0.hasPrefix("WARNING") }, id: \.self) {
                    Text($0.replacingOccurrences(of: "WARNING: ", with: "⚠︎ ")).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            actions(row)
        }
        .padding(.vertical, 3)
    }

    private func describe(_ state: SkillRow.State) -> (String, Color, String) {
        switch state {
        case .upload(new: true): return ("plus.circle.fill", .orange, "Not in your Claude account yet")
        case .upload(new: false): return ("arrow.up.circle.fill", .orange, "Newer on this Mac than in Claude")
        case .upToDate: return ("checkmark.circle.fill", .green, "Same as in Claude")
        case .onlyInClaude: return ("icloud.and.arrow.down", .blue, "Set it up here to edit it on this Mac")
        case .onlyOnMac: return ("circle.dashed", .secondary, "Only on this Mac")
        case .hidden: return ("eye.slash", .secondary, "Not offered for this Mac")
        case .failed(let why): return ("exclamationmark.triangle.fill", .red, why)
        }
    }

    @ViewBuilder
    private func actions(_ row: SkillRow) -> some View {
        HStack(spacing: 6) {
            switch row.state {
            case .upload(let new):
                Button("Show ZIP") { NSWorkspace.shared.activateFileViewerSelecting([Skills.zip(for: row.name)]) }
                if new { Button("Cancel") { model.discard(row.name) } }
            case .upToDate:
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([Skills.skillsDir.appendingPathComponent(row.name)]) }
            case .onlyInClaude:
                Button("Set Up Here") { model.setUp(row.name) }
                Button("Hide") { model.hide(row.name, true) }
            case .onlyOnMac:
                Button("Add to Claude") { model.add(row.name) }
            case .hidden:
                Button("Unhide") { model.hide(row.name, false) }
            case .failed:
                EmptyView()
            }
        }
        .controlSize(.small)
        .disabled(model.busy)
    }
}
