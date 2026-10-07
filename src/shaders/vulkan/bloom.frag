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
// Bloom passes for the strobe glow:
//   mode 0 - downsample the strobe and keep only the bright parts (the background shouldn't glow)
//   mode 1 - one direction of a separable gaussian blur

#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D texture0;

// Same layout as BloomUniforms in src/gfx/gfx.odin
layout(set = 3, binding = 0) uniform BloomUniforms {
    vec2 texel_step; // mode 0: source texel size, mode 1: blur step (texel size * direction * spacing)
    int mode;
} u;

const int BLUR_RADIUS = 6;
const float BLUR_SIGMA = 3.0; // in taps

void main()
{
    if (u.mode == 0) {
        // 4 bilinear taps cover a 4x4 block of source texels, avoids shimmer from skipping pixels
        vec3 c = texture(texture0, frag_uv + u.texel_step * vec2(-1.0, -1.0)).rgb;
        c += texture(texture0, frag_uv + u.texel_step * vec2(1.0, -1.0)).rgb;
        c += texture(texture0, frag_uv + u.texel_step * vec2(-1.0, 1.0)).rgb;
        c += texture(texture0, frag_uv + u.texel_step * vec2(1.0, 1.0)).rgb;
        c *= 0.25;

        // Soft threshold on the brightest channel, only the lit stripes bloom (a pure red counts as bright)
        float peak = max(c.r, max(c.g, c.b));
        c *= smoothstep(0.35, 0.9, peak);

        out_color = vec4(c, 1.0);
        return;
    }

    vec3 sum = vec3(0.0);
    float weight_sum = 0.0;
    for (int i = -BLUR_RADIUS; i <= BLUR_RADIUS; i++) {
        float w = exp(-float(i * i) / (2.0 * BLUR_SIGMA * BLUR_SIGMA));
        sum += texture(texture0, frag_uv + u.texel_step * float(i)).rgb * w;
        weight_sum += w;
    }
    out_color = vec4(sum / weight_sum, 1.0);
}
