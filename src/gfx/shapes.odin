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

// Rounded shapes are cut from one white anti-aliased circle generated at startup and tinted when drawn:
// the quarters make the corners, the middle row and column stretch into the straight edges.

// Pixels, a 24pt pill at 2x, the size of all the buttons
SHAPE_SIZE :: 48

shape_texture: Texture

load_shapes :: proc() {
    pixels: [SHAPE_SIZE * SHAPE_SIZE * 4]u8
    radius: f32 = SHAPE_SIZE / 2

    for y in 0 ..< SHAPE_SIZE {
        for x in 0 ..< SHAPE_SIZE {
            // Distance from the pixel centre to the edge covers the pixel partially
            distance := linalg.length([2]f32{f32(x) + 0.5, f32(y) + 0.5} - radius)
            coverage := clamp(radius - distance + 0.5, 0, 1)

            pixel := (y * SHAPE_SIZE + x) * 4
            pixels[pixel + 0] = 255
            pixels[pixel + 1] = 255
            pixels[pixel + 2] = 255
            pixels[pixel + 3] = u8(coverage * 255 + 0.5)
        }
    }

    shape_texture = load_texture_rgba(SHAPE_SIZE, SHAPE_SIZE, pixels[:])
}

unload_shapes :: proc() {
    unload_texture(shape_texture)
}

draw_rounded_rect :: proc(rect: Rect, radius: f32, color: Color) {
    corner := min(radius, rect.width / 2, rect.height / 2)
    half: f32 = SHAPE_SIZE / 2

    left, right := rect.x, rect.x + rect.width - corner
    top, bottom := rect.y, rect.y + rect.height - corner
    inner := [2]f32{rect.width - 2 * corner, rect.height - 2 * corner}

    // Corners
    draw_texture(shape_texture, {0, 0, half, half}, {left, top, corner, corner}, color)
    draw_texture(shape_texture, {half, 0, half, half}, {right, top, corner, corner}, color)
    draw_texture(shape_texture, {0, half, half, half}, {left, bottom, corner, corner}, color)
    draw_texture(shape_texture, {half, half, half, half}, {right, bottom, corner, corner}, color)

    // Edges
    if inner.x > 0 {
        draw_texture(shape_texture, {half - 0.5, 0, 1, half}, {left + corner, top, inner.x, corner}, color)
        draw_texture(shape_texture, {half - 0.5, half, 1, half}, {left + corner, bottom, inner.x, corner}, color)
    }
    if inner.y > 0 {
        draw_texture(shape_texture, {0, half - 0.5, half, 1}, {left, top + corner, corner, inner.y}, color)
        draw_texture(shape_texture, {half, half - 0.5, half, 1}, {right, top + corner, corner, inner.y}, color)
    }

    if inner.x > 0 && inner.y > 0 {
        draw_rect({left + corner, top + corner}, inner, color)
    }
}

// Fully rounded ends
draw_pill :: proc(rect: Rect, color: Color) {
    draw_rounded_rect(rect, rect.height / 2, color)
}

// The whole circle stretched over rect, e.g. a dot of the scope's beam
draw_disc :: proc(rect: Rect, color: Color) {
    draw_texture(shape_texture, {0, 0, SHAPE_SIZE, SHAPE_SIZE}, rect, color)
}
