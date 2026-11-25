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
                case .signedIn:
                    DownloadView()
                }
            }
            .transition(.blurReplace)
        }
        .animation(.smooth(duration: 0.3), value: model.phase)
        .frame(minWidth: 900, minHeight: 640)
        // The window has no title bar: the content runs to the top edge, under the traffic lights.
        .ignoresSafeArea()
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: Sign in

struct SignInView: View {
    private enum Field { case appleID, password }

    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @FocusState private var focus: Field?

    private var isSigningIn: Bool { model.phase == .signingIn }

    var body: some View {
        HStack(spacing: 0) {
            // The mosaic is taller than any window, so it goes in an overlay, where it can't
            // stretch the pane and push the caption off the bottom.
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.3)
                    .overlay(alignment: .top) { PhotoMosaic() }
                    .clipped()
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 28, weight: .regular))
                    Text("Your whole library,\nsafely on your Mac.")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.6)
                    Text("Every photo and video, in original quality, saved to a folder you choose.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 36)
            }
            .frame(width: 400)
            .clipped()

            form
                .frame(maxWidth: 340)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)
                Text("Use your Apple ID. Your password goes only to Apple.")
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.bottom, 8)

            Group {
                LabeledField(title: "Apple ID", isFocused: focus == .appleID) {
                    TextField("Apple ID", text: $model.appleID, prompt: Text("name@example.com"))
                        .textContentType(.username)
                        .focused($focus, equals: .appleID)
                        .onSubmit { focus = .password }
                }
                LabeledField(title: "Password", isFocused: focus == .password) {
                    SecureField("Password", text: $password, prompt: Text("Required"))
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }
                HStack {
                    Text("Remember in Keychain").foregroundStyle(Color(white: 0.84))
                    Spacer()
                    Toggle("Remember in Keychain", isOn: $model.rememberPassword)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .frame(minHeight: 36)
            }
            .disabled(isSigningIn)

            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if isSigningIn { ProgressView().controlSize(.small) }
                    Text(isSigningIn ? "Signing In…" : "Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(height: 50))
            .keyboardShortcut(.defaultAction)
            .disabled(model.appleID.isEmpty || password.isEmpty || isSigningIn)

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 4)

            HStack {
                Text("Region").foregroundStyle(Theme.secondary)
                Spacer()
                Picker("Region", selection: $model.domain) {
                    Text("Worldwide (icloud.com)").tag(ICloudDomain.com)
                    Text("China mainland (icloud.com.cn)").tag(ICloudDomain.cn)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.white)
                .fixedSize()
                .disabled(isSigningIn)
            }
            Text("\"Access iCloud Data on the Web\" must be on, and Advanced Data Protection off, on your iPhone or iPad.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focus = model.appleID.isEmpty ? .appleID : .password }
    }

    private func submit() {
        guard !model.appleID.isEmpty, !password.isEmpty, !isSigningIn else { return }
        let typed = password
        Task {
            await model.signIn(password: typed)
            password = ""
        }
    }
}

// MARK: Two-factor code

