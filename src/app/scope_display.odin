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

import "../core"
import "../gfx"

// Two display types, both views of the scope in src/core/scope.odin that only draw what it gives them:
//   scope   - its screen
//   lamp   - its screen from above, stripes as bright as the wave is high, the lamp of a mechanical strobe
//
// Two periods of the strobe's frequency across. An in tune note stands still, a detuned one drifts. The
// scope runs left to right like an oscilloscope, a sawtooth leans the way it's generated and a sharp note
// drifts left. The lamp is mirrored to move like the strobe tracks, flat to the left and sharp to the right.
// Tapped, the scope draws the wave against the strobe's frequency instead, a Lissajous figure that
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

// The scope or the lamp. With the retro glow on the scope's beam glows like the strobe, through the
// strobe display's render targets. The lamp is lit all over and a glow adds little, it has none.
// snr_db is of the whole signal, the beam fades in with it like the strobe's stripes.
draw_scope_display :: proc(display: ^StrobeDisplay, scope: ^core.Scope, rect: gfx.Rect, config: ^Config, snr_db: f32) {
    colors := strobe_colors(config)
    beam_color, dark_color := gfx.hex(colors[0]), gfx.hex(colors[1])

    fade := core.STROBE_FADE_SNR_DB
    target := math.lerp(f32(SCOPE_NOISE_BRIGHTNESS), 1, math.smoothstep(fade[0], fade[1], snr_db))
    alpha := 1 - math.exp(-gfx.frame_time() / STROBE_LOOK_TIME_S)
    display.scope_visibility += alpha * (target - display.scope_visibility)

    if config.strobe_display_type == .SCOPE && config.strobe_glow {
        // Offscreen, it's as large as rect and cuts off what is outside
        ensure_glow_targets(display, {rect.width, rect.height})
        gfx.begin_render_target(display.scene_rt, display.background, {rect.x, rect.y}, display.glow_scale)
        draw_scope_screen(display, rect, scope, beam_color, dark_color)
        gfx.end_render_target()
        render_bloom(display)

        // Not the strobe's any more
        display.glow_drawn = {}

        gfx.set_blend_mode(.REPLACE)
        gfx.draw_render_target(display.scene_rt, rect)
        gfx.set_blend_mode(.ADD)
        for _ in 0 ..< SCOPE_BLOOM_PASSES {
            gfx.draw_render_target(display.bloom_rt[0], rect)
        }
        gfx.set_blend_mode(.ALPHA)
        return
    }

    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, display.background)

    // the beam's dots at the edges reach over it
    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if config.strobe_display_type == .LAMP {
        heights, dwell := core.scope_from_above(scope, config.lamp_shape)
        draw_lamp(rect, heights, dwell, config.lamp_shape, beam_color, dark_color)
    } else {
        draw_scope_screen(display, rect, scope, beam_color, dark_color)
    }
}

// The screen of an analog oscilloscope, as bright as the beam stayed long. The beam in the colorway's lit
// color, the lines through the middle in its second color.
// Every lit cell is a round dot wider than the cell, the dots of neighbouring cells overlap and add up
// to a thicker and brighter beam, drawn by the scope shader from the screen as a texture, a byte a cell.
// The beam dims with the display's scope_visibility, 1 is full.
draw_scope_screen :: proc(display: ^StrobeDisplay, rect: gfx.Rect, scope: ^core.Scope, beam_color, grid_color: gfx.Color) {
    // The Lissajous figure is round, on a square in the middle
    width := core.scope_width(scope)
    rect := rect
    if scope.sweep == .XY {
        side := min(rect.width, rect.height)
        rect = {rect.x + (rect.width - side) / 2, rect.y + (rect.height - side) / 2, side, side}
    }

    // Through zero, and where the second period starts or the reference's zero
    gfx.draw_rect({rect.x, rect.y + (rect.height - SCOPE_GRID_THICKNESS) / 2}, {rect.width, SCOPE_GRID_THICKNESS}, grid_color)
    gfx.draw_rect({rect.x + (rect.width - SCOPE_GRID_THICKNESS) / 2, rect.y}, {SCOPE_GRID_THICKNESS, rect.height}, grid_color)

    // Against the dwell of a steady trace one cell thick, so a smeared trace is dimmer instead of being
    // scaled back up
    total: f32 = 0
    for dwell in scope.screen do total += dwell
    if total == 0 do return

    full := total / f32(width)

    columns, rows := i32(scope.columns), i32(scope.rows)
    if display.scope_texture.width != columns || display.scope_texture.height != rows {
        gfx.unload_texture(display.scope_texture)
        display.scope_texture = gfx.create_gray_texture(columns, rows)
        delete(display.scope_pixels)
        display.scope_pixels = make([]u8, scope.columns * scope.rows)
    }

    // A steady beam is shared by a few cells of its column, more where the wave is steep. A third of
    // the column's dwell is full brightness.
    EXPOSURE :: 3
    DARK :: 0.02
    for dwell, i in scope.screen {
        intensity := min(EXPOSURE * dwell / full, 1)
        display.scope_pixels[i] = u8(255 * intensity + 0.5) if intensity >= DARK else 0
    }
    gfx.update_texture(display.scope_texture, display.scope_pixels)

    color := gfx.normalize_color(beam_color)
    color.a = display.scope_visibility
    uniforms := gfx.ScopeUniforms {
        color     = color,
        cells     = {f32(columns), f32(rows)},
        cell_size = {rect.width / f32(width), rect.height / f32(rows)},
        radius    = SCOPE_BEAM_RADIUS,
    }
    gfx.begin_shader(display.scope_shader)
    defer gfx.end_shader()

    gfx.set_shader_uniforms(display.scope_shader, &uniforms)
    gfx.draw_texture(display.scope_texture, {0, 0, f32(width), f32(rows)}, rect)
}

