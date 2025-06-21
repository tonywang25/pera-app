import Foundation
import SwiftUI
import AVFoundation

// guarantee only this runs on the main thread
@MainActor
class WhisperState: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isModelLoaded = false
    @Published var messageLog = ""
    @Published var canTranscribe = false
    @Published var isRecording = false
    @Published var isCapturing = false

    private var whisperContext: WhisperContext?
    private let recorder = Recorder()
    var capturer: Capturer?
    private var recordedFile: URL? = nil
    private var capturedFile: URL? = nil
    private var audioPlayer: AVAudioPlayer?

    private var builtInModelUrl: URL? {
        Bundle.main.url(forResource: "ggml-base", withExtension: "bin")
    }

    private var sampleUrl: URL? {
        Bundle.main.url(forResource: "jfk", withExtension: "wav")
    }

    private enum LoadError: Error {
        case couldNotLocateModel
    }

    override init() {
        super.init()
        loadModel()
    }

    func loadModel(path: URL? = nil, log: Bool = true) {
        do {
            whisperContext = nil
            if log { messageLog += "Loading model...\n" }
            let modelUrl = path ?? builtInModelUrl
            if let modelUrl {
                whisperContext = try WhisperContext.createContext(path: modelUrl.path())
                if log { messageLog += "Loaded model \(modelUrl.lastPathComponent)\n" }
            } else {
                if log { messageLog += "Could not locate model\n" }
            }
            canTranscribe = true
        } catch {
            print(error.localizedDescription)
            if log { messageLog += "\(error.localizedDescription)\n" }
        }
    }

    func benchCurrentModel() async {
        if whisperContext == nil {
            messageLog += "Cannot bench without loaded model\n"
            return
        }
        messageLog += "Running benchmark for loaded model\n"
        let result = await whisperContext?.benchFull(modelName: "<current>", nThreads: Int32(min(4, cpuCount())))
        if let result {
            messageLog += result + "\n"
        }
    }

    func bench(models: [Model]) async {
        let nThreads = Int32(min(4, cpuCount()))
        messageLog += "Running benchmark for all downloaded models\n"
        messageLog += "| CPU | OS | Config | Model | Th | FA | Enc. | Dec. | Bch5 | PP | Commit |\n"
        messageLog += "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
        for model in models {
            loadModel(path: model.fileURL, log: false)
            if whisperContext == nil {
                messageLog += "Cannot bench without loaded model\n"
                break
            }
            let result = await whisperContext?.benchFull(modelName: model.name, nThreads: nThreads)
            if let result {
                messageLog += result + "\n"
            }
        }
        messageLog += "Benchmarking completed\n"
    }

    // Purpose: transcribing full podcast episodes
    
    func transcribeSample() async {
        if let sampleUrl {
            await transcribeAudio(sampleUrl)
        } else {
            messageLog += "Could not locate sample\n"
        }
    }

    // Purpose: transcribing live audio
    
    private func transcribeAudio(_ url: URL) async {
        if !canTranscribe { return }
        guard let whisperContext else { return }

        do {
            canTranscribe = false
            messageLog += "Reading wave samples...\n"
            let data = try readAudioSamples(url)
            messageLog += "Transcribing data...\n"
            await whisperContext.fullTranscribe(samples: data)
            let text = await whisperContext.getTranscription()
            messageLog += "Done: \(text)\n"
        } catch {
            print(error.localizedDescription)
            messageLog += "\(error.localizedDescription)\n"
        }

        canTranscribe = true
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        stopPlayback()
        try startPlayback(url)
        return try decodeWaveFile(url)
    }

    /// Static async permission request helper
    static func requestRecordingPermission() async -> Bool {
        // Use Recorder.checkMicrophonePermission() which throws if denied
        #if os(macOS)
        do {
            try await Recorder.checkMicrophonePermission()
            return true
        } catch {
            return false
        }
        #else
        // iOS/tvOS/watchOS: wrap requestRecordPermission in async
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }

    func toggleRecord() async {
        if isRecording {
            // Stop recording
            await recorder.stopRecording()
            isRecording = false
            if let recordedFile {
                await transcribeAudio(recordedFile)
            }
        } else {
            // Start: check permission first
            let granted = await Self.requestRecordingPermission()
            if !granted {
                messageLog += "Microphone permission denied. Please enable in Settings (or System Preferences).\n"
                return
            }
            Task {
                do {
                    self.stopPlayback()
                    let file = try FileManager.default.url(
                        for: .documentDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: true
                    ).appending(path: "output.wav")
                    try await self.recorder.startRecording(toOutputFile: file, delegate: self)
                    self.isRecording = true
                    self.recordedFile = file
                    messageLog += "Recording started...\n"
                } catch {
                    print(error.localizedDescription)
                    messageLog += "\(error.localizedDescription)\n"
                    self.isRecording = false
                }
            }
        }
    }
    
    func toggleCapture() async {
        if isCapturing {
            await stopCapturing()
            messageLog += "Capture stopped...\n"
            isCapturing = false
            capturer = nil
        } else {
            // start capturing
            do {
                self.stopPlayback()
                isCapturing = true
                if capturer == nil {
                    capturer = Capturer()
                    messageLog += "Capture started...\n"
                } else {
                    messageLog += "Capturer not initialized.\n"
                    return
                }
            }
        }
    }
    
    func stopCapturing() async {
        capturer?.stopCapturing()
        capturer = nil
    }

    private func startPlayback(_ url: URL) throws {
        audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: AVAudioRecorderDelegate

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error {
            Task { await handleRecError(error) }
        }
    }

    private func handleRecError(_ error: Error) {
        print(error.localizedDescription)
        messageLog += "\(error.localizedDescription)\n"
        isRecording = false
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { await onDidFinishRecording() }
    }

    private func onDidFinishRecording() {
        isRecording = false
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
