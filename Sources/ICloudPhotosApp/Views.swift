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

    var body: some View {
        HStack(spacing: WindowButtons.margin) {
            // The easy setup takes over both columns: its steps in the sidebar, one question beside
            // them. Every other page keeps the main sidebar, Settings included.
            if model.page == .setup {
                SetupFlow()
            } else {
                AppSidebar()
                Group {
                    switch model.page {
                    case .activity: activityStage
                    case .settings: SettingsStage(pane: $model.settingsPane)
                    case .syncChoice: SyncChoiceStage()
                    default:
                        if model.hasOnboarded { HomeStage() } else { WelcomeStage() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A new page replaces the old one at once. Only the sidebar animates the move:
                // fading two whole pages into each other is what looked jumpy.
            }
        }
        .padding(WindowButtons.margin)
        .confirmationDialog("Remove photos from iCloud?", isPresented: $model.pendingDestructiveRun) {
            Button("Save Here, Then Remove from iCloud", role: .destructive) { model.startDownload(confirmed: true) }
            Button("Preview First") { model.startDownload(dryRun: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destructiveMessage)
        }
    }

    // MARK: Activity

    @ViewBuilder private var activityStage: some View {
        if model.hasRun {
            ActivityStage()
        } else {
            VStack(spacing: 14) {
                HeroTile(systemName: "waveform.path.ecg")
                Text("Nothing has run yet")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
                Text("Press Sync Now or Preview on Home, and how it's going shows here.")
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

    // MARK: Helpers

    private var destructiveMessage: String {
        var text = "Photos go to Recently Deleted in iCloud once they are safely on this Mac"
        if let days = model.config.keepICloudRecentDays { text += ", except the last \(days) days" }
        return text + ". Recently Deleted keeps them for 30 days."
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
