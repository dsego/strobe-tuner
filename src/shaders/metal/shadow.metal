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


// Metal version of vulkan/shadow.frag, keep the two in sync.
//
// The inner shadow that sets the strobe into the window: dark along the inside of a rounded rectangle,
// fading out away from its edges. The rounded corners curve the shade around them, darker than the two
// edges together.

#include <metal_stdlib>
using namespace metal;

struct FragmentIn {
    float4 position [[position]];
    float2 uv [[user(uv)]];
    float4 color [[user(color)]];
};

// Same layout as ShadowUniforms in src/gfx/gfx.odin
struct ShadowUniforms {
    float4 shape; // the rounded rectangle, min x and y then max x and y, in points of the quad
    float2 size; // the quad, in points
};

constant float CORNER_RADIUS = 19.0; // points
constant float REACH = 15.0; // points from the edge, where the shade has faded out
constant float DARKNESS = 0.29; // on the edge
constant float FALLOFF = 1.7; // the curve of the fade

fragment float4 shadow_fragment(FragmentIn in [[stage_in]], constant ShadowUniforms &u [[buffer(0)]])
{
    float2 position = in.uv * u.size;

    // Signed distance to the rounded rectangle, negative inside
    float2 center = 0.5 * (u.shape.xy + u.shape.zw);
    float2 half_size = 0.5 * (u.shape.zw - u.shape.xy);
    float2 corner = abs(position - center) - half_size + CORNER_RADIUS;
    float edge_distance = length(max(corner, 0.0)) + min(max(corner.x, corner.y), 0.0) - CORNER_RADIUS;

    float shade = DARKNESS * pow(max(1.0 + edge_distance / REACH, 0.0), FALLOFF);
    return float4(0.0, 0.0, 0.0, min(shade, 1.0));
}
