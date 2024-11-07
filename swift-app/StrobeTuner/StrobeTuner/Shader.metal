//
//  Shader.metal
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 recolor(float2 position, half4 color, half4 replacement) {
    // Send back the RGB values from the replacement color
    // factoring in the original alpha to preserve opacity.
    return replacement * color.a;
}
