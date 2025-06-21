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
    var audioEngine: AVAudioEngine!
    private var speechRecognizer: SFSpeechRecognizer!
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest!
    var request: SFSpeechAudioBufferRecognitionRequest!
    var recognitionTask: SFSpeechRecognitionTask!
    
    var inputNode: AVAudioInputNode!
    
    @ObservationIgnored
    private var tapStreamDescription: AudioStreamBasicDescription?
    
    // process
    var pid: pid_t?
    var muteWhenRunning: Bool = false
    var aggregateDeviceID: AudioObjectID!
    
    init() {
        // identify target process where system output is
        guard let pid = getFocusAppPID() else {
            print("Error fetching pid")
            exit(1)
        }
        
        self.pid = pid
        print("Successfully fetched pid: \(pid)")
        
        // translate pid to AudioObjectID
        let AudioOID = translatePIDtoAudioObjectID(pid)
        
        print("Successfully fetched AudioObjectID: \(AudioOID)")
        
        // set up speech recognizer
        setupSpeechRecognition()
        
//        // create tap and retrieve its UUID
//        let processTapID = createProcessTap(AudioOID)
//        // get aggregate tap ID
//        let aggTapID = createAggregateDevice(processTapID)
        
        let globalTapID = createGlobalTap()
        
        let aggID = createAggregateDevice(globalTapID)
        
        addTapToAggregate(globalTapID, aggID)
        
        print("Successfully fetched Aggregate device ID: \(aggID)")
        
        // capture AV from aggregator device
        startCapturing(from: aggID)
        
        print("capturing...")
    }
    
    func setupSpeechRecognition() {
        // set up the speech recognizer
        speechRecognizer = SFSpeechRecognizer(locale: Locale.init(identifier: "ja-JP"))
        // initialize AVAudioEngine
        audioEngine = AVAudioEngine()
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
    
    func createAggregateDevice(_ processTapID: AudioObjectID) -> AudioObjectID {
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
        
        self.aggregateDeviceID = aggregateDeviceID
        return aggregateDeviceID
    }
    
    func addTapToAggregate(_ tapID: AudioObjectID, _ aggID: AudioObjectID) {
        // Get the UID of the audio tap.
        var tapPropAddress = getPropertyAddress(selector: kAudioTapPropertyUID)
        var tapPropSize = UInt32(MemoryLayout<CFString>.stride)
        var tapUID: CFString = "" as CFString
        _ = withUnsafeMutablePointer(to: &tapUID) { tapUID in
            AudioObjectGetPropertyData(tapID, &tapPropAddress, 0, nil, &tapPropSize, tapUID)
        }
        
        // initialize propAddress
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
            // Set the list back on the aggregate device.
            list = listAsArray as CFArray
            _ = withUnsafeMutablePointer(to: &list) { list in
                AudioObjectSetPropertyData(aggID, &listPropAddress, 0, nil, listPropSize, list)
            }
        }
        print("Tap added!")
    }
    
    /// Helper to create an AudioObjectPropertyAddress for a given selector,
    /// using global scope and main element by default.
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
    
    func setDefaultInput(as aggTapID: AudioObjectID) {
        var id = aggTapID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }
    
    func startCapturing(from aggTapID: AudioObjectID) {
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        isCapturing = true
        
        // set default engine as the aggregate tap ID
        setDefaultInput(as: aggTapID)
        
        // input node now points to the aggTapID
        inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        
        // install the tap onto the input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            self.recognitionRequest.append(buffer)
        }
        
        // start the audio engine
        audioEngine.prepare()
        try! audioEngine.start()
        print("Audio Engine started!")
        
        
        speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                Task {
                    self.recognizedText = result.bestTranscription.formattedString
                }
            }
            if error != nil || result?.isFinal == true {
                self.audioEngine.stop()
                self.inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
            }
        }
    }
    
    func stopCapturing () {
        inputNode.removeTap(onBus: 0)
        print("Tap removed!")
        audioEngine.stop()
        recognitionRequest.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        isCapturing = false
        print("Audio Engine stopped!")
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        print("Aggregate Device destroyed!")
    }

    
    // takes in the process AudioObjectID, creates the aggregate device, and returns the tap's UUID
//    func buildAggregateDevice(_ AudioOID: AudioObjectID) -> AudioObjectID {
//
//
//
////        do {
////            let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
////            let outputUID = try systemOutputID.readDeviceUID()
////        } catch {
////            print("Error reading system output device: \(error)")
////        }
//
//        let aggregateUID = UUID().uuidString
//
//        let description: [String: Any] = [
//                    kAudioAggregateDeviceNameKey: "Tap-\(pid)",
//                    kAudioAggregateDeviceUIDKey: aggregateUID,
//                    kAudioAggregateDeviceMainSubDeviceKey: processID,
//                    kAudioAggregateDeviceIsPrivateKey: true,
//                    kAudioAggregateDeviceIsStackedKey: false,
//                    kAudioAggregateDeviceTapAutoStartKey: true,
//                    kAudioAggregateDeviceSubDeviceListKey: [
//                        [
//                            kAudioSubDeviceUIDKey: processID
//                        ]
//                    ],
//                    kAudioAggregateDeviceTapListKey: [
//                        [
//                            kAudioSubTapDriftCompensationKey: true,
//                            kAudioSubTapUIDKey: tapDescription.uuid.uuidString
//                        ]
//                    ]
//                ]
//        do {
//            self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()
//        } catch {
//            print("Error getting tap stream description")
//        }
//
//        aggregateDeviceID = kAudioObjectUnknown
//
//        AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
//
//    }
}
