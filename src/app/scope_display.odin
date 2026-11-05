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

import "core:fmt"
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
// Tapped, the wave goes round a circle, lobes that stand still in tune and spin clockwise when sharp.

// The cells of the screen, about one a point at the desktop size
SCOPE_COLUMNS :: STROBE_WIDTH
SCOPE_ROWS :: 240
SCOPE_GRID_THICKNESS :: 2

// The beam's line, smooth at a feather of about a pixel
SCOPE_TRACE_THICKNESS :: #config(SCOPE_TRACE_THICKNESS, 3.5) // points
SCOPE_TRACE_FEATHER :: 0.75

// The phosphor is as bright as a flat line where the beam moves no more than this many times as fast, like
// the cells of the screen it was drawn from
SCOPE_PHOSPHOR_EXPOSURE :: #config(SCOPE_PHOSPHOR_EXPOSURE, 3)
// and glows in a wide line under it, this bright
SCOPE_GLOW :: #config(SCOPE_GLOW, 0.25)
SCOPE_GLOW_THICKNESS :: 4 * SCOPE_TRACE_THICKNESS // points

// The beam is a thin line and its bloom is spread thin, it's added this many times over
SCOPE_BLOOM_PASSES :: #config(SCOPE_BLOOM_PASSES, 3)

// The graticule over time, fixed like an oscilloscope's, its times change with the note: SCOPE_DIVISIONS across
// the two periods, a quarter period each, and as many up, a quarter of full scale each. The times are under
// every other line.
SCOPE_DIVISIONS :: 8
SCOPE_AXIS_PIXELS :: 2 // the line through zero

// The circle's afterglow, the Afterglow setting: behind the newest line the circle as it was drawn
// core.SCOPE_AFTERGLOW_PERIODS ago, core.SCOPE_AFTERGLOW_SWEEPS of them, each further back SCOPE_AFTERGLOW_SHRINK
// times as big and SCOPE_AFTERGLOW_FADE times as bright. Each is the line from that long ago held at its size,
// not one shrinking as it ages: an in tune note stands still as nested copies of itself, a detuned one turns them apart,
// the older further round. All the same size they lay on each other and were hard to see. The website's Circle
// pane draws the same.
SCOPE_AFTERGLOW_SHRINK :: #config(SCOPE_AFTERGLOW_SHRINK, 0.94)
SCOPE_AFTERGLOW_FADE :: 0.3 // 0.5 was too much

// What the scope's and the lamp's views keep from one frame to the next
ScopeDisplay :: struct {
    background:   gfx.Color,
    // the beam's line, a color a point for it and the phosphor's light, see draw_scope_trace
    trace:        [dynamic][2]f32,
    trace_colors: [dynamic]gfx.Color,
    trace_light:  [dynamic]f32,
}

init_scope_display :: proc(background: u32) -> (self: ScopeDisplay) {
    self.background = gfx.hex(background)
    return
}

destroy_scope_display :: proc(self: ^ScopeDisplay) {
    delete(self.trace)
    delete(self.trace_colors)
    delete(self.trace_light)
}

// The scope or the lamp. With the retro glow on the scope's beam glows like the strobe, through the
// shared glow targets. The lamp is lit all over and a glow adds little, it has none.
// The scope's beam is as bright over the room's noise as over a note, like an oscilloscope's: its height
// already shows how loud it is. Faded in with the signal over the noise like the strobe's stripes, a soft
// pluck over a fridge's hum drew at 40% and the hum itself hid.
draw_scope_display :: proc(self: ^ScopeDisplay, targets: ^GlowTargets, scope: ^core.Scope, rect: gfx.Rect, config: ^Config) {
    colors := strobe_colors(config)
    beam_color, dark_color := gfx.hex(colors[0]), gfx.hex(colors[1])

    // The times under the graticule outside the glow, sharp
    if config.strobe_display_type == .SCOPE && config.strobe_glow {
        begin_glow(targets, rect, self.background)
        draw_scope_screen(self, rect, scope, config.scope_beam, config.scope_afterglow, beam_color, dark_color)
        end_glow(targets, rect, SCOPE_BLOOM_PASSES)
        draw_scope_time_labels(rect, scope, self.background)
        return
    }

    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, self.background)

    // the beam's line at the edges reaches over it
    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if config.strobe_display_type == .LAMP {
        heights, dwell := core.scope_from_above(scope, config.lamp_shape)
        draw_lamp(rect, heights, scope.depths, dwell, config.lamp_shape, beam_color, dark_color)
    } else {
        draw_scope_screen(self, rect, scope, config.scope_beam, config.scope_afterglow, beam_color, dark_color)
        draw_scope_time_labels(rect, scope, self.background)
    }
}

