#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// What Sync Now opens: do the same as last time, or change something first.
struct SyncChoiceStage: View {
    @EnvironmentObject var model: AppModel

    private var removing: Bool { model.config.deletesFromICloud }
    private var canStart: Bool { model.phase == .signedIn && model.directory != nil && !model.isDownloading }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sync Now")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accentSoft)
                        Text("What would you like to do?")
                            .font(.system(size: 34, weight: .bold))
                            .tracking(-1)
                        Text("Pick one. Nothing happens until you do.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                    }

                    VStack(spacing: 12) {
                        BigChoice(symbol: "arrow.clockwise", tint: Theme.accentSoft,
                                  title: model.lastRun == nil ? "Go with my plan" : "Same as last time",
                                  text: PlanWords.what(model.config, immich: model.sendsToImmich, keepLocal: model.immichKeepLocal)
                                      + folderSentence,
                                  note: removing ? "Removed photos wait in Recently Deleted for 30 days, so you can still get them back." : nil,
                                  action: start)
                            .disabled(!canStart)
                        BigChoice(symbol: "slider.horizontal.3", tint: Color(white: 0.9),
                                  title: "Change something",
                                  text: "Choose different photos or a different folder, or stop removing photos from iCloud.",
                                  note: nil) { model.page = .setup }
                    }

                    if model.phase != .signedIn {
                        Label("Connecting to iCloud…", systemImage: "icloud")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }

                    HStack {
                        Button { model.startDownload(dryRun: true) } label: {
                            Label("Not sure? Preview first. Nothing is changed.", systemImage: "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentSoft)
                        .disabled(!canStart)
                        Spacer()
                        Button("Cancel") { model.page = .library }
                            .buttonStyle(HeroButtonStyle(isPrimary: false, height: 40))
                            .keyboardShortcut(.cancelAction)
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.never)
        }
    }

    private var folderSentence: String {
        guard let directory = model.directory, !model.immichOnly else { return "" }
        return " They go in your \u{201C}\(directory.lastPathComponent)\u{201D} folder."
    }

    private func start() {
        // Picking this card, with what it removes spelled out on it, is the confirmation.
        model.startDownload(confirmed: removing)
    }
}

/// A large, plainly worded answer that starts something when clicked.
struct BigChoice: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let note: String?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 19, weight: .semibold))
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(white: 0.78))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Label(note, systemImage: "arrow.uturn.backward.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(height: 52)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isHovered && isEnabled ? 0.07 : 0.04), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isHovered && isEnabled ? Theme.accent.opacity(0.8) : Color.white.opacity(0.09), lineWidth: 1.5))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
#endif
