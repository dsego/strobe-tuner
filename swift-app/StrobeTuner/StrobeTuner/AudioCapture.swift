//
//  AudioCapture.swift
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

import Foundation
import AVFoundation

struct AudioCapture {
    var audioEngine: AVAudioEngine
    var sinkNode: AVAudioSinkNode
    
    init () {
        audioEngine = AVAudioEngine()
        sinkNode = AVAudioSinkNode(receiverBlock: {(timestamp, frameCount, inputData) -> OSStatus in
            return noErr
        })
    }
    
    func startAudio() {
        audioEngine.attach(sinkNode)
        audioEngine.connect(
            audioEngine.inputNode,
            to: sinkNode,
            // TODO: define in a config somewhere
            format: AVAudioFormat.init(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        do {
            try audioEngine.start()
        } catch {
            // TODO: how to best handle ??
            fatalError("Failed to start audio engine.")
        }
        print("Started input stream.")
    }
    
     func stopAudio() {
        audioEngine.stop()
    }
}