// The scope's screen, the beam in the colorway's lit color and the lines through the middle in its second
// color. The beam is a line through the sweeps' average or the newest sweep, see draw_scope_trace.
draw_scope_screen :: proc(
    self: ^ScopeDisplay,
    rect: gfx.Rect,
    scope: ^core.Scope,
    beam: ScopeBeam,
    afterglow: bool,
    beam_color, grid_color: gfx.Color,
) {
    // The circle is round, on a square in the middle
    rect := rect
    if scope.sweep != .TIME {
        side := min(rect.width, rect.height)
        rect = {rect.x + (rect.width - side) / 2, rect.y + (rect.height - side) / 2, side, side}
    }

    if scope.sweep == .CIRCLE {
        // The ring at the wave's zero
        RING_POINTS :: 96
        center := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}
        radius := core.SCOPE_CIRCLE_REACH * core.SCOPE_CIRCLE_RING * rect.width
        points: [RING_POINTS + 1][2]f32
        for &point, index in points {
            angle := math.TAU * f32(index) / RING_POINTS
            point = center + radius * [2]f32{math.cos(angle), math.sin(angle)}
        }
        gfx.draw_polyline(points[:], SCOPE_GRID_THICKNESS, grid_color, closed = true)
    } else {
        // The graticule faint and a pixel wide, the line through zero brighter and SCOPE_AXIS_PIXELS wide. Where
        // the second period starts isn't a round time, a line there stood beside the graticule's.
        hairline := 1 / gfx.dpi_scale()
        draw_scope_graticule(rect, grid_color, hairline)

        axis := SCOPE_AXIS_PIXELS * hairline
        gfx.draw_rect({rect.x, rect.y + (rect.height - axis) / 2}, {rect.width, axis}, grid_color)
    }

    draw_scope_trace(self, rect, scope, beam, afterglow, beam_color)
}

// The graticule's lines, width wide, SCOPE_DIVISIONS apart across and up. The middle one up is where the second
// period starts, the one through zero across is the caller's axis.
draw_scope_graticule :: proc(rect: gfx.Rect, grid_color: gfx.Color, width: f32) {
    faint := grid_color
    faint.a /= 2

    // Up, a quarter of full scale apart
    middle := rect.y + rect.height / 2
    for quarter in 1 ..= SCOPE_DIVISIONS / 2 {
        offset := 0.5 * core.SCOPE_FILL * rect.height * f32(quarter) / (SCOPE_DIVISIONS / 2)
        gfx.draw_rect({rect.x, middle - offset}, {rect.width, width}, faint)
        gfx.draw_rect({rect.x, middle + offset}, {rect.width, width}, faint)
    }

    // Across, a quarter period apart
    for division in 1 ..< SCOPE_DIVISIONS {
        gfx.draw_rect({rect.x + rect.width * f32(division) / SCOPE_DIVISIONS, rect.y}, {width, rect.height}, faint)
    }
}

// The milliseconds under every other line of the graticule along the bottom, from 0 at the right where the
// sweep's time starts, see the top of the file. Over time only, on pills, the beam can be there.
draw_scope_time_labels :: proc(rect: gfx.Rect, scope: ^core.Scope, background: gfx.Color) {
    if scope.sweep != .TIME || scope.freq_hz <= 0 do return

    INSET :: 8
    font := pixel_fonts.label_small
    span_ms := f32(core.SCOPE_PERIODS / scope.freq_hz * 1000)
    step_ms := 2 * span_ms / SCOPE_DIVISIONS
    decimals := 0 if step_ms >= 10 else (1 if step_ms >= 1 else 2)
    for division := 0; division <= SCOPE_DIVISIONS; division += 2 {
        text: cstring = "0 ms"
        if division > 0 do text = fmt.ctprintf("%.*f ms", decimals, span_ms * f32(division) / SCOPE_DIVISIONS)

        size := measure_label(font, text)
        line := rect.x + rect.width * (1 - f32(division) / SCOPE_DIVISIONS)
        x := clamp(line - size.x / 2, rect.x + INSET, rect.x + rect.width - size.x - INSET)
        position := [2]f32{x, rect.y + rect.height - size.y - INSET}
        draw_spectrum_label_pill({position.x, position.y, size.x, size.y}, background, 0.6)
        draw_label(font, text, position, text_color_muted)
    }
}

