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


// Vulkan version of metal/strobe.metal, keep the two in sync.

#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

// Same layout as StrobeUniforms in src/gfx/gfx.odin
layout(set = 3, binding = 0) uniform StrobeUniforms {
    vec4 bounding_rect;
    vec4 color_a;
    vec4 color_b;
    vec4 glow_filter; // lamp filter, normalized and squared on the CPU, see glow_filter in strobe_display.odin
    vec4 glow_dark_filter; // the dark stripes can have a hue of their own
    vec4 highlight_color; // outline of the selected track
    float curvature_radius;
    float time_stretch;
    float phase;
    float lamp_spread; // angular width of the lamp hotspot in radians
    float glow_exposure; // how hard the lamp drives the exposure curve, higher washes lit stripes out
    float glow_saturation; // 1 keeps the full color, lower mixes in gray
    float amp; // stripe sharpness
    float visibility; // 0..1, fades the stripes out when the signal is buried in noise
    float norm_freq;
    float band_height;
    float err_cents;
    float period_count;
    float min_radius;
    float max_radius;
    float highlight; // 0..1, outlines the track whose sheet is open
    float dim; // 0..1, darkens the other tracks meanwhile
    int strobe_blur;
    int glow;
    int flat_track; // the top of the arc straightened, see main
} u;

const float TAU = 6.28318530717958647692;

// Share of the lamp light the dark stripes let through
const float DARK_TRANSMISSION = 0.3;

// The selected track: its outline along both edges, inside the track, and how much the others darken
const float OUTLINE_WIDTH = 1.0;
const float DIM_AMOUNT = 0.65;


float generate_signal(
    float freq,
    float phase,
    float amplitude,
    float visibility,
    float time,
    float time_stretch,
    float period_count,
    bool strobe_blur
) {
    time = time * time_stretch;

    float value = 0.0;
    float sinewave = sin(period_count * (freq * TAU * time + phase));

    if (strobe_blur) {
        value = amplitude * sinewave;
    } else {
        value = amplitude * sign(sinewave);
    }
    value = visibility * clamp(value, -1.0, 1.0);

    // convert from range -1..1 to 0..1
    value = 0.5 * value + 0.5;

    return value;
}

float draw_curved_track(float thickness, float outer_radius, float feathering, float radial_position)
{
    float inner_radius = outer_radius - thickness;

    float outer_circle = smoothstep(outer_radius, outer_radius - feathering, abs(radial_position));
    float inner_circle = smoothstep(inner_radius, inner_radius - feathering, abs(radial_position));

    return outer_circle - inner_circle;
}


void main()
{
    // Viewport resolution (extract width & height)
    vec2 size = u.bounding_rect.zw;

    // Position in pixels
    vec2 position = frag_uv * size;
    float feathering = 2.0; // 2 px feathering for smoothstep

    // Define the thickness of our donut shape (track), leave a gap between tracks
    float thickness = u.band_height - 4.0;

    // Calculate the center so the circle touches the top of the viewport
    // vertically and is centered horizontally
    vec2 center = vec2(0.5 * size.x, u.curvature_radius);

    // This is the pixel position in terms of distance from the circle center
    vec2 distance = center - position;
    float radial_position = length(distance);

    // Current pixel angle
    float angle = atan(distance.y, distance.x);

    // Flat, the top of the arc straightened: the radius is the distance down from the top of the quad and
    // the angle grows to the right as on the innermost track's top, every track has as many stripes across
    if (u.flat_track > 0) {
        radial_position = u.curvature_radius - position.y;
        angle = 0.25 * TAU + (position.x - center.x) / (u.min_radius + u.band_height);
    }

    // Color the pixel at position based on whether it sits in the donut shape
    float curved_track = draw_curved_track(thickness, u.curvature_radius, feathering, radial_position);

    // Most of the quad is outside the arc, skip the signal there
    if (curved_track <= 0.0) {
        out_color = vec4(0.0);
        return;
    }

    // Time is translated from the linear to radial
    float time = angle / TAU;

    float signal_value = generate_signal(
        u.norm_freq,
        u.phase,
        u.amp,
        u.visibility,
        time,
        u.time_stretch,
        u.period_count,
        u.strobe_blur > 0
    );

    // Blend colors
    vec3 rgb = mix(u.color_a.rgb, u.color_b.rgb, signal_value);
    float alpha = curved_track;

    if (u.glow > 0) {
        // Emulate a lamp shining through a strobe disc, like the old mechanical strobe tuners

        // Stripes drawn in color_a are the lit ones
        float lit = 1.0 - signal_value;

        // Lamp hotspot, sits behind the inner band at the top centre of the arcs.
        // The outer bands fall off in brightness, so each band gets its own tone.
        float radial_t = (radial_position - u.min_radius) / max(u.max_radius - u.min_radius, 1.0);
        float angle_offset = (angle - 0.25 * TAU) / u.lamp_spread;
        float hotspot = exp(-angle_offset * angle_offset - 2.0 * radial_t * radial_t);

        // Light model: the lamp shines through a colored filter, the stripes modulate how much gets through.
        // Dark stripes still pass some light, so they read as deep saturated color rather than an opaque surface.
        float lamp = mix(0.6, 1.0, hotspot) * u.glow_exposure;

        // Exposure curve per channel, bright light rolls off from saturated color towards pale gold/white,
        // dim light stays deep and saturated. Only the fully lit and fully dark colors go through the curve,
        // in between is a linear blend. Otherwise the mid tones (soft stripe edges, a weak strobe fading out)
        // pick up the curve's most saturated color and show up as red fringes.
        vec3 lit_rgb = 1.0 - exp(-lamp * u.glow_filter.rgb);
        vec3 dark_rgb = 1.0 - exp(-DARK_TRANSMISSION * lamp * u.glow_dark_filter.rgb);
        rgb = mix(dark_rgb, lit_rgb, lit);
        rgb = mix(vec3(dot(rgb, vec3(0.299, 0.587, 0.114))), rgb, u.glow_saturation);
    }

    // The outline follows the arc, the distance to the nearer edge of the track. The edges are where the
    // feathering is halfway, the outer one fades inside the radius and the inner one outside it.
    if (u.highlight > 0.0) {
        float outer_edge = u.curvature_radius - 0.5 * feathering;
        float inner_edge = u.curvature_radius - thickness - 0.5 * feathering;
        float edge = min(radial_position - inner_edge, outer_edge - radial_position);
        float outline = 1.0 - smoothstep(OUTLINE_WIDTH - 0.5, OUTLINE_WIDTH + 0.5, edge);
        rgb = mix(rgb, u.highlight_color.rgb, u.highlight * outline);
    }
    rgb *= 1.0 - DIM_AMOUNT * u.dim;

    out_color = vec4(rgb, alpha);
}
