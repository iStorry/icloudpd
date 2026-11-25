import Foundation
import ICloudKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// icloudpd-swift: the command-line face of ICloudKit, taking icloudpd's options.

let version = "0.2.0"

struct Options {
    var username: String?
    var password: String?
    var passwordProviders: [String] = ["parameter", "keychain", "console"]
    var cookieDirectory: String?
    var domain: ICloudDomain = .com
    var config: SyncConfiguration?
    var directory: String?
    var authOnly = false
    var listAlbums = false
    var listLibraries = false
    var onlyPrintFilenames = false
    var watchInterval: Int?
    var logLevel: SyncLogLevel = .info
    var noProgressBar = false
    var adpWebAccess = false
    var notificationScript: String?
    var deleteList: String?
    var deleteListAllowUndated = false
    var deleteListMax = 100
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icloudpd-swift: error: \(message)\n".utf8))
    exit(2)
}

let help = """
Usage: icloudpd-swift [OPTIONS]

Download iCloud Photos to a folder. A Swift port of icloudpd; options keep icloudpd's names.

Account
  -u, --username APPLE_ID           Apple ID email address
  -p, --password PASSWORD           Password (prefer the Keychain or the prompt)
  --password-provider NAME          parameter, keychain, console, or env (ICLOUD_PASSWORD);
                                    repeat to try several in order. Default: parameter keychain console
  --cookie-directory DIR            Where to keep the session (default: ~/Library/Application Support/ICloudPhotos/Sessions)
  --domain com|cn                   iCloud root domain; cn for mainland China
  --auth-only                       Sign in (and do 2FA) only, then exit
  --adp-web-access                  Unlock Advanced Data Protection data for the web session
  --notification-script PATH        Run this script when a 2FA code is needed

Where
  -d, --directory DIR               Local folder to download into
  --folder-structure FORMAT         Folder format, default "{:%Y/%m/%d}"; "none" for no subfolders
  --live-photo-directory DIR        Put Live Photo videos here instead of next to the photo

What
  --library NAME                    Library to download (default PrimarySync)
  --list-libraries                  List the libraries and exit
  -a, --album NAME                  Album to download; repeat for several (default: whole library)
  -l, --list-albums                 List the albums and exit
  --size SIZE                       original, adjusted, alternative, medium, thumb; repeat for several
  --force-size                      Only download the requested size; don't fall back to original
  --live-photo-size SIZE            original, medium or thumb
  --skip-live-photos, --skip-videos, --skip-photos, --skip-screenshots
  --skip-created-before DATE        ISO date (2025-01-02) or interval (20d)
  --skip-created-after DATE         ISO date or interval
  --exclude-filename PATTERN        Skip names matching a glob such as IMG_12*.JPG; repeatable
  --recent N                        Only the N most recent photos
  --until-found N                   Stop after N consecutive photos that are already downloaded

Naming
  --live-photo-mov-filename-policy suffix|original
  --align-raw as-is|original|alternative
  --file-match-policy name-size-dedup-with-suffix|name-id7
  --keep-unicode-in-filenames
  --temp-suffix SUFFIX              Suffix of in-progress downloads (default .part)

Metadata
  --set-exif-datetime               Write DateTimeOriginal into JPEGs that have none
  --xmp-sidecar                     Write .xmp sidecars
  --xmp-sidecar-only                Only write .xmp sidecars, download nothing

Sync and delete
  --auto-delete                     Delete local files of photos in iCloud's Recently Deleted
  --prune-orphans                   Move downloaded files of photos gone from iCloud to .icloudpd-swift-pruned/
  --delete-after-download           Delete each photo from iCloud once it's downloaded
  --keep-icloud-recent-days N       Delete photos older than N days from iCloud once they're downloaded
  --delete-list FILE                Delete from iCloud the assets in FILE (FILENAME<TAB>SIZE<TAB>DATE lines)
  --delete-list-allow-undated       Accept delete-list lines without a date
  --delete-list-max N               Refuse lists longer than N (default 100)

Run
  --dry-run                         Change nothing locally or in iCloud
  --only-print-filenames            Print the files that would be downloaded, and nothing else
  --threads-num N                   Parallel downloads (default 4)
  --watch-with-interval SECONDS     Run again every SECONDS
  --ignore-indexing-state           Go on when iCloud keeps saying the library is still indexing
  --log-level debug|info|error
  --no-progress-bar
  --version, -h/--help

Not supported from icloudpd: --smtp-* email notifications and the web UI; use --notification-script instead.
"""

