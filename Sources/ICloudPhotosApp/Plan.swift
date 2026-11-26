#if canImport(SwiftUI) && os(macOS)
import Foundation
import ICloudKit

/// The easy setup's answers, and how they map onto the sync settings.
///
/// Freeing up iCloud uses "keep recent photos in iCloud": every photo is downloaded, and once one
/// is safely on this Mac and older than the chosen age, it moves to Recently Deleted in iCloud.
/// Photos the run already finds on this Mac count too, so a second run clears what the first saved.
/// A date range limits what is downloaded at all, and so what can leave iCloud.
struct SetupAnswers {
    enum Goal { case freeUp, backUp }

    enum Photos: Hashable {
        /// Free up only: everything is downloaded, photos older than this leave iCloud.
        case olderThan(days: Int)
        case everything
        /// Only photos taken between `from` and `to` are downloaded (and, freeing up, removed).
        case between
    }

    var goal: Goal = .freeUp
    var photos: Photos = .olderThan(days: 365)
    var from: Date = Calendar.current.date(byAdding: .year, value: -10, to: Date()) ?? Date()
    var to: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var directoryPath: String
    var size: PhotoSize = .original
    var folderStructure: String
    /// Sync every night from now on.
    var keepGoing = true

    /// Starts from what is set now, so running the setup again shows the current answers.
    init(config: SyncConfiguration, schedule: ScheduleInterval, isFirstTime: Bool) {
        directoryPath = config.directoryPath
        folderStructure = config.folderStructure
        if config.sizes.count == 1, [.original, .adjusted, .medium].contains(config.sizes[0]) { size = config.sizes[0] }
        keepGoing = isFirstTime || schedule != .off
        goal = isFirstTime || config.deletesFromICloud ? .freeUp : .backUp
        if case .date(let start)? = config.skipCreatedBefore, case .date(let end)? = config.skipCreatedAfter {
            photos = .between
            from = start
            to = end
        } else if let days = config.keepICloudRecentDays, days > 0 {
            photos = .olderThan(days: days)
        } else if !isFirstTime {
            photos = .everything
        }
    }

    /// The choices question 2 offers for this goal: backing up has no "older than".
    var presets: [Photos] {
        goal == .freeUp ? [.olderThan(days: 182), .olderThan(days: 365), .everything, .between] : [.everything, .between]
    }

    func apply(to config: inout SyncConfiguration) {
        config.directoryPath = directoryPath
        config.sizes = [size]
        config.forceSize = false
        config.folderStructure = folderStructure
        config.albums = []
        config.dryRun = false
        config.deleteAfterDownload = false
        let removing = goal == .freeUp
        switch photos {
        case .olderThan(let days):
            config.skipCreatedBefore = nil
            config.skipCreatedAfter = nil
            config.keepICloudRecentDays = removing ? days : nil
        case .everything:
            config.skipCreatedBefore = nil
            config.skipCreatedAfter = nil
            config.keepICloudRecentDays = removing ? 0 : nil
        case .between:
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: max(from, to))) ?? to
            config.skipCreatedBefore = .date(start)
            config.skipCreatedAfter = .date(end)
            config.keepICloudRecentDays = removing ? 0 : nil
        }
        if removing {
            // Both are refused next to deleting from iCloud.
            config.ignoreIndexingState = false
            config.xmpSidecarOnly = false
        }
    }

    // MARK: Words

    static func title(_ photos: Photos) -> String {
        switch photos {
        case .olderThan(let days): return "Older than \(RemovalAge.label(days).lowercased())"
        case .everything: return "Everything"
        case .between: return "Choose dates"
        }
    }

    func detail(_ photos: Photos) -> String {
        switch photos {
        case .olderThan(let days): return "Before \(RemovalAge.cutoff(days).formatted(date: .abbreviated, time: .omitted))"
        case .everything: return "All of your library"
        case .between: return "From and to"
        }
    }

    /// The answer to question 2, in a line.
    var photosSummary: String {
        switch photos {
        case .olderThan(let days):
            return "Taken before \(RemovalAge.cutoff(days).formatted(date: .abbreviated, time: .omitted))"
        case .everything:
            return goal == .freeUp ? "Your whole library" : "Everything"
        case .between:
            return "Taken \(min(from, to).formatted(date: .abbreviated, time: .omitted)) to \(max(from, to).formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

/// The current plan in plain sentences, for people who never open Settings.
enum PlanWords {
    /// "Photos older than 1 year are saved on this Mac, then removed from iCloud."
    static func what(_ c: SyncConfiguration) -> String {
        var text: String
        if c.deletesFromICloud {
            let age = c.keepICloudRecentDays ?? 0
            text = age > 0
                ? "Photos older than \(RemovalAge.label(age).lowercased()) are saved on this Mac, then removed from iCloud."
                : "Photos are saved on this Mac, then removed from iCloud."
        } else {
            text = "Photos are saved on this Mac. iCloud stays as it is."
        }
        if c.skipCreatedBefore != nil || c.skipCreatedAfter != nil {
            text += " Only ones " + PhotoSettings.rangeText(c).lowercased() + "."
        }
        if !c.albums.isEmpty {
            text += c.albums.count == 1 ? " Only from the album \(c.albums[0])." : " Only from \(c.albums.count) albums."
        }
        return text
    }

    /// The same, when Sync Now sends the photos on to Immich.
    static func what(_ c: SyncConfiguration, immich: Bool, keepLocal: Bool) -> String {
        var text = what(c)
        guard immich else { return text }
        if keepLocal { return text + " Each one is also sent to Immich." }
        text = text.replacingOccurrences(of: "are saved on this Mac, then removed from iCloud", with: "are sent to Immich, then removed from iCloud")
        return text.replacingOccurrences(of: "are saved on this Mac. iCloud", with: "are sent to Immich. iCloud")
    }

    /// "Runs by itself every night at 2:00."
    static func when(_ schedule: ScheduleInterval, hour: Int) -> String {
        switch schedule {
        case .off: return "Runs only when you press Sync Now."
        case .daily:
            let time = DateComponents(calendar: .current, hour: hour, minute: 0).date?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
            return "Runs by itself every night at \(time)."
        default: return "Runs by itself \(schedule.label.lowercased())."
        }
    }
}

/// How old a photo must be before it leaves iCloud.
enum RemovalAge {
    static let choices = [0, 30, 91, 182, 365, 730]

    static func label(_ days: Int) -> String {
        switch days {
        case 0: return "Any age"
        case 30: return "30 days"
        case 91: return "3 months"
        case 182: return "6 months"
        case 365: return "1 year"
        case 730: return "2 years"
        default: return "\(days) days"
        }
    }

    static func cutoff(_ days: Int, now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    }
}

extension PhotoSize {
    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .adjusted: return "Edited"
        case .alternative: return "Alternative"
        case .medium: return "Medium"
        case .thumb: return "Thumbnail"
        }
    }

    /// The name in the quality pickers.
    var qualityLabel: String {
        switch self {
        case .original: return "Full quality"
        case .adjusted: return "With your edits"
        case .alternative: return "RAW + JPEG pair"
        case .medium: return "Smaller"
        case .thumb: return "Tiny preview"
        }
    }
}

extension LivePhotoSize {
    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .medium: return "Medium"
        case .thumb: return "Thumbnail"
        }
    }
}

extension SyncLogLevel {
    var label: String {
        switch self {
        case .debug: return "Detailed"
        case .info, .warning: return "Normal"
        case .error: return "Problems only"
        }
    }
}
#endif
