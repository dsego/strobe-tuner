#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Output fragment color
out vec4 finalColor;

const float TAU = radians(360);

// Uniforms
uniform vec4 boundingRect;
uniform float curvatureRadius;
uniform vec3 colorA;
uniform vec3 colorB;
uniform float phaseCorrection;
uniform float timeStretch;
uniform float phase;
uniform float amp;
uniform float normFreq;
uniform float bandHeight;


float generateSignal(
    float freq,
    float phase,
    float amplitude,
    float time,
    float timeStretch,
    float phaseCorrection
) {
    time = time * timeStretch;
    float value = amplitude * sin(freq * TAU * (time - phaseCorrection) + phase);

    // convert from range [-1, 1] to [0, 1]
    value = 0.5 * value + 0.5;
    value = max(min(value, 1.0), 0.0);

    return value;
}

float drawDonut (
    vec2 size,
    float thickness,
    float curvatureRadius,
    float feathering,
    vec2 distance
) {
    // vec2 translate = vec2(0.0, 0.5 * size.y - 10);
    vec2 translate = vec2(0.0, 0.0);
    distance = distance - translate;
    float radialPosition = sqrt((distance.x * distance.x) + (distance.y * distance.y));

    float outerRadius = 0; // why ?
    float innerRadius = curvatureRadius - thickness;

    float outerCircle = smoothstep(curvatureRadius, curvatureRadius - feathering, abs(radialPosition));
    float innerCircle = smoothstep(innerRadius, innerRadius - feathering, abs(radialPosition));

    float donut = outerCircle - innerCircle;

    return donut;
}



void main()
{
    // Viewport resolution (extract width & height)
    vec2 size = boundingRect.zw;

    // Position in pixels
    vec2 position = fragTexCoord * size;
    float feathering = 2; // 2 px feathering for smoothstep

    // Define the thickness of our donut shape (track), leave a gap between tracks
    float thickness = 0.9 * bandHeight;

    // Calculate the center so the circle touches the top of the viewport
    // vertically and is centered horizontally
    vec2 center = vec2(0.5 * size.x, curvatureRadius + thickness);

    // This is the pixel position in terms of distance from the circle center
    vec2 distance = center - position.xy;


    // Color the pixel at position based on whether it sits in the donut shape
    float donut = drawDonut(size, thickness, curvatureRadius, feathering, distance);


    // Color in the generated strobe signal

    // TODO: color glow effect based on distance from center of strobe!!!

    // Current pixel angle
    float angle = atan(distance.y, distance.x);

    // Time is translated from the linear to radial
    float time = angle / TAU;

    float value = generateSignal(
        normFreq,
        phase,
        amp,
        time,
        timeStretch,
        phaseCorrection
    );

    // Blend colors
    vec3 rgb = mix(colorA, colorB, value);

    finalColor = vec4(rgb, donut);
}