func parse(_ raw: [String]) -> Options {
    // --name=value is the same as --name value
    let arguments = raw.flatMap { arg -> [String] in
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
            return [String(arg[..<eq]), String(arg[arg.index(after: eq)...])]
        }
        return [arg]
    }
    var o = Options()
    var c = SyncConfiguration(directoryPath: "")
    var sizes: [PhotoSize] = []
    var providersSet = false
    var i = 0
    func value(_ name: String) -> String {
        i += 1
        guard i < arguments.count else { fail("\(name) needs a value") }
        return arguments[i]
    }
    func int(_ name: String) -> Int {
        let v = value(name)
        guard let n = Int(v), n >= 0 else { fail("\(name) needs a whole number, got \(v)") }
        return n
    }
    func choice<T: RawRepresentable>(_ name: String, _: T.Type) -> T where T.RawValue == String {
        let v = value(name).lowercased()
        guard let t = T(rawValue: v) else { fail("invalid value for \(name): \(v)") }
        return t
    }
    while i < arguments.count {
        var arg = arguments[i]
        if arg == "-h" { arg = "--help" }
        switch arg {
        case "--help": print(help); exit(0)
        case "--version": print("icloudpd-swift \(version)"); exit(0)
        case "-u", "--username": o.username = value(arg)
        case "-p", "--password": o.password = value(arg)
        case "--password-provider":
            if !providersSet { o.passwordProviders = []; providersSet = true }
            let p = value(arg).lowercased()
            guard ["parameter", "keychain", "keyring", "console", "env"].contains(p) else { fail("unknown password provider \(p)") }
            o.passwordProviders.append(p == "keyring" ? "keychain" : p)
        case "--cookie-directory": o.cookieDirectory = value(arg)
        case "--domain": o.domain = choice(arg, ICloudDomain.self)
        case "--auth-only": o.authOnly = true
        case "--adp-web-access": o.adpWebAccess = true
        case "--notification-script": o.notificationScript = value(arg)
        case "-d", "--directory": o.directory = value(arg)
        case "--folder-structure": c.folderStructure = value(arg)
        case "--live-photo-directory": c.livePhotoDirectoryPath = value(arg)
        case "--library": c.library = value(arg)
        case "--list-libraries": o.listLibraries = true
        case "-a", "--album": c.albums.append(value(arg))
        case "-l", "--list-albums": o.listAlbums = true
        case "--size": sizes.append(choice(arg, PhotoSize.self))
        case "--force-size": c.forceSize = true
        case "--live-photo-size": c.livePhotoSize = choice(arg, LivePhotoSize.self)
        case "--skip-live-photos": c.skipLivePhotos = true
        case "--skip-videos": c.skipVideos = true
        case "--skip-photos": c.skipPhotos = true
        case "--skip-screenshots": c.skipScreenshots = true
        case "--skip-created-before":
            let v = value(arg)
            guard let d = DateBound.parse(v) else { fail("--skip-created-before: use an ISO date (2025-01-02) or an interval (20d), got \(v)") }
            c.skipCreatedBefore = d
        case "--skip-created-after":
            let v = value(arg)
            guard let d = DateBound.parse(v) else { fail("--skip-created-after: use an ISO date (2025-01-02) or an interval (20d), got \(v)") }
            c.skipCreatedAfter = d
        case "--exclude-filename": c.excludeFilenames.append(value(arg))
        case "--recent": c.recent = int(arg)
        case "--until-found": c.untilFound = int(arg)
        case "--live-photo-mov-filename-policy": c.livePhotoMovFilenamePolicy = choice(arg, LivePhotoMovFilenamePolicy.self)
        case "--align-raw": c.alignRaw = choice(arg, RawPolicy.self)
        case "--file-match-policy": c.fileMatchPolicy = choice(arg, FileMatchPolicy.self)
        case "--keep-unicode-in-filenames": c.keepUnicodeInFilenames = true
        case "--temp-suffix": c.temporarySuffix = value(arg)
        case "--set-exif-datetime": c.setExifDatetime = true
        case "--xmp-sidecar": c.xmpSidecar = true
        case "--xmp-sidecar-only": c.xmpSidecarOnly = true
        case "--auto-delete": c.autoDelete = true
        case "--prune-orphans": c.pruneOrphans = true
        case "--delete-after-download": c.deleteAfterDownload = true
        case "--keep-icloud-recent-days": c.keepICloudRecentDays = int(arg)
        case "--delete-list": o.deleteList = value(arg)
        case "--delete-list-allow-undated": o.deleteListAllowUndated = true
        case "--delete-list-max": o.deleteListMax = int(arg)
        case "--dry-run": c.dryRun = true
        case "--only-print-filenames": o.onlyPrintFilenames = true; c.dryRun = true
        case "--threads-num": c.concurrentDownloads = max(1, int(arg))
        case "--watch-with-interval": o.watchInterval = int(arg)
        case "--ignore-indexing-state": c.ignoreIndexingState = true
        case "--log-level":
            switch value(arg).lowercased() {
            case "debug": o.logLevel = .debug
            case "info": o.logLevel = .info
            case "warning": o.logLevel = .warning
            case "error": o.logLevel = .error
            default: fail("--log-level: debug, info or error")
            }
        case "--no-progress-bar": o.noProgressBar = true
        case "--use-os-locale": break // dates are formatted in the POSIX locale either way
        default:
            if arg.hasPrefix("--smtp") || arg.hasPrefix("--notification-email") || arg.hasPrefix("--webui") || arg == "--mfa-provider" {
                fail("\(arg) isn't supported by icloudpd-swift; use --notification-script")
            }
            fail("unknown option \(arg) (see --help)")
        }
        i += 1
    }
    if !sizes.isEmpty { c.sizes = sizes }
    if let d = o.directory { c.directoryPath = d }
    o.config = c
    return o
}

