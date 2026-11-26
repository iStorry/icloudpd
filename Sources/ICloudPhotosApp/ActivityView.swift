#if canImport(SwiftUI) && os(macOS)
import AppKit
import ICloudKit
import SwiftUI

/// A run in progress or just finished, told in plain sentences: where it is, what it did, what
/// went wrong and what to do next. The log is there for those who ask for details.
struct ActivityStage: View {
    @EnvironmentObject var model: AppModel
    /// The details are folded away unless someone opens them; the choice is remembered.
    @AppStorage("showsActivityLog") private var showsLog = false

    private var isDownload: Bool { model.runKind == .download }
    private var dry: Bool { model.currentDryRun }
    private var running: Bool { model.isDownloading }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                if isDownload, !results.isEmpty {
                    resultsCard
                }
                if isDownload, !dry, !model.recentSaves.isEmpty {
                    recentPhotos
                }
                if !running, isDownload, model.failed > 0 {
                    problemCard
                }
                details
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.never)
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                StatusBadge(kind: badge)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(white: 0.75))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            if running {
                progress
            }

            HStack(spacing: 10) { buttons }
                .fixedSize()
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(cornerRadius: 20, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }

    private var badge: StatusBadge.Kind {
        if running { return .working }
        if dry && model.outcome == .finished { return .preview }
        switch model.outcome {
        case .finished: return model.failed > 0 && isDownload ? .problem : .done
        case .stopped: return .stopped
        case .failed: return .problem
        }
    }

    private var title: String {
        if !isDownload {
            if running { return dry ? "Checking the delete list" : "Deleting the listed photos" }
            switch model.outcome {
            case .finished: return dry ? "Delete list checked" : "Delete list finished"
            case .stopped: return "Stopped"
            case .failed: return "Couldn't finish"
            }
        }
        if running { return dry ? "Previewing your sync" : "Saving your photos" }
        switch model.outcome {
        case .finished:
            if dry { return "Preview finished" }
            if model.failed > 0 { return "Mostly done" }
            return model.downloaded == 0 && model.deletedFromICloud == 0 ? "Everything was already saved" : "All done!"
        case .stopped: return "Stopped"
        case .failed: return "Couldn't finish"
        }
    }

    private var subtitle: String {
        if running {
            if dry { return "Nothing will be saved or removed. This only shows what Sync Now would do." }
            return "You can keep using your Mac while this runs."
        }
        switch model.outcome {
        case .finished:
            if dry { return "Nothing was changed. Here is what Sync Now would do." }
            var text = model.failed > 0 ? "Everything else is safe on this Mac." : "Your photos are safe on this Mac."
            if let end = model.runEndedAt {
                text += " Finished at \(end.formatted(date: .omitted, time: .shortened))"
                if let start = model.runStartedAt { text += ", in \(Self.spoken(end.timeIntervalSince(start)))" }
                text += "."
            }
            return text
        case .stopped:
            return "Nothing is lost. Press Carry On, or Sync Now later, and it picks up where it left off."
        case .failed:
            return Self.plainReason(for: model.log.last(where: \.isError)?.text, otherwise: "Something went wrong talking to iCloud.")
                + " Nothing is lost, and you can try again."
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if let fraction = model.runFraction {
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.system(size: 22, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Text(timeLeft(now: context.date))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }
                ProgressView(value: model.runFraction ?? 0)
                    .progressViewStyle(CapsuleProgressStyle())
                    .animation(.smooth(duration: 0.4), value: model.processed)
                    .accessibilityLabel("Progress")
                .accessibilityValue(model.runFraction.map { "\(Int($0 * 100)) percent" } ?? "Starting")
                Text(lookedAt)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var lookedAt: String {
        guard isDownload else { return "\(model.log.count.formatted()) lines so far" }
        guard let total = model.total else { return "Getting the list of your photos from iCloud…" }
        return "Looked at \(model.processed.formatted()) of \(total.formatted()) photos"
            + (model.currentAlbum.map { $0 == "All Photos" ? "" : " in \u{201C}\($0)\u{201D}" } ?? "")
    }

    private func timeLeft(now: Date) -> String {
        guard let total = model.total, let start = model.albumStartedAt else { return "Starting…" }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 5, model.processed > 10, model.processed < total else { return "Working…" }
        let left = elapsed / Double(model.processed) * Double(total - model.processed)
        return left < 60 ? "Less than a minute left" : "About \(Self.spoken(left)) left"
    }

    /// "2 minutes", "1 hour 5 minutes", "40 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 1)) ?? ""
    }

    @ViewBuilder private var buttons: some View {
        if running {
            Button { model.stopDownload() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(HeroButtonStyle(isPrimary: false, height: 44))
        } else if dry && model.outcome == .finished && isDownload {
            Button(action: runForReal) { Label("Do It Now", systemImage: "arrow.down.to.line") }
                .buttonStyle(HeroButtonStyle(height: 44))
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            Button { model.page = .library } label: { Text("Not Now") }
                .buttonStyle(HeroButtonStyle(isPrimary: false, height: 44))
        } else if model.outcome != .finished && isDownload {
            Button(action: runForReal) {
                Label(model.outcome == .stopped ? "Carry On" : "Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(HeroButtonStyle(height: 44))
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)
            Button { model.page = .library } label: { Text("Done") }
                .buttonStyle(HeroButtonStyle(isPrimary: false, height: 44))
        } else {
            Button { model.page = .library } label: { Text("Done").frame(minWidth: 50) }
                .buttonStyle(HeroButtonStyle(height: 44))
                .keyboardShortcut(.defaultAction)
            if model.directory != nil, isDownload {
                Button { model.openDirectory() } label: { Label("Open Folder", systemImage: "folder") }
                    .buttonStyle(HeroButtonStyle(isPrimary: false, height: 44))
            }
        }
    }

    private var canRun: Bool { model.phase == .signedIn && model.directory != nil }

    /// Runs the plan for real. The person has just seen what it does, so it doesn't ask again.
    private func runForReal() {
        model.startDownload(confirmed: model.config.deletesFromICloud)
    }

    // MARK: Results

    private struct Result: Identifiable {
        let symbol: String
        let tint: Color
        let text: String
        var id: String { text }
    }

    private var results: [Result] {
        var list: [Result] = []
        let size = model.bytes > 0 && !dry ? " (\(AppSidebar.size(Int64(model.bytes))))" : ""
        if model.downloaded > 0 {
            list.append(Result(symbol: "arrow.down.circle.fill", tint: Theme.accentSoft,
                               text: dry ? "\(Self.photos(model.downloaded)) would be saved to this Mac"
                                         : "\(Self.photos(model.downloaded, new: true)) saved to this Mac\(size)"))
        } else if !running {
            list.append(Result(symbol: "checkmark.circle.fill", tint: Theme.accentSoft,
                               text: dry ? "No new photos would be saved" : "No new photos to save"))
        }
        if model.skipped > 0 {
            list.append(Result(symbol: "checkmark.circle.fill", tint: Color(white: 0.6),
                               text: "\(Self.photos(model.skipped)) \(model.skipped == 1 ? "was" : "were") already on this Mac"))
        }
        if model.deletedFromICloud > 0 {
            list.append(Result(symbol: "icloud.slash.fill", tint: Theme.warning,
                               text: dry ? "\(Self.photos(model.deletedFromICloud)) would be removed from iCloud"
                                         : "\(Self.photos(model.deletedFromICloud)) removed from iCloud. You can get them back from Recently Deleted for 30 days."))
        }
        if model.deletedLocally > 0 {
            list.append(Result(symbol: "trash.circle.fill", tint: Color(white: 0.6),
                               text: "\(Self.photos(model.deletedLocally)) \(dry ? "would be" : "were") deleted here, because you deleted them in iCloud"))
        }
        if model.pruned > 0 {
            list.append(Result(symbol: "archivebox.circle.fill", tint: Color(white: 0.6),
                               text: "\(Self.photos(model.pruned)) \(dry ? "would be" : "were") put aside, because they're no longer in iCloud"))
        }
        if running, model.failed > 0 {
            list.append(Result(symbol: "exclamationmark.circle.fill", tint: Theme.dangerSoft,
                               text: "\(Self.photos(model.failed)) couldn't be saved so far"))
        }
        return list
    }

    /// "1 photo", "337 photos", "337 new photos".
    static func photos(_ count: Int, new: Bool = false) -> String {
        "\(count.formatted()) \(new ? "new " : "")\(count == 1 ? "photo" : "photos")"
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { CardDivider() }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Image(systemName: result.symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(result.tint)
                        .frame(width: 22)
                    Text(result.text)
                        .font(.system(size: 15))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
            }
        }
        .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
        .accessibilityElement(children: .combine)
    }

    // MARK: Photos

    private var recentPhotos: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(running ? "Just saved" : "Saved this time")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            GeometryReader { geo in
                let size: CGFloat = 84
                let count = max(1, Int((geo.size.width + 8) / (size + 8)))
                HStack(spacing: 8) {
                    ForEach(model.recentSaves.suffix(count).reversed(), id: \.self) { path in
                        SavedThumbnail(path: path, directory: model.directory)
                            .frame(width: size, height: size)
                    }
                }
            }
            .frame(height: 84)
        }
        .padding(18)
        .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }

    // MARK: Problems

    private var problemCard: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warning)
                .frame(width: 44, height: 44)
                .background(Theme.warning.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Self.photos(model.failed)) couldn't be saved")
                    .font(.system(size: 17, weight: .semibold))
                Text(Self.plainReason(for: model.log.last(where: \.isError)?.text)
                     + " \(model.failed == 1 ? "It stays" : "They stay") in iCloud and will be tried again the next time you sync.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.78))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button { runForReal() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
                        .disabled(!canRun)
                    Button("Which ones?") { withAnimation(.smooth(duration: 0.2)) { showsLog = true } }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentSoft)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .panel(cornerRadius: 18, fill: Theme.warning.opacity(0.06), stroke: Theme.warning.opacity(0.28))
    }

    /// A guess at why, in words anyone understands, from the last error message.
    static func plainReason(for error: String?, otherwise: String = "iCloud didn't send them this time.") -> String {
        let text = (error ?? "").lowercased()
        if ["network", "internet", "offline", "timed out", "connection"].contains(where: text.contains) {
            return "Your internet connection seems to have dropped."
        }
        if ["space", "disk full", "no room"].contains(where: text.contains) {
            return "This Mac, or the drive the folder is on, may be full."
        }
        if ["permission", "not permitted", "read-only"].contains(where: text.contains) {
            return "The folder couldn't be written to."
        }
        if ["sign in", "session", "401", "421"].contains(where: text.contains) {
            return "iCloud asked you to sign in again."
        }
        return otherwise
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        if isDownload {
            DisclosureGroup(isExpanded: $showsLog) {
                ActivityList(lines: model.log).frame(height: 280)
            } label: {
                Text(showsLog ? "Hide details" : "Show details")
            }
            .disclosureGroupStyle(LinkDisclosureStyle())
        } else {
            ActivityList(lines: model.log).frame(height: 420)
        }
    }
}

