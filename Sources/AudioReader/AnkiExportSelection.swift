import Foundation

/// Keeps export intent ephemeral so selecting cards cannot become learning or My List state.
struct AnkiExportSelectionState: Equatable, Sendable {
    private(set) var isActive = false
    private(set) var selectedIDs: Set<String> = []

    var selectedCount: Int { selectedIDs.count }

    mutating func begin() {
        selectedIDs.removeAll()
        isActive = true
    }

    mutating func toggle(_ entryID: String) {
        guard isActive else { return }
        if selectedIDs.contains(entryID) {
            selectedIDs.remove(entryID)
        } else {
            selectedIDs.insert(entryID)
        }
    }

    func isSelected(_ entryID: String) -> Bool {
        isActive && selectedIDs.contains(entryID)
    }

    func entriesForExport(from entries: [VocabEntry]) -> [VocabEntry] {
        guard isActive else { return [] }
        return entries.filter { selectedIDs.contains($0.id) }
    }

    mutating func cancel() {
        clear()
    }

    mutating func leaveVocabulary() {
        clear()
    }

    mutating func completeExport() {
        clear()
    }

    private mutating func clear() {
        selectedIDs.removeAll()
        isActive = false
    }
}
