import SwiftUI

struct AudiobookLanguagePicker: View {
    @Bindable var state: AppState
    let book: Book
    var title = "Audiobook language"

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(TranscriptionLanguage.allCases) { language in
                Text(language.menuLabel).tag(language)
            }
        }
        .pickerStyle(.menu)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHint("Sets the transcription language for this book")
    }

    private var selection: Binding<TranscriptionLanguage> {
        Binding(
            get: { state.audiobookLanguage(for: book) },
            set: { state.setAudiobookLanguage($0, for: book) }
        )
    }
}
