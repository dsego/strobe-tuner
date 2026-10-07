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
// Bloom passes for the strobe glow:
//   mode 0 - downsample the strobe and keep only the bright parts (the background shouldn't glow)
//   mode 1 - one direction of a separable gaussian blur

#include <metal_stdlib>
using namespace metal;

struct FragmentIn {
    float4 position [[position]];
    float2 uv [[user(uv)]];
    float4 color [[user(color)]];
};

// Same layout as BloomUniforms in src/gfx/gfx.odin
struct BloomUniforms {
    float2 texel_step; // mode 0: source texel size, mode 1: blur step (texel size * direction * spacing)
    int mode;
};

constant int BLUR_RADIUS = 6;
constant float BLUR_SIGMA = 3.0; // in taps

fragment float4 bloom_fragment(
    FragmentIn in [[stage_in]],
    constant BloomUniforms &u [[buffer(0)]],
    texture2d<float> texture0 [[texture(0)]],
    sampler sampler0 [[sampler(0)]]
) {
    if (u.mode == 0) {
        // 4 bilinear taps cover a 4x4 block of source texels, avoids shimmer from skipping pixels
        float3 c = texture0.sample(sampler0, in.uv + u.texel_step * float2(-1.0, -1.0)).rgb;
        c += texture0.sample(sampler0, in.uv + u.texel_step * float2(1.0, -1.0)).rgb;
        c += texture0.sample(sampler0, in.uv + u.texel_step * float2(-1.0, 1.0)).rgb;
        c += texture0.sample(sampler0, in.uv + u.texel_step * float2(1.0, 1.0)).rgb;
        c *= 0.25;

        // Soft threshold on the brightest channel, only the lit stripes bloom (a pure red counts as bright)
        float peak = max(c.r, max(c.g, c.b));
        c *= smoothstep(0.35, 0.9, peak);

        return float4(c, 1.0);
    }

    float3 sum = float3(0.0);
    float weight_sum = 0.0;
    for (int i = -BLUR_RADIUS; i <= BLUR_RADIUS; i++) {
        float w = exp(-float(i * i) / (2.0 * BLUR_SIGMA * BLUR_SIGMA));
        sum += texture0.sample(sampler0, in.uv + u.texel_step * float(i)).rgb * w;
        weight_sum += w;
    }
    return float4(sum / weight_sum, 1.0);
}
