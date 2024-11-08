//
//  Shader.metal
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 recolor(float2 position, half4 color, float2 size) {
    const float TAU = 6.28318530717958647692528676655900576;
    
    float2 center = 0.5 * size;
    
    float2 circle = center - position.xy;
    
    float feathering = 2; // 2 px feathering for smoothstep
    
    float radius = sqrt((circle.x * circle.x) + (circle.y * circle.y));
    
    float minSize = min(size.x, size.y);
    
    float innerCircle = smoothstep(0.4 * minSize, 0.4 * minSize - feathering, abs(radius));
    float outerCircle = smoothstep(0.5 * minSize, 0.5 * minSize - feathering, abs(radius));
    float wheel = outerCircle - innerCircle;
    
    half3 rgb = half3(1.0, 1.0, 1.0);
    return half4(wheel * rgb, color.a);
}
