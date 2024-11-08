//
//  Shader.metal
//  StrobeTuner
//
//  Created by Davorin on 05.11.2024..
//

#include <metal_stdlib>
using namespace metal;

#define MAX_STROBES 8

struct StrobeBand {
    float amp;
    float phase;
};

[[ stitchable ]] half4 recolor(
                               float2 position,
                               half4 color,
                               float4 boundingRect,
                               constant StrobeBand* strobeBands,
                               int sizeBytes
) {
//    float TAU = 6.28318530717958647692528676655900576;
    half4 outColor = color;
    int count = sizeBytes / sizeof(struct StrobeBand);
    
    // Loop over all strobes
    for (int i = 0; i < count; i++) {
        
        float amplitude = strobeBands[i].amp;
        float phase = strobeBands[i].phase;
        
        // Each track is translated down and its circumference is smaller to make concetrical tracks
        float translate = 16.5 * i;
    
        // Viewport resolution (extract width & height)
        float2 size = boundingRect.zw;
        
        float grow = 4.0;
        float padding = 10.0; // top padding, distance from top of the viewport
        float feathering = 2 / grow; // 2 px feathering for smoothstep
        
        // Define the thickness of our donut shape (track)
        float thickness = 80.0 / grow;
        
        // Calculate the center so the circle touches the top of the viewport vertically and is centered horizontally
        float2 center = float2(0.5 * size.x, grow * size.y + padding + thickness + translate);
        
        float2 donutRadii = float2(size.y - thickness  - translate, size.y - translate);

        
        // This is the pixel position in terms of distance from the circle center
        float2 distance = center - position.xy;
        float radialPosition = sqrt((distance.x * distance.x) + (distance.y * distance.y)) / grow;
        
        // Color the pixel at position based on whether it sits in the donut shape
        float innerCircle = smoothstep(donutRadii.x, donutRadii.x - feathering, abs(radialPosition));
        float outerCircle = smoothstep(donutRadii.y, donutRadii.y - feathering, abs(radialPosition));
        float donut = outerCircle - innerCircle;
        
        half3 rgb = half3(amplitude, 0.0, 0.0);
        outColor.rgb = max(donut * rgb, outColor.rgb);
    }
    
    return outColor;
}
