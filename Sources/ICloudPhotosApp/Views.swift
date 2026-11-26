#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.background
            Group {
                switch model.phase {
                case .signedOut, .signingIn:
                    SignInView()
                case .needsCode:
                    VerificationView()
                case .needsTwoStep:
                    TwoStepView()
                case .signedIn, .restoring:
                    DownloadView()
                }
            }
            .transition(.blurReplace)
        }
        .animation(.smooth(duration: 0.3), value: model.phase)
        .frame(minWidth: 900, minHeight: 640)
        // The window has no title bar: the content runs to the top edge, and the window buttons
        // are moved inside the panel in the top-left corner.
        .background(WindowButtonsPlacer())
        .ignoresSafeArea()
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

enum Initials {
    /// "Alex Morgan" gives "AM"; an email address gives its first letter.
    static func of(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(name.contains("@") ? 1 : 2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

// MARK: Download

struct DownloadView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAlbums = false
    @State private var settingsPane: SettingsPane = .general

    var body: some View {
        HStack(spacing: WindowButtons.margin) {
            // Setup and settings take over both columns: their steps or sections in the sidebar,
            // the chosen one beside it.
            if model.page == .setup {
                SetupFlow()
                    .transition(.opacity)
            } else if model.page == .settings {
                SettingsSidebar(pane: $settingsPane)
                    .transition(.opacity)
                SettingsStage(pane: settingsPane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                AppSidebar()
                    .transition(.opacity)
                Group {
                    if model.page == .activity { activityStage } else { HomeStage(showingAlbums: $showingAlbums) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .padding(WindowButtons.margin)
        .animation(.smooth(duration: 0.22), value: model.page)
        .sheet(isPresented: $showingAlbums) {
            AlbumPicker().environmentObject(model)
        }
        .confirmationDialog("Delete photos from iCloud?", isPresented: $model.pendingDestructiveRun) {
            Button("Download and Delete from iCloud", role: .destructive) { model.startDownload(confirmed: true) }
            Button("Dry Run First") { model.startDownload(dryRun: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destructiveMessage)
        }
    }

    // MARK: Activity

    @ViewBuilder private var activityStage: some View {
        if model.hasRun {
            runStage
        } else {
            VStack(spacing: 14) {
                HeroTile(systemName: "waveform.path.ecg")
                Text("Nothing has run yet")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
                Text("Start a sync or a dry run from Home, and its progress and activity show here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button { model.page = .library } label: { Text("Go to Home").frame(width: 120) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                    .padding(.top, 6)
            }
            .padding(.bottom, 24)
        }
    }

    private func startButtons(large: Bool) -> some View {
        HStack(spacing: 12) {
            Button { model.startDownload(dryRun: true) } label: {
                Label("Dry Run", systemImage: "eye")
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: large ? 50 : 44))
            .help("See what would be downloaded, moved or deleted, without changing anything")

            Button { model.startDownload() } label: {
                Label(model.config.albums.isEmpty ? "Download All Photos" : "Download Albums", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(PillButtonStyle(height: large ? 50 : 44))
            .keyboardShortcut(.defaultAction)
        }
        .disabled(model.directory == nil || model.phase != .signedIn)
    }

    // MARK: Running and finished

    private var runStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 22) {
                ProgressRing(progress: fraction) {
                    if let fraction {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int((fraction * 100).rounded(.down)))")
                                .font(.system(size: 42, weight: .semibold))
                                .tracking(-1.5)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("%").font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                    } else if model.isDownloading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: outcomeSymbol).font(.system(size: 40, weight: .medium))
                    }
                }
                .frame(width: 160, height: 160)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Progress")
                .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "")

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let album = model.currentAlbum {
                            Text(album)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(red: 0.61, green: 0.8, blue: 1))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Theme.accent.opacity(0.22), in: .capsule)
                                .padding(.bottom, 4)
                        }
                        Text(runTitle)
                            .font(.system(size: 25, weight: .semibold))
                            .tracking(-0.6)
                        if model.runKind == .download {
                            Text("\(model.processed.formatted())\(model.total.map { " of \($0.formatted())" } ?? "") checked")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.secondary)
                                .monospacedDigit()
                        }
                    }
                    if model.isDownloading {
                        Button { model.stopDownload() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                    } else {
                        startButtons(large: false)
                    }
                }
                Spacer(minLength: 0)
            }

            // A delete list downloads nothing, so it has no numbers to show here.
            if model.runKind == .download {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(stats) { StatCard(stat: $0) }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Activity")
                ActivityList(lines: model.log)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var fraction: Double? {
        guard let total = model.total, total > 0 else { return nil }
        return Double(min(model.processed, total)) / Double(total)
    }

    private var runTitle: String {
        let dry = model.currentDryRun
        let deleteList = model.runKind == .deleteList
        if model.isDownloading {
            if deleteList { return dry ? "Checking the delete list" : "Deleting listed photos" }
            return dry ? "Checking your library" : "Downloading your photos"
        }
        switch model.outcome {
        case .stopped: return "Stopped"
        case .failed: return "Couldn't finish"
        case .finished:
            if deleteList { return dry ? "Delete list checked" : "Delete list finished" }
            return dry ? "Dry run finished" : "Finished"
        }
    }

    private var outcomeSymbol: String {
        switch model.outcome {
        case .finished: return "checkmark"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var stats: [Stat] {
        let dry = model.currentDryRun
        var list = [
            Stat(title: dry ? "To download" : "New", value: model.downloaded,
                 caption: dry ? "Dry run" : ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file)),
            Stat(title: "Already saved", value: model.skipped, caption: "Skipped"),
        ]
        if model.deletedFromICloud > 0 {
            list.append(Stat(title: dry ? "To delete in iCloud" : "Deleted in iCloud", value: model.deletedFromICloud, caption: "Recently Deleted"))
        }
        if model.deletedLocally > 0 {
            list.append(Stat(title: dry ? "To remove here" : "Removed here", value: model.deletedLocally, caption: "Deleted in iCloud"))
        }
        if model.pruned > 0 {
            list.append(Stat(title: dry ? "To move aside" : "Moved aside", value: model.pruned, caption: "Gone from iCloud"))
        }
        if model.failed > 0 {
            list.append(Stat(title: "Failed", value: model.failed, caption: "See activity", isBad: true))
        }
        return list
    }

    // MARK: Helpers

    private var destructiveMessage: String {
        var text = "Photos go to Recently Deleted in iCloud once they are safely on this Mac"
        if let days = model.config.keepICloudRecentDays { text += ", except the last \(days) days" }
        return text + ". Recently Deleted keeps them for 30 days."
    }

}

struct Stat: Identifiable {
    let title: String
    let value: Int
    let caption: String
    var isBad = false
    var id: String { title }
}

struct StatCard: View {
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.title).font(.system(size: 12)).foregroundStyle(stat.isBad ? Theme.dangerSoft : Theme.secondary)
            Text(stat.value.formatted())
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(stat.caption).font(.system(size: 12)).foregroundStyle(stat.isBad ? Theme.dangerSoft : Theme.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(fill: stat.isBad ? Theme.danger.opacity(0.14) : Theme.panelFill,
               stroke: stat.isBad ? Theme.dangerSoft.opacity(0.3) : Theme.panelStroke)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Album picker

struct AlbumPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Albums")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                Spacer()
                Button { Task { await model.loadAlbums() } } label: { CircleIcon(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Reload albums")
                    .accessibilityLabel("Reload albums")
                Button("Done") { dismiss() }
                    .buttonStyle(PillButtonStyle(height: 32))
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .panel(cornerRadius: 18, fill: Theme.fieldFill, stroke: Color.white.opacity(0.1))

            // A row to pick like the albums below, not a switch: a switch could be flipped off,
            // and there is nothing for "not All Photos" to mean until an album is chosen.
            Card {
                let isOn = model.config.albums.isEmpty
                Button { model.config.albums = [] } label: {
                    CardRow(minHeight: 42) {
                        Text("All Photos")
                        Spacer(minLength: 8)
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(isOn ? Theme.accentSoft : Color.white.opacity(0.3))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }

            HStack {
                SectionHeader(title: model.config.albums.isEmpty ? "Albums" : "Albums · \(model.config.albums.count) selected")
                if model.isLoadingAlbums { ProgressView().controlSize(.small) }
            }
            .padding(.top, 2)

            ScrollView {
                Card {
                    ForEach(filtered, id: \.self) { name in
                        let isOn = model.config.albums.contains(name)
                        Button {
                            if isOn { model.config.albums.removeAll { $0 == name } } else { model.config.albums.append(name) }
                        } label: {
                            CardRow(minHeight: 42) {
                                Text(name).lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(isOn ? Theme.accentSoft : Color.white.opacity(0.3))
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
                if filtered.isEmpty && !model.isLoadingAlbums {
                    Text(search.isEmpty ? "No albums in this library." : "No albums match \"\(search)\".")
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
        .frame(width: 440, height: 560)
        .background(Theme.sheet)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task { if model.albums.isEmpty { await model.loadAlbums() } }
    }

    private var filtered: [String] {
        search.isEmpty ? model.albums : model.albums.filter { $0.localizedCaseInsensitiveContains(search) }
    }
}

// MARK: Activity

/// The run's log, newest at the bottom, in a card.
struct ActivityList: View {
    let lines: [AppModel.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 10) {
                            Image(systemName: line.isError ? "exclamationmark.circle.fill" : "circle.fill")
                                .font(.system(size: line.isError ? 13 : 5))
                                .foregroundStyle(line.isError ? Theme.dangerSoft : Color.white.opacity(0.3))
                                .frame(width: 14)
                            Text(line.text)
                                .font(.system(size: 12))
                                .foregroundStyle(line.isError ? Theme.dangerSoft : Color.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        .id(line.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .overlay {
                if lines.isEmpty {
                    Text("Nothing yet.").foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            // The newest line, not the count: the count stops changing once old lines are dropped.
            .onChange(of: lines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}
#endif