// The beam, a line through the points of core.scope_trace. Over time it runs right to left, like the lamp,
// see the top of the file. Solid, it's as bright all along. Phosphor, it's as bright as the beam stays like an
// analog oscilloscope's: the points are as long apart in time, where they're further apart the beam moves
// faster and is dimmer, the steep edges fade and the crests stay lit. A wide faint line under it glows.
// Round the circle with the afterglow on, the circle as it was drawn before is behind it, see draw_afterglow.
draw_scope_trace :: proc(
    self: ^ScopeDisplay,
    rect: gfx.Rect,
    scope: ^core.Scope,
    beam: ScopeBeam,
    afterglow: bool,
    beam_color: gfx.Color,
) {
    // In pieces where the sweep over time starts over on the left
    draw_pieces :: proc(self: ^ScopeDisplay, rect: gfx.Rect, thickness, feather: f32) {
        piece := 0
        for index in 1 ..= len(self.trace) {
            if index < len(self.trace) && !trace_wraps(rect, self.trace[:], index - 1, index) do continue

            gfx.draw_soft_polyline(self.trace[piece:index], self.trace_colors[piece:index], thickness, feather)
            piece = index
        }
    }

    core.scope_trace(scope, &self.trace)
    if len(self.trace) < 2 do return

    resize(&self.trace_colors, len(self.trace))
    resize(&self.trace_light, len(self.trace))
    place_trace(rect, scope, beam, self.trace[:], self.trace_light[:])

    if afterglow && scope.sweep == .CIRCLE do draw_afterglow(self, rect, scope, beam, beam_color)

    // Solid, as bright all along. Round the circle the ends fade where they overlap. Dimmer is clearer, not
    // darker: the ring, the graticule and the afterglow under it show through.
    if beam == .SOLID {
        for &color, index in self.trace_colors do color = fade_color(beam_color, self.trace_light[index])
        if scope.sweep == .CIRCLE do fade_circle_ends(self.trace_colors[:])
        draw_pieces(self, rect, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER)
        return
    }

    for &color, index in self.trace_colors do color = fade_color(beam_color, self.trace_light[index] * SCOPE_GLOW)
    if scope.sweep == .CIRCLE do fade_circle_ends(self.trace_colors[:])
    draw_pieces(self, rect, SCOPE_GLOW_THICKNESS, 0.5 * SCOPE_GLOW_THICKNESS)

    for &color, index in self.trace_colors do color = fade_color(beam_color, self.trace_light[index])
    if scope.sweep == .CIRCLE do fade_circle_ends(self.trace_colors[:])
    draw_pieces(self, rect, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER)
}

// The ends of the circle's line where they overlap, see core.SCOPE_CIRCLE_OVERLAP: its start fades in under
// its end over the first half of the overlap, its end out over the start over the second half. Faded clearer,
// each still as bright as the beam: in tune the end lies on the start, where either fades the other shows
// through at the same color and the circle is whole. Detuned the end runs on beside the start, both taper.
// Faded darker, the end dimmed the start under it and left a dark notch.
fade_circle_ends :: proc(colors: []gfx.Color) {
    overlap := f32(core.SCOPE_CIRCLE_OVERLAP)
    ends := f32(len(colors) - 1) * 0.5 * overlap / (1 + overlap) // points over half the overlap
    if ends <= 0 do return

    for &color, index in colors {
        along := f32(min(index, len(colors) - 1 - index))
        color.a = u8(math.round(f32(color.a) * math.smoothstep(f32(0), f32(1), along / ends)))
    }
}

