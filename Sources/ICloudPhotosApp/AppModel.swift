#if canImport(SwiftUI) && os(macOS)
import AppKit
import Foundation
import ICloudKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// How often to sync automatically (icloudpd's --watch-with-interval).
enum ScheduleInterval: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case hourly = 3_600
    case every6Hours = 21_600
    case every12Hours = 43_200
    case daily = 86_400

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .hourly: return "Every hour"
        case .every6Hours: return "Every 6 hours"
        case .every12Hours: return "Every 12 hours"
        case .daily: return "Every day"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case needsCode
        case needsTwoStep
        case signedIn
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        let isError: Bool
    }

    private let defaults = UserDefaults.standard

    // MARK: Account

    @Published var phase: Phase = .signedOut
    @Published var appleID: String = UserDefaults.standard.string(forKey: "appleID") ?? ""
    @Published var domain: ICloudDomain = ICloudDomain(rawValue: UserDefaults.standard.string(forKey: "domain") ?? "") ?? .com
    @Published var rememberPassword: Bool = UserDefaults.standard.object(forKey: "rememberPassword") as? Bool ?? true
    @Published var errorMessage: String?
    @Published var accountName: String?

    // Two-factor and two-step
    @Published var phones: [TrustedPhoneNumber] = []
    @Published var smsPhone: TrustedPhoneNumber?
    @Published var twoStepDevices: [TrustedDevice] = []
    @Published var twoStepDevice: TrustedDevice?
    @Published var isVerifying = false

    // MARK: Settings (persisted)

    @Published var config: SyncConfiguration {
        didSet { saveConfig() }
    }
    @Published var adpWebAccess: Bool = UserDefaults.standard.bool(forKey: "adpWebAccess") {
        didSet { defaults.set(adpWebAccess, forKey: "adpWebAccess") }
    }
    @Published var schedule: ScheduleInterval = ScheduleInterval(rawValue: UserDefaults.standard.integer(forKey: "schedule")) ?? .off {
        didSet { defaults.set(schedule.rawValue, forKey: "schedule"); reschedule() }
    }
    @Published var showInMenuBar: Bool = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true {
        didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    @Published var notifyWhenDone: Bool = UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true {
        didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone"); if notifyWhenDone { requestNotificationPermission() } }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { updateLaunchAtLogin() }
    }

    // MARK: Library and albums

    @Published var libraries: [String] = []
    @Published var albums: [String] = []
    @Published var isLoadingAlbums = false

    // MARK: Run state

    @Published var isDownloading = false
    @Published var currentDryRun = false
    @Published var currentAlbum: String?
    @Published var total: Int?
    @Published var processed = 0
    @Published var downloaded = 0
    @Published var skipped = 0
    @Published var failed = 0
    @Published var bytes = 0
    @Published var deletedLocally = 0
    @Published var deletedFromICloud = 0
    @Published var pruned = 0
    @Published var log: [LogLine] = []
    @Published var lastRun: Date? = UserDefaults.standard.object(forKey: "lastRun") as? Date
    @Published var lastRunSummary: String? = UserDefaults.standard.string(forKey: "lastRunSummary")
    @Published var nextRun: Date?
    /// What the run screen is showing: a download (or dry run), or a delete list.
    enum RunKind { case download, deleteList }
    /// How the last run ended.
    enum RunOutcome { case finished, stopped, failed }
    /// True once a run was started: the window then keeps showing it and its activity.
    @Published var hasRun = false
    @Published var runKind: RunKind = .download
    @Published var outcome: RunOutcome = .finished
    /// A problem outside a run (a setting that can't work, albums that didn't load), for the start screen.
    @Published var notice: String?
    /// Set when a run would delete from iCloud, so the window can ask first.
    @Published var pendingDestructiveRun = false

    private var account: ICloudAccount?
    private var photos: PhotosService?
    private var downloadTask: Task<Void, Never>?
    private var scheduleTimer: Timer?

    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        if let data = UserDefaults.standard.data(forKey: "syncConfiguration"),
           let saved = try? JSONDecoder().decode(SyncConfiguration.self, from: data) {
            config = saved
        } else {
            // Carry over the folder chosen in the first version of the app.
            let old = UserDefaults.standard.url(forKey: "directory")?.path ?? ""
            var fresh = SyncConfiguration(directoryPath: old)
            fresh.keepUnicodeInFilenames = true // friendlier default on a Mac; icloudpd strips non-ASCII
            if let legacy = UserDefaults.standard.string(forKey: "folderStructure"), let s = FolderStructure(rawValue: legacy) {
                fresh.folderStructure = s.rawValue
            }
            config = fresh
        }
        // Try the saved session quietly at launch.
        if !appleID.isEmpty, defaults.bool(forKey: "wasSignedIn") {
            Task { await signIn(password: nil) }
        }
        reschedule()
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "syncConfiguration") }
    }

    var directory: URL? { config.directoryPath.isEmpty ? nil : config.directory }

    // MARK: Sign-in

    func signIn(password typed: String?) async {
        let id = appleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        errorMessage = nil
        phase = .signingIn
        defaults.set(id, forKey: "appleID")
        defaults.set(domain.rawValue, forKey: "domain")
        defaults.set(rememberPassword, forKey: "rememberPassword")

        let account = ICloudAccount(appleID: id, domain: domain)
        self.account = account
        photos = nil
        let remember = rememberPassword
        do {
            let result = try await account.signIn(password: {
                if let typed, !typed.isEmpty { return typed }
                return Keychain.password(for: id)
            })
            if let typed, !typed.isEmpty {
                if remember { Keychain.save(typed, for: id) } else { Keychain.delete(id) }
            }
            switch result {
            case .signedIn:
                await finishSignIn()
            case .needsVerificationCode:
                smsPhone = nil
                phones = (try? await account.trustedPhoneNumbers()) ?? []
                if phones.isEmpty, await account.usesSecurityKeys() {
                    throw ICloudError.securityKeysNotSupported
                }
                phase = .needsCode
                notify(title: "iCloud needs a verification code", body: "Open iCloud Photos Downloader to enter the code Apple sent you.")
                await account.requestCodeOnTrustedDevices()
            case .needsTwoStepVerification:
                twoStepDevices = try await account.trustedDevices()
                twoStepDevice = nil
                phase = .needsTwoStep
                notify(title: "iCloud needs a verification code", body: "Open iCloud Photos Downloader to finish signing in.")
            }
        } catch ICloudError.passwordRequired {
            phase = .signedOut // the saved session expired; just show the form
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func verify(code: String) async {
        guard let account else { return }
        isVerifying = true
        defer { isVerifying = false }
        errorMessage = nil
        do {
            if let device = twoStepDevice {
                try await account.verify(code: code, device: device)
            } else if let phone = smsPhone {
                try await account.verifySMS(code: code, phone: phone)
            } else {
                try await account.verify(code: code)
            }
            await finishSignIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendSMS(to phone: TrustedPhoneNumber) async {
        guard let account else { return }
        do {
            try await account.sendSMSCode(to: phone)
            smsPhone = phone
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendTwoStepCode(to device: TrustedDevice) async {
        guard let account else { return }
        do {
            try await account.sendVerificationCode(to: device)
            twoStepDevice = device
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelVerification() {
        phase = .signedOut
        twoStepDevice = nil
        smsPhone = nil
        phones = []
        errorMessage = nil // it was about the code, not about signing in
        account = nil
    }

    private func finishSignIn() async {
        phase = .signedIn
        accountName = account?.fullName
        defaults.set(true, forKey: "wasSignedIn")
        await loadLibraries()
    }

    func signOut() {
        stopDownload()
        account?.signOut()
        Keychain.delete(appleID)
        account = nil
        photos = nil
        accountName = nil
        libraries = []
        albums = []
        // The next account starts on the start screen, not on this one's last run.
        hasRun = false
        notice = nil
        log = []
        resetRunCounters()
        phase = .signedOut
        defaults.set(false, forKey: "wasSignedIn")
    }

    // MARK: Libraries and albums

    private func photosService() async throws -> PhotosService {
        if let photos { return photos }
        guard let account else { throw ICloudError.passwordRequired }
        if adpWebAccess {
            append("Asking for web access to your Advanced Data Protection data…")
            try await account.requestWebAccess { [weak self] in
                Task { @MainActor in self?.append("Approve the iCloud web access request on your iPhone, iPad or Mac.") }
            }
        }
        let service = try await account.photos(ignoreIndexingState: config.ignoreIndexingState)
        photos = service
        return service
    }

    func loadLibraries() async {
        notice = nil
        do {
            let service = try await photosService()
            libraries = try await service.allLibraries().map(\.name)
            if libraries.isEmpty { libraries = [service.primary.name] }
            await loadAlbums()
        } catch {
            append("Couldn't load your libraries: \(error.localizedDescription)", isError: true)
        }
    }

    func loadAlbums() async {
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }
        notice = nil
        do {
            let library = try await photosService().library(named: config.library)
            albums = try await library.albums().map(\.name)
        } catch {
            albums = []
            append("Couldn't load albums: \(error.localizedDescription)", isError: true)
        }
    }

    func libraryLabel(_ name: String) -> String {
        if name == "PrimarySync" || name == photos?.primary.name { return "Personal Library" }
        if name.hasPrefix("SharedSync") { return "Shared Library" }
        return name
    }

    // MARK: Download

    func chooseDirectory() {
        if let url = pickFolder(message: "Choose where to save your iCloud photos") { config.directoryPath = url.path }
    }

    func chooseLivePhotoDirectory() {
        if let url = pickFolder(message: "Choose where to save Live Photo videos") { config.livePhotoDirectoryPath = url.path }
    }

    func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openDirectory() {
        if let directory { NSWorkspace.shared.open(directory) }
    }

    /// Starts a run. A run that would delete from iCloud asks first (unless `confirmed`).
    func startDownload(dryRun: Bool = false, confirmed: Bool = false, scheduled: Bool = false) {
        guard account != nil, directory != nil, !isDownloading else { return }
        notice = nil
        var run = config
        run.dryRun = run.dryRun || dryRun
        if run.deletesFromICloud && !run.dryRun && !confirmed && !scheduled {
            pendingDestructiveRun = true
            return
        }
        do { try run.validate() } catch {
            append(error.localizedDescription, isError: true)
            return
        }
        isDownloading = true
        hasRun = true
        runKind = .download
        outcome = .finished
        currentDryRun = run.dryRun
        resetRunCounters()
        log = []
        append(run.dryRun ? "Dry run: nothing will be downloaded, moved or deleted." : "Opening your iCloud Photos library…")

        downloadTask = Task {
            do {
                let service = try await photosService()
                let engine = try SyncEngine(configuration: run, events: eventSink())
                // Show what the run reported before its outcome: here when it throws, below when it ends.
                defer { flushEvents() }
                let summary = try await engine.run(photos: service)
                flushEvents()
                var parts = ["\(summary.filesDownloaded) new", "\(summary.filesExisting) already saved"]
                if summary.filesFailed > 0 { parts.append("\(summary.filesFailed) failed") }
                if summary.deletedFromICloud > 0 { parts.append("\(summary.deletedFromICloud) \(run.dryRun ? "would be " : "")deleted from iCloud") }
                if summary.deletedLocally > 0 { parts.append("\(summary.deletedLocally) \(run.dryRun ? "would be " : "")removed locally") }
                if summary.pruned > 0 { parts.append("\(summary.pruned) orphans \(run.dryRun ? "would be " : "")moved aside") }
                let text = parts.joined(separator: ", ")
                append((run.dryRun ? "Dry run done: " : "Done: ") + text + ".")
                if !run.dryRun {
                    lastRun = Date()
                    lastRunSummary = text
                    defaults.set(lastRun, forKey: "lastRun")
                    defaults.set(text, forKey: "lastRunSummary")
                }
                if notifyWhenDone && (summary.filesDownloaded > 0 || summary.filesFailed > 0 || !scheduled) {
                    notify(title: run.dryRun ? "Dry run finished" : "iCloud Photos downloaded", body: text.prefix(1).uppercased() + text.dropFirst())
                }
            } catch is CancellationError {
                outcome = .stopped
                append("Stopped.")
            } catch {
                outcome = .failed
                append(error.localizedDescription, isError: true)
                if case ICloudError.http(let status, _) = error, [401, 421, 450].contains(status) {
                    append("Your iCloud session expired. Sign in again.", isError: true)
                    photos = nil
                    errorMessage = "Your iCloud session expired. Sign in again." // the sign-in form says why it is back
                    phase = .signedOut
                    notify(title: "Sign in to iCloud again", body: "Your iCloud session expired, so scheduled downloads are paused.")
                }
            }
            isDownloading = false
            reschedule()
        }
    }

    private func resetRunCounters() {
        currentAlbum = nil
        total = nil
        processed = 0
        downloaded = 0
        skipped = 0
        failed = 0
        bytes = 0
        deletedLocally = 0
        deletedFromICloud = 0
        pruned = 0
    }

    func stopDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    func runDeleteList(dryRun: Bool, allowUndated: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a delete list: one FILENAME<TAB>SIZE<TAB>DATE per line"
        guard panel.runModal() == .OK, let url = panel.url, !isDownloading else { return }
        isDownloading = true
        hasRun = true
        runKind = .deleteList
        outcome = .finished
        notice = nil
        currentDryRun = dryRun
        resetRunCounters() // the last download's numbers aren't this run's
        log = []
        append("\(dryRun ? "Checking" : "Deleting") the photos listed in \(url.lastPathComponent)…")
        let libraryName = config.library
        downloadTask = Task {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let list = try DeleteList(contents: text, allowUndated: allowUndated, source: url.lastPathComponent)
                let library = try await photosService().library(named: libraryName)
                let report = eventSink()
                defer { flushEvents() } // what the list reported comes before how it ended
                _ = try await list.run(library: library, dryRun: dryRun) { level, message in
                    report(.log(level, message))
                }
            } catch is CancellationError {
                outcome = .stopped
                append("Stopped.")
            } catch {
                outcome = .failed
                append(error.localizedDescription, isError: true)
            }
            isDownloading = false
        }
    }

    /// Events of the run that haven't reached the window yet.
    private let events = SyncEventBuffer()
    /// The window follows a run ten times a second, however many events the run sends.
    static let eventInterval: UInt64 = 100_000_000

    /// Where a run sends its events, from whichever task they come. The first event of a batch
    /// schedules one update of the window; the ones that arrive before it runs ride along, in order.
    private func eventSink() -> @Sendable (SyncEvent) -> Void {
        { [events, weak self] event in
            guard events.add(event) else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: AppModel.eventInterval)
                self?.flushEvents()
            }
        }
    }

    private func flushEvents() {
        for event in events.drain() { handle(event) }
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .log(let level, let message):
            if level >= .info { append(message, isError: level >= .warning) }
        case .albumStarted(let title, let total):
            currentAlbum = title
            self.total = total
            processed = 0
            if let total { append("\(title): \(total.formatted()) items.") }
        case .progress(let processed):
            self.processed = processed
        case .downloaded(let path, let size):
            downloaded += 1
            bytes += size
            append("Downloaded \(path)")
        case .wouldDownload(let path):
            downloaded += 1
            append("Would download \(path)")
        case .alreadyExists:
            skipped += 1
        case .failed(let name, let message):
            failed += 1
            append("\(name): \(message)", isError: true)
        case .deletedLocally(let path):
            deletedLocally += 1
            append("\(currentDryRun ? "Would remove" : "Removed") \(path) (deleted in iCloud)")
        case .deletedFromICloud:
            deletedFromICloud += 1
        case .pruned(let path):
            pruned += 1
            append("\(currentDryRun ? "Would move" : "Moved") \(path) to .icloudpd-swift-pruned")
        }
    }

    func append(_ text: String, isError: Bool = false) {
        log.append(LogLine(text: text, isError: isError))
        if isError, !isDownloading { notice = text }
        // Trimmed in steps: dropping one line per new line would shift the whole list every time.
        if log.count > 1_200 { log.removeFirst(log.count - 1_000) }
    }

    // MARK: Schedule, notifications, login item

    func reschedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard schedule != .off else { nextRun = nil; return }
        let base = lastRun ?? Date()
        var next = base.addingTimeInterval(TimeInterval(schedule.rawValue))
        if next < Date().addingTimeInterval(60) { next = Date().addingTimeInterval(60) }
        nextRun = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scheduledRunFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    private func scheduledRunFired() {
        guard phase == .signedIn, !isDownloading else { reschedule(); return }
        startDownload(scheduled: true)
    }

    func requestNotificationPermission() {
        guard AppModel.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        guard AppModel.canNotify, notifyWhenDone || title.contains("verification") || title.contains("Sign in") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            append("Couldn't change Open at Login: \(error.localizedDescription). Build the .app with scripts/build-app.sh first.", isError: true)
            // Put the switch back to what is true. (Setting it runs this again, which then finds nothing to do.)
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual { launchAtLogin = actual }
        }
    }

    var statusLine: String {
        if isDownloading {
            var s = "\(processed.formatted())\(total.map { " of \($0.formatted())" } ?? "") checked"
            s += " · \(downloaded.formatted()) \(currentDryRun ? "to download" : "new")"
            return s
        }
        if let lastRun { return "Last run \(lastRun.formatted(.relative(presentation: .named)))" }
        return "Not run yet"
    }
}

/// Collects the events a run sends from its download tasks, in order, until the main actor takes them.
final class SyncEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [SyncEvent] = []

    /// Returns true when this is the first event since the last `drain`, so the caller schedules one.
    func add(_ event: SyncEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending.append(event)
        return pending.count == 1
    }

    func drain() -> [SyncEvent] {
        lock.lock(); defer { lock.unlock() }
        let events = pending
        pending = []
        return events
    }
}
#endif