// MARK: Console

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

final class Console: @unchecked Sendable {
    let level: SyncLogLevel
    let quiet: Bool
    let lock = NSLock()
    init(level: SyncLogLevel, quiet: Bool) { self.level = level; self.quiet = quiet }

    func log(_ l: SyncLogLevel, _ message: String) {
        guard !quiet, l >= level else { return }
        let name: String
        switch l { case .debug: name = "DEBUG"; case .info: name = "INFO"; case .warning: name = "WARNING"; case .error: name = "ERROR" }
        lock.lock()
        let line = "\(stamp.string(from: Date())) \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }

    func print(_ s: String) {
        lock.lock(); Swift.print(s); fflush(stdout); lock.unlock()
    }
}

func prompt(_ text: String) -> String? {
    FileHandle.standardError.write(Data(text.utf8))
    return readLine(strippingNewline: true)
}

func promptSecret(_ text: String) -> String? {
    guard let p = getpass(text) else { return nil }
    return String(cString: p)
}

func runScript(_ path: String, console: Console) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do { try process.run(); process.waitUntilExit() } catch {
        console.log(.error, "Could not run the notification script: \(error.localizedDescription)")
    }
}

// MARK: Sign-in

func signIn(_ o: Options, console: Console) async throws -> ICloudAccount {
    guard let username = o.username else { fail("--username is required") }
    let store = o.cookieDirectory.map {
        SessionStore(directory: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            .appendingPathComponent(SessionStore.defaultDirectory(for: username).lastPathComponent))
    }
    let account = ICloudAccount(appleID: username, domain: o.domain, store: store)
    var usedPassword: String?
    var fromConsole = false
    let result = try await account.signIn(password: {
        for provider in o.passwordProviders {
            switch provider {
            case "parameter": if let p = o.password { usedPassword = p; return p }
            case "env": if let p = ProcessInfo.processInfo.environment["ICLOUD_PASSWORD"] { usedPassword = p; return p }
            case "keychain": if let p = Keychain.password(for: username) { usedPassword = p; return p }
            case "console":
                if let p = promptSecret("iCloud Password for \(username): "), !p.isEmpty { usedPassword = p; fromConsole = true; return p }
            default: break
            }
        }
        return nil
    })
    if fromConsole, let p = usedPassword, o.passwordProviders.contains("keychain") {
        Keychain.save(p, for: username) // like icloudpd, a valid password is saved to the keyring provider
    }

    switch result {
    case .signedIn:
        break
    case .needsVerificationCode:
        console.log(.info, "Two-factor authentication is required (2fa)")
        if let script = o.notificationScript { runScript(script, console: console) }
        let phones = try await account.trustedPhoneNumbers()
        if phones.isEmpty, await account.usesSecurityKeys() { throw ICloudError.securityKeysNotSupported }
        await account.requestCodeOnTrustedDevices()
        var sms: TrustedPhoneNumber?
        while true {
            var text = "Please enter two-factor authentication code"
            if !phones.isEmpty && sms == nil {
                FileHandle.standardError.write(Data("  Or ask for a text message:\n".utf8))
                for (index, phone) in phones.enumerated() {
                    let letter = Character(UnicodeScalar(UInt8(97 + index)))
                    FileHandle.standardError.write(Data("  \(letter): SMS to \(phone.obfuscatedNumber)\n".utf8))
                }
                text += " or a letter"
            }
            guard let input = prompt(text + ": ")?.trimmingCharacters(in: .whitespaces), !input.isEmpty else { fail("no code given") }
            if sms == nil, input.count == 1, let ascii = input.unicodeScalars.first?.value, ascii >= 97, Int(ascii - 97) < phones.count {
                let phone = phones[Int(ascii - 97)]
                try await account.sendSMSCode(to: phone)
                sms = phone
                continue
            }
            guard input.count == 6, input.allSatisfy(\.isNumber) else { console.log(.error, "Codes have six digits"); continue }
            do {
                if let sms { try await account.verifySMS(code: input, phone: sms) } else { try await account.verify(code: input) }
                break
            } catch ICloudError.wrongVerificationCode {
                console.log(.error, "Code verification failed.")
            }
        }
        console.log(.info, "Great, you're all set up. The script can now be run without user interaction until 2FA expires.")
    case .needsTwoStepVerification:
        console.log(.info, "Two-step authentication is required (2sa)")
        if let script = o.notificationScript { runScript(script, console: console) }
        let devices = try await account.trustedDevices()
        guard !devices.isEmpty else { throw ICloudError.twoStepNotSupported }
        for d in devices { FileHandle.standardError.write(Data("  \(d.id): \(d.name)\n".utf8)) }
        let pick = Int(prompt("Please choose an option: [0] ") ?? "") ?? 0
        guard let device = devices.first(where: { $0.id == pick }) else { fail("no such device") }
        try await account.sendVerificationCode(to: device)
        while true {
            guard let code = prompt("Please enter validation code: "), !code.isEmpty else { fail("no code given") }
            do { try await account.verify(code: code, device: device); break }
            catch ICloudError.wrongVerificationCode { console.log(.error, "Failed to verify verification code") }
        }
    }
    if o.adpWebAccess {
        try await account.requestWebAccess { console.log(.info, "Approve the iCloud web access request on your Apple device (waiting 120s)") }
    }
    return account
}

