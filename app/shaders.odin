package app


FRAGMENT_SHADER :: `
////////////////////////////////////////////

#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Output fragment color
out vec4 finalColor;

const float TAU = 6.28318530717958647692528676655900576;

// Uniforms
uniform vec3 colorA;
uniform vec3 colorB;
uniform float timeStretch;
uniform float phaseCorrection;
uniform float phase;
uniform float amp;
uniform int winSize;
uniform float normFreq;

void main()
{
    float time = fragTexCoord.s * timeStretch * float(winSize);
    float value = amp * sin(normFreq * TAU * (time - phaseCorrection) + phase);

    // convert from range [-1, 1] to [0, 1]
    value = 0.5 * value + 0.5;
    value = max(min(value, 1.0), 0.0);

    // Blend colors
    vec3 rgb = mix(colorA, colorB, value);

    finalColor = vec4(rgb, 1.0);
}

////////////////////////////////////////////
`
