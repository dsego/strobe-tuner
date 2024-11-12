//
//  ContentView.swift
//  StrobeTuner
//
//  Created by Davorin on 28.10.2024..
//

import SwiftUI

struct StrobeBand {
    var amp: Float
    var phase: Float
}

struct ContentView: View {
    @StateObject private var displayLinkManager = DisplayLinkManager()
    
    var shader: Shader {
        
//        displayLinkManager.phaseInfo.phase_correction
//
        let strobeBands: [StrobeBand] = [
            StrobeBand(amp: 2.0, phase: Float(displayLinkManager.time)),
            StrobeBand(amp: 20.0, phase: .pi / 2),
            StrobeBand(amp: 20.8, phase: .pi / 4),
        ]
        
        let data = Data(bytes: strobeBands, count: MemoryLayout<StrobeBand>.stride * strobeBands.count)
        return ShaderLibrary.recolor(.boundingRect, .data(data))
    }
    var body: some View {
        VStack {
            Text("Hello, world!")
            RoundedRectangle(cornerRadius: 8)
                .fill(.black)
//                .fill(Color(red: 84.0/255.0, green: 32.0/255.0, blue: 43.0/255.0))
                .frame(height: 400)
                .colorEffect(shader, isEnabled: true)
            Text("Hey")
        }
        .padding()
    }
}
