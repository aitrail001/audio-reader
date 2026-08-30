#if os(macOS)
import AppKit
import SwiftUI

struct MacAppleBooksView: View {
    @Bindable var library: MacAppleBooksLibrary
    let importingID: String?
    let onImport: (MacAppleBookItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Books")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Downloaded audiobooks and EPUB books stored by Apple Books")
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
                appleBooksSection("Audiobooks", items: library.items.filter { $0.kind == .audiobook })
                appleBooksSection("EPUBs", items: library.items.filter { $0.kind == .ebook })
            }
            .overlay {
                if library.isLoading {
                    ProgressView("Reading Apple Books…")
                } else if library.items.isEmpty {
                    ContentUnavailableView(
                        "No Apple Books titles found",
                        systemImage: "books.vertical",
                        description: Text("Download an audiobook or EPUB in Apple Books, then refresh. Cloud-only and DRM-protected titles cannot be imported.")
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
    }

    @ViewBuilder
    private func appleBooksSection(_ title: String, items: [MacAppleBookItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack(spacing: 14) {
                        cover(item)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if item.isProtected {
                                Label("Protected — unavailable for import", systemImage: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if item.kind == .ebook {
                                Text("EPUB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(formatClock(item.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Open") { library.openInBooks(item) }
                            .buttonStyle(.bordered)
                        if importingID == item.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Import") { onImport(item) }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.terracotta)
                                .disabled(!item.canImport || importingID != nil)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
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