// The comparator's tracks turned by the lamp instead, the strobe the other way: a DFT bin of the
// scope's screen from above (core.scope_partials) for each track's partial, instead of its DFT on the
// samples. They turn like the tracks: by the bin's phase advance, rescaled so all notes spin at the same
// rate per cent, times the track's speed, and stand still at its partial's target, offset included.
// The screen's quirks show, a pluck or a weak partial can make the stripes jump. A copy for drawing until the next frame, its
// DFTs are the comparator's own. The phases between frames are kept in the display.
lamp_bands :: proc(
    display: ^StrobeDisplay,
    scope: ^core.Scope,
    comparator_bands: []core.PhaseBand,
    signal_snr_db: f32,
) -> (
    bands: []core.PhaseBand,
) {
    bands = make([]core.PhaseBand, len(comparator_bands), context.temp_allocator)
    copy(bands, comparator_bands)
    if scope.freq_hz <= 0 do return

    // The bin nearest each track's partial, its target a little off for an offset in cents
    periods := make([]int, len(bands), context.temp_allocator)
    for band, index in bands {
        periods[index] = max(int(math.round(core.SCOPE_PERIODS * f64(band.freq_hz) / scope.freq_hz)), 1)
    }
    partials := make([]core.ScopePartial, len(bands), context.temp_allocator)
    noise := max(core.scope_partials(scope, periods, partials), 1e-9)

    // A new reference starts with a dark screen, the phases before it are arbitrary
    has_phase := display.lamp_freq_hz == scope.freq_hz
    elapsed := f64(scope.sample_clock - display.lamp_clock) / f64(scope.sample_rate)
    display.lamp_freq_hz = scope.freq_hz
    display.lamp_clock = scope.sample_clock

    for &band, index in bands {
        partial := partials[index]
        phase_before := display.lamp_phases[index]
        display.lamp_phases[index] = partial.phase
        if !band.in_range do continue

        // The screen remembers a note after it fades into the room's noise, the signal's SNR fades it out
        level := max(partial.level, 1e-9)
        band.snr_db = min(f32(20 * math.log10(level / noise)), signal_snr_db)

        // As run_phase_detection does it, the shortest way from the previous frame's phase. On the target
        // the partial drifts on the screen by how far it is from the bin.
        bin_hz := f64(periods[index]) / core.SCOPE_PERIODS * scope.freq_hz
        target_advance := math.TAU * (f64(band.freq_hz) - bin_hz) * elapsed
        advance := core.wrap_phase(partial.phase - phase_before - target_advance) if has_phase else 0

        rescale := core.strobe_rescale(band.freq_hz)
        band.phase_diff = f32(advance * rescale)
        display.lamp_scaled_phases[index] -= band.phase_diff * band.speed
        band.scaled_phase = display.lamp_scaled_phases[index]
    }
    return
}

// Stripes as bright as the beam is high, the lamp of a mechanical strobe and the first version of this
// one. heights is the beam's height in every column, 1 is the peak level, dwell is 0 where the beam
// hasn't been. A smeared beam is gray, its height is the middle of the smear.
draw_lamp :: proc(rect: gfx.Rect, heights, dwell: []f32, shape: core.ScopeShape, bright_color, dark_color: gfx.Color) {
    bright := gfx.normalize_color(bright_color)
    dark := gfx.normalize_color(dark_color)
    column_width := rect.width / f32(len(heights))

    for height, i in heights {
        // The beam wasn't here, a frame is shorter than the sweep of a low note
        if dwell[i] == 0 do continue

        // The wave as it is goes below zero, zero is halfway
        brightness := height
        if shape == .RAW_WAVEFORM do brightness = 0.5 + 0.5 * height

        color := gfx.color_from_normalized(math.lerp(dark, bright, clamp(brightness, 0, 1)))

        x := rect.x + rect.width - f32(i + 1) * column_width
        gfx.draw_rect({x, rect.y}, {column_width, rect.height}, color)
    }
}
