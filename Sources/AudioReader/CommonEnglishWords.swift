import Foundation
import SwiftUI

enum CommonEnglishWordTier: Int, CaseIterable, Identifiable, Sendable {
    case first500 = 500
    case first1000 = 1_000
    case first1500 = 1_500
    case first2000 = 2_000
    case first2500 = 2_500
    case first3000 = 3_000
    case first3500 = 3_500
    case first4000 = 4_000
    case first4500 = 4_500
    case first5000 = 5_000

    var id: Int { rawValue }
    var title: String { "First \(rawValue.formatted())" }
}

struct CommonEnglishWordCatalog: Sendable {
    static let shared: CommonEnglishWordCatalog = {
        do { return try load() }
        catch { preconditionFailure("Common English word families are missing or invalid: \(error.localizedDescription)") }
    }()

    private let rankedHeadwords: [String]
    private let headwordByForm: [String: String]
    private let rankByHeadword: [String: Int]

    func headwords(first count: Int) -> [String] {
        Array(rankedHeadwords.prefix(max(0, count)))
    }

    func headword(for form: String) -> String? {
        headwordByForm[Self.normalized(form)]
    }

    func rank(for form: String) -> Int? {
        guard let headword = headword(for: form) else { return nil }
        return rankByHeadword[headword]
    }

    /// Attribution stays in the resource header so redistributed rankings retain their license context.
    private static func load() throws -> CommonEnglishWordCatalog {
        let fileName = "CommonEnglishWordFamilies.txt"
        let candidates = [
            Bundle.main.url(forResource: "CommonEnglishWordFamilies", withExtension: "txt"),
            Bundle.main.resourceURL?.appendingPathComponent("AudioReader_AudioReader.bundle/\(fileName)"),
            Bundle.main.bundleURL.appendingPathComponent("AudioReader_AudioReader.bundle/\(fileName)"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(fileName)")
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var headwords: [String] = []
        var byForm: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t").map(String.init)
            guard let headword = fields.first, !headword.isEmpty else { continue }
            headwords.append(headword)
            for form in fields where byForm[form] == nil {
                byForm[form] = headword
            }
        }
        guard headwords.count == 5_000, Set(headwords).count == 5_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ranks = Dictionary(uniqueKeysWithValues: headwords.enumerated().map { ($0.element, $0.offset + 1) })
        return CommonEnglishWordCatalog(
            rankedHeadwords: headwords,
            headwordByForm: byForm,
            rankByHeadword: ranks
        )
    }

    private static func normalized(_ form: String) -> String {
        form.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
    }
}

private struct CommonEnglishWordsAction: Identifiable {
    let tier: CommonEnglishWordTier
    let known: Bool

    var id: String { "\(known ? "add" : "remove")-\(tier.rawValue)" }
    var title: String { known ? "Add common English words?" : "Remove common English words?" }
    var buttonTitle: String { known ? "Add to Known Words" : "Remove from Known Words" }
    var message: String {
        if known {
            return "This marks the \(tier.title.lowercased()) English word families, including forms such as do, did, and done, as known. Existing vocabulary cards are not deleted."
        }
        return "This removes the \(tier.title.lowercased()) English word families from Known Words. Words outside this preset and vocabulary cards remain unchanged."
    }
}

private struct CommonEnglishWordsNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct CommonEnglishWordsMenu: View {
    @Bindable var state: AppState
    @State private var pendingAction: CommonEnglishWordsAction?
    @State private var isApplying = false
    @State private var notice: CommonEnglishWordsNotice?

    var body: some View {
        Menu {
            Section("Add to Known Words") {
                ForEach(CommonEnglishWordTier.allCases) { tier in
                    Button(tier.title) { pendingAction = CommonEnglishWordsAction(tier: tier, known: true) }
                }
            }
            Section("Remove from Known Words") {
                ForEach(CommonEnglishWordTier.allCases) { tier in
                    Button(tier.title, role: .destructive) {
                        pendingAction = CommonEnglishWordsAction(tier: tier, known: false)
                    }
                }
            }
        } label: {
            Label(isApplying ? "Updating common words…" : "Common words", systemImage: "text.badge.checkmark")
        }
        .disabled(isApplying)
        .accessibilityIdentifier("words.commonWords")
        .accessibilityHint("Bulk add or remove ranked English word families from Known Words.")
        .confirmationDialog(
            pendingAction?.title ?? "Update common English words?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.buttonTitle, role: action.known ? nil : .destructive) {
                    apply(action)
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.message ?? "")
        }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private func apply(_ action: CommonEnglishWordsAction) {
        pendingAction = nil
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                let changed = try await state.setCommonEnglishWordsKnown(
                    first: action.tier.rawValue,
                    known: action.known
                )
                let verb = action.known ? "Added" : "Removed"
                notice = CommonEnglishWordsNotice(
                    title: "Known Words updated",
                    message: changed == 0
                        ? "No changes were needed."
                        : "\(verb) \(changed.formatted()) English word families."
                )
            } catch {
                notice = CommonEnglishWordsNotice(
                    title: "Couldn’t update Known Words",
                    message: error.localizedDescription
                )
            }
        }
    }
}
