//
//  AudioCapture.swift
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

import Foundation
import AVFoundation

class AudioCapture {
    var audioEngine: AVAudioEngine
    var phaseTracker: PhaseTracker
    
    init () {
        audioEngine = AVAudioEngine()
        
        let format = audioEngine.inputNode.inputFormat(forBus: 0)
        phaseTracker = c_init_phase_tracker(110.0, Float(format.sampleRate), 3)
    }
    
    deinit {
        c_destroy_phase_tracker(phaseTracker)
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
        
        let sinkNode = AVAudioSinkNode(receiverBlock: {(timestamp, frameCount, audioBufferList) -> OSStatus in
            let bufferPointer = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
            let frameCount = Int32(frameCount)
            
            guard let bufferPointer = bufferPointer else {
                return noErr
            }
            
            if frameCount > 0 {
                c_phase_tracker_audio_callback(self.phaseTracker, bufferPointer, frameCount)
            }
            return noErr
        })
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
        
        print("Started input stream at \(format.sampleRate)Hz.")
    }
    
    func runPhaseAnalysis () -> PhaseInfo {
        let phaseInfo = c_run_dft_analysis(self.phaseTracker)
        return phaseInfo
    }
    
    func stopAudio() {
        audioEngine.stop()
    }
}
