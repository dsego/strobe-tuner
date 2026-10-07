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


// Vulkan version of metal/scope.metal, keep the two in sync.
//
// The scope's screen, a texel a cell, its value how bright the beam left the cell. Every lit cell is a round
// dot wider than the cell, the dots of neighbouring cells overlap like alpha blended ones and add up to a
// thicker and brighter beam.

#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D texture0;

// Same layout as ScopeUniforms in src/gfx/gfx.odin
layout(set = 3, binding = 0) uniform ScopeUniforms {
    vec4 color; // the beam's, its alpha the brightness
    vec2 cells; // the screen's columns and rows, the texture's size
    vec2 cell_size; // of a cell, in points
    float radius; // of the beam's dot round each cell, in points
} u;

const int MAX_REACH = 4; // cells a dot reaches over at most

void main()
{
    // In cells, the middle of the first one at 0
    vec2 cell = frag_uv * u.cells - 0.5;
    vec2 nearest = floor(cell + 0.5);
    int reach = min(int(ceil((u.radius + 0.5) / min(u.cell_size.x, u.cell_size.y))), MAX_REACH);

    // Each dot lets through what's behind it by what it doesn't cover
    float through = 1.0;
    for (int dy = -reach; dy <= reach; dy++) {
        for (int dx = -reach; dx <= reach; dx++) {
            vec2 neighbour = nearest + vec2(dx, dy);
            if (any(lessThan(neighbour, vec2(0.0))) || any(greaterThanEqual(neighbour, u.cells))) continue;

            // At the texel's middle the linear sampler gives the texel as it is
            float lit = texture(texture0, (neighbour + 0.5) / u.cells).r;
            if (lit == 0.0) continue;

            // An antialiased disc, its edge half a point either side of the radius
            float distance = length((cell - neighbour) * u.cell_size);
            float covered = clamp(u.radius - distance + 0.5, 0.0, 1.0);
            through *= 1.0 - lit * covered;
        }
    }
    out_color = vec4(u.color.rgb, (1.0 - through) * u.color.a);
}
