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


// Vulkan version of vertex_main in metal/sprite.metal, keep the two in sync.
//
// The vertex shader for everything. Bindings follow SDL GPU: vertex uniform slot N is set 1, binding N.
// SDL flips the Vulkan viewport, clip space y points up as in Metal.

#version 450

layout(location = 0) in vec2 position; // in drawing coordinates, pixels at 1x
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

layout(set = 1, binding = 0) uniform View {
    vec4 transform; // xy: scale to clip space, zw: drawing position of the target's top left corner
} view;

void main()
{
    vec2 p = (position - view.transform.zw) * view.transform.xy;

    gl_Position = vec4(p.x - 1.0, 1.0 - p.y, 0.0, 1.0);
    frag_uv = uv;
    frag_color = color;
}
