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


package gfx

import "core:math/linalg"

// Rendering and input go through a small immediate mode API, sdl.odin implements it with SDL3 GPU: Metal
// shaders in src/shaders/metal/ on macOS and iOS, Vulkan shaders in src/shaders/vulkan/ on Linux and Android.
//
//   init(width, height, title) -> bool, shutdown()
//   should_close() -> bool              polls the window events, call once per frame
//   begin_frame(clear), end_frame()
//   frame_time() -> f32, dpi_scale() -> f32
//   window_size() -> [2]f32, safe_area() -> Rect   in points
//   in_background() -> bool, wait_for_foreground()  a phone, nothing may be drawn in the background
//   open_url(url), system_back()        the latter what Android does with its back button
//   limit_fps(fps)                      fewer frames while there's nothing to show, 0 for the display's rate
//
//   key_pressed(key), key_down(key), mouse_position(), mouse_pressed(), mouse_down(), mouse_wheel()
//
//   Texture, load_texture(png), load_texture_rgba(width, height, pixels), unload_texture(texture)
//   Font, load_font(ttf, size, codepoints), unload_font(font)
//   draw_texture(texture, source, dest, tint), negative source width/height flips the image
//   draw_rect(position, size, color), draw_rect_lines(rect, thickness, color)
//   draw_line(start, end, thickness, color), draw_circle(center, radius, color)
//   draw_text(font, text, position, size, spacing, color), measure_text(font, text, size, spacing)
//   begin_scissor(rect), end_scissor(), set_blend_mode(mode)
//   load_shapes(), draw_rounded_rect(rect, radius, color), draw_pill(rect, color), draw_disc(rect, color),
//   see shapes.odin
//
//   Shader, load_shader(kind), unload_shader(shader)
//   begin_shader(shader), end_shader(), set_shader_uniforms(shader, &uniforms)
//   draw_shader_quad(rect)              runs the active shader over rect, texcoords 0..1
//
//   RenderTarget, load_render_target(width, height), unload_render_target(target)
//   begin_render_target(target, clear, offset, zoom), end_render_target()
//   draw_render_target(target, dest, tint), render_target_size(target)


// Building for iOS, see platform/ios/build-sim.sh
IOS :: #config(IOS, false)

// Building for Android, see platform/android/build.sh
ANDROID :: ODIN_PLATFORM_SUBTARGET == .Android

// A phone: touch sized controls, portrait, suspended in the background, the system picks the input
MOBILE :: IOS || ANDROID


Rect :: struct {
    x, y, width, height: f32,
}

Color :: [4]u8

WHITE :: Color{255, 255, 255, 255}
LIGHTGRAY :: Color{200, 200, 200, 255}
GOLD :: Color{255, 203, 0, 255}
ORANGE :: Color{255, 161, 0, 255}
PINK :: Color{255, 109, 194, 255}
PURPLE :: Color{200, 122, 255, 255}

Key :: enum {
    LEFT,
    RIGHT,
    UP,
    DOWN,
    TAB,
    SPACE,
    COMMA,
    ESCAPE,
    G,
    I,
    R,
    X,
    LEFT_SHIFT,
    RIGHT_SHIFT,
    LEFT_SUPER,
    RIGHT_SUPER,
}

BlendMode :: enum {
    ALPHA,
    REPLACE, // overwrite the destination, render targets carry no meaningful alpha
    ADD,
}

ShaderKind :: enum {
    STROBE,
    BLOOM,
    SHADOW,
    SCOPE,
}

// Shader uniforms are plain structs, pushed as a uniform buffer. The layout has to match the MSL struct and
// the Vulkan uniform block (std140): vec4s first, then scalars, padded to 16 bytes.

StrobeUniforms :: struct #align (16) {
    bounding_rect:    [4]f32,
    color_a:          [4]f32,
    color_b:          [4]f32,
    glow_filter:      [4]f32, // see glow_filter in src/app/strobe_display.odin
    glow_dark_filter: [4]f32,
    highlight_color:  [4]f32, // outline of the selected track
    curvature_radius: f32,
    time_stretch:     f32,
    phase:            f32,
    phase_step:       f32, // change of phase since the previous frame
    lamp_spread:      f32, // angular width of the lamp hotspot in radians
    glow_exposure:    f32,
    glow_saturation:  f32,
    amp:              f32, // stripe sharpness
    visibility:       f32, // 0..1, fades the stripes out when the signal is buried in noise
    norm_freq:        f32,
    band_height:      f32,
    err_cents:        f32,
    period_count:     f32,
    min_radius:       f32,
    max_radius:       f32,
    highlight:        f32, // 0..1, outlines the track whose sheet is open
    dim:              f32, // 0..1, darkens the other tracks meanwhile
    strobe_blur:      i32,
    motion_blur:      i32,
    glow:             i32,
    flat_track:       i32, // the top of the arc straightened
}

BloomUniforms :: struct #align (16) {
    texel_step: [2]f32, // mode 0: source texel size, mode 1: blur step
    mode:       i32, // 0 - downsample & threshold, 1 - blur
}

ShadowUniforms :: struct #align (16) {
    shape: [4]f32, // the rounded rectangle, min x and y then max x and y, in points of the quad
    size:  [2]f32, // the quad, in points
}

ScopeUniforms :: struct #align (16) {
    color:     [4]f32, // the beam's, its alpha the brightness
    cells:     [2]f32, // the screen's columns and rows, the texture's size
    cell_size: [2]f32, // of a cell, in points
    radius:    f32, // of the beam's dot round each cell, in points
}


hex :: proc "contextless" (value: u32) -> Color {
    return {u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)}
}

normalize_color :: proc(color: Color) -> [4]f32 {
    return {f32(color.r), f32(color.g), f32(color.b), f32(color.a)} / 255.0
}

color_from_normalized :: proc(color: [4]f32) -> Color {
    scaled := linalg.clamp(color, 0, 1) * 255.0
    return {u8(scaled.r + 0.5), u8(scaled.g + 0.5), u8(scaled.b + 0.5), u8(scaled.a + 0.5)}
}

point_in_rect :: proc(point: [2]f32, rect: Rect) -> bool {
    return(
        point.x >= rect.x &&
        point.x < rect.x + rect.width &&
        point.y >= rect.y &&
        point.y < rect.y + rect.height \
    )
}

draw_line_strip :: proc(points: [][2]f32, color: Color) {
    for i in 1 ..< len(points) {
        draw_line(points[i - 1], points[i], 1, color)
    }
}
