// Copyright (C) 2026  Davorin Šego

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


// Metal version of vulkan/bloom.frag, keep the two in sync.
//
// Bloom passes for the strobe glow, the mode:
//   DOWNSAMPLE - downsample the strobe and keep only the bright parts (the background shouldn't glow)
//   BLUR - one direction of a separable gaussian blur
//   SHRINK - the whole screen shrunk many times for the unlock's blurred backdrop, each texel the average of
//            the source's under it

#include <metal_stdlib>
using namespace metal;

struct FragmentIn {
    float4 position [[position]];
    float2 uv [[user(uv)]];
    float4 color [[user(color)]];
};

// Same layout as BloomUniforms in src/gfx/gfx.odin
struct BloomUniforms {
    float2 texel_step; // DOWNSAMPLE: source texel size, BLUR: blur step (texel size * direction * spacing),
                       // SHRINK: target texel size
    int mode;
};

// BloomMode in src/gfx/gfx.odin
constant int DOWNSAMPLE = 0;
constant int BLUR = 1;
constant int SHRINK = 2;

constant int BLUR_RADIUS = 6;
constant float BLUR_SIGMA = 3.0; // in taps

// SHRINK's bilinear taps across a target texel, each the average of 2 source texels across, up to 16 of them
constant int MAX_SHRINK_TAPS = 8;

fragment float4 bloom_fragment(
    FragmentIn in [[stage_in]],
    constant BloomUniforms &u [[buffer(0)]],
    texture2d<float> texture0 [[texture(0)]],
    sampler sampler0 [[sampler(0)]]
) {
    if (u.mode == DOWNSAMPLE) {
        // 4 bilinear taps cover a 4x4 block of source texels, avoids shimmer from skipping pixels
        float3 color = texture0.sample(sampler0, in.uv + u.texel_step * float2(-1.0, -1.0)).rgb;
        color += texture0.sample(sampler0, in.uv + u.texel_step * float2(1.0, -1.0)).rgb;
        color += texture0.sample(sampler0, in.uv + u.texel_step * float2(-1.0, 1.0)).rgb;
        color += texture0.sample(sampler0, in.uv + u.texel_step * float2(1.0, 1.0)).rgb;
        color *= 0.25;

        // Soft threshold on the brightest channel, only the lit stripes bloom (a pure red counts as bright)
        float peak = max(color.r, max(color.g, color.b));
        color *= smoothstep(0.35, 0.9, peak);

        return float4(color, 1.0);
    }

    if (u.mode == SHRINK) {
        // A grid of taps evenly over the block under this texel, each between 2x2 source texels, so they cover
        // all of it. A thin stripe moving across the block counts the same wherever it is.
        float2 source_size = float2(texture0.get_width(), texture0.get_height());
        int2 taps = clamp(int2(ceil(u.texel_step * source_size / 2.0)), int2(1), int2(MAX_SHRINK_TAPS));
        float3 sum = float3(0.0);
        for (int row = 0; row < taps.y; row += 1) {
            for (int column = 0; column < taps.x; column += 1) {
                float2 offset = (float2(column, row) + 0.5) / float2(taps) - 0.5;
                sum += texture0.sample(sampler0, in.uv + offset * u.texel_step).rgb;
            }
        }
        return float4(sum / float(taps.x * taps.y), 1.0);
    }

    float3 sum = float3(0.0);
    float weight_sum = 0.0;
    for (int tap = -BLUR_RADIUS; tap <= BLUR_RADIUS; tap += 1) {
        float weight = exp(-float(tap * tap) / (2.0 * BLUR_SIGMA * BLUR_SIGMA));
        sum += texture0.sample(sampler0, in.uv + u.texel_step * float(tap)).rgb * weight;
        weight_sum += weight;
    }
    return float4(sum / weight_sum, 1.0);
}
