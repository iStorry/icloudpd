#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

// MARK: Shell

/// The sign-in screens' layout: a wall of photos with a few words on the left, the form on the right.
struct AuthShell<Form: View>: View {
    let headline: String
    let message: String
    var points: [String] = []
    var formWidth: CGFloat = 360
    @ViewBuilder var form: Form

    var body: some View {
        HStack(spacing: 12) {
            AuthPhotoPanel(headline: headline, message: message, points: points)
            form
                .frame(maxWidth: formWidth)
                .padding(.horizontal, 36)
                .frame(width: formWidth + 80)
                .frame(maxHeight: .infinity)
        }
        .padding(12)
    }
}

/// The photo wall beside the sign-in form: the newest photos in the folder, or colour placeholders.
struct AuthPhotoPanel: View {
    @EnvironmentObject var model: AppModel
    let headline: String
    let message: String
    let points: [String]
    @State private var isNarrow = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoWall(photos: model.glance?.photos ?? [], layout: .tall)
            LinearGradient(stops: [.init(color: Theme.background.opacity(0.15), location: 0),
                                   .init(color: Theme.background.opacity(0.2), location: 0.35),
                                   .init(color: Theme.background.opacity(0.7), location: 0.65),
                                   .init(color: Theme.background.opacity(0.97), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent, in: .rect(cornerRadius: 9, style: .continuous))
                    Text("iCloud Photos")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(headline)
                    .font(.system(size: isNarrow ? 31 : 38, weight: .bold))
                    .tracking(isNarrow ? -1 : -1.3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.75))
                    .lineSpacing(3)
                    .frame(maxWidth: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !points.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { pointLabels }
                        VStack(alignment: .leading, spacing: 6) { pointLabels }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(isNarrow ? 28 : 36)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 480 } action: { isNarrow = $0 }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private var pointLabels: some View {
        ForEach(points, id: \.self) { point in
            Label(point, systemImage: "checkmark")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.8))
                .labelStyle(PointLabelStyle())
        }
    }

    private struct PointLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.font(.system(size: 10, weight: .bold))
                configuration.title
            }
        }
    }
}

/// The title block at the top of each form: an optional eyebrow or icon, a title and a line under it.
struct AuthHeading<Top: View>: View {
    let title: String
    let message: String
    @ViewBuilder var top: Top

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            top.padding(.bottom, 2)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.8)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The square tinted tile with a symbol above the verification titles.
struct AuthIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22))
            .foregroundStyle(Theme.accentSoft)
            .frame(width: 52, height: 52)
            .background(Theme.accent.opacity(0.16), in: .rect(cornerRadius: 16, style: .continuous))
            .padding(.bottom, 6)
    }
}

/// The signed-in Apple ID, in the corner while Apple asks for a code.
struct AccountChip: View {
    let appleID: String

