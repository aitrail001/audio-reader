import SwiftUI

struct MainActorAction: Sendable {
    private let work: @MainActor @Sendable () -> Void

    init(_ work: @escaping @MainActor @Sendable () -> Void = {}) {
        self.work = work
    }

    nonisolated func callAsFunction() {
        Task { @MainActor in work() }
    }
}

struct PlatformTap: View {
    var isEnabled = true
    var accessibilityLabelText: String
    var accessibilityHintText = ""
    var action: MainActorAction

    init(
        isEnabled: Bool = true,
        accessibilityLabelText: String,
        accessibilityHintText: String = "",
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.isEnabled = isEnabled
        self.accessibilityLabelText = accessibilityLabelText
        self.accessibilityHintText = accessibilityHintText
        self.action = MainActorAction(action)
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(isEnabled)
            .onTapGesture { action() }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityHint(accessibilityHintText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
