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


// Metal version of vulkan/strobe.frag, keep the two in sync.

#include <metal_stdlib>
using namespace metal;

struct FragmentIn {
    float4 position [[position]];
    float2 uv [[user(uv)]];
    float4 color [[user(color)]];
};

// Same layout as StrobeUniforms in src/gfx/gfx.odin
struct StrobeUniforms {
    float4 bounding_rect;
    float4 color_a;
    float4 color_b;
    float4 glow_filter; // what the glow's lamp shines through, normalized and squared on the CPU, see glow_filter in strobe_display.odin
    float4 glow_dark_filter; // the dark stripes can have a hue of their own
    float4 highlight_color; // outline of the selected track
    float curvature_radius;
    float time_stretch;
    float phase;
    float phase_step; // change of phase since the previous frame
    float glow_spread; // angular width of the glow's hotspot in radians
    float glow_exposure; // how hard the glow's lamp drives the exposure curve, higher washes lit stripes out
    float glow_saturation; // 1 keeps the full color, lower mixes in gray
    float amp; // stripe sharpness
    float visibility; // 0..1, fades the stripes out when the signal is buried in noise
    float norm_freq;
    float band_height;
    float period_count;
    float min_radius;
    float max_radius;
    float highlight; // 0..1, outlines the track whose sheet is open
    float dim; // 0..1, darkens the other tracks meanwhile
    float min_edge_width; // the narrowest a stripe's edge gets in points, 0 for as amp has it, see strobe_fragment
    int strobe_blur;
    int motion_blur;
    int glow;
    int flat_track; // the top of the arc straightened, see strobe_fragment
};

constant float TAU = 6.28318530717958647692;

// Share of the glow's lamp light the dark stripes let through
constant float DARK_TRANSMISSION = 0.3;

// The selected track: its outline along both edges, inside the track, and how much the others darken
constant float OUTLINE_WIDTH = 1.0;
constant float DIM_AMOUNT = 0.65;

// Between the tracks, a track is this much thinner than band_height, STROBE_TRACK_GAP in strobe_display.odin
constant float TRACK_GAP = 4.0;


// The stripes' sine at a pixel goes by this angle
static float stripe_angle(float freq, float phase, float time, float time_stretch, float period_count)
{
    return period_count * (freq * TAU * (time * time_stretch) + phase);
}

