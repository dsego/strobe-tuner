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

import "../core"
import "core:math"

// Two display types, both views of the scope in core/scope.odin that only draw what it gives them:
//   scope   - its screen
//   ribbon - its screen from above, stripes as bright as the wave is high
//
// Two periods of the strobe's frequency across. An in tune note stands still, a flat one drifts to the
// left and a sharp one to the right, like the strobe tracks. Mirrored for that, time runs right to left.

// The cells of the screen, about one a point at the desktop size
SCOPE_COLUMNS :: STROBE_WIDTH
SCOPE_ROWS :: 240
SCOPE_BEAM_RADIUS :: 1.25 // points
SCOPE_GRID_THICKNESS :: 2

// Over the background noise the beam dims to this, the room's hiss stays in the same cells and would
// be as bright as a note
SCOPE_NOISE_BRIGHTNESS :: 0.3

SCOPE_PERSISTENCE_STEP_MS :: 10
SCOPE_MAX_PERSISTENCE_MS :: 500

// Debug builds: up and down change the persistence of the screen, H flips what the ribbon shows
scope_keys :: proc(config: ^Config) {
    if config.strobe_display_type != .SCOPE && config.strobe_display_type != .RIBBON do return

    if key_pressed(.H) {
        config.ribbon_shape = .RAW_WAVEFORM if config.ribbon_shape == .HALF_RECTIFIED else .HALF_RECTIFIED
    }
    step: f32 = 0
    if key_pressed(.UP) do step = SCOPE_PERSISTENCE_STEP_MS
    if key_pressed(.DOWN) do step = -SCOPE_PERSISTENCE_STEP_MS
    config.scope_persistence_ms = clamp(config.scope_persistence_ms + step, 0, SCOPE_MAX_PERSISTENCE_MS)
}

// The beam is a thin line and its bloom is spread thin, it's added this many times over
SCOPE_BLOOM_PASSES :: 3

// The scope or the ribbon. With the retro glow on the scope's beam glows like the strobe, through the
// strobe display's render targets. The ribbon is lit all over and a glow adds little, it has none.
// snr_db is of the whole signal, the beam fades in with it like the strobe's stripes.
draw_scope_display :: proc(display: ^StrobeDisplay, scope: ^core.Scope, rect: Rect, config: ^Config, snr_db: f32) {
    colors := get_strobe_colors(config)
    beam_color, dark_color := hex(colors[0]), hex(colors[1])

    fade := STROBE_FADE_SNR_DB
    target := math.lerp(f32(SCOPE_NOISE_BRIGHTNESS), 1, math.smoothstep(fade[0], fade[1], snr_db))
    alpha := 1 - math.exp(-gfx_frame_time() / STROBE_LOOK_TIME_S)
    display.scope_visibility += alpha * (target - display.scope_visibility)

    if config.strobe_display_type == .SCOPE && config.strobe_glow {
        // Offscreen, it's as large as rect and cuts off what is outside
        ensure_glow_targets(display, {rect.width, rect.height})
        begin_render_target(display.scene_rt, display.background, {rect.x, rect.y}, display.glow_scale)
        draw_scope_screen(rect, scope, beam_color, dark_color, display.scope_visibility)
        end_render_target()
        render_bloom(display)

        set_blend_mode(.REPLACE)
        draw_render_target(display.scene_rt, rect)
        set_blend_mode(.ADD)
        for _ in 0 ..< SCOPE_BLOOM_PASSES {
            draw_render_target(display.bloom_rt[0], rect)
        }
        set_blend_mode(.ALPHA)
        return
    }

    draw_rect({rect.x, rect.y}, {rect.width, rect.height}, display.background)

    // the beam's dots at the edges reach over it
    begin_scissor(rect)
    defer end_scissor()

    if config.strobe_display_type == .RIBBON {
        heights, dwell := core.scope_from_above(scope, config.ribbon_shape)
        draw_ribbon(rect, heights, dwell, config.ribbon_shape, beam_color, dark_color)
    } else {
        draw_scope_screen(rect, scope, beam_color, dark_color, display.scope_visibility)
    }
}

// The screen of an analog oscilloscope, as bright as the beam stayed long. The beam in the colorway's lit
// color, the lines through the middle in its second color.
// Every lit cell is a round dot wider than the cell, the dots of neighbouring cells overlap and add up
// to a thicker and brighter beam. brightness dims the whole beam, 1 is full.
draw_scope_screen :: proc(rect: Rect, scope: ^core.Scope, beam_color, grid_color: Color, brightness: f32) {
    // Through zero, and where the second period starts
    draw_rect({rect.x, rect.y + (rect.height - SCOPE_GRID_THICKNESS) / 2}, {rect.width, SCOPE_GRID_THICKNESS}, grid_color)
    draw_rect({rect.x + (rect.width - SCOPE_GRID_THICKNESS) / 2, rect.y}, {SCOPE_GRID_THICKNESS, rect.height}, grid_color)

    // Against the dwell of a steady trace one cell thick, so a smeared trace is dimmer instead of being
    // scaled back up
    total: f32 = 0
    for dwell in scope.screen do total += dwell
    if total == 0 do return
    full := total / f32(scope.columns)

    // A steady beam is shared by a few cells of its column, more where the wave is steep. A third of
    // the column's dwell is full brightness.
    EXPOSURE :: 3
    DARK :: 0.02
    cell_size := [2]f32{rect.width / f32(scope.columns), rect.height / f32(scope.rows)}
    for dwell, i in scope.screen {
        intensity := min(EXPOSURE * dwell / full, 1)
        if intensity < DARK do continue

        column := scope.columns - 1 - i % scope.columns
        row := i / scope.columns
        center := [2]f32{rect.x + (f32(column) + 0.5) * cell_size.x, rect.y + (f32(row) + 0.5) * cell_size.y}
        dot := Rect{center.x - SCOPE_BEAM_RADIUS, center.y - SCOPE_BEAM_RADIUS, 2 * SCOPE_BEAM_RADIUS, 2 * SCOPE_BEAM_RADIUS}
        alpha := u8(255 * brightness * intensity)
        draw_texture(shape_texture, {0, 0, SHAPE_SIZE, SHAPE_SIZE}, dot, {beam_color.r, beam_color.g, beam_color.b, alpha})
    }
}

// Stripes as bright as the beam is high, the classic strobe and the first version of this one. heights
// is the beam's height in every column, 1 is the peak level, dwell is 0 where the beam hasn't been.
// A smeared beam is gray, its height is the middle of the smear.
draw_ribbon :: proc(rect: Rect, heights, dwell: []f32, shape: core.ScopeShape, bright_color, dark_color: Color) {
    bright := normalize_color(bright_color)
    dark := normalize_color(dark_color)
    column_width := rect.width / f32(len(heights))

    for height, i in heights {
        // The beam wasn't here, a frame is shorter than the sweep of a low note
        if dwell[i] == 0 do continue

        // The wave as it is goes below zero, zero is halfway
        brightness := height
        if shape == .RAW_WAVEFORM do brightness = 0.5 + 0.5 * height
        color := color_from_normalized(math.lerp(dark, bright, clamp(brightness, 0, 1)))

        x := rect.x + rect.width - f32(i + 1) * column_width
        draw_rect({x, rect.y}, {column_width, rect.height}, color)
    }
}
