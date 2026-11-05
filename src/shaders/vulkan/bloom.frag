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


// Vulkan version of metal/bloom.metal, keep the two in sync.
//
// Bloom passes for the strobe glow, the mode:
//   DOWNSAMPLE - downsample the strobe and keep only the bright parts (the background shouldn't glow)
//   BLUR - one direction of a separable gaussian blur
//   SHRINK - the whole screen shrunk many times for the unlock's blurred backdrop, each texel the average of
//            the source's under it

#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D texture0;

// Same layout as BloomUniforms in src/gfx/gfx.odin
layout(set = 3, binding = 0) uniform BloomUniforms {
    vec2 texel_step; // DOWNSAMPLE: source texel size, BLUR: blur step (texel size * direction * spacing),
                     // SHRINK: target texel size
    int mode;
} u;

// BloomMode in src/gfx/gfx.odin
const int DOWNSAMPLE = 0;
const int BLUR = 1;
const int SHRINK = 2;

const int BLUR_RADIUS = 6;
const float BLUR_SIGMA = 3.0; // in taps

// SHRINK's bilinear taps across a target texel, each the average of 2 source texels across, up to 16 of them
const int MAX_SHRINK_TAPS = 8;

void main()
{
    if (u.mode == DOWNSAMPLE) {
        // 4 bilinear taps cover a 4x4 block of source texels, avoids shimmer from skipping pixels
        vec3 color = texture(texture0, frag_uv + u.texel_step * vec2(-1.0, -1.0)).rgb;
        color += texture(texture0, frag_uv + u.texel_step * vec2(1.0, -1.0)).rgb;
        color += texture(texture0, frag_uv + u.texel_step * vec2(-1.0, 1.0)).rgb;
        color += texture(texture0, frag_uv + u.texel_step * vec2(1.0, 1.0)).rgb;
        color *= 0.25;

        // Soft threshold on the brightest channel, only the lit stripes bloom (a pure red counts as bright)
        float peak = max(color.r, max(color.g, color.b));
        color *= smoothstep(0.35, 0.9, peak);

        out_color = vec4(color, 1.0);
        return;
    }

    if (u.mode == SHRINK) {
        // A grid of taps evenly over the block under this texel, each between 2x2 source texels, so they cover
        // all of it. A thin stripe moving across the block counts the same wherever it is.
        vec2 source_size = vec2(textureSize(texture0, 0));
        ivec2 taps = clamp(ivec2(ceil(u.texel_step * source_size / 2.0)), ivec2(1), ivec2(MAX_SHRINK_TAPS));
        vec3 sum = vec3(0.0);
        for (int row = 0; row < taps.y; row += 1) {
            for (int column = 0; column < taps.x; column += 1) {
                vec2 offset = (vec2(column, row) + 0.5) / vec2(taps) - 0.5;
                sum += texture(texture0, frag_uv + offset * u.texel_step).rgb;
            }
        }
        out_color = vec4(sum / float(taps.x * taps.y), 1.0);
        return;
    }

    vec3 sum = vec3(0.0);
    float weight_sum = 0.0;
    for (int tap = -BLUR_RADIUS; tap <= BLUR_RADIUS; tap += 1) {
        float weight = exp(-float(tap * tap) / (2.0 * BLUR_SIGMA * BLUR_SIGMA));
        sum += texture(texture0, frag_uv + u.texel_step * float(tap)).rgb * weight;
        weight_sum += weight;
    }
    out_color = vec4(sum / weight_sum, 1.0);
}
