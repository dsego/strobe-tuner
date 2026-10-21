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

package app

import "core:math"
import "core:slice"

import "../core"
import "../gfx"

// Two display types, both views of the scope in src/core/scope.odin that only draw what it gives them:
//   scope   - its screen
//   lamp   - its screen from above, stripes as bright as the wave is high, the lamp of a mechanical strobe
//
// Two periods of the strobe's frequency across. An in tune note stands still, a detuned one drifts. Both
// are mirrored to move like the strobe tracks, flat to the left and sharp to the right: the scope runs
// right to left, time the other way from an oscilloscope's, so a sawtooth leans the other way too.
// Tapped, the wave goes round a circle, petals that stand still in tune and spin clockwise when sharp.
// Tapped again, the scope draws the wave against the strobe's frequency instead, a Lissajous figure that
// stands still in tune and rolls open and shut when it isn't.

// The cells of the screen, about one a point at the desktop size
SCOPE_COLUMNS :: STROBE_WIDTH
SCOPE_ROWS :: 240
SCOPE_BEAM_RADIUS :: 1.25 // points
SCOPE_GRID_THICKNESS :: 2

// Over the background noise the beam dims to this, the room's hiss stays in the same cells and would
// be as bright as a note
SCOPE_NOISE_BRIGHTNESS :: 0.3

// The beam is a thin line and its bloom is spread thin, it's added this many times over
SCOPE_BLOOM_PASSES :: 3

// What the scope's and the lamp's views keep from one frame to the next
ScopeDisplay :: struct {
    background: gfx.Color,
    // the scope beam's visibility, see draw_scope_display
    visibility: f32,
    // the scope's screen for its shader, a byte a cell, see draw_scope_screen
    texture:    gfx.Texture,
    pixels:     []u8,
    // each column's brightness on the lamp as last lit, its top and its split bottom, see draw_lamp
    lamp_held:  [SCOPE_COLUMNS][2]f32,
}

init_scope_display :: proc(background: u32) -> (self: ScopeDisplay) {
    self.background = gfx.hex(background)
    return
}

destroy_scope_display :: proc(self: ^ScopeDisplay) {
    gfx.unload_texture(self.texture)
    delete(self.pixels)
}

// The scope or the lamp. With the retro glow on the scope's beam glows like the strobe, through the
// shared glow targets. The lamp is lit all over and a glow adds little, it has none.
// snr_db is of the whole signal, the beam fades in with it like the strobe's stripes.
draw_scope_display :: proc(
    self: ^ScopeDisplay,
    targets: ^GlowTargets,
    scope: ^core.Scope,
    rect: gfx.Rect,
    config: ^Config,
    snr_db: f32,
) {
    colors := strobe_colors(config)
    beam_color, dark_color := gfx.hex(colors[0]), gfx.hex(colors[1])

    fade := core.STROBE_FADE_SNR_DB
    target := math.lerp(f32(SCOPE_NOISE_BRIGHTNESS), 1, math.smoothstep(fade[0], fade[1], snr_db))
    alpha := 1 - math.exp(-gfx.frame_time() / STROBE_LOOK_TIME_S)
    self.visibility += alpha * (target - self.visibility)

    if config.strobe_display_type == .SCOPE && config.strobe_glow {
        begin_glow(targets, rect, self.background)
        draw_scope_screen(self, rect, scope, beam_color, dark_color)
        end_glow(targets, rect, SCOPE_BLOOM_PASSES)
        return
    }

    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, self.background)

    // the beam's dots at the edges reach over it
    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if config.strobe_display_type == .LAMP {
        heights, dwell := core.scope_from_above(scope, config.lamp_shape)
        draw_lamp(self, rect, heights, scope.depths, dwell, config.lamp_shape, beam_color, dark_color)
    } else {
        draw_scope_screen(self, rect, scope, beam_color, dark_color)
    }
}

