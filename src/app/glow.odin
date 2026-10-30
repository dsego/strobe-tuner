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


package app

import "core:math"

import "../gfx"

// Bloom for the strobe glow, rendered at a fraction of the strobe size since it gets blurred anyway
BLOOM_DOWNSCALE :: 2
BLOOM_TAP_SPACING :: 1.5 // blur taps spaced apart for a wider glow at the same cost
BLOOM_ITERATIONS :: 2

// The retro glow's render targets, shared by the displays that glow: the strobe and the scope.
// A display is rendered into scene_rt and blurred through bloom_rt.
GlowTargets :: struct {
    scene_rt: gfx.RenderTarget,
    bloom_rt: [2]gfx.RenderTarget,
    scale:    f32, // DPI scale the render targets were created for
    size:     [2]f32, // and the display's size in points
    bloom:    [2]f32, // and the bloom targets' size, see ensure_glow_targets
    // Counts up whenever what the targets held is gone, made again or drawn over by another display than the
    // strobe, which draws a dark strobe again from them as it was, see draw_strobe_display
    version:  int,
}

unload_glow_targets :: proc(self: ^GlowTargets) {
    if self.scale == 0 do return

    gfx.unload_render_target(self.scene_rt)
    for rt in self.bloom_rt {
        gfx.unload_render_target(rt)
    }
    self.scale = 0
    self.version += 1
}

// (Re)create the glow render targets, the scene is rendered at the display's DPI scale to stay sharp, the
// bloom in the window's own points so the glow spreads the same at any UI scale
ensure_glow_targets :: proc(self: ^GlowTargets, size: [2]f32) {
    scale := gfx.dpi_scale()
    bloom := size * gfx.ui_scale() / BLOOM_DOWNSCALE
    if scale == self.scale && size == self.size && bloom == self.bloom do return

    unload_glow_targets(self)

    // Rounded, a tablet's UI scale can leave 1365.9999 pixels
    self.scene_rt = gfx.load_render_target(i32(math.round(size.x * scale)), i32(math.round(size.y * scale)))
    for &rt in self.bloom_rt {
        rt = gfx.load_render_target(i32(math.round(bloom.x)), i32(math.round(bloom.y)))
    }
    self.scale = scale
    self.size = size
    self.bloom = bloom
}

// A view other than the strobe drawn with the glow, between begin_glow and end_glow: offscreen, as large
// as rect and cut off outside it, then over the screen with its bloom added passes times over
begin_glow :: proc(self: ^GlowTargets, rect: gfx.Rect, background: gfx.Color) {
    ensure_glow_targets(self, {rect.width, rect.height})
    gfx.begin_render_target(self.scene_rt, background, {rect.x, rect.y}, self.scale)
}

end_glow :: proc(self: ^GlowTargets, rect: gfx.Rect, passes: int) {
    gfx.end_render_target()
    render_bloom(self)

    // Not the strobe's any more
    self.version += 1

    gfx.set_blend_mode(.REPLACE)
    gfx.draw_render_target(self.scene_rt, rect)
    gfx.set_blend_mode(.ADD)
    for _ in 0 ..< passes {
        gfx.draw_render_target(self.bloom_rt[0], rect)
    }
    gfx.set_blend_mode(.ALPHA)
}

// Separable gaussian blur, ping-pongs between the two targets and ends up in rts[0]
blur_render_targets :: proc(rts: [2]gfx.RenderTarget, iterations: int, tap_spacing: f32) {
    size := gfx.render_target_size(rts[0])
    dest := gfx.Rect{0, 0, size.x, size.y}

    uniforms := gfx.BloomUniforms {
        mode = 1,
    }
    for _ in 0 ..< iterations {
        uniforms.texel_step = {tap_spacing / size.x, 0}
        gfx.set_shader_uniforms(.BLOOM, &uniforms)
        gfx.begin_render_target(rts[1], nil)
        gfx.draw_render_target(rts[0], dest)
        gfx.end_render_target()

        uniforms.texel_step = {0, tap_spacing / size.y}
        gfx.set_shader_uniforms(.BLOOM, &uniforms)
        gfx.begin_render_target(rts[0], nil)
        gfx.draw_render_target(rts[1], dest)
        gfx.end_render_target()
    }
}

render_bloom :: proc(self: ^GlowTargets) {
    gfx.set_blend_mode(.REPLACE)
    defer gfx.set_blend_mode(.ALPHA)

    gfx.begin_shader(.BLOOM)
    defer gfx.end_shader()

    // Downsample and keep the bright parts
    scene_size := gfx.render_target_size(self.scene_rt)
    uniforms := gfx.BloomUniforms {
        mode       = 0,
        texel_step = 1.0 / scene_size,
    }
    gfx.set_shader_uniforms(.BLOOM, &uniforms)
    bloom_size := gfx.render_target_size(self.bloom_rt[0])

    // Each pass replaces every pixel of its target, nothing to clear
    gfx.begin_render_target(self.bloom_rt[0], nil)
    gfx.draw_render_target(self.scene_rt, {0, 0, bloom_size.x, bloom_size.y})
    gfx.end_render_target()

    blur_render_targets(self.bloom_rt, BLOOM_ITERATIONS, BLOOM_TAP_SPACING)
}
