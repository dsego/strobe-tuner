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


// Vulkan version of metal/shadow.metal, keep the two in sync.
//
// The inner shadow that sets the strobe into the window: dark along the inside of a rounded rectangle,
// fading out away from its edges. The rounded corners curve the shade around them, darker than the two
// edges together.

#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

// Same layout as ShadowUniforms in app/gfx.odin
layout(set = 3, binding = 0) uniform ShadowUniforms {
    vec4 shape; // the rounded rectangle, min x and y then max x and y, in points of the quad
    vec2 size; // the quad, in points
} u;

const float CORNER_RADIUS = 19.0; // points
const float REACH = 15.0; // points from the edge, where the shade has faded out
const float DARKNESS = 0.29; // on the edge
const float FALLOFF = 1.7; // the curve of the fade

void main()
{
    vec2 position = frag_uv * u.size;

    // Signed distance to the rounded rectangle, negative inside
    vec2 center = 0.5 * (u.shape.xy + u.shape.zw);
    vec2 half_size = 0.5 * (u.shape.zw - u.shape.xy);
    vec2 corner = abs(position - center) - half_size + CORNER_RADIUS;
    float edge_distance = length(max(corner, 0.0)) + min(max(corner.x, corner.y), 0.0) - CORNER_RADIUS;

    float shade = DARKNESS * pow(max(1.0 + edge_distance / REACH, 0.0), FALLOFF);
    out_color = vec4(0.0, 0.0, 0.0, min(shade, 1.0));
}