// MARK: Pieces

/// The big round symbol beside the status: working, done, preview, stopped or a problem.
struct StatusBadge: View {
    enum Kind { case working, done, preview, stopped, problem }
    let kind: Kind
    @State private var bob = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(color)
            .offset(y: kind == .working && bob ? 3 : 0)
            .frame(width: 64, height: 64)
            .background(color.opacity(0.16), in: .circle)
            .overlay(Circle().strokeBorder(color.opacity(0.3)))
            .animation(kind == .working ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: bob)
            .onAppear { bob = true }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .working: return "arrow.down"
        case .done: return "checkmark"
        case .preview: return "eye"
        case .stopped: return "pause.fill"
        case .problem: return "exclamationmark"
        }
    }

    private var color: Color {
        switch kind {
        case .working, .preview: return Theme.accentSoft
        case .done: return Color(red: 0.5, green: 0.89, blue: 0.66)
        case .stopped: return Color(white: 0.85)
        case .problem: return Theme.warning
        }
    }
}

/// A photo this run saved, loaded small and off the main thread. Videos show a symbol.
struct SavedThumbnail: View {
    let path: String
    let directory: URL?
    @State private var image: NSImage?

    private var url: URL {
        path.hasPrefix("/") || directory == nil ? URL(fileURLWithPath: path) : directory!.appendingPathComponent(path)
    }

    var body: some View {
        // The photo is an overlay, so it takes the tile's size and is cut to it, however wide it is.
        Color.white.opacity(0.06)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? "video.fill" : "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .help(url.lastPathComponent)
        .accessibilityLabel(url.lastPathComponent)
        .task(id: path) {
            let file = url
            image = await Task.detached(priority: .utility) { LibraryGlance.thumbnail(of: file) }.value
        }
    }
}

/// The run's progress next to Activity in the sidebar: a ring at icon size and the percentage.
struct RunBadge: View {
    let fraction: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let fraction {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accentSoft)
                    .accessibilityHidden(true)
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(RingProgressStyle())
        .accessibilityLabel("Sync progress")
    }
}
#endif
