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
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record)
            try session.setActive(true)
        } catch {
            fatalError("Failed to start audio engine.")
        }
#endif
        audioEngine.attach(sinkNode)
            
        let format = audioEngine.inputNode.inputFormat(forBus: 0)
        
        audioEngine.connect(
            audioEngine.inputNode,
            to: sinkNode,
            format: format
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