// A line from core onto the screen in place, and how bright the beam is at each of its points. Solid, as bright
// all along. Phosphor, each point as bright as the beam stays there, see draw_scope_trace.
place_trace :: proc(rect: gfx.Rect, scope: ^core.Scope, beam: ScopeBeam, points: [][2]f32, light: []f32) {
    for &point in points {
        if scope.sweep == .TIME do point.x = 1 - point.x

        point = {rect.x + point.x * rect.width, rect.y + point.y * rect.height}
    }

    if beam == .SOLID {
        slice.fill(light, 1)
        return
    }

    // How far the beam goes from one point to the next on a flat line, the line's way at the wave's zero
    way := rect.width
    if scope.sweep == .CIRCLE {
        turns := f32(core.scope_trace_sweeps(scope))
        way = turns * math.TAU * core.SCOPE_CIRCLE_REACH * core.SCOPE_CIRCLE_RING * rect.width
    }
    flat := way / f32(len(points) - 1)

    // Each point as far as the beam goes to the next one, or from the one before where it starts over
    for &brightness, index in light {
        next := index + 1
        if next == len(points) || trace_wraps(rect, points, index, next) do next = max(index - 1, 0)

        delta := points[next] - points[index]
        distance := math.sqrt(delta.x * delta.x + delta.y * delta.y)
        brightness = min(SCOPE_PHOSPHOR_EXPOSURE * flat / max(distance, 1e-6), 1)
    }
}

// Over time the line starts over on the left between these two points
trace_wraps :: proc(rect: gfx.Rect, points: [][2]f32, from, to: int) -> bool {
    return abs(points[to].x - points[from].x) >= rect.width / 2
}

// The afterglow's sweeps, the oldest first so the newer are drawn over it, smaller and dimmer about the middle.
// None where the scope has none, as when the note has only just come in. Phosphor, each glows under its line
// like the newest. Dim as clear, the ring and the older sweeps show through, like the newest's.
draw_afterglow :: proc(self: ^ScopeDisplay, rect: gfx.Rect, scope: ^core.Scope, beam: ScopeBeam, beam_color: gfx.Color) {
    center := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}
    points := make([dynamic][2]f32, context.temp_allocator)
    for sweep := core.SCOPE_AFTERGLOW_SWEEPS; sweep >= 1; sweep -= 1 {
        core.scope_afterglow_trace(scope, sweep, &points)
        if len(points) < 2 do continue

        light := make([]f32, len(points), context.temp_allocator)
        place_trace(rect, scope, beam, points[:], light)

        size := math.pow(f32(SCOPE_AFTERGLOW_SHRINK), f32(sweep))
        brightness := math.pow(f32(SCOPE_AFTERGLOW_FADE), f32(sweep))
        colors := make([]gfx.Color, len(points), context.temp_allocator)
        for &point in points do point = center + size * (point - center)

        if beam == .PHOSPHOR {
            for &color, index in colors {
                color = fade_color(beam_color, brightness * light[index] * SCOPE_GLOW)
            }
            fade_circle_ends(colors)
            gfx.draw_soft_polyline(points[:], colors, SCOPE_GLOW_THICKNESS, 0.5 * SCOPE_GLOW_THICKNESS)
        }
        for &color, index in colors do color = fade_color(beam_color, brightness * light[index])
        fade_circle_ends(colors)
        gfx.draw_soft_polyline(points[:], colors, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER)
    }
}

// Stripes as bright as the beam is high, the lamp of a mechanical strobe and the first version of this
// one. heights is the beam's height in every column, 1 is the peak level, dwell is 0 where the beam
// hasn't been. A smeared beam is gray, its height is the middle of the smear. Split, the top half is lit
// by the heights and the bottom half by the depths, the negative half of the wave. A screen dark all over
// stays dark.
draw_lamp :: proc(
    rect: gfx.Rect,
    heights, depths, dwell: []f32,
    shape: core.ScopeShape,
    bright_color, dark_color: gfx.Color,
) {
    if !slice.any_of_proc(dwell, proc(time: f32) -> bool { return time > 0 }) do return

    column_width := rect.width / f32(len(heights))
    lamp_height := rect.height / 2 if shape == .SPLIT else rect.height

    for height, column in heights {
        // The wave as it is goes below zero, zero is halfway
        lit := 0.5 + 0.5 * height if shape == .RAW_WAVEFORM else height

        x := rect.x + rect.width - f32(column + 1) * column_width
        color := lerp_color(dark_color, bright_color, clamp(lit, 0, 1))
        gfx.draw_rect({x, rect.y}, {column_width, lamp_height}, color)

        if shape == .SPLIT {
            color = lerp_color(dark_color, bright_color, clamp(depths[column], 0, 1))
            gfx.draw_rect({x, rect.y + lamp_height}, {column_width, lamp_height}, color)
        }
    }
}
