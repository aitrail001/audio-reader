import Foundation

enum Cli {
    static func scan() {
        let path = UserDefaults.standard.string(forKey: "library")
            ?? Persistence.loadSettings().libraryPath
        let books = LibraryScanner.scan(root: URL(fileURLWithPath: path))
        print("Library: \(path)")
        print("Books: \(books.count)")
        for book in books {
            print("— \(book.title)")
            print("  author: \(book.author ?? "—")")
            print("  chapters: \(book.chapters.count)")
            print("  ebook: \(book.ebookPath ?? "none")")
            print("  cover: \(book.coverPath ?? "none")")
            if let first = book.chapters.first {
                print("  first: \(first.title)  \(first.audioPath)")
            }
        }
    }

    static func transcribe(audioPath: String, ebookPath: String?) {
        let chapter = Chapter(
            id: "cli-test",
            index: 0,
            title: "CLI",
            audioPath: audioPath,
            duration: nil
        )
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await Transcriber().transcribe(
                    chapter: chapter,
                    ebookPath: ebookPath,
                    expectedMetadata: .init(
                        title: URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent,
                        author: nil
                    ),
                    language: TranscriptionLanguage(
                        rawValue: Persistence.loadSettings().transcriptionLanguage
                    ) ?? .englishUS,
                    progress: { p in
                        FileHandle.standardError.write(
                            Data("[\(Int(p.fraction * 100))%] \(p.message)\n".utf8)
                        )
                    },
                    checkpoint: { _, _ in }
                )
                print("segments: \(result.segments.count)")
                print("ebookAligned: \(result.ebookAligned)")
                for (i, seg) in result.segments.prefix(12).enumerated() {
                    let score = seg.alignmentScore.map { String(format: "%.2f", $0) } ?? "-"
                    print("\(i+1). \(String(format: "%.2f", seg.start))s  score=\(score)")
                    print("   STT: \(seg.spokenText)")
                    if let e = seg.ebookText { print("   EBK: \(e)") }
                }
            } catch {
                fputs("transcribe failed: \(error)\n", stderr)
            }
            sem.signal()
        }
        sem.wait()
    }
}
