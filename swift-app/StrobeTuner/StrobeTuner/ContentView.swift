//
//  ContentView.swift
//  StrobeTuner
//
//  Created by Davorin on 28.10.2024..
//

import SwiftUI
    
struct ContentView: View {
    @State var size: CGSize = CGSize()
    
    var shader: Shader {
        ShaderLibrary.recolor(.float2(size))
    }
    var body: some View {
        VStack {
            Text("Hello, world!")
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 40)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: {
                        size = $0
                    }
                    .frame(height: 400)
                    .colorEffect(shader, isEnabled: true)
            }
            Text("Hey")
        }
        .padding()
    }
}
