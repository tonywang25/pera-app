import Foundation
import AVFoundation
import AVKit // not strictly needed for AVAudioRecorder, but ok

actor Recorder {
    private var recorder: AVAudioRecorder?

    enum RecorderError: Error {
        case couldNotStartRecording
        case permissionDenied
        case permissionRestricted
    }

    /// Check/request microphone access. Call this before startRecording.
    static func checkMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            // Request access
            try await withCheckedThrowingContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RecorderError.permissionDenied)
                    }
                }
            }
        case .denied:
            throw RecorderError.permissionDenied
        case .restricted:
            throw RecorderError.permissionRestricted
        @unknown default:
            throw RecorderError.permissionDenied
        }
    }

    /// Start recording to the given URL. Call `await Recorder.checkMicrophonePermission()` first.
    func startRecording(toOutputFile url: URL, delegate: AVAudioRecorderDelegate?) throws {
        // At this point, permission should already be granted.
        let recordSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // Create and start AVAudioRecorder
        let recorder = try AVAudioRecorder(url: url, settings: recordSettings)
        recorder.delegate = delegate
        guard recorder.record() else {
            throw RecorderError.couldNotStartRecording
        }
        self.recorder = recorder
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
    }
}
