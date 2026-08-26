import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

enum IsolationRuntimeGuard {
    static func install() {
        setenv("SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE", "nocrash", 1)
        setenv("SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL", "1", 1)
    }
}

struct UncheckedAction: @unchecked Sendable {
    private let work: () -> Void

    init(_ work: @escaping () -> Void = {}) {
        self.work = work
    }

    func callAsFunction() {
        work()
    }
}

struct PlatformTap: View {
    var isEnabled = true
    var accessibilityLabelText: String
    var accessibilityHintText = ""
    var action: () -> Void

    var body: some View {
        PlatformTapRepresentable(isEnabled: isEnabled, action: action)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityHint(accessibilityHintText)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

#if os(macOS)
private struct PlatformTapRepresentable: NSViewRepresentable {
    var isEnabled: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> PlatformClickView {
        let view = PlatformClickView()
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: PlatformClickView, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
    }
}

final class PlatformClickView: NSView {
    nonisolated(unsafe) var isEnabled = true
    nonisolated(unsafe) var action: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    nonisolated override func mouseUp(with event: NSEvent) {
        let enabled = isEnabled
        let work = action
        DispatchQueue.main.async {
            guard enabled else { return }
            work()
        }
    }

    nonisolated override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var isOpaque: Bool { false }
}
#else
private struct PlatformTapRepresentable: UIViewRepresentable {
    var isEnabled: Bool
    var action: () -> Void

    func makeUIView(context: Context) -> PlatformClickView {
        let view = PlatformClickView()
        view.isEnabled = isEnabled
        view.action = action
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ view: PlatformClickView, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
        view.isUserInteractionEnabled = isEnabled
    }
}

final class PlatformClickView: UIView {
    nonisolated(unsafe) var isEnabled = true
    nonisolated(unsafe) var action: () -> Void = {}

    nonisolated override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let enabled = isEnabled
        let work = action
        DispatchQueue.main.async {
            guard enabled else { return }
            work()
        }
    }
}
#endif