// The screen of an analog oscilloscope, as bright as the beam stayed long. The beam in the colorway's lit
// color, the lines through the middle in its second color.
// Every lit cell is a round dot wider than the cell, the dots of neighbouring cells overlap and add up
// to a thicker and brighter beam, drawn by the scope shader from the screen as a texture, a byte a cell.
// The beam dims with the display's visibility, 1 is full.
draw_scope_screen :: proc(self: ^ScopeDisplay, rect: gfx.Rect, scope: ^core.Scope, beam_color, grid_color: gfx.Color) {
    // The Lissajous figure and the circle are round, on a square in the middle
    width := core.scope_width(scope)
    rect := rect
    if scope.sweep != .TIME {
        side := min(rect.width, rect.height)
        rect = {rect.x + (rect.width - side) / 2, rect.y + (rect.height - side) / 2, side, side}
    }

    if scope.sweep == .CIRCLE {
        // The ring at the wave's zero
        RING_POINTS :: 96
        center := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}
        radius := 0.5 * core.SCOPE_FILL * core.SCOPE_CIRCLE_RING * rect.width
        points: [RING_POINTS + 1][2]f32
        for &point, index in points {
            angle := math.TAU * f32(index) / RING_POINTS
            point = center + radius * [2]f32{math.cos(angle), math.sin(angle)}
        }
        gfx.draw_polyline(points[:], SCOPE_GRID_THICKNESS, grid_color)
    } else {
        // Through zero, and where the second period starts or the reference's zero
        gfx.draw_rect({rect.x, rect.y + (rect.height - SCOPE_GRID_THICKNESS) / 2}, {rect.width, SCOPE_GRID_THICKNESS}, grid_color)
        gfx.draw_rect({rect.x + (rect.width - SCOPE_GRID_THICKNESS) / 2, rect.y}, {SCOPE_GRID_THICKNESS, rect.height}, grid_color)
    }

    // Against the dwell of a steady trace one cell thick, so a smeared trace is dimmer instead of being
    // scaled back up
    total: f32 = 0
    for dwell in scope.screen do total += dwell
    if total == 0 do return

    full := total / f32(width)

    columns, rows := i32(scope.columns), i32(scope.rows)
    if self.texture.width != columns || self.texture.height != rows {
        gfx.unload_texture(self.texture)
        self.texture = gfx.create_gray_texture(columns, rows)
        delete(self.pixels)
        self.pixels = make([]u8, scope.columns * scope.rows)
    }

    // A steady beam is shared by a few cells of its column, more where the wave is steep. A third of
    // the column's dwell is full brightness.
    EXPOSURE :: 3
    DARK :: 0.02
    for dwell, cell in scope.screen {
        intensity := min(EXPOSURE * dwell / full, 1)
        self.pixels[cell] = u8(255 * intensity + 0.5) if intensity >= DARK else 0
    }
    gfx.update_texture(self.texture, self.pixels)

    color := gfx.normalize_color(beam_color)
    color.a = self.visibility
    uniforms := gfx.ScopeUniforms {
        color     = color,
        cells     = {f32(columns), f32(rows)},
        cell_size = {rect.width / f32(width), rect.height / f32(rows)},
        radius    = SCOPE_BEAM_RADIUS,
    }
    gfx.begin_shader(.SCOPE)
    defer gfx.end_shader()

    gfx.set_shader_uniforms(.SCOPE, &uniforms)

    // Over time it runs right to left, like the lamp, see the top of the file
    source := gfx.Rect{0, 0, f32(width), f32(rows)}
    if scope.sweep == .TIME do source.width = -source.width

    gfx.draw_texture(self.texture, source, rect)
}

// Stripes as bright as the beam is high, the lamp of a mechanical strobe and the first version of this
// one. heights is the beam's height in every column, 1 is the peak level, dwell is 0 where the beam
// hasn't been. A smeared beam is gray, its height is the middle of the smear. Split, the top half is lit
// by the heights and the bottom half by the depths, the negative half of the wave.
// A column the beam wasn't in keeps its brightness as last lit, like the eye holds a lamp's flash. Without
// persistence the screen is only the frame's samples, rarely a whole number of sweeps and a third of one
// on a low note, the rest would show a dark gap walking across. A screen dark all over stays dark.
draw_lamp :: proc(
    self: ^ScopeDisplay,
    rect: gfx.Rect,
    heights, depths, dwell: []f32,
    shape: core.ScopeShape,
    bright_color, dark_color: gfx.Color,
) {
    if !slice.any_of_proc(dwell, proc(time: f32) -> bool { return time > 0 }) do return

    column_width := rect.width / f32(len(heights))
    lamp_height := rect.height / 2 if shape == .SPLIT else rect.height

    for height, column in heights {
        held := &self.lamp_held[column]
        if dwell[column] > 0 {
            // The wave as it is goes below zero, zero is halfway
            held[0] = 0.5 + 0.5 * height if shape == .RAW_WAVEFORM else height
            held[1] = depths[column]
        }

        x := rect.x + rect.width - f32(column + 1) * column_width
        color := lerp_color(dark_color, bright_color, clamp(held[0], 0, 1))
        gfx.draw_rect({x, rect.y}, {column_width, lamp_height}, color)

        if shape == .SPLIT {
            color = lerp_color(dark_color, bright_color, clamp(held[1], 0, 1))
            gfx.draw_rect({x, rect.y + lamp_height}, {column_width, lamp_height}, color)
        }
    }
}
