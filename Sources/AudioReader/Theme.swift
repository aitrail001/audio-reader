import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
#if os(macOS)
        self.init(nsImage: platformImage)
#else
        self.init(uiImage: platformImage)
#endif
    }
}

final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for path: String) -> PlatformImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = PlatformImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func preload(paths: [String]) {
        for path in paths {
            _ = image(for: path)
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Palette {
    static let bg = Color(light: (0.97, 0.95, 0.91), dark: (0.078, 0.067, 0.055))
    static let panel = Color(light: (0.995, 0.98, 0.955), dark: (0.118, 0.102, 0.086))
    static let panel2 = Color(light: (0.93, 0.90, 0.85), dark: (0.157, 0.133, 0.110))
    static let ink = Color(light: (0.16, 0.12, 0.09), dark: (0.957, 0.929, 0.890))
    static let dim = Color(light: (0.42, 0.37, 0.32), dark: (0.545, 0.494, 0.447))
    static let mute = Color(light: (0.55, 0.50, 0.44), dark: (0.365, 0.325, 0.286))
    static let gold = Color(light: (0.72, 0.50, 0.18), dark: (0.910, 0.722, 0.427))
    static let goldSoft = Color(light: (0.91, 0.72, 0.43, 0.22), dark: (0.910, 0.722, 0.427, 0.18))
    static let terracotta = Color(light: (0.72, 0.32, 0.12), dark: (0.769, 0.361, 0.149))
    static let line = Color(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.06))
    static let inkOnGold = Color(light: (0.14, 0.10, 0.06), dark: (0.078, 0.067, 0.055))
}

private extension Color {
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        self.init(light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }

    init(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) {
#if os(macOS)
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = useDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        }))
#else
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
#endif
    }
}

struct ReaderType {
    var body: CGFloat
    var dual: CGFloat
    var gloss: CGFloat
    var line: CGFloat

    static func metrics(columnWidth: CGFloat, scale: Double) -> ReaderType {
        let w = max(columnWidth, 280)
        let base = min(34, max(16, 16 + (w - 320) / 38))
        let body = (base * scale).rounded()
        return ReaderType(
            body: body,
            dual: max(12, (body * 0.62).rounded()),
            gloss: max(13, (body * 0.78).rounded()),
            line: max(4, (body * 0.28).rounded())
        )
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            width = max(width, x - spacing)
        }
        let height = y + rowHeight
        return (CGSize(width: width, height: height), origins, sizes)
    }
}
