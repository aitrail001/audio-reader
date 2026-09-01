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
    static let bg = Color(light: (0.965, 0.953, 0.932), dark: (0.072, 0.064, 0.057))
    static let panel = Color(light: (0.995, 0.988, 0.975), dark: (0.112, 0.100, 0.090))
    static let panel2 = Color(light: (0.918, 0.899, 0.872), dark: (0.168, 0.149, 0.132))
    static let ink = Color(light: (0.16, 0.12, 0.09), dark: (0.957, 0.929, 0.890))
    // Secondary copy remains AA-readable on both tonal surfaces; `mute` is for non-text ornament only.
    static let dim = Color(light: (0.34, 0.29, 0.25), dark: (0.76, 0.72, 0.68))
    static let mute = Color(light: (0.40, 0.35, 0.30), dark: (0.68, 0.63, 0.58))
    static let gold = Color(light: (0.55, 0.35, 0.09), dark: (0.925, 0.735, 0.430))
    static let goldSoft = Color(light: (0.91, 0.72, 0.43, 0.22), dark: (0.910, 0.722, 0.427, 0.18))
    static let terracotta = Color(light: (0.64, 0.25, 0.08), dark: (0.90, 0.45, 0.20))
    static let line = Color(light: (0.16, 0.12, 0.09, 0.14), dark: (0.957, 0.929, 0.890, 0.14))
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

enum ReaderFontChoice: String, CaseIterable, Identifiable, Codable {
    case newYork = "New York"
    case georgia = "Georgia"
    case palatino = "Palatino"
    case sanFrancisco = "San Francisco"

    var id: String { rawValue }

    func font(size: CGFloat, bold: Bool) -> Font {
        let weight: Font.Weight = bold ? .bold : .regular
        switch self {
        case .newYork:
            return .system(size: size, weight: weight, design: .serif)
        case .georgia, .palatino:
            return .custom(rawValue, size: size).weight(weight)
        case .sanFrancisco:
            return .system(size: size, weight: weight, design: .default)
        }
    }
}

struct ReaderType {
    var body: CGFloat
    var dual: CGFloat
    var gloss: CGFloat
    var line: CGFloat
    var paragraph: CGFloat
    var word: CGFloat
    var font: ReaderFontChoice
    var bold: Bool

    static func metrics(
        columnWidth: CGFloat,
        scale: Double,
        lineSpacing: Double = 1,
        wordSpacing: Double = 2,
        font: String = ReaderFontChoice.newYork.rawValue,
        bold: Bool = false
    ) -> ReaderType {
        let w = max(columnWidth, 280)
        let base = min(34, max(16, 16 + (w - 320) / 38))
        let body = max(AssistantTypography.minimumBodySize, (base * scale).rounded())
        return ReaderType(
            body: body,
            dual: min(body, max(AssistantTypography.minimumBodySize, (body * 0.62).rounded())),
            gloss: AssistantTypography.bodySize(forBookTextSize: body),
            line: max(2, (body * 0.28 * lineSpacing).rounded()),
            paragraph: max(4, (body * 0.75 * lineSpacing).rounded()),
            word: max(0, wordSpacing),
            font: ReaderFontChoice(rawValue: font) ?? .newYork,
            bold: bold
        )
    }
}

enum AssistantTypography {
    static let minimumBodySize: CGFloat = 11
    static let maximumBodySize: CGFloat = 15
    static let defaultBodySize: CGFloat = 13

    static func bodySize(forBookTextSize bookTextSize: CGFloat) -> CGFloat {
        min(maximumBodySize, max(minimumBodySize, (bookTextSize * 0.8).rounded()))
    }

    static func bodySize(forReaderScale readerScale: Double) -> CGFloat {
        let minimumColumnBookSize = max(
            minimumBodySize,
            (16 * readerScale).rounded()
        )
        return bodySize(forBookTextSize: minimumColumnBookSize)
    }

    static func clampedBodySize(_ proposedSize: CGFloat) -> CGFloat {
        min(maximumBodySize, max(minimumBodySize, proposedSize))
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

extension View {
    /// Keeps inspector and Chapter AI actions on one line when the side panel is narrow.
    func inspectorActionLabel() -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.78)
            .truncationMode(.tail)
    }
}
