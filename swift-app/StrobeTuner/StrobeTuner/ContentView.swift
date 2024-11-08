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
    
    var strobeBands: [StrobeBand] = [
        StrobeBand(amp: 1.0, phase: 0.0),
        StrobeBand(amp: 0.5, phase: .pi / 2),
        StrobeBand(amp: 0.2, phase: .pi / 2),
    ]
    
    var shader: Shader {
        let data = Data(bytes: strobeBands, count: MemoryLayout<StrobeBand>.stride * strobeBands.count)
        return ShaderLibrary.recolor(.boundingRect, .data(data))
    }
    var body: some View {
        VStack {
            Text("Hello, world!")
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 8)
                    .frame(height: 400)
                    .colorEffect(shader, isEnabled: true)
            }
            Text("Hey")
        }
        .padding()
    }
}
