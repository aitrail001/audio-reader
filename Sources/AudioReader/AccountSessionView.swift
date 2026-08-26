import SwiftUI
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif

struct AccountSessionView: View {
    @Bindable var session: AccountSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var stackSpacing: CGFloat = 12
    @State private var email = ""
    @State private var code = ""
    @State private var confirmSignOut = false
    @State private var devicePendingRevoke: AccountDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: stackSpacing) {
            Text(modeCaption)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(modeCaption)

            if let recovery = session.recoveryMessage {
                Label(recovery, systemImage: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Account session recovery")
                    .accessibilityValue(recovery)
            }

            if let error = session.errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.mode.isSignedIn {
                signedInContent
            } else {
                signedOutContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .dynamicTypeSize(.xSmall ... .accessibility5)
        .disabled(session.isBusy)
        .task(id: session.mode) {
            if session.mode.isSignedIn {
                await session.refreshDevices()
            }
        }
        .alert("Sign out of AudioReader?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await session.signOut() }
            }
        } message: {
            Text("Books on this device stay here. Vocabulary, transcripts, and local files are not deleted.")
        }
        .alert("Revoke this device?", isPresented: Binding(
            get: { devicePendingRevoke != nil },
            set: { if !$0 { devicePendingRevoke = nil } }
        )) {
            Button("Cancel", role: .cancel) { devicePendingRevoke = nil }
            Button("Revoke", role: .destructive) {
                if let device = devicePendingRevoke {
                    Task { await session.revokeDevice(device) }
                }
                devicePendingRevoke = nil
            }
        } message: {
            Text("That device returns to local mode. Books already on that device are not deleted by this action.")
        }
    }

    private var modeCaption: String {
        switch session.mode {
        case .local:
            "Local mode — reading stays on this device. Signing in is optional and does not remove local books."
        case .signedInSyncOff:
            "Signed in — sync off. Learning data stays on this device."
        case .signedInSyncOn:
            "Signed in — sync on. Learning data can copy to your other devices. This version does not upload books."
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: stackSpacing) {
            Button {
                Task { await session.signInWithOAuth(.google) }
            } label: {
                Label("Sign in with Google", systemImage: "globe")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Sign in with Google")

            Button {
                Task { await session.signInWithOAuth(.microsoft) }
            } label: {
                Label("Sign in with Microsoft", systemImage: "globe")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Sign in with Microsoft")

            Text("Or request a one-time email code. The same confirmation is shown whether or not the address already has an account.")
                .font(.body)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Email", text: $email)
                .font(.body)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .accessibilityLabel("Email address for sign-in code")
#if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif

            Button {
                Task { await session.requestEmailCode(email) }
            } label: {
                Text("Send email sign-in code")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.terracotta)
            .accessibilityLabel("Send email sign-in code")
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if session.pendingEmail != nil {
                Text("Enter the six-digit code from your email.")
                    .font(.body)
                    .foregroundStyle(Palette.dim)

                TextField("123456", text: $code)
                    .font(.body)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Six-digit email sign-in code")
#if os(iOS)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
#endif

                Button {
                    Task { await session.verifyEmailCode(code) }
                } label: {
                    Text("Verify email sign-in code")
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Verify email sign-in code")
                .disabled(code.filter(\.isNumber).count != 6)
            }
        }
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: stackSpacing) {
            if let profile = session.profile {
                Text(profileTitle(profile))
                    .font(.body.weight(.semibold))
                Text(profile.email)
                    .font(.body)
                    .foregroundStyle(Palette.dim)
                    .accessibilityLabel("Signed-in email \(profile.email)")
            }

            Toggle(isOn: Binding(
                get: { session.mode.isSyncEnabled },
                set: { session.setSyncEnabled($0) }
            )) {
                Text("Sync learning data across devices")
                    .font(.body)
            }
            .accessibilityLabel("Sync learning data across devices")

            Text("Sync is optional. Turning it off keeps books and learning data on this device. This version does not push or pull a remote library.")
                .font(.body)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if !session.devices.isEmpty {
                Text("Devices")
                    .font(.body.weight(.semibold))
                ForEach(session.devices) { device in
                    deviceRow(device)
                }
            }

            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Text("Sign out")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Sign out of AudioReader account")
        }
    }

    private func profileTitle(_ profile: AccountProfile) -> String {
        let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? profile.email : name
    }

    private func deviceRow(_ device: AccountDevice) -> some View {
        let isCurrent = device.id == session.currentDeviceID
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.body)
                Text(device.platform.uppercased() + (isCurrent ? " · this device" : ""))
                    .font(.body)
                    .foregroundStyle(Palette.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Revoke") {
                devicePendingRevoke = device
            }
            .font(.body)
            .frame(minHeight: 44)
            .accessibilityLabel("Revoke \(device.displayName)")
        }
        .accessibilityElement(children: .contain)
    }
}
