import SwiftUI

struct DictionarySummaryView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Palette.gold)
                        .frame(width: 16, alignment: .trailing)
                    Text(line)
                        .font(.system(size: AssistantTypography.defaultBodySize, design: .serif))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
