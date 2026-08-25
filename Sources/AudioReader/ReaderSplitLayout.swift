import CoreGraphics

enum ReaderSplitLayout {
    static let macSplitterWidth: CGFloat = 8
    static let iPadSplitterWidth: CGFloat = 44
    static let minimumLookupWidth: CGFloat = 220
    static let preferredMinimumTextWidth: CGFloat = 320
    static let absoluteMinimumTextWidth: CGFloat = 200
    static let preferredLookupFraction: CGFloat = 0.38

    static var splitterVisualWidth: CGFloat {
#if os(iOS)
        iPadSplitterWidth
#else
        macSplitterWidth
#endif
    }

    static func reservedTextWidth(
        in containerWidth: CGFloat,
        splitterWidth: CGFloat = splitterVisualWidth
    ) -> CGFloat {
        let width = max(containerWidth, 0)
        let available = max(width - splitterWidth, 0)
        let absoluteText = min(absoluteMinimumTextWidth, available)
        return min(
            preferredMinimumTextWidth,
            max(absoluteText, (width * (1 - preferredLookupFraction)).rounded())
        )
    }

    static func clampedLookupWidth(
        proposed: CGFloat,
        containerWidth: CGFloat,
        splitterWidth: CGFloat = splitterVisualWidth
    ) -> CGFloat {
        let width = max(containerWidth, 0)
        let reservedText = reservedTextWidth(in: width, splitterWidth: splitterWidth)
        let maxLookup = max(0, width - reservedText - splitterWidth)
        guard maxLookup > 0 else { return 0 }
        let minLookup = min(minimumLookupWidth, maxLookup)
        return min(max(proposed, minLookup), maxLookup)
    }

    static func initialLookupWidth(
        stored: CGFloat,
        containerWidth: CGFloat,
        splitterWidth: CGFloat = splitterVisualWidth
    ) -> CGFloat {
        let suggested = min(stored, (containerWidth * preferredLookupFraction).rounded())
        return clampedLookupWidth(
            proposed: suggested,
            containerWidth: containerWidth,
            splitterWidth: splitterWidth
        )
    }

    static func textWidth(
        containerWidth: CGFloat,
        lookupWidth: CGFloat,
        isLookupOpen: Bool,
        splitterWidth: CGFloat = splitterVisualWidth
    ) -> CGFloat {
        guard isLookupOpen else { return max(containerWidth, 0) }
        return max(0, containerWidth - lookupWidth - splitterWidth)
    }
}

struct ReaderSplitGeometry: Equatable {
    var containerWidth: CGFloat
    var proposedLookupWidth: CGFloat
    var isLookupOpen: Bool
    var splitterWidth: CGFloat = ReaderSplitLayout.splitterVisualWidth

    var lookupWidth: CGFloat {
        guard isLookupOpen else { return 0 }
        return ReaderSplitLayout.clampedLookupWidth(
            proposed: proposedLookupWidth,
            containerWidth: containerWidth,
            splitterWidth: splitterWidth
        )
    }

    var textWidth: CGFloat {
        ReaderSplitLayout.textWidth(
            containerWidth: containerWidth,
            lookupWidth: lookupWidth,
            isLookupOpen: isLookupOpen,
            splitterWidth: splitterWidth
        )
    }
}