struct VerificationView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                HeroTile(systemName: "lock.shield").padding(.bottom, 6)
                Text("Enter your code")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)
                Text(model.smsPhone.map { "Apple texted a code to \($0.obfuscatedNumber)." }
                     ?? "Apple sent a six-digit code to your iPhone, iPad or Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            codeBoxes

            if let error = model.errorMessage {
                ErrorBanner(message: error).frame(maxWidth: 400)
            }

            HStack(spacing: 12) {
                Button { model.cancelVerification() } label: {
                    Text("Back").frame(width: 102)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if model.isVerifying { ProgressView().controlSize(.small) }
                        Text("Verify")
                    }
                    .frame(width: 102)
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(code.count != 6 || model.isVerifying)
            }

            if !model.phones.isEmpty {
                Menu("Didn't get a code? Text me instead") {
                    ForEach(model.phones) { phone in
                        Button(phone.obfuscatedNumber) { Task { await model.sendSMS(to: phone) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(Theme.accentSoft)
                .fixedSize()
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { accountChip.padding(14) }
        .onAppear { codeFocused = true }
    }

    /// Six boxes drawn over one real text field, which keeps typing, paste and code autofill working.
    private var codeBoxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                if index == 3 {
                    Capsule().fill(Color.white.opacity(0.25)).frame(width: 10, height: 2)
                }
                let isActive = codeFocused && index == code.count
                Text(digit(at: index))
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 56, height: 68)
                    .background(Color.white.opacity(isActive ? 0.08 : 0.06), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent : Theme.fieldStroke))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(Theme.accent.opacity(isActive ? 0.3 : 0), lineWidth: 4)
                        .padding(-3))
            }
        }
        .overlay {
            TextField("Six-digit code", text: $code)
                .textFieldStyle(.plain)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.02)
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { code = digits }
                    if digits.count == 6 { submit() }
                }
        }
        .animation(.easeOut(duration: 0.12), value: code.count)
    }

    private var accountChip: some View {
        HStack(spacing: 8) {
            Text(Initials.of(model.appleID))
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: .circle)
            Text(model.appleID).foregroundStyle(Color(white: 0.84))
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 32)
        .background(Theme.fieldFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
    }

    private func digit(at index: Int) -> String {
        index < code.count ? String(code[code.index(code.startIndex, offsetBy: index)]) : ""
    }

    private func submit() {
        guard code.count == 6, !model.isVerifying else { return }
        let typed = code
        Task { await model.verify(code: typed) }
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

// MARK: Two-step verification (older Apple IDs)

struct TwoStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.twoStepDevice == nil {
            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    HeroTile(systemName: "iphone").padding(.bottom, 6)
                    Text("Two-Step Verification")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.7)
                    Text("This Apple ID uses two-step verification. Choose where Apple should send the code.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                Card {
                    ForEach(model.twoStepDevices) { device in
                        Button { Task { await model.sendTwoStepCode(to: device) } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "iphone")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.accentSoft)
                                    .frame(width: 38, height: 38)
                                    .background(Theme.accent.opacity(0.22), in: .rect(cornerRadius: 11, style: .continuous))
                                Text(device.name).font(.system(size: 15, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 64)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 380)

                if let error = model.errorMessage {
                    ErrorBanner(message: error).frame(width: 380)
                }

                Button { model.cancelVerification() } label: {
                    Text("Cancel").frame(width: 102)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VerificationView()
        }
    }
}

// MARK: Download

