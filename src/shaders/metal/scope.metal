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


// Metal version of vulkan/scope.frag, keep the two in sync.
//
// The scope's screen, a texel a cell, its value how bright the beam left the cell. Every lit cell is a round
// dot wider than the cell, the dots of neighbouring cells overlap like alpha blended ones and add up to a
// thicker and brighter beam.

#include <metal_stdlib>
using namespace metal;

struct FragmentIn {
    float4 position [[position]];
    float2 uv [[user(uv)]];
    float4 color [[user(color)]];
};

// Same layout as ScopeUniforms in src/gfx/gfx.odin
struct ScopeUniforms {
    float4 color; // the beam's, its alpha the brightness
    float2 cells; // the screen's columns and rows, the texture's size
    float2 cell_size; // of a cell, in points
    float radius; // of the beam's dot round each cell, in points
};

constant int MAX_REACH = 4; // cells a dot reaches over at most

fragment float4 scope_fragment(
    FragmentIn in [[stage_in]],
    constant ScopeUniforms &u [[buffer(0)]],
    texture2d<float> texture0 [[texture(0)]],
    sampler sampler0 [[sampler(0)]]
) {
    // In cells, the middle of the first one at 0
    float2 cell = in.uv * u.cells - 0.5;
    float2 nearest = floor(cell + 0.5);
    int reach = min(int(ceil((u.radius + 0.5) / min(u.cell_size.x, u.cell_size.y))), MAX_REACH);

    // Each dot lets through what's behind it by what it doesn't cover
    float through = 1.0;
    for (int dy = -reach; dy <= reach; dy++) {
        for (int dx = -reach; dx <= reach; dx++) {
            float2 neighbour = nearest + float2(dx, dy);
            if (any(neighbour < 0.0) || any(neighbour >= u.cells)) continue;

            // At the texel's middle the linear sampler gives the texel as it is
            float lit = texture0.sample(sampler0, (neighbour + 0.5) / u.cells).r;
            if (lit == 0.0) continue;

            // An antialiased disc, its edge half a point either side of the radius
            float distance = length((cell - neighbour) * u.cell_size);
            float covered = clamp(u.radius - distance + 0.5, 0.0, 1.0);
            through *= 1.0 - lit * covered;
        }
    }
    return float4(u.color.rgb, (1.0 - through) * u.color.a);
}
