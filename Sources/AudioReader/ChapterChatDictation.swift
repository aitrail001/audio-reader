@preconcurrency import AVFoundation
import Foundation
import Speech

struct ChapterChatDictationDraft: Sendable {
    let prefix: String

    func text(for transcription: String) -> String {
        Self.join(prefix, transcription)
    }

    static func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        if first.last?.isWhitespace == true || second.first?.isWhitespace == true {
            return first + second
        }
        return first + " " + second
    }
}

struct ChapterChatDictationTranscript: Sendable {
    let prefix: String
    private var finalized = ""
    private var volatile = ""

    init(prefix: String) {
        self.prefix = prefix
    }

    mutating func receive(_ text: String, isFinal: Bool) -> String {
        if isFinal {
            finalized = ChapterChatDictationDraft.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        return ChapterChatDictationDraft.join(
            prefix,
            ChapterChatDictationDraft.join(finalized, volatile)
        )
    }
}

enum ChapterChatVoiceLevel {
    private static let silenceFloorDecibels = -50.0

    static func normalized(amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let decibels = 20 * log10(amplitude)
        return min(max((decibels - silenceFloorDecibels) / -silenceFloorDecibels, 0), 1)
    }

    static func normalized(_ buffer: AVAudioPCMBuffer) -> Double {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0, let channels = buffer.floatChannelData else {
            return 0
        }

        var sumOfSquares = 0.0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = Double(channels[channel][frame])
                sumOfSquares += sample * sample
            }
        }
        let amplitude = sqrt(sumOfSquares / Double(frameCount * channelCount))
        return normalized(amplitude: amplitude)
    }
}

struct ChapterChatVoiceLevelHistory: Sendable {
    private(set) var samples: [Double]

    init(sampleCount: Int = 24) {
        samples = Array(repeating: 0, count: max(sampleCount, 1))
    }

    mutating func append(_ level: Double) {
        samples.removeFirst()
        samples.append(min(max(level, 0), 1))
    }
}

private enum ChapterChatLiveTranscriber: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var modules: [any SpeechModule] {
        switch self {
        case .speech(let transcriber): [transcriber]
        case .dictation(let transcriber): [transcriber]
        }
    }
}

private final class ChapterChatAudioConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ChapterChatDictationError.audioFormat
            }
            self.converter = converter
        }
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return input }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, 1)
        ) else { return nil }

        let provider = ChapterChatConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outputStatus in
            provider.next(outputStatus)
        }
        return status == .error ? nil : output
    }
}

private final class ChapterChatConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

private enum ChapterChatAudioTap {
    static func install(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        converter: ChapterChatAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        levelContinuation: AsyncStream<Double>.Continuation
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            levelContinuation.yield(ChapterChatVoiceLevel.normalized(buffer))
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }
}

private enum ChapterChatDictationError: LocalizedError {
    case unsupportedLocale(String)
    case audioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let language):
            "Apple on-device speech recognition is not available for \(language) on this device."
        case .audioFormat:
            "The microphone audio format is not supported."
        }
    }
}

@MainActor
@Observable
final class ChapterChatDictation {
    private(set) var isListening = false
    private(set) var isRequestingPermission = false
    private(set) var isFinalizing = false
    private(set) var preparationMessage: String?
    private(set) var unavailableMessage: String?
    private(set) var audioLevels = ChapterChatVoiceLevelHistory().samples

    var canStart: Bool {
        !isListening && !isRequestingPermission && !isFinalizing
    }

    private let requestedLocale: Locale
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var levelContinuation: AsyncStream<Double>.Continuation?
    private var levelTask: Task<Void, Never>?
    private var inputTapInstalled = false
    private var levelHistory = ChapterChatVoiceLevelHistory()
    private var transcript = ChapterChatDictationTranscript(prefix: "")
    private var onTextUpdate: (@MainActor (String) -> Void)?
    private var onWillRecord: (@MainActor () -> Void)?

    init(locale: Locale = .autoupdatingCurrent) {
        requestedLocale = locale
    }

    func start(
        existingText: String,
        onWillRecord: @escaping @MainActor () -> Void,
        onTextUpdate: @escaping @MainActor (String) -> Void
    ) {
        guard canStart else { return }
        unavailableMessage = nil
        preparationMessage = "Preparing Apple on-device speech…"
        resetAudioLevels()
        transcript = ChapterChatDictationTranscript(prefix: existingText)
        self.onWillRecord = onWillRecord
        self.onTextUpdate = onTextUpdate
        isRequestingPermission = true
        permissionTask = Task { [weak self] in
            await self?.prepareAndStart()
        }
    }

