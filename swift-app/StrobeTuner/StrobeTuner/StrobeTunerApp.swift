//
//  StrobeTunerApp.swift
//  StrobeTuner
//
//  Created by Davorin on 28.10.2024..
//

import SwiftUI

@main
struct StrobeTunerApp: App {
    var capture: AudioCapture
    
    init () {
        capture = AudioCapture()
        capture.startAudio()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
