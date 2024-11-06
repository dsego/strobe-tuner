//
//  Shader.metal
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

#include <metal_stdlib>
using namespace metal;

vertex float4 vertexFunction(uint vid [[vertex_id]], constant float2* vertices [[buffer(0)]]) {
    return float4(vertices[vid], 0.0, 1.0);
}

fragment float4 fragmentFunction() {
    return float4(0.2, 0.7, 0.9, 1.0);
}
