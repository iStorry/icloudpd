#if canImport(SwiftUI) && os(macOS)
import AppKit
import ICloudKit
import SwiftUI

/// A run in progress or just finished: how far it is, what it saved, any problems, and the log
/// for those who want it.
struct ActivityStage: View {
    @EnvironmentObject var model: AppModel
    /// The log is folded away unless someone opens it; the choice is remembered.
    @AppStorage("showsActivityLog") private var showsLog = false

    private var isDownload: Bool { model.runKind == .download }
    /// A delete list has no numbers of its own: the log is all there is to show.
    private var logIsOpen: Bool { showsLog || !isDownload }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                if isDownload {
                    // Up to four share one row; more go in rows of three.
                    let stats = tiles
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: stats.count <= 4 ? stats.count : 3),
                              spacing: 10) {
                        ForEach(stats) { StatTile(stat: $0) }
                    }
                }
                if isDownload, !model.currentDryRun, !model.recentSaves.isEmpty {
                    recentPhotos
                }
                if !problems.isEmpty {
                    problemsCard
                }
                logSection
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.never)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 26) {
                ProgressRing(progress: model.runFraction ?? (model.isDownloading ? nil : 1), lineWidth: 10) {
                    ringCenter
                }
                .frame(width: 132, height: 132)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Progress")
                .accessibilityValue(model.runFraction.map { "\(Int($0 * 100)) percent" } ?? "")

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        if model.currentDryRun {
                            Chip(text: "Preview · nothing changes", color: Theme.warning)
                        }
                        if let album = model.currentAlbum {
                            Chip(text: album, color: Theme.accentSoft)
                        }
                    }
                    Text(title)
                        .font(.system(size: 26, weight: .bold))
                        .tracking(-0.7)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(detail(now: context.date))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                    }
                    buttons.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            if isDownload, let total = model.total, total > 0 {
                breakdownBar(total: total)
            }
        }
        .padding(24)
        .panel(cornerRadius: 20, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }

    @ViewBuilder private var ringCenter: some View {
        if model.isDownloading, let fraction = model.runFraction {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int((fraction * 100).rounded(.down)))")
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-1.2)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
        } else if model.isDownloading {
            ProgressView().controlSize(.large)
        } else {
            Image(systemName: outcomeSymbol)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(model.outcome == .failed ? Theme.dangerSoft : Color.primary)
        }
    }

    private var title: String {
        let dry = model.currentDryRun
        let deleteList = model.runKind == .deleteList
        if model.isDownloading {
            if deleteList { return dry ? "Checking the delete list" : "Deleting listed photos" }
            return dry ? "Checking your library" : "Saving your photos"
        }
        switch model.outcome {
        case .stopped: return "Stopped"
        case .failed: return "Couldn't finish"
        case .finished:
            if deleteList { return dry ? "Delete list checked" : "Delete list finished" }
            if dry { return model.downloaded == 0 ? "Nothing new to download" : "\(model.downloaded.formatted()) would be downloaded" }
            return model.downloaded == 0 ? "Already up to date" : "\(model.downloaded.formatted()) new photos saved"
        }
    }

    /// "501 of 1,106 checked · about 3 min left", or how long the run took.
    private func detail(now: Date) -> String {
        var parts: [String] = []
        if isDownload {
            parts.append("\(model.processed.formatted())\(model.total.map { " of \($0.formatted())" } ?? "") checked")
        }
        if model.isDownloading {
            if let left = timeLeft(now: now) {
                parts.append(left)
            } else if let start = model.runStartedAt {
                parts.append(Self.duration(now.timeIntervalSince(start)) + " so far")
            }
        } else if let start = model.runStartedAt, let end = model.runEndedAt {
            parts.append("took " + Self.duration(end.timeIntervalSince(start)))
        }
        return parts.joined(separator: " · ")
    }

    private func timeLeft(now: Date) -> String? {
        guard let total = model.total, let start = model.albumStartedAt else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 5, model.processed > 10, model.processed < total else { return nil }
        let left = elapsed / Double(model.processed) * Double(total - model.processed)
        return left < 60 ? "less than a minute left" : "about \(Self.duration(left)) left"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 1)) ?? ""
    }

    private var outcomeSymbol: String {
        switch model.outcome {
        case .finished: return "checkmark"
        case .stopped: return "stop.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if model.isDownloading {
                Button { model.stopDownload() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(HeroButtonStyle(isPrimary: false, height: 42))
            } else {
                Button { model.page = .library } label: { Text("Done").frame(minWidth: 50) }
                    .buttonStyle(HeroButtonStyle(height: 42))
                    .keyboardShortcut(.defaultAction)
                if model.currentDryRun, isDownload {
                    Button { model.startDownload() } label: { Label("Run It for Real", systemImage: "arrow.down.to.line") }
                        .buttonStyle(HeroButtonStyle(isPrimary: false, height: 42))
                        .disabled(model.phase != .signedIn || model.directory == nil)
                } else if model.directory != nil {
                    Button { model.openDirectory() } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(HeroButtonStyle(isPrimary: false, height: 42))
                }
            }
        }
        .fixedSize()
    }

    /// Everything checked so far, split by what happened to it, against what is still to check.
    private func breakdownBar(total: Int) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let share = { (count: Int) in width * CGFloat(count) / CGFloat(max(total, 1)) }
            HStack(spacing: 2) {
                Rectangle().fill(Theme.accent).frame(width: share(model.downloaded))
                Rectangle().fill(Color.white.opacity(0.32)).frame(width: share(model.skipped))
                Rectangle().fill(Theme.danger).frame(width: share(model.failed))
                Spacer(minLength: 0)
            }
            .animation(.smooth(duration: 0.4), value: model.processed)
        }
        .frame(height: 6)
        .background(Color.white.opacity(0.08))
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }

    // MARK: Numbers

    private var tiles: [Stat] {
        let dry = model.currentDryRun
        var list = [
            Stat(title: dry ? "To download" : "New", value: model.downloaded,
                 caption: dry ? "Preview only" : AppSidebar.size(Int64(model.bytes)), color: Theme.accent),
            Stat(title: "Already saved", value: model.skipped, caption: "Skipped", color: Color.white.opacity(0.32)),
        ]
        if model.deletedFromICloud > 0 || model.config.deletesFromICloud {
            list.append(Stat(title: dry ? "Would leave iCloud" : "Left iCloud", value: model.deletedFromICloud,
                             caption: "In Recently Deleted", color: Theme.warning))
        }
        if model.deletedLocally > 0 {
            list.append(Stat(title: dry ? "Would remove here" : "Removed here", value: model.deletedLocally,
                             caption: "Deleted in iCloud", color: Color(white: 0.6)))
        }
        if model.pruned > 0 {
            list.append(Stat(title: dry ? "Would set aside" : "Set aside", value: model.pruned,
                             caption: "Gone from iCloud", color: Color(white: 0.6)))
        }
        if model.failed > 0 {
            list.append(Stat(title: "Failed", value: model.failed, caption: "See problems below", color: Theme.danger, isBad: true))
        }
        return list
    }

    // MARK: Photos

    private var recentPhotos: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: model.isDownloading ? "Just saved" : "Saved this run")
                Spacer()
                if model.directory != nil {
                    CardLink(title: "Show in Finder") { model.openDirectory() }
                }
            }
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
        .padding(16)
        .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }

    // MARK: Problems

    private var problems: [AppModel.LogLine] { model.log.filter(\.isError) }

    private var problemsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: problems.count == 1 ? "1 problem" : "\(problems.count.formatted()) problems")
                Spacer()
                if problems.count > 4 {
                    CardLink(title: "See all in the log") { showsLog = true }
                }
            }
            Card {
                ForEach(problems.suffix(4)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.dangerSoft)
                        Text(line.text)
                            .foregroundStyle(Theme.dangerSoft)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.smooth(duration: 0.2)) { showsLog.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(Theme.secondary)
                    Text("Activity log").font(.system(size: 13, weight: .medium))
                    Text("\(model.log.count.formatted()) lines")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(logIsOpen ? 0 : -90))
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isDownload)
            .panel(cornerRadius: 14, fill: Color.white.opacity(0.02), stroke: Color.white.opacity(0.07))
            .accessibilityValue(logIsOpen ? "Shown" : "Hidden")

            if logIsOpen {
                ActivityList(lines: model.log)
                    .frame(height: isDownload ? 280 : 420)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: Pieces

struct Stat: Identifiable {
    let title: String
    let value: Int
    let caption: String
    var color: Color = Theme.accent
    var isBad = false
    var id: String { title }
}

/// One number of a run, with the colour it has in the bar above.
struct StatTile: View {
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(stat.color).frame(width: 8, height: 8)
                Text(stat.title).font(.system(size: 12)).foregroundStyle(stat.isBad ? Theme.dangerSoft : Theme.secondary)
            }
            Text(stat.value.formatted())
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.5)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(stat.caption).font(.system(size: 12)).foregroundStyle(stat.isBad ? Theme.dangerSoft : Theme.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(cornerRadius: 16,
               fill: stat.isBad ? Theme.danger.opacity(0.14) : Color.white.opacity(0.035),
               stroke: stat.isBad ? Theme.dangerSoft.opacity(0.3) : Color.white.opacity(0.07))
        .accessibilityElement(children: .combine)
    }
}

/// A small coloured label in the activity header.
struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(color.opacity(0.16), in: .capsule)
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
        ZStack {
            Color.white.opacity(0.06)
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
    @State private var spins = false

    var body: some View {
        HStack(spacing: 6) {
            if let fraction {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accentSoft)
            }
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.03, $0) } ?? 0.3)
                    .stroke(Theme.accentSoft, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(fraction == nil && spins ? 270 : -90))
                    .animation(fraction == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .smooth(duration: 0.3),
                               value: spins)
            }
            .frame(width: 15, height: 15)
        }
        .onAppear { spins = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction.map { "\(Int($0 * 100)) percent" } ?? "Running")
    }
}
#endif