static float generate_signal(
    float freq,
    float phase,
    float amplitude,
    float visibility,
    float time,
    float time_stretch,
    float period_count,
    bool strobe_blur
) {
    float value = 0.0;
    float sinewave = sin(stripe_angle(freq, phase, time, time_stretch, period_count));

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

// The stripes' running total from angle 0, the clipped sine of generate_signal at full height added up. It
// climbs over the lit half of a period and comes back down over the dark half, a whole period adds up to
// nothing. clip_angle is where the sine reaches full brightness and turns flat, 0 for a square wave.
static float stripe_integral(float angle, float amplitude, float clip_angle)
{
    const float HALF_PERIOD = 0.5 * TAU;

    angle -= TAU * floor(angle / TAU);
    bool dark = angle >= HALF_PERIOD;
    float within = dark ? angle - HALF_PERIOD : angle;

    // The sine rising to the clip, flat at full brightness, then falling from it
    float rise = min(within, clip_angle);
    float plateau = clamp(within, clip_angle, HALF_PERIOD - clip_angle);
    float fall = max(within, HALF_PERIOD - clip_angle);
    float total = amplitude * (1.0 - cos(rise)) + (plateau - clip_angle) - amplitude * (cos(clip_angle) + cos(fall));

    // The dark half takes back what the lit half added
    float lit_half = 2.0 * amplitude * (1.0 - cos(clip_angle)) + HALF_PERIOD - 2.0 * clip_angle;
    return dark ? lit_half - total : total;
}

// Average the signal over the phase swept since the previous frame, like a camera shutter would.
// Without it the pattern aliases (wagon wheel effect) and shimmers once it moves close to
// half a period per frame. Exactly: the stripes' running total now less the one a frame ago, over the
// sweep, see stripe_integral.
static float generate_blurred_signal(
    float freq,
    float phase,
    float phase_step,
    float amplitude,
    float visibility,
    float time,
    float time_stretch,
    float period_count,
    bool strobe_blur
) {
    // Radians of the pattern swept during one frame, signed, and how far
    float pattern_step = period_count * phase_step;
    float sweep = abs(pattern_step);

    // Barely moving, the two running totals would be too close to tell apart in a float
    if (sweep < 0.05) {
        return generate_signal(freq, phase, amplitude, visibility, time, time_stretch, period_count, strobe_blur);
    }

    // A full period or more averages out to a flat colour, the pattern carries no information
    if (sweep >= TAU) {
        return 0.5;
    }

    // The sine turns flat where it clips at full brightness. A square wave is flat from the start, as high
    // as the amplitude lets it.
    float clip_angle = 0.25 * TAU;
    float height = 1.0;
    if (!strobe_blur) {
        clip_angle = 0.0;
        height = min(amplitude, 1.0);
    } else if (amplitude > 1.0) {
        clip_angle = asin(1.0 / amplitude);
    }

    // Brought within a period before the step is taken off, on the outer tracks the angle is thousands of
    // radians, too coarse in a float for the difference of the totals
    float angle = stripe_angle(freq, phase, time, time_stretch, period_count);
    angle -= TAU * floor(angle / TAU);

    float swept = stripe_integral(angle, amplitude, clip_angle) -
        stripe_integral(angle - pattern_step, amplitude, clip_angle);
    float value = visibility * height * swept / pattern_step;

    // convert from range -1..1 to 0..1
    return 0.5 * value + 0.5;
}

static float draw_curved_track(float thickness, float outer_radius, float feathering, float radial_position)
{
    float inner_radius = outer_radius - thickness;

    float outer_circle = smoothstep(outer_radius, outer_radius - feathering, abs(radial_position));
    float inner_circle = smoothstep(inner_radius, inner_radius - feathering, abs(radial_position));

    return outer_circle - inner_circle;
}

// The Retro glow setting, the stripes lit like an old mechanical strobe tuner's: a lamp behind the disc shines
// through it, brightest in a hotspot at the top. Not the Lamp display.
static float3 glow_color(constant StrobeUniforms &u, float signal_value, float radial_position, float angle)
{
    // Stripes drawn in color_a are the lit ones
    float lit = 1.0 - signal_value;

    // The lamp's hotspot sits behind the inner band at the top centre of the arcs.
    // The outer bands fall off in brightness, so each band gets its own tone.
    float radial_t = (radial_position - u.min_radius) / max(u.max_radius - u.min_radius, 1.0);
    float angle_offset = (angle - 0.25 * TAU) / u.glow_spread;
    float hotspot = exp(-angle_offset * angle_offset - 2.0 * radial_t * radial_t);

    // Light model: the lamp shines through a colored filter, the stripes modulate how much gets through.
    // Dark stripes still pass some light, so they read as deep saturated color rather than an opaque surface.
    float exposure = mix(0.6, 1.0, hotspot) * u.glow_exposure;

    // Exposure curve per channel, bright light rolls off from saturated color towards pale gold/white,
    // dim light stays deep and saturated. Only the fully lit and fully dark colors go through the curve,
    // in between is a linear blend. Otherwise the mid tones (soft stripe edges, a weak strobe fading out)
    // pick up the curve's most saturated color and show up as red fringes.
    float3 lit_rgb = 1.0 - exp(-exposure * u.glow_filter.rgb);
    float3 dark_rgb = 1.0 - exp(-DARK_TRANSMISSION * exposure * u.glow_dark_filter.rgb);
    float3 rgb = mix(dark_rgb, lit_rgb, lit);

    return mix(float3(dot(rgb, float3(0.299, 0.587, 0.114))), rgb, u.glow_saturation);
}


fragment float4 strobe_fragment(FragmentIn in [[stage_in]], constant StrobeUniforms &u [[buffer(0)]])
{
    // Viewport resolution (extract width & height)
    float2 size = u.bounding_rect.zw;

    // Position in pixels
    float2 position = in.uv * size;
    float feathering = 2.0; // 2 px feathering for smoothstep

    // Define the thickness of our donut shape (track), leave a gap between tracks
    float thickness = u.band_height - TRACK_GAP;

    // Calculate the center so the circle touches the top of the viewport
    // vertically and is centered horizontally
    float2 center = float2(0.5 * size.x, u.curvature_radius);

    // This is the pixel position in terms of distance from the circle center
    float2 distance = center - position;
    float radial_position = length(distance);

    // Current pixel angle
    float angle = atan2(distance.y, distance.x);

    // Flat, the top of the arc straightened: the radius is the distance down from the top of the quad and
    // the angle grows to the right as on the innermost track's top, every track has as many stripes across
    if (u.flat_track > 0) {
        radial_position = u.curvature_radius - position.y;
        angle = 0.25 * TAU + (position.x - center.x) / (u.min_radius + u.band_height);
    }

    // Color the pixel at position based on whether it sits in the donut shape
    float curved_track = draw_curved_track(thickness, u.curvature_radius, feathering, radial_position);

    // Most of the quad is outside the arc, skip the signal there, it's the costly part with the motion blur
    if (curved_track <= 0.0) {
        return float4(0.0);
    }

    // Time is translated from the linear to radial
    float time = angle / TAU;

    // How fast the stripes' sine changes across them here, per point: on an arc by its radius, flat as on the
    // innermost track's top
    float angle_per_point = 1.0 / radial_position;
    if (u.flat_track > 0) angle_per_point = 1.0 / (u.min_radius + u.band_height);

    float sine_per_point = u.period_count * u.time_stretch * u.norm_freq * angle_per_point;

    // An edge spans 2 / amp of the sine, never narrower than min_edge_width. See MIN_EDGE_PIXELS in
    // strobe_display.odin.
    float amp = u.amp;
    if (u.min_edge_width > 0.0) amp = min(amp, 2.0 / (u.min_edge_width * sine_per_point));

    float signal_value = generate_blurred_signal(
        u.norm_freq,
        u.phase,
        u.motion_blur > 0 ? u.phase_step : 0.0,
        amp,
        u.visibility,
        time,
        u.time_stretch,
        u.period_count,
        u.strobe_blur > 0
    );

    // The colors blended, or with Retro glow on lit by the lamp behind the disc, see glow_color
    float3 rgb;
    if (u.glow > 0) {
        rgb = glow_color(u, signal_value, radial_position, angle);
    } else {
        rgb = mix(u.color_a.rgb, u.color_b.rgb, signal_value);
    }
    float alpha = curved_track;

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

    return float4(rgb, alpha);
}