    var body: some View {
        HStack(spacing: 8) {
            Text(Initials.of(appleID))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: .circle)
            Text(appleID).foregroundStyle(Color(white: 0.84)).lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 32)
        .background(Theme.fieldFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
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
        AuthShell(headline: "Your whole library,\nsafely on your Mac.",
                  message: "Every photo and video, in original quality, saved to a folder you choose. Photos you already have are skipped.",
                  points: ["Original quality", "Folders by date", "Syncs on a schedule"]) {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuthHeading(title: "Sign in to iCloud", message: "Use your Apple ID. Your password goes only to Apple.") {
                Label("Signed in on this Mac only", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentSoft)
            }
            .padding(.bottom, 6)

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
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember in Keychain").foregroundStyle(Color(white: 0.86))
                        Text("So scheduled syncs can sign in for you")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Remember in Keychain", isOn: $model.rememberPassword)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .font(.system(size: 14))
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
            .buttonStyle(HeroButtonStyle(height: 50))
            .keyboardShortcut(.defaultAction)
            .disabled(model.appleID.isEmpty || password.isEmpty || isSigningIn)

            CardDivider().padding(.top, 2)

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

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.accentSoft)
                Text("On your iPhone or iPad, turn on \(Text("Access iCloud Data on the Web").foregroundStyle(Color(white: 0.9))) and turn off \(Text("Advanced Data Protection").foregroundStyle(Color(white: 0.9))).")
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(cornerRadius: 14, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
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
        AuthShell(headline: "One more step,\nthen your photos.",
                  message: "Apple asks for a code when this Mac signs in. Once it's trusted, scheduled syncs can sign in on their own for a while.",
                  formWidth: 380) {
            form
        }
        .overlay(alignment: .topTrailing) { AccountChip(appleID: model.appleID).padding(26) }
        .onAppear { codeFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            AuthHeading(title: "Enter your code",
                        message: model.smsPhone.map { "Apple texted a code to \($0.obfuscatedNumber)." }
                            ?? "Apple sent a six-digit code to your iPhone, iPad or Mac.") {
                AuthIcon(systemName: "checkmark.shield")
            }

            codeBoxes

            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }

            HStack(spacing: 10) {
                Button { model.cancelVerification() } label: {
                    Text("Back").frame(width: 76)
                }
                .buttonStyle(HeroButtonStyle(isPrimary: false, height: 48))
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if model.isVerifying { ProgressView().controlSize(.small) }
                        Text("Verify")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HeroButtonStyle(height: 48))
                .keyboardShortcut(.defaultAction)
                .disabled(code.count != 6 || model.isVerifying)
            }

            if !model.phones.isEmpty {
                VStack(spacing: 14) {
                    CardDivider()
                    HStack {
                        Text("Didn't get a code?").foregroundStyle(Theme.secondary)
                        Spacer(minLength: 8)
                        Menu("Text me instead") {
                            ForEach(model.phones) { phone in
                                Button(phone.obfuscatedNumber) { Task { await model.sendSMS(to: phone) } }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .foregroundStyle(Theme.accentSoft)
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// Six boxes drawn over one real text field, which keeps typing, paste and code autofill working.
    private var codeBoxes: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                if index == 3 {
                    Capsule().fill(Color.white.opacity(0.25)).frame(width: 10, height: 2)
                }
                let isActive = codeFocused && index == code.count
                Text(digit(at: index))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 50, height: 62)
                    .background(Color.white.opacity(isActive ? 0.08 : 0.05), in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent : Theme.fieldStroke))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
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

    private func digit(at index: Int) -> String {
        index < code.count ? String(code[code.index(code.startIndex, offsetBy: index)]) : ""
    }

    private func submit() {
        guard code.count == 6, !model.isVerifying else { return }
        let typed = code
        Task {
            await model.verify(code: typed)
            // A code Apple turned down is no use in the boxes: empty them for the next try.
            if model.errorMessage != nil, model.phase != .signedIn {
                code = ""
                codeFocused = true
            }
        }
    }
}

// MARK: Two-step verification (older Apple IDs)

struct TwoStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.twoStepDevice == nil {
            AuthShell(headline: "One more step,\nthen your photos.",
                      message: "This Apple ID uses two-step verification, so Apple sends a code to one of your devices first.",
                      formWidth: 380) {
                form
            }
            .overlay(alignment: .topTrailing) { AccountChip(appleID: model.appleID).padding(26) }
        } else {
            VerificationView()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            AuthHeading(title: "Two-step verification", message: "Choose where Apple should send your code.") {
                AuthIcon(systemName: "iphone")
            }

            Card {
                ForEach(model.twoStepDevices) { device in
                    Button { Task { await model.sendTwoStepCode(to: device) } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.accentSoft)
                                .frame(width: 38, height: 38)
                                .background(Theme.accent.opacity(0.18), in: .rect(cornerRadius: 11, style: .continuous))
                            Text(device.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 60)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }

            Button { model.cancelVerification() } label: {
                Text("Back").frame(maxWidth: .infinity)
            }
            .buttonStyle(HeroButtonStyle(isPrimary: false, height: 48))
            .keyboardShortcut(.cancelAction)
        }
    }
}
#endif