struct DownloadView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAlbums = false

    var body: some View {
        HStack(spacing: 12) {
            sidebar
            Group {
                if isActive { runStage } else { readyStage }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .animation(.smooth(duration: 0.3), value: isActive)
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

    /// A run is going, or its results are still on screen.
    private var isActive: Bool { model.isDownloading || model.processed > 0 }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Save to")
                        Card {
                            CardRow {
                                Image(systemName: "folder.fill").foregroundStyle(Theme.accentSoft)
                                Text(model.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(model.directory == nil ? Theme.secondary : Color.primary)
                                Spacer(minLength: 4)
                                if model.directory != nil {
                                    Button("Show") { model.openDirectory() }
                                }
                                Button("Choose…") { model.chooseDirectory() }
                            }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 26))
                            FolderStructureRows(format: $model.config.folderStructure)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "From")
                        Card {
                            if model.libraries.count > 1 {
                                CardRow {
                                    Text("Library")
                                    Spacer(minLength: 8)
                                    Picker("Library", selection: libraryBinding) {
                                        ForEach(model.libraries, id: \.self) { Text(model.libraryLabel($0)).tag($0) }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                .tint(.white)
                                    .fixedSize()
                                }
                            }
                            CardRow {
                                Text("Albums")
                                Spacer(minLength: 8)
                                Text(albumSummary).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                                Button("Choose…") { showingAlbums = true }
                                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 26))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Include")
                        Card {
                            SwitchRow(title: "Photos", isOn: inverted(\.skipPhotos))
                            SwitchRow(title: "Videos", isOn: inverted(\.skipVideos))
                            SwitchRow(title: "Live Photo videos", isOn: inverted(\.skipLivePhotos))
                            SwitchRow(title: "Screenshots", isOn: inverted(\.skipScreenshots))
                        }
                    }
                    if !model.config.dryRun && model.config.deletesFromICloud {
                        Label("This setup deletes photos from iCloud after downloading them. Change it in Settings > Sync.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .panel(fill: Theme.warning.opacity(0.08), stroke: Theme.warning.opacity(0.35))
                    }
                }
                .disabled(model.isDownloading)
                .opacity(model.isDownloading ? 0.45 : 1)
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        // Clear the traffic lights, which sit over the top of the sidebar.
        .padding(.top, 26)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .panel(cornerRadius: 22)
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            Text(Initials.of(model.accountName ?? model.appleID))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Theme.accent, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.accountName ?? model.appleID)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if model.accountName != nil {
                    Text(model.appleID)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            SettingsLink { CircleIcon(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            Menu {
                Section(model.appleID) {
                    Button("Reload Libraries and Albums", systemImage: "arrow.clockwise") {
                        Task { await model.loadLibraries() }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") { model.signOut() }
                        .disabled(model.isDownloading)
                }
            } label: {
                CircleIcon(systemName: "chevron.down")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Account")
            .accessibilityLabel("Account")
        }
        .padding(.leading, 4)
    }

    // MARK: Ready

    private var readyStage: some View {
        VStack(spacing: 24) {
            ProgressRing(progress: nil, lineWidth: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 56, weight: .light))
            }
            .frame(width: 196, height: 196)

            VStack(spacing: 8) {
                Text(model.directory == nil ? "Choose a folder to begin" : "Ready when you are")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)
                Text("Photos already in your folder are skipped, so you can stop and pick up again any time.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            startButtons(large: true)

            if let status = idleStatus {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .panel(cornerRadius: 17)
            }
        }
        .padding(.horizontal, 20)
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
        .disabled(model.directory == nil)
    }

    private var idleStatus: String? {
        guard model.directory != nil else { return nil }
        var parts: [String] = []
        if let summary = model.lastRunSummary { parts.append("Last run: \(summary)") }
        if let next = model.nextRun { parts.append("Next run \(next.formatted(date: .omitted, time: .shortened))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                        Image(systemName: "checkmark").font(.system(size: 40, weight: .medium))
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
                        Text("\(model.processed.formatted())\(model.total.map { " of \($0.formatted())" } ?? "") checked")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(stats) { StatCard(stat: $0) }
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
        if model.isDownloading { return model.currentDryRun ? "Checking your library" : "Downloading your photos" }
        return model.currentDryRun ? "Dry run finished" : "Finished"
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

    private var libraryBinding: Binding<String> {
        Binding(get: { model.config.library ?? model.libraries.first ?? "PrimarySync" },
                set: { name in
                    model.config.library = name
                    model.config.albums = []
                    Task { await model.loadAlbums() }
                })
    }

    private func inverted(_ key: WritableKeyPath<SyncConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { !model.config[keyPath: key] }, set: { model.config[keyPath: key] = !$0 })
    }

    private var albumSummary: String {
        switch model.config.albums.count {
        case 0: return "All Photos"
        case 1: return model.config.albums[0]
        default: return "\(model.config.albums.count) albums"
        }
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

/// Folder layout presets plus a custom icloudpd-style format, as rows of a card.
struct FolderStructureRows: View {
    @Binding var format: String

    private var preset: Binding<String> {
        Binding(get: { FolderStructure(rawValue: format) != nil ? format : "custom" },
                set: { if $0 != "custom" { format = $0 } else if FolderStructure(rawValue: format) != nil { format = "{:%Y}/{:%m-%B}" } })
    }

    var body: some View {
        CardRow {
            Text("Folders")
            Spacer(minLength: 8)
            Picker("Folders", selection: preset) {
                ForEach(FolderStructure.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                Text("Custom").tag("custom")
            }
            .labelsHidden()
            .pickerStyle(.menu)
                .tint(.white)
            .fixedSize()
        }
        if FolderStructure(rawValue: format) == nil {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Format", text: $format, prompt: Text("{:%Y}/{:%m}"))
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                Text(example).font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var example: String {
        guard let f = try? FolderFormat(format) else { return "Use fields like {:%Y}, {:%m}, {:%d}, {:%B}." }
        let path = f.path(for: Date())
        return path.isEmpty ? "All photos in one folder" : "Today's photos go in \(path)/"
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

            Card {
                SwitchRow(title: "All Photos", isOn: Binding(
                    get: { model.config.albums.isEmpty },
                    set: { if $0 { model.config.albums = [] } }))
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
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
#endif
