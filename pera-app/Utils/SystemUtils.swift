//
//  SystemUtils.swift
//  pera-app
//
//  Created by Tony Wang on 6/19/25.
//
import Cocoa
import AudioToolbox
import CoreAudio

func getFocusAppPID() -> pid_t? {
    if let focusApp = NSWorkspace.shared.frontmostApplication {
        return focusApp.processIdentifier
    }
    return nil
}


func translatePIDtoAudioObjectID(_ pid: pid_t) -> AudioObjectID {
    var audioOID = AudioObjectID(kAudioObjectUnknown)
    var pidVar = pid
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
        )
    // data size for one AudioObjectId
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &pidVar,
        &dataSize,
        &audioOID
    )
    return audioOID
}
