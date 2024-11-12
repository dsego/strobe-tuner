//
//  DisplayLinkManager.swift
//  StrobeTuner
//
//  Created by Davorin on 11.11.2024..
//

import Foundation
import SwiftUI


#if os(iOS)
class DisplayLinkManager: ObservableObject {
    private var displayLink: CADisplayLink?
    @Published var time: CFTimeInterval = 0
    
    init() {
        displayLink = CADisplayLink(target: self, selector: #selector(update))
        displayLink?.add(to: .current, forMode: .common)
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    @objc private func update() {
        time = displayLink?.timestamp ?? 0
    }
}

#endif

#if os(macOS)
class DisplayLinkManager: ObservableObject {
    var audioCapture: AudioCapture
    private var displayLink: CADisplayLink?
    @Published var time: CFTimeInterval = 0
    @Published var phaseInfo: PhaseInfo = PhaseInfo()
    
    init() {
        audioCapture = AudioCapture()
        audioCapture.startAudio()
        
        let window = NSApplication.shared.windows.first
        displayLink = window?.displayLink(target: self, selector: #selector(update))
        displayLink?.add(to: .current, forMode: .common)
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    @objc private func update() {
        time = displayLink?.timestamp ?? 0
//        phaseInfo = audioCapture.runPhaseAnalysis()
    }
}
#endif
