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


float generateSignal(float freq, float time, float phase, float amplitude) {
    float tau = 2.0 * M_PI_F;
    float pi = M_PI_2_F;
    
    // Calculate the signal value for this position in the strobe
    float phaseCorrection = 0.0;
    float timeStretch = 4.0; // show 4 half periods of the base frequency (4 different colored stripes)
    float winSize = 4096.0;
    
    time = time * timeStretch * winSize;
    float value = amplitude * sin(freq * tau * (time - phaseCorrection) + phase);
    
    // convert from range [-1, 1] to [0, 1]
    value = 0.5 * value + 0.5;
    value = max(min(value, 1.0), 0.0);
    
    return value;
}

float drawDonut (
                 float2 size,
                 float thickness,
                 float translate,
                 float feathering,
                 float radialPosition
                 ) {
    float2 donutRadii = float2(size.y - thickness  - translate, size.y - translate);
    float innerCircle = smoothstep(donutRadii.x, donutRadii.x - feathering, abs(radialPosition));
    float outerCircle = smoothstep(donutRadii.y, donutRadii.y - feathering, abs(radialPosition));
    float donut = outerCircle - innerCircle;

    return donut;
}


[[ stitchable ]] half4 recolor(
                               float2 position,
                               half4 color,
                               float4 boundingRect,
                               constant StrobeBand* strobeBands,
                               int sizeBytes
                               ) {
    float tau = 2.0 * M_PI_F;
    float pi = M_PI_2_F;
    
    half4 outColor = color;
    int count = sizeBytes / sizeof(struct StrobeBand);
                                   
                                   
    // Viewport resolution (extract width & height)
    float2 size = boundingRect.zw;
   
    float grow = 4.0;
    float padding = 10.0; // top padding, distance from top of the viewport
    float feathering = 2 / grow; // 2 px feathering for smoothstep
   
    // Define the thickness of our donut shape (track)
    float thickness = 80.0 / grow;
    
    
    float freq = 55.0 * pow(2.0, count - 1);
    freq = freq / 48000.0; // normalize
                                   
    // Calculate the center so the circle touches the top of the viewport vertically and is centered horizontally
    float2 center = float2(0.5 * size.x, grow * size.y + padding + thickness);
                                   
    // starting angle & final angle
    float2 minAngleDistance = center - float2(0.0, size.y);
    float2 maxAngleDistance = center - float2(size.x, size.y);
    float minAngle = atan2(minAngleDistance.y, minAngleDistance.x);
    float maxAngle = atan2(maxAngleDistance.y, maxAngleDistance.x);
                                   
    // Loop over all strobes
    for (int i = 0; i < count; i++) {
        
        float amplitude = strobeBands[i].amp;
        float phase = strobeBands[i].phase;
        
        // Each track is translated down and its circumference is smaller to make concetrical tracks
        float translate = 16.5 * i; // * size.x / size.y;
        
        // This is the pixel position in terms of distance from the circle center
        float2 distance = center - position.xy + float2(0.0, translate);
        
        float angle = atan2(distance.y, distance.x);
        float time = angle / abs(maxAngle - minAngle) / tau;
        
        // Generate a strobe signal to match the amplitude and phase of the detected sound frequency
        float value = generateSignal(freq, time, phase, amplitude);
        freq = freq / 2.0;
        
        half3 baseColor = half3(255.0, 69.0, 58.0) / 255.0;
        half3 accentColor = half3(64.0, 0.0, 3.0) / 255.0;

         // Blend colors
        half3 strobeColor = mix(baseColor, accentColor, value);
        
        float radialPosition = sqrt((distance.x * distance.x) + (distance.y * distance.y)) / grow;
        
        // Color the pixel at position based on whether it sits in the donut shape
        float donut = drawDonut(size, thickness, translate, feathering, radialPosition);

        
        outColor.rgb = max(donut * strobeColor, outColor.rgb);
    }
    
    return outColor;
}
