package app


FRAGMENT_SHADER_WHEEL :: `
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

    float x = 0.5 - fragTexCoord.s;
    float y = 0.5 - fragTexCoord.t;

    float r = sqrt((x * x) + (y * y));
    float circle = smoothstep(0.5, 0.498, abs(r)) - smoothstep(0.4, 0.398, abs(r));

    float pi = radians(180);
    float angle = atan(y, x) + pi;
    angle = 0.5 * angle / pi;


    float time = angle * timeStretch * float(winSize);
    float value = amp * sin(normFreq * TAU * (time - phaseCorrection) + phase);

    // convert from range [-1, 1] to [0, 1]
    value = 0.5 * value + 0.5;
    value = max(min(value, 1.0), 0.0);


    // Blend colors
    vec3 rgb = mix(colorA, colorB, value);


    finalColor = vec4(circle * rgb, 1.0);
}
////////////////////////////////////////////
`



// TODO:
//  correct formula to control the following variables:
//     - track thickness
//     - track curvature (lower tracks need to be more curved)
//     - adjust time stretch to fit exactly n stripes

FRAGMENT_SHADER_CURVED_TRACK :: `
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
    vec2 center = vec2(0.5, 3.2);

    vec2 circle = center - fragTexCoord.st;
    float r = sqrt((circle.x * circle.x) + (circle.y * circle.y)) / 6.0;

    float pi = radians(180);
    float angle = atan(circle.y, circle.x);
    angle = 0.5 * angle /  pi;

    float wheel = smoothstep(0.5, 0.499, abs(r)) - smoothstep(0.47, 0.469, abs(r));

    float time = angle * timeStretch * float(winSize) * 10.0;
    float value = amp * sin(normFreq * TAU * (time - phaseCorrection) + phase);

    // convert from range [-1, 1] to [0, 1]
    value = 0.5 * value + 0.5;
    value = max(min(value, 1.0), 0.0);

    // Blend colors
    // vec3 rgb = vec3(1.0);
    vec3 rgb = mix(colorA, colorB, value);


    finalColor = vec4(wheel * rgb, wheel);
}
////////////////////////////////////////////
`


FRAGMENT_SHADER_FLAT_TRACK :: `
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