// MARK: Run

func runOnce(_ o: Options, console: Console) async throws -> Int32 {
    let account = try await signIn(o, console: console)
    if o.authOnly {
        console.log(.info, "Authentication completed successfully")
        return 0
    }
    var config = o.config!
    let photos = try await account.photos(ignoreIndexingState: config.ignoreIndexingState)
    if o.listLibraries {
        for library in try await photos.allLibraries() { console.print(library.name) }
        return 0
    }
    let library = try await photos.library(named: config.library)
    if o.listAlbums {
        for album in try await library.albums() { console.print(album.name) }
        return 0
    }
    if let path = o.deleteList {
        let text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        let list = try DeleteList(contents: text, allowUndated: o.deleteListAllowUndated, source: path)
        let summary = try await list.run(library: library, maxEntries: o.deleteListMax, dryRun: config.dryRun) { console.log($0, $1) }
        return summary.isClean ? 0 : 1
    }
    guard o.directory != nil else { fail("--directory is required") }
    if config.library == nil { config.library = library.name }
    let runConfig = config

    let progress = !o.noProgressBar && isatty(STDERR_FILENO) != 0 && !o.onlyPrintFilenames
    let state = ProgressState()
    let engine = try SyncEngine(configuration: runConfig) { event in
        switch event {
        case .log(let level, let message): console.log(level, message)
        case .albumStarted(let title, let total):
            state.set(total: total)
            if let total { console.log(.info, "Downloading \(total) \(title == "All Photos" ? "" : "\(title) ")items...") }
        case .progress(let processed):
            if progress { state.draw(processed: processed) }
        case .downloaded(let path, _): console.log(.info, "Downloaded \(path)")
        case .wouldDownload(let path):
            if o.onlyPrintFilenames { console.print(runConfig.directory.appendingPathComponent(path).path) }
            else { console.log(.info, "[DRY RUN] Would download \(path)") }
        case .alreadyExists(let path): console.log(.debug, "\(path) already exists")
        case .failed(let name, let message): console.log(.error, "Could not download \(name): \(message)")
        case .deletedLocally, .deletedFromICloud, .bytesReceived: break
        case .pruned(let path): console.log(.info, "\(runConfig.dryRun ? "[DRY RUN] Would move" : "Moved") orphan \(path) to .icloudpd-swift-pruned/")
        }
    }
    let summary = try await engine.run(photos: photos)
    if progress { FileHandle.standardError.write(Data("\n".utf8)) }
    console.log(.info, "All photos have been downloaded" + (summary.filesFailed > 0 ? " except \(summary.filesFailed) that failed" : ""))
    return summary.filesFailed > 0 ? 1 : 0
}

final class ProgressState: @unchecked Sendable {
    let lock = NSLock()
    var total: Int?
    func set(total: Int?) { lock.lock(); self.total = total; lock.unlock() }
    func draw(processed: Int) {
        lock.lock(); let total = self.total; lock.unlock()
        let text = total.map { "\r\(processed)/\($0) checked" } ?? "\r\(processed) checked"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
let console = Console(level: options.logLevel, quiet: options.onlyPrintFilenames)
if let c = options.config, options.directory != nil {
    do { try c.validate() } catch { fail(error.localizedDescription) }
}

signal(SIGINT, SIG_DFL)
var exitCode: Int32 = 0
repeat {
    do {
        exitCode = try await runOnce(options, console: console)
    } catch {
        console.log(.error, error.localizedDescription)
        exitCode = 1
        if options.watchInterval == nil { break }
    }
    if let interval = options.watchInterval, !options.authOnly, !options.listAlbums, !options.listLibraries {
        console.log(.info, "Waiting for \(interval) sec...")
        try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
    } else {
        break
    }
} while true
exit(exitCode)
