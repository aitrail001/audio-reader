#if os(macOS)
import AppKit
import SwiftUI

struct MacAppleBooksView: View {
    @Bindable var library: MacAppleBooksLibrary
    @Binding var pendingDuplicateImport: MacAppleBookItem?
    let importingID: String?
    let companionBookTitle: String?
    let companionRequirement: MacAppleBooksCompanionRequirement?
    let onImport: (MacAppleBookItem) -> Void
    let onConfirmDuplicate: (MacAppleBookItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Books")
                        .font(.system(size: 22, weight: .semibold))
                    Text(companionBookTitle.map {
                        "\(companionRequirement?.prompt ?? "Choose companion media.") Add it to \($0)"
                    } ?? "Accessible downloaded audiobooks and non-DRM EPUB books stored by Apple Books")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Apple Books") { library.openBooks() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            List {
                if let message = library.message {
                    Section {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Downloaded Books") {
                    ForEach(library.items) { item in
                        let isCompatibleCompanion = companionRequirement?.accepts(item.kind) ?? true
                        HStack(spacing: 14) {
                            cover(item)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if item.isProtected {
                                    Label("Protected or unreadable — unavailable to AudioReader", systemImage: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(item.kind == .ebook ? "EPUB book" : formatClock(item.duration))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if companionRequirement != nil, !isCompatibleCompanion {
                                        Text("This book needs a different media type")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button("Open") { library.openInBooks(item) }
                                .buttonStyle(.bordered)
                            if importingID == item.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(companionBookTitle == nil ? "Import" : "Add") { onImport(item) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Palette.terracotta)
                                    .disabled(!item.canImport || !isCompatibleCompanion || importingID != nil)
                                    .accessibilityLabel(companionBookTitle == nil
                                        ? "Import \(item.title)"
                                        : "Add \(item.title) to \(companionBookTitle ?? "selected book")")
                                    .accessibilityIdentifier(companionBookTitle == nil
                                        ? "library.importAppleBooks.\(item.id)"
                                        : "library.addAppleBooksCompanion.\(item.id)")
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .overlay {
                if library.isLoading {
                    ProgressView("Reading Apple Books…")
                } else if library.items.isEmpty {
                    ContentUnavailableView(
                        "No accessible books found",
                        systemImage: "books.vertical",
                        description: Text("Download an audiobook or DRM-free EPUB in Apple Books, then refresh. Cloud-only, protected, and files macOS does not grant access to cannot be imported.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await library.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isLoading)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            if library.items.isEmpty { await library.reload() }
        }
        .alert("Import another copy?", isPresented: Binding(
            get: { pendingDuplicateImport != nil },
            set: { if !$0 { pendingDuplicateImport = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDuplicateImport = nil }
            Button("Import Another Copy") {
                guard let item = pendingDuplicateImport else { return }
                onConfirmDuplicate(item)
            }
        } message: {
            Text("“\(pendingDuplicateImport?.title ?? "This book")” is already in your AudioReader library. Import another copy anyway?")
        }
    }

    @ViewBuilder
    private func cover(_ item: MacAppleBookItem) -> some View {
        if let data = item.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Palette.panel2)
                .frame(width: 48, height: 70)
                .overlay(Image(systemName: "book.closed").foregroundStyle(Palette.gold))
        }
    }
}
#endif
