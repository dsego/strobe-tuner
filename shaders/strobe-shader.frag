// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


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
uniform float min_radius;
uniform float max_radius;


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
    // TODO: define gap in strobe display struct
    float thickness = band_height - 4;

    // Calculate the center so the circle touches the top of the viewport
    // vertically and is centered horizontally
    vec2 center = vec2(0.5 * size.x, curvature_radius);

    // This is the pixel position in terms of distance from the circle center
    vec2 distance = center - position.xy;

    // Color the pixel at position based on whether it sits in the donut shape
    float curved_track = draw_curved_track(size, thickness, curvature_radius, feathering, distance);


    // Color in the generated strobe signal

    // Current pixel angle
    float angle = atan(distance.y, distance.x);

    // Time is translated from the linear to radial
    float time = angle / TAU;

    float signal_value = generate_signal(
        norm_freq,
        phase,
        amp,
        time,
        time_stretch,
        period_count
    );


    // Blend colors
    vec3 rgb = mix(color_a, color_b, signal_value);


    // Circular gradient from center to the outer edge

    // vec3 color_a = vec3(255.0, 10.0, 125.0); // pink
    // vec3 color_b = vec3(255.0, 140.0, 20.0); // orange

    // float radial_position = length(distance);
    // float gradient_position = 1.2 * (radial_position - min_radius) / (max_radius - min_radius);
    // vec3 rgb = mix(color_b / 255.0, color_a / 255.0, gradient_position);

    finalColor = vec4(rgb, curved_track);
}
