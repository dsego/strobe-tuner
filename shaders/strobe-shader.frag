#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Output fragment color
out vec4 finalColor;

const float TAU = radians(360);

// Uniforms
uniform vec4 bounding_rect;
uniform float curvature_radius;
uniform vec3 color_a;
uniform vec3 color_b;

uniform float time_stretch;
uniform float phase;
uniform float amp;
uniform float norm_freq;
uniform float band_height;
uniform float err_cents;
uniform float period_count;


float generate_signal(
    float freq,
    float phase,
    float amplitude,
    float time,
    float time_stretch,
    float period_count
) {
    time = time * time_stretch;
    float value = amplitude * sin(period_count * (freq * TAU * time + phase));

    // convert from range [-1, 1] to [0, 1]
    value = 0.5 * value + 0.5;
    value = max(min(value, 1.0), 0.0);

    return value;
}

float draw_curved_track(
    vec2 size,
    float thickness,
    float outer_radius,
    float feathering,
    vec2 distance
) {
    float radial_position = length(distance); // sqrt((x * x) + (y * y))
    float inner_radius = outer_radius - thickness;

    float outerCircle = smoothstep(outer_radius, outer_radius - feathering, abs(radial_position));
    float innerCircle = smoothstep(inner_radius, inner_radius - feathering, abs(radial_position));

    float donut = outerCircle - innerCircle;

    return donut;
}



void main()
{
    // Viewport resolution (extract width & height)
    vec2 size = bounding_rect.zw;

    // Position in pixels
    vec2 position = fragTexCoord * size;
    float feathering = 2; // 2 px feathering for smoothstep

    // Define the thickness of our donut shape (track), leave a gap between tracks
    float thickness = band_height - 4;

    // Calculate the center so the circle touches the top of the viewport
    // vertically and is centered horizontally
    vec2 center = vec2(0.5 * size.x, curvature_radius);

    // This is the pixel position in terms of distance from the circle center
    vec2 distance = center - position.xy;

    // Color the pixel at position based on whether it sits in the donut shape
    float curved_track = draw_curved_track(size, thickness, curvature_radius, feathering, distance);


    // Color in the generated strobe signal

    // TODO: color glow effect based on distance from center of strobe!!!

    // Current pixel angle
    float angle = atan(distance.y, distance.x);

    // Time is translated from the linear to radial
    float time = angle / TAU;

    float value = generate_signal(
        norm_freq,
        phase,
        amp,
        time,
        time_stretch,
        period_count
    );


    // Blend colors
    vec3 rgb = mix(color_a, color_b, value);

    finalColor = vec4(rgb, curved_track);
}
