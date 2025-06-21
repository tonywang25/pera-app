//
//  ContentView.swift
//  pera-app
//
//  Created by Tony Wang on 6/19/25.
//
import SwiftUI
import AVFoundation
import Foundation
import AppKit
import Speech

struct ContentView: View {
    @StateObject var whisperState = WhisperState()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Button("Transcribe") {
                        Task {
                            await whisperState.transcribeSample()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!whisperState.canTranscribe)
                    
                    Button(whisperState.isRecording ? "Stop Recording" : "Start Recording") {
                        Task {
                            await whisperState.toggleRecord()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!whisperState.canTranscribe)
                    
                    Button(whisperState.isCapturing ? "Stop Capturing" : "Start Capturing") {
                        Task {
                            await whisperState.toggleCapture()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!whisperState.canTranscribe)
                }
                
                ScrollView {
                    // Use Text with monospaced font if you like
                    Text(verbatim: whisperState.messageLog)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.body, design: .monospaced))
                        .padding(4)
                }
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
                .frame(minHeight: 200)
                
                VStack(spacing: 50) {
                    Text(whisperState.capturer?.recognizedText ?? "")
                        .padding()
                }
                
                HStack {
                    Button("Clear Logs") {
                        whisperState.messageLog = ""
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    
                    Button("Copy Logs") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(whisperState.messageLog, forType: .string)
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Whisper macOS Demo")
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// You may need to adjust WhisperState and Model to work on macOS:
// - Ensure fileURL points to a writable location on macOS (e.g., Application Support folder).
// - Audio recording: AVAudioEngine APIs are available on macOS but ensure microphone permissions in Info.plist.
// - Pasteboard uses NSPasteboard as above.
// - If you used UIKit-specific types elsewhere, replace with AppKit or pure Swift types.
// - Test that whisperState.toggleRecord() and transcription logic works under macOS audio session.

