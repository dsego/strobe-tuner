//
//  MetalView.swift
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

import Foundation
import SwiftUI
import MetalKit


#if os(iOS)

struct MetalView: UIViewRepresentable {
    
    func makeCoordinator() -> Renderer {
        Renderer(self)
    }
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
    }
}
#elseif os(macOS)

struct MetalView: NSViewRepresentable {
    
    func makeCoordinator() -> Renderer {
        Renderer(self)
    }
    
    func makeNSView(context: Context) -> some NSView {
        let mtkView = MTKView()
        return mtkView
    }

    func updateNSView(_ uiView: NSViewType, context: Context) { }
}

#endif
