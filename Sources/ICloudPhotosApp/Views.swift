#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut, .signingIn:
                SignInView()
            case .needsCode:
                VerificationView()
            case .signedIn:
                DownloadView()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}

// MARK: Sign in

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("Download your iCloud Photos")
                .font(.title2.weight(.semibold))
            Text("Sign in with your Apple ID. Your password goes only to Apple and, if you choose, to your Mac's Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Form {
                TextField("Apple ID", text: $model.appleID)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(submit)
                Picker("Region", selection: $model.domain) {
                    Text("Worldwide (icloud.com)").tag(ICloudDomain.com)
                    Text("China mainland (icloud.com.cn)").tag(ICloudDomain.cn)
                }
                Toggle("Remember password in Keychain", isOn: $model.rememberPassword)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)
            .disabled(model.phase == .signingIn)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 420)
            }

            HStack {
                if model.phase == .signingIn { ProgressView().controlSize(.small) }
                Button("Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.appleID.isEmpty || password.isEmpty || model.phase == .signingIn)
            }

            Text("\"Access iCloud Data on the Web\" must be on, and Advanced Data Protection off, on your iPhone or iPad.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    private func submit() {
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

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Enter the verification code")
                .font(.title2.weight(.semibold))
            Text(model.smsPhone.map { "Apple texted a code to \($0.obfuscatedNumber)." }
                 ?? "Apple sent a six-digit code to your iPhone, iPad or Mac.")
                .foregroundStyle(.secondary)

            TextField("123456", text: $code)
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 200)
                .textFieldStyle(.roundedBorder)
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { code = digits }
                    if digits.count == 6 { submit() }
                }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { model.cancelVerification() }
                if model.isVerifying { ProgressView().controlSize(.small) }
                Button("Verify", action: submit)
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
                .fixedSize()
            }
        }
        .padding(32)
    }

    private func submit() {
        guard code.count == 6, !model.isVerifying else { return }
        let typed = code
        Task { await model.verify(code: typed) }
    }
}

// MARK: Download

struct DownloadView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("Save to") {
                    HStack {
                        Image(systemName: "folder")
                        Text(model.directory?.path ?? "No folder chosen")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.directory == nil ? Color.secondary : Color.primary)
                        Spacer()
                        Button("Choose…") { model.chooseDirectory() }
                    }
                    Picker("Folders", selection: $model.folderStructure) {
                        ForEach(FolderStructure.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Include") {
                    Toggle("Videos", isOn: $model.includeVideos)
                    Toggle("Live Photo videos", isOn: $model.includeLivePhotoVideos)
                }
            }
            .formStyle(.grouped)
            .disabled(model.isDownloading)
            .frame(maxHeight: 260)

            progress
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            LogView(lines: model.log)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill").font(.title)
            VStack(alignment: .leading) {
                Text(model.accountName ?? model.appleID).font(.headline)
                if model.accountName != nil {
                    Text(model.appleID).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Sign Out") { model.signOut() }
        }
        .padding(16)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.isDownloading {
                    Button(role: .cancel) { model.stopDownload() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { model.startDownload() } label: { Label("Download All Photos", systemImage: "arrow.down.circle.fill") }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.directory == nil)
                }
                Spacer()
                Text(statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.isDownloading || model.processed > 0 {
                if let total = model.total, total > 0 {
                    ProgressView(value: Double(min(model.processed, total)), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }

    private var statusText: String {
        guard model.isDownloading || model.processed > 0 else { return "" }
        var parts = ["\(model.processed.formatted())\(model.total.map { " of \($0.formatted())" } ?? "") checked",
                     "\(model.downloaded.formatted()) new (\(ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file)))",
                     "\(model.skipped.formatted()) already saved"]
        if model.failed > 0 { parts.append("\(model.failed) failed") }
        return parts.joined(separator: " · ")
    }
}

struct LogView: View {
    let lines: [AppModel.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            List(lines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .id(line.id)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
#endif
