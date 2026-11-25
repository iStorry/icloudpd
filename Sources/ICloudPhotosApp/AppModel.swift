#if canImport(SwiftUI) && os(macOS)
import AppKit
import Foundation
import ICloudKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case needsCode
        case signedIn
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
        let isError: Bool
    }

    // Account
    @Published var phase: Phase = .signedOut
    @Published var appleID: String = UserDefaults.standard.string(forKey: "appleID") ?? ""
    @Published var domain: ICloudDomain = ICloudDomain(rawValue: UserDefaults.standard.string(forKey: "domain") ?? "") ?? .com
    @Published var rememberPassword: Bool = UserDefaults.standard.object(forKey: "rememberPassword") as? Bool ?? true
    @Published var errorMessage: String?
    @Published var accountName: String?

    // Two-factor
    @Published var phones: [TrustedPhoneNumber] = []
    @Published var smsPhone: TrustedPhoneNumber?
    @Published var isVerifying = false

    // Download settings
    @Published var directory: URL? = UserDefaults.standard.url(forKey: "directory") {
        didSet { UserDefaults.standard.set(directory, forKey: "directory") }
    }
    @Published var folderStructure: FolderStructure =
        FolderStructure(rawValue: UserDefaults.standard.string(forKey: "folderStructure") ?? "") ?? .yearMonthDay {
        didSet { UserDefaults.standard.set(folderStructure.rawValue, forKey: "folderStructure") }
    }
    @Published var includeVideos: Bool = UserDefaults.standard.object(forKey: "includeVideos") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeVideos, forKey: "includeVideos") }
    }
    @Published var includeLivePhotoVideos: Bool = UserDefaults.standard.object(forKey: "includeLive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeLivePhotoVideos, forKey: "includeLive") }
    }

    // Download progress
    @Published var isDownloading = false
    @Published var total: Int?
    @Published var processed = 0
    @Published var downloaded = 0
    @Published var skipped = 0
    @Published var failed = 0
    @Published var bytes = 0
    @Published var log: [LogLine] = []

    private var account: ICloudAccount?
    private var downloadTask: Task<Void, Never>?

    init() {
        // Try the saved session quietly at launch.
        if !appleID.isEmpty, UserDefaults.standard.bool(forKey: "wasSignedIn") {
            Task { await signIn(password: nil) }
        }
    }

    // MARK: Sign-in

    func signIn(password typed: String?) async {
        let id = appleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        errorMessage = nil
        phase = .signingIn
        UserDefaults.standard.set(id, forKey: "appleID")
        UserDefaults.standard.set(domain.rawValue, forKey: "domain")
        UserDefaults.standard.set(rememberPassword, forKey: "rememberPassword")

        let account = ICloudAccount(appleID: id, domain: domain)
        self.account = account
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
                finishSignIn()
            case .needsVerificationCode:
                phase = .needsCode
                smsPhone = nil
                await account.requestCodeOnTrustedDevices()
                phones = (try? await account.trustedPhoneNumbers()) ?? []
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
            if let phone = smsPhone {
                try await account.verifySMS(code: code, phone: phone)
            } else {
                try await account.verify(code: code)
            }
            finishSignIn()
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

    func cancelVerification() {
        phase = .signedOut
        account = nil
    }

    private func finishSignIn() {
        phase = .signedIn
        accountName = account?.fullName
        UserDefaults.standard.set(true, forKey: "wasSignedIn")
    }

    func signOut() {
        stopDownload()
        account?.signOut()
        Keychain.delete(appleID)
        account = nil
        accountName = nil
        phase = .signedOut
        UserDefaults.standard.set(false, forKey: "wasSignedIn")
    }

    // MARK: Download

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to save your iCloud photos"
        if panel.runModal() == .OK { directory = panel.url }
    }

    func startDownload() {
        guard let account, let directory, !isDownloading else { return }
        isDownloading = true
        total = nil
        processed = 0
        downloaded = 0
        skipped = 0
        failed = 0
        bytes = 0
        log = []
        append("Opening your iCloud Photos library…")

        let options = DownloadOptions(directory: directory, folderStructure: folderStructure,
                                      includeVideos: includeVideos, includeLivePhotoVideos: includeLivePhotoVideos)
        downloadTask = Task {
            do {
                let photos = try await account.photos()
                let downloader = PhotoDownloader(options: options)
                let summary = try await downloader.run(service: photos) { event in
                    Task { @MainActor [weak self] in self?.handle(event) }
                }
                append("Done. \(summary.filesDownloaded) new files, \(summary.filesSkipped) already there, \(summary.filesFailed) failed.")
            } catch is CancellationError {
                append("Stopped.")
            } catch {
                append(error.localizedDescription, isError: true)
                if case ICloudError.http(let status, _) = error, [401, 421, 450].contains(status) {
                    append("Your iCloud session expired. Sign in again.", isError: true)
                    phase = .signedOut
                }
            }
            isDownloading = false
        }
    }

    func stopDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .counted(let total):
            self.total = total
            append("\(total.formatted()) items in iCloud Photos.")
        case .processed(let index):
            processed = max(processed, index)
        case .downloaded(let path, let size):
            downloaded += 1
            bytes += size
            append("Downloaded \(path)")
        case .alreadyExists:
            skipped += 1
        case .failed(let name, let message):
            failed += 1
            append("\(name): \(message)", isError: true)
        }
    }

    private func append(_ text: String, isError: Bool = false) {
        log.append(LogLine(text: text, isError: isError))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
#endif
