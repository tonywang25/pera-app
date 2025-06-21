//
//  Untitled.swift
//  pera-app
//
//  Created by Tony Wang on 6/19/25.
//
import Foundation
import AVFoundation
import Speech
import CoreAudio

@Observable
class Capturer {
    var recognizedText: String = ""
    var isCapturing: Bool = false
    // SFSpeechRecognizer member variables
    private var speechRecognizer: SFSpeechRecognizer!
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest!
    var recognitionTask: SFSpeechRecognitionTask!
    
    // queue buffer
    private let queue = DispatchQueue(label: "ProcessTapRecorder", qos: .userInitiated)
    var muteWhenRunning: Bool = false
    
    @ObservationIgnored
    private var processTapID: AudioObjectID!
    @ObservationIgnored
    private var aggregateDeviceID: AudioObjectID!
    @ObservationIgnored
    private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored
    private var tapStreamDescription: AudioStreamBasicDescription?
    
    
    init() {
        
        // set up speech recognizer
        setupSpeechRecognition()
        
        // create global process tap
        self.processTapID = createGlobalTap()
        
        // Create Aggregate Device
        self.aggregateDeviceID = createAggregateDevice()
        
        // add Tap to Aggregate Device
        addTapToAggregate(from: self.processTapID, to: self.aggregateDeviceID)
        
        print("Successfully fetched Aggregate device ID: \(aggregateDeviceID!)")
        
        do {
            self.tapStreamDescription = try processTapID.readAudioTapStreamBasicDescription()
        } catch {
            print("error reading stream description")
        }
        
        // START CAPTURING FROM AGGREGATOR DEVICE
        do {
            try startCapturing(from: aggregateDeviceID)
        } catch {
            print("error capturing")
        }
        
        print("capturing...")
    }
    
    
    func setupSpeechRecognition() {
        // set up the speech recognizer
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale.init(identifier: "ja-JP"))
        // set up permissions
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("Speech recognition authorized")
                case .denied, .restricted, .notDetermined:
                    print("Speech recognition not authorized")
                @unknown default:
                    fatalError("Unknown authorization status")
                }
            }
        }
    }
    
    //    consider changing AUAudioObjectID -> AudioObjectID
    func createProcessTap(_ AudioOID: AudioObjectID) -> AUAudioObjectID {
        // compose a tap description
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [AudioOID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        
        // Create the process tap and pass in a pointer that will hold the tapID at the end
        var tapID = kAudioObjectUnknown
        AudioHardwareCreateProcessTap(tapDescription, &tapID)
        
        return tapID
    }
    
    func createGlobalTap() -> AUAudioObjectID {
        // compose a global tap description
        let processes: [AudioObjectID] = [];
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        
        // Create the process tap and pass in a pointer that will hold the tapID at the end
        var tapID = kAudioObjectUnknown
        AudioHardwareCreateProcessTap(tapDescription, &tapID)
        print("Global tap created!")
        return tapID
    }
    
    func createAggregateDevice() -> AudioDeviceID {
        let aggName = "MyTapAggregate-\(UUID().uuidString)"
        let aggUID = "com.myapp.aggregate.\(UUID().uuidString)" as CFString
        let tapListEntry: CFDictionary = [
            kAudioSubTapUIDKey as String: processTapID
        ] as CFDictionary
        let tapList: CFArray = [tapListEntry] as CFArray
        
        // set up dictionary, used as tap description
        let aggDict: CFMutableDictionary = [
            kAudioAggregateDeviceNameKey as String: aggName as CFString,
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: tapList,
            kAudioAggregateDeviceIsPrivateKey as String: true as CFBoolean
        ] as! CFMutableDictionary
        
        // actually create the aggregate device
        
        var aggregateDeviceID: AudioObjectID = 0
        
        AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateDeviceID)
        
        return aggregateDeviceID
    }
    
    func addTapToAggregate(from tapID: AUAudioObjectID, to aggID: AudioDeviceID) {
        // Get the UID of the audio tap.
        var tapPropAddress = getPropertyAddress(selector: kAudioTapPropertyUID)
        var tapPropSize = UInt32(MemoryLayout<CFString>.stride)
        var tapUID: CFString = "" as CFString
        _ = withUnsafeMutablePointer(to: &tapUID) { tapUID in
            AudioObjectGetPropertyData(tapID, &tapPropAddress, 0, nil, &tapPropSize, tapUID)
        }
        
        var listPropAddress = getPropertyAddress(selector: kAudioAggregateDevicePropertyTapList)
        var listPropSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(aggID, &listPropAddress, 0, nil, &listPropSize)
        var list: CFArray? = nil
        _ = withUnsafeMutablePointer(to: &list) { list in
            AudioObjectGetPropertyData(aggID, &listPropAddress, 0, nil, &listPropSize, list)
        }
        
        
        if var listAsArray = list as? [CFString] {
            if !listAsArray.contains(tapUID as CFString) {
                listAsArray.append(tapUID as CFString)
                listPropSize += UInt32(MemoryLayout<CFString>.stride)
            }
            list = listAsArray as CFArray
            _ = withUnsafeMutablePointer(to: &list) { list in
                AudioObjectSetPropertyData(aggID, &listPropAddress, 0, nil, listPropSize, list)
            }
        }
        print("Tap added!")
    }
    
    func getPropertyAddress(selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
    
    func startCapturing(from aggTapID: AudioObjectID) throws {
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        isCapturing = true
        
        guard var streamDescription = tapStreamDescription else {
            print("Tap stream description not available")
            return
        }
        
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            print("Failed to create AVAudioFormat")
            return
        }
        
        // callback for delivering transcription results
        self.recognitionTask = self.speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                Task { @MainActor in
                    self.recognizedText = result.bestTranscription.formattedString
                }
            }
        }
        
        // callback for audio capture
        // supplying raw audio data on a background queue.
        try run(on: queue) { [weak self] _, inInputData, _, _, _ in
            guard let self = self else { return }
            
            // Create a buffer from the incoming audio data.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                print("Failed to create PCM buffer")
                return
            }
            // APPEND TO BUFFER
            self.recognitionRequest?.append(buffer)
        }
    }
    
    func stopCapturing () {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        isCapturing = false
        AudioDeviceStop(aggregateDeviceID, deviceProcID)
        AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID!)
        deviceProcID = nil
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = nil
        print("Recognizer, Devices, and Processes Destroyed!")
    }
    
    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
        guard err == noErr else {
            print("Failed to create device I/O proc: \(err)")
            return
        }
        
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            print("Failed to start audio device: \(err)")
            return
        }
    }
}
