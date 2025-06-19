import Foundation
import AppKit    // for Host, if needed elsewhere
import whisper
import AVFoundation

enum WhisperError: Error {
    case couldNotInitializeContext
}

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    func fullTranscribe(samples: [Float]) {
        // Leave 2 processors free (i.e. the high-efficiency cores).
        let maxThreads = max(1, min(8, cpuCount() - 2))
        print("Selecting \(maxThreads) threads")
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        "japanese".withCString { jp in
            params.print_realtime   = true
            params.print_progress   = false
            params.print_timestamps = true
            params.print_special    = false
            params.translate        = false
            params.language         = jp
            params.n_threads        = Int32(maxThreads)
            params.offset_ms        = 0
            params.no_context       = true
            params.single_segment   = false

            whisper_reset_timings(context)
            print("About to run whisper_full")
            samples.withUnsafeBufferPointer { ptr in
                if whisper_full(context, params, ptr.baseAddress, Int32(ptr.count)) != 0 {
                    print("Failed to run the model")
                } else {
                    whisper_print_timings(context)
                }
            }
        }
    }

    func getTranscription() -> String {
        var transcription = ""
        let n = Int(whisper_full_n_segments(context))
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(context, Int32(i)) {
                transcription += String(cString: cstr)
            }
        }
        return transcription
    }

    static func benchMemcpy(nThreads: Int32) async -> String {
        return String(cString: whisper_bench_memcpy_str(nThreads))
    }

    static func benchGgmlMulMat(nThreads: Int32) async -> String {
        return String(cString: whisper_bench_ggml_mul_mat_str(nThreads))
    }

    private func systemInfo() -> String {
        // You can customize: detect CPU features on macOS if desired (e.g., via sysctl).
        // For now, leave blank or simple:
        return ""
    }

    func benchFull(modelName: String, nThreads: Int32) async -> String {
        let nMels = whisper_model_n_mels(context)
        if whisper_set_mel(context, nil, 0, nMels) != 0 {
            return "error: failed to set mel"
        }

        // heat encoder
        if whisper_encode(context, 0, nThreads) != 0 {
            return "error: failed to encode"
        }

        var tokens = [whisper_token](repeating: 0, count: 512)

        // prompt heat
        if whisper_decode(context, &tokens, 256, 0, nThreads) != 0 {
            return "error: failed to decode"
        }

        // text-generation heat
        if whisper_decode(context, &tokens, 1, 256, nThreads) != 0 {
            return "error: failed to decode"
        }

        whisper_reset_timings(context)

        // actual run
        if whisper_encode(context, 0, nThreads) != 0 {
            return "error: failed to encode"
        }

        // text-generation
        for i in 0..<256 {
            if whisper_decode(context, &tokens, 1, Int32(i), nThreads) != 0 {
                return "error: failed to decode"
            }
        }

        // batched decoding
        for _ in 0..<64 {
            if whisper_decode(context, &tokens, 5, 0, nThreads) != 0 {
                return "error: failed to decode"
            }
        }

        // prompt processing
        for _ in 0..<16 {
            if whisper_decode(context, &tokens, 256, 0, nThreads) != 0 {
                return "error: failed to decode"
            }
        }

        whisper_print_timings(context)

        // macOS equivalents for device/system info:
        let deviceName = Host.current().localizedName ?? "Mac"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemName = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let sysInfoStr = systemInfo()
        let timings: whisper_timings = whisper_get_timings(context).pointee
        let encodeMs = String(format: "%.2f", timings.encode_ms)
        let decodeMs = String(format: "%.2f", timings.decode_ms)
        let batchdMs = String(format: "%.2f", timings.batchd_ms)
        let promptMs = String(format: "%.2f", timings.prompt_ms)
        return "| \(deviceName) | \(systemName) | \(sysInfoStr) | \(modelName) | \(nThreads) | 1 | \(encodeMs) | \(decodeMs) | \(batchdMs) | \(promptMs) | <todo> |"
    }

    static func createContext(path: String) throws -> WhisperContext {
        var params = whisper_context_default_params()
#if targetEnvironment(simulator)
        // On macOS there’s no simulator targetEnvironment; this branch won’t run.
        params.use_gpu = false
        print("Running on simulator? Unlikely on macOS, using CPU")
#else
        params.flash_attn = true // Enabled by default for Metal if whisper supports it
#endif
        let ctx = whisper_init_from_file_with_params(path, params)
        if let ctx {
            return WhisperContext(context: ctx)
        } else {
            print("Couldn't load model at \(path)")
            throw WhisperError.couldNotInitializeContext
        }
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
