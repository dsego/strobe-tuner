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


package gfx

import "core:math/linalg"

// Rendering and input on SDL3 GPU: Metal shaders in src/shaders/metal/ on macOS and iOS, Vulkan shaders in
// src/shaders/vulkan/ on Linux and Android.


// Building for iOS, see platform/ios/build-sim.sh
IOS :: #config(IOS, false)

// Building for Android, see platform/android/build.sh
ANDROID :: ODIN_PLATFORM_SUBTARGET == .Android

// A phone: touch sized controls, portrait, suspended in the background, the system picks the input
MOBILE :: IOS || ANDROID


Rect :: struct {
    x, y, width, height: f32,
}

// An item of the macOS menu bar, see menu_darwin.odin
MenuItem :: struct {
    title:   cstring, // nil for a separator
    key:     cstring, // with Command, nil for none
    command: int, // what menu_command returns when it's chosen, from 1 to under MAX_MENU_COMMANDS, 0 greys it out
}

MAX_MENU_COMMANDS :: 64

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
    TAB,
    SPACE,
    COMMA,
    ESCAPE,
    C,
    G,
    I,
    W,
    NUM_0,
    NUM_1,
    NUM_2,
    NUM_3,
    NUM_4,
    NUM_5,
    LEFT_SUPER,
    RIGHT_SUPER,
    LEFT_CONTROL,
    RIGHT_CONTROL,
}

BlendMode :: enum {
    ALPHA,
    REPLACE, // overwrite the destination, render targets carry no meaningful alpha
    ADD,
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
