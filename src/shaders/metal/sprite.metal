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


// The vertex shader for everything, and the fragment shader for textured and plain 2D shapes.
// Bindings follow SDL GPU: uniform slot N is [[buffer(N)]], sampler slot N is [[texture(N)]] + [[sampler(N)]].
// The Vulkan versions are vulkan/sprite.vert and vulkan/sprite.frag, keep them in sync.

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]]; // in drawing coordinates, pixels at 1x
    float2 uv [[attribute(1)]];
    float4 color [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv [[user(uv)]];
    float4 color [[user(color)]];
};

struct View {
    float4 transform; // xy: scale to clip space, zw: drawing position of the target's top left corner
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]], constant View &view [[buffer(0)]])
{
    float2 p = (in.position - view.transform.zw) * view.transform.xy;

    VertexOut out;
    out.position = float4(p.x - 1.0, 1.0 - p.y, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

fragment float4 sprite_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> texture0 [[texture(0)]],
    sampler sampler0 [[sampler(0)]]
) {
    return texture0.sample(sampler0, in.uv) * in.color;
}
