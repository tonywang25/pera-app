//
//  AudioRecorder.h
//  pera-app
//
//  Created by Tony Wang on 6/20/25.
//


/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A class that provides functions for running IO on an audio device, recording audio input to a file, and looping back audio data from input to output streams.
*/

#ifndef AudioRecorder_h
#define AudioRecorder_h

#include <AppKit/AppKit.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/ExtendedAudioFile.h>

// Define the callback block type for audio buffers
typedef void (^AudioBufferCallback)(const AudioBufferList* inInputData, UInt32 inNumberFrames, const AudioTimeStamp* inTimeStamp);

// You implement the `AudioRecorder` class in Objective-C++ because Swift doesn't have the real-time safety required to run an audio IO proc.
@interface AudioRecorder : NSObject

@property (readwrite, nonatomic) AudioObjectID deviceID;
@property (readwrite, atomic) bool recordingEnabled;
@property (readwrite, atomic) bool loopbackEnabled;
@property (strong, readonly, nonatomic) NSURL* recordingURL;

// Add the callback property
@property (copy, nonatomic) AudioBufferCallback audioBufferCallback;

@end

#endif /* AudioRecorder_h */
