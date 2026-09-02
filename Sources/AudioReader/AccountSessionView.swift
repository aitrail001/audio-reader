import SwiftUI
import UniformTypeIdentifiers
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
    @State private var confirmDelete = false
    @State private var deletionReason = ""
    @State private var devicePendingRevoke: AccountDevice?
    @State private var showingExportSaver = false

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
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.body)
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.goldSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Account connection issue")
                    .accessibilityValue(error)
            }

            if session.flagEnabled("maintenance_mode", default: false) {
                Label("The hosted service is in maintenance mode. Reading on this device still works.", systemImage: "wrench.and.screwdriver")
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Hosted service is in maintenance mode")
            }

            if (session.isBusy || session.activityMessage != nil), !session.syncStatus.isActive {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(session.activityMessage ?? "Working with your account…")
                        .font(.body)
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Account activity")
                .accessibilityValue(session.activityMessage ?? "Working with your account…")
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
        .onChange(of: session.pendingExport?.id) { _, newID in
            showingExportSaver = newID != nil
        }
        .fileExporter(
            isPresented: $showingExportSaver,
            document: AccountExportDocument(data: session.pendingExport?.data ?? Data()),
            contentType: .json,
            defaultFilename: session.pendingExport?.fileName ?? "audioreader-account.json"
        ) { result in
            switch result {
            case .success:
                session.markExportSaved()
            case .failure:
                session.markExportSaveCancelled()
            }
        }
        .task(id: session.mode) {
            if session.mode.isSignedIn {
                // Do not POST /token/refresh here. Sign-in just issued tokens;
                // a second refresh with a hosted GoTrue token was rejected as
                // "refreshToken must be at least 16 characters." Launch restore
                // still refreshes. This only reloads the device list.
                await session.refreshDevices()
                await session.refreshAnalyticsPreference()
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
        .alert("Delete this AudioReader account?", isPresented: $confirmDelete) {
            TextField("Reason", text: $deletionReason)
            Button("Cancel", role: .cancel) { deletionReason = "" }
            Button("Delete Account", role: .destructive) {
                Task { await session.deleteAccount(reason: deletionReason) }
            }
        } message: {
            Text("This queues deletion on the server. Books already on this device stay until you remove them.")
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
            .disabled(session.isBusy)

            Button {
                Task { await session.signInWithOAuth(.microsoft) }
            } label: {
                Label("Sign in with Microsoft", systemImage: "globe")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Sign in with Microsoft")
            .disabled(session.isBusy)

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
            .disabled(session.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if session.pendingEmail != nil {
                Text("Enter the sign-in code from your email.")
                    .font(.body)
                    .foregroundStyle(Palette.dim)

                TextField("123456", text: $code)
                    .font(.body)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Email sign-in code")
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
                .disabled(session.isBusy || !(6...12).contains(code.filter(\.isNumber).count))
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
                set: { enabled in
                    session.setSyncEnabled(enabled)
                    if enabled {
                        Task { await session.synchronize() }
                    }
                }
            )) {
                Text("Sync learning data across devices")
                    .font(.body)
            }
            .accessibilityLabel("Sync learning data across devices")
            .disabled(session.isBusy || (!session.mode.isSyncEnabled && !session.accountSyncReadiness.effective))

            Text("Sync is optional. Turning it on pushes pending learning-data changes and pulls updates from your other devices. Books and media stay on this device unless you enable cloud media later.")
                .font(.body)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if let readinessMessage = session.syncReadinessMessage {
                Text(readinessMessage)
                    .font(.body)
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Account sync readiness")
            }

            if session.syncAvailabilityManagedByOperator {
                Button("Refresh sync availability") {
                    Task { await session.refreshSession() }
                }
                .disabled(session.isBusy)
                .accessibilityHint("Checks whether the service operator has enabled cross-device sync")
            }

            AccountSyncStatusView(session: session)

            Toggle(isOn: Binding(
                get: { session.operatorLearningAnalyticsEnabled ?? false },
                set: { enabled in
                    Task { await session.setOperatorLearningAnalyticsEnabled(enabled) }
                }
            )) {
                Text("Share aggregate learning progress with Operator support")
                    .font(.body)
            }
            .accessibilityLabel("Share aggregate learning progress with Operator support")
            .disabled(session.isBusy)

            Text("Optional. This shares counts and timestamps for sync, reading, review, vocabulary, and AI-feature use so support can diagnose trends. Reading text, transcripts, saved words, translations, notes, and prompts are never shared.")
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

            if !session.quotas.isEmpty {
                Text("Account allowances")
                    .font(.body.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(session.quotas, id: \.key) { quota in
                    Text(quotaCaption(quota))
                        .font(.body)
                        .foregroundStyle(Palette.dim)
                        .accessibilityLabel(quotaCaption(quota))
                }
            }

            if let exportStatus = session.lastExportStatus {
                Text(exportStatus)
                    .font(.body)
                    .foregroundStyle(Palette.dim)
            }

            Button {
                if session.pendingExport != nil {
                    showingExportSaver = true
                } else {
                    Task { await session.exportAccount() }
                }
            } label: {
                Text(session.pendingExport == nil ? "Export account data" : "Save export")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(session.pendingExport == nil ? "Export account data" : "Save export")
            .disabled(session.isBusy && session.pendingExport == nil)

            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Text("Sign out")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red)
            .accessibilityLabel("Sign out of AudioReader account")
            .disabled(session.isBusy)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Text("Delete account")
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red)
            .accessibilityLabel("Delete AudioReader account")
            .disabled(session.isBusy)
        }
    }

    private func quotaCaption(_ quota: Quota) -> String {
        let used = quota.key == "cloud_media_bytes" ? byteCaption(quota.used) : "\(Int(quota.used))"
        let limit = quota.key == "cloud_media_bytes" ? byteCaption(quota.limit) : "\(Int(quota.limit))"
        return "\(quota.key.replacingOccurrences(of: "_", with: " ")): \(used) of \(limit)"
    }

    private func byteCaption(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
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
            .disabled(session.isBusy)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Shared across Settings and both platform sidebars so sync progress and VoiceOver semantics cannot drift.
struct AccountSyncStatusView: View {
    let session: AccountSession
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(session.syncStatus.requiresAttention ? Palette.terracotta : Palette.dim)
                if session.syncStatus.isActive {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(session.syncStatus.resolutionHelp, id: \.self) { help in
                Text(help)
                    .font(.caption)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !compact, !session.syncStatus.entityProgress.isEmpty {
                ForEach(session.syncStatus.entityProgress) { item in
                    HStack(spacing: 8) {
                        Text(item.title)
                        Spacer(minLength: 8)
                        Text("\(item.completedCount) / \(item.totalCount)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync status")
        .accessibilityValue(session.syncStatusAccessibilityDescription)
        .accessibilityIdentifier("sync.status")
    }

    private var title: String {
        if session.syncStatus.phase != .idle {
            return session.syncStatus.title
        }
        switch session.mode {
        case .local: return "Local only"
        case .signedInSyncOff: return "Sync off"
        case .signedInSyncOn: return "Up to date"
        }
    }

    private var detail: String {
        session.syncStatus.phase == .idle ? "" : session.syncStatus.detail
    }

    private var symbol: String {
        if session.syncStatus.requiresAttention { return "exclamationmark.icloud" }
        if session.syncStatus.isActive { return "arrow.triangle.2.circlepath" }
        return session.mode.isSyncEnabled ? "checkmark.icloud" : "icloud.slash"
    }
}

private struct AccountExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
