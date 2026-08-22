import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 22, weight: .regular, design: .serif))

            GroupBox("Appearance") {
                Picker("Theme", selection: $state.settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.menuLabel).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.settings.appearance) { _, _ in state.persistSettings() }
                Text("Reader type scales with the text panel width. Drag the divider next to Lookup to resize panels. Use A / A in the player to nudge size.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                HStack {
                    Text("Text size")
                    Slider(value: $state.settings.readerFontScale, in: 0.75...1.6, step: 0.05)
                    Text(String(format: "%.0f%%", state.settings.readerFontScale * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                .onChange(of: state.settings.readerFontScale) { _, _ in state.persistSettings() }
            }

            GroupBox("Apple Dictionary") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lookups query each installed dictionary on this Mac. For English → Chinese, use 牛津英汉汉英词典. 现代汉语规范词典 is Chinese-to-Chinese (it will not define English words).")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                    Picker("Preferred dictionary", selection: $state.settings.preferredDictionary) {
                        ForEach(DictionaryLookup.installedNames(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: state.settings.preferredDictionary) { _, name in
                        state.selectedDictionaryName = name
                        state.persistSettings()
                    }
                    HStack {
                        Button("Open Dictionary.app") { DictionaryLookup.openDictionaryApp() }
                        Button("Choose books folder…") { state.chooseLibrary() }
                    }
                }
                .padding(6)
            }

            GroupBox("Study language") {
                Picker("Translate into", selection: $state.settings.targetLanguage) {
                    ForEach(StudyLanguage.allCases) { lang in
                        Text(lang.menuLabel).tag(lang.rawValue)
                    }
                }
                .onChange(of: state.settings.targetLanguage) { _, _ in state.persistSettings() }
                Toggle("Auto-translate the current sentence with Grok", isOn: $state.settings.autoTranslate)
                    .onChange(of: state.settings.autoTranslate) { _, _ in state.persistSettings() }
                Toggle("Play audio when tapping a sentence or word", isOn: $state.settings.playOnSelect)
                    .onChange(of: state.settings.playOnSelect) { _, _ in state.persistSettings() }
            }

            GroupBox("Grok / Grok Build (xAI)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If you are signed in to Grok Build (`grok login`), AudioReader uses that session and does not need a console API key. grok-4.6 is better for literary Chinese; grok-build-0.1 is the Grok Build coding model.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                    Text(APIKeyStore.sourceLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(APIKeyStore.isConfigured ? Palette.gold : Palette.dim)
                    SecureField("Optional xAI API key (only if not using Grok Build login)", text: $state.apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Picker("Model", selection: $state.settings.grokModel) {
                        ForEach(GrokModel.allCases) { model in
                            Text(model.menuLabel).tag(model.rawValue)
                        }
                    }
                    .onChange(of: state.settings.grokModel) { _, _ in state.persistSettings() }
                    if GrokModel(rawValue: state.settings.grokModel)?.supportsEffort == true {
                        Picker("Effort", selection: $state.settings.grokEffort) {
                            ForEach(GrokEffort.allCases) { effort in
                                Text(effort.menuLabel).tag(effort.rawValue)
                            }
                        }
                        .onChange(of: state.settings.grokEffort) { _, _ in state.persistSettings() }
                    }
                    HStack {
                        Button("Save key") {
                            APIKeyStore.save(state.apiKeyDraft)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.terracotta)
                        if APIKeyStore.isConfigured {
                            Text("Key on file")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.gold)
                        }
                    }
                }
                .padding(6)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done") { state.showSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 580)
        .background(Palette.bg)
    }
}
