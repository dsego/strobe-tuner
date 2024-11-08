//
//  Shader.metal
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 recolor(float2 position, half4 color, float2 size) {
//    float TAU = 6.28318530717958647692528676655900576;
    
    float grow = 4.0;
    float padding = 10.0;
    float feathering = 2 / grow; // 2 px feathering for smoothstep
    
    // Calculate the center so the circle touches the top of the viewport vertically and is centered horizontally
    float2 center = float2(0.5 * size.x, grow * size.y + padding);
    
    // Define the thickness of our donut shape
    float thickness = 80 / grow;
    float2 donutRadii = float2(size.y - thickness, size.y);

    
    // This is the pixel position in terms of distance from the circle center
    float2 circle = center - position.xy;
    float radialPosition = sqrt((circle.x * circle.x) + (circle.y * circle.y)) / grow;
    
    // Color the pixel at position based on whether it sits in the donut shape
    float innerCircle = smoothstep(donutRadii.x, donutRadii.x - feathering, abs(radialPosition));
    float outerCircle = smoothstep(donutRadii.y, donutRadii.y - feathering, abs(radialPosition));
    float donut = outerCircle - innerCircle;
    
    
    
    half3 rgb = half3(1.0, 1.0, 1.0);
    return half4(donut * rgb, color.a);
}