    func stop() {
        guard isListening else { return }
        stopAudioCapture()
        inputContinuation?.finish()
        isListening = false
        isFinalizing = true
        preparationMessage = "Finishing voice input…"

        let analyzer = analyzer
        finalizationTask = Task { [weak self] in
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                await self?.resultTask?.value
                self?.completeFinalization()
            } catch {
                self?.completeFinalization(error: error)
            }
        }
    }

    func cancel() {
        permissionTask?.cancel()
        finalizationTask?.cancel()
        resultTask?.cancel()
        stopAudioCapture()
        inputContinuation?.finish()
        let analyzer = analyzer
        clearSession()
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func prepareAndStart() async {
        defer {
            permissionTask = nil
            isRequestingPermission = false
            if !isListening { preparationMessage = nil }
        }

        do {
            let transcriber = try await makeTranscriber()
            try Task.checkCancellation()

            if let installer = try await AssetInventory.assetInstallationRequest(
                supporting: transcriber.modules
            ) {
                preparationMessage = "Installing Apple speech assets…"
                try await installer.downloadAndInstall()
            }
            try Task.checkCancellation()

            let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            try Task.checkCancellation()
            guard microphoneAllowed else {
                unavailableMessage = "Allow microphone access in System Settings to use voice input."
                return
            }

            try await beginRecognition(with: transcriber)
        } catch is CancellationError {
            return
        } catch {
            unavailableMessage = "Voice input could not start: \(error.localizedDescription)"
            await cancelPreparedAnalyzer()
        }
    }

    private func makeTranscriber() async throws -> ChapterChatLiveTranscriber {
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            return .speech(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            return .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
        }
        let language = requestedLocale.localizedString(forIdentifier: requestedLocale.identifier)
            ?? requestedLocale.identifier
        throw ChapterChatDictationError.unsupportedLocale(language)
    }

    private func beginRecognition(with transcriber: ChapterChatLiveTranscriber) async throws {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
#endif

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: transcriber.modules,
            considering: inputFormat
        ) else {
            throw ChapterChatDictationError.audioFormat
        }

        let analyzer = SpeechAnalyzer(modules: transcriber.modules)
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        inputContinuation = continuation
        startResultTask(for: transcriber)
        try await analyzer.start(inputSequence: inputSequence)
        try Task.checkCancellation()

        let converter = try ChapterChatAudioConverter(
            inputFormat: inputFormat,
            outputFormat: analyzerFormat
        )
        let (levelSequence, levelContinuation) = AsyncStream<Double>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.levelContinuation = levelContinuation
        startLevelTask(levelSequence)
        ChapterChatAudioTap.install(
            on: inputNode,
            format: inputFormat,
            converter: converter,
            continuation: continuation,
            levelContinuation: levelContinuation
        )
        inputTapInstalled = true

        onWillRecord?()
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        preparationMessage = nil
        unavailableMessage = nil
    }

    private func startResultTask(for transcriber: ChapterChatLiveTranscriber) {
        resultTask = Task { [weak self] in
            do {
                switch transcriber {
                case .speech(let speech):
                    for try await result in speech.results {
                        guard let self else { return }
                        receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                case .dictation(let dictation):
                    for try await result in dictation.results {
                        guard let self else { return }
                        receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, isListening || isFinalizing else { return }
                unavailableMessage = "Voice input stopped: \(error.localizedDescription)"
                cancel()
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        onTextUpdate?(transcript.receive(text, isFinal: isFinal))
    }

    private func startLevelTask(_ levels: AsyncStream<Double>) {
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self else { return }
                levelHistory.append(level)
                audioLevels = levelHistory.samples
            }
        }
    }

    private func resetAudioLevels() {
        levelHistory = ChapterChatVoiceLevelHistory()
        audioLevels = levelHistory.samples
    }

    private func completeFinalization(error: Error? = nil) {
        if let error {
            unavailableMessage = "Voice input stopped: \(error.localizedDescription)"
        }
        clearSession()
    }

    private func stopAudioCapture() {
        audioEngine.stop()
        levelContinuation?.finish()
        levelTask?.cancel()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private func cancelPreparedAnalyzer() async {
        stopAudioCapture()
        inputContinuation?.finish()
        resultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        clearSession()
    }

    private func clearSession() {
        analyzer = nil
        inputContinuation = nil
        resultTask = nil
        permissionTask = nil
        finalizationTask = nil
        levelContinuation = nil
        levelTask = nil
        isListening = false
        isRequestingPermission = false
        isFinalizing = false
        preparationMessage = nil
        resetAudioLevels()
        onTextUpdate = nil
        onWillRecord = nil
    }
}
