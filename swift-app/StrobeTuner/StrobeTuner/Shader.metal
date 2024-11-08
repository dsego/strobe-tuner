//
//  Shader.metal
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 recolor(float2 position, half4 color, float2 size) {
        
    // normalized position
    float2 p = position / size;
    
    return half4(p.x, p.y, 0.0, 1.0);
}
