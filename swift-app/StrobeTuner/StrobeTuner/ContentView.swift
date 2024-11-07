//
//  ContentView.swift
//  StrobeTuner
//
//  Created by Davorin on 28.10.2024..
//

import SwiftUI
    
struct ContentView: View {
    var shader: Shader {
        ShaderLibrary.recolor(.color(.red))
    }
    var body: some View {
        VStack {
            Text("Hello, world!")
            RoundedRectangle(cornerRadius: 40)
                .frame(height: 400)
                .padding(.horizontal, 50)
                .colorEffect(shader, isEnabled: true)
            Text("Hey")
        }
        .padding()
    }
}
