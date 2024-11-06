//
//  Renderer.swift
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//
//  Copied from https://github.com/amengede/getIntoMetalDev/blob/main/swift/01%20App%20Setup/HelloTriangle/Renderer.swift

import Foundation
import MetalKit

class Renderer: NSObject, MTKViewDelegate {
    
    var parent: MetalView
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    
    init(_ parent: MetalView) {
        
        self.parent = parent
        if let device = MTLCreateSystemDefaultDevice() {
            self.device = device
        }
        self.commandQueue = device.makeCommandQueue()
        
        super.init()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
//        print(mtkView)
//        print(size)
    }
    
    func draw(in view: MTKView) {
        
        guard let drawable = view.currentDrawable else {
            return
        }
        print("draw")
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        let renderPassDescriptor = view.currentRenderPassDescriptor!
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0.0, 0.5, 1.0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        let renderEncoder = commandBuffer
            .makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
