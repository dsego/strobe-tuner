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
// Tapped, the wave goes round a circle, lobes that stand still in tune and spin clockwise when sharp.

// The cells of the screen, about one a point at the desktop size
SCOPE_COLUMNS :: STROBE_WIDTH
SCOPE_ROWS :: 240
SCOPE_GRID_THICKNESS :: 2

// The beam's line, smooth at a feather of about a pixel
SCOPE_TRACE_THICKNESS :: #config(SCOPE_TRACE_THICKNESS, 3.5) // points
SCOPE_TRACE_FEATHER :: 0.75

// Over the background noise the beam dims to this, the line at rest stays
SCOPE_NOISE_BRIGHTNESS :: 0.3

// The phosphor is as bright as a flat line where the beam moves no more than this many times as fast, like
// the cells of the screen it was drawn from
SCOPE_PHOSPHOR_EXPOSURE :: #config(SCOPE_PHOSPHOR_EXPOSURE, 3)
// and glows in a wide line under it, this bright
SCOPE_GLOW :: #config(SCOPE_GLOW, 0.25)
SCOPE_GLOW_THICKNESS :: 4 * SCOPE_TRACE_THICKNESS // points

// The beam is a thin line and its bloom is spread thin, it's added this many times over
SCOPE_BLOOM_PASSES :: #config(SCOPE_BLOOM_PASSES, 3)

// What the scope's and the lamp's views keep from one frame to the next
ScopeDisplay :: struct {
    background:   gfx.Color,
    // the scope beam's visibility, see draw_scope_display
    visibility:   f32,
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
        draw_scope_screen(self, rect, scope, config.scope_beam, beam_color, dark_color)
        end_glow(targets, rect, SCOPE_BLOOM_PASSES)
        return
    }

    gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, self.background)

    // the beam's dots at the edges reach over it
    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if config.strobe_display_type == .LAMP {
        heights, dwell := core.scope_from_above(scope, config.lamp_shape)
        draw_lamp(rect, heights, scope.depths, dwell, config.lamp_shape, beam_color, dark_color)
    } else {
        draw_scope_screen(self, rect, scope, config.scope_beam, beam_color, dark_color)
    }
}

// The scope's screen, the beam in the colorway's lit color and the lines through the middle in its second
// color. The beam is a line through the sweeps' average or the newest sweep, see draw_scope_trace. It dims
// with the display's visibility, 1 is full.
draw_scope_screen :: proc(
    self: ^ScopeDisplay,
    rect: gfx.Rect,
    scope: ^core.Scope,
    beam: ScopeBeam,
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
        // Through zero, and where the second period starts or the reference's zero
        gfx.draw_rect({rect.x, rect.y + (rect.height - SCOPE_GRID_THICKNESS) / 2}, {rect.width, SCOPE_GRID_THICKNESS}, grid_color)
        gfx.draw_rect({rect.x + (rect.width - SCOPE_GRID_THICKNESS) / 2, rect.y}, {SCOPE_GRID_THICKNESS, rect.height}, grid_color)
    }

    draw_scope_trace(self, rect, scope, beam, beam_color)
}

// The beam, a line through the points of core.scope_trace. Over time it runs right to left, like the lamp,
// see the top of the file. Solid, it's as bright all along. Phosphor, it's as bright as the beam stays like an
// analog oscilloscope's: the points are as long apart in time, where they're further apart the beam moves
// faster and is dimmer, the steep edges fade and the crests stay lit. A wide faint line under it glows.
draw_scope_trace :: proc(self: ^ScopeDisplay, rect: gfx.Rect, scope: ^core.Scope, beam: ScopeBeam, beam_color: gfx.Color) {
    // In pieces where the sweep over time starts over on the left. A line that ends where it started, the
    // circle through the sweeps' average, is closed.
    draw_pieces :: proc(self: ^ScopeDisplay, rect: gfx.Rect, thickness, feather: f32) {
        piece := 0
        for index in 1 ..= len(self.trace) {
            if index < len(self.trace) && !wraps(self, rect, index - 1, index) do continue

            gap := self.trace[index - 1] - self.trace[piece]
            closed := piece == 0 && index == len(self.trace) && abs(gap.x) + abs(gap.y) < 0.01
            gfx.draw_soft_polyline(self.trace[piece:index], self.trace_colors[piece:index], thickness, feather, closed)
            piece = index
        }
    }

    wraps :: proc(self: ^ScopeDisplay, rect: gfx.Rect, from, to: int) -> bool {
        return abs(self.trace[to].x - self.trace[from].x) >= rect.width / 2
    }

    core.scope_trace(scope, &self.trace)
    if len(self.trace) < 2 do return

    for &point in self.trace {
        if scope.sweep == .TIME do point.x = 1 - point.x

        point = {rect.x + point.x * rect.width, rect.y + point.y * rect.height}
    }
    resize(&self.trace_colors, len(self.trace))

    if beam == .SOLID {
        slice.fill(self.trace_colors[:], lerp_color(self.background, beam_color, self.visibility))
        draw_pieces(self, rect, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER)
        return
    }

    // How far the beam goes from one point to the next on a flat line, a sweep's way at the wave's zero
    way := rect.width
    if scope.sweep == .CIRCLE do way = math.TAU * core.SCOPE_CIRCLE_REACH * core.SCOPE_CIRCLE_RING * rect.width
    flat := way / f32(len(self.trace) - 1)

    // Each point as far as the beam goes to the next one, or from the one before where it starts over
    resize(&self.trace_light, len(self.trace))
    for &light, index in self.trace_light {
        next := index + 1
        if next == len(self.trace) || wraps(self, rect, index, next) do next = max(index - 1, 0)

        delta := self.trace[next] - self.trace[index]
        distance := math.sqrt(delta.x * delta.x + delta.y * delta.y)
        light = min(SCOPE_PHOSPHOR_EXPOSURE * flat / max(distance, 1e-6), 1)
    }

    for &color, index in self.trace_colors {
        color = lerp_color(self.background, beam_color, self.visibility * self.trace_light[index] * SCOPE_GLOW)
    }
    draw_pieces(self, rect, SCOPE_GLOW_THICKNESS, 0.5 * SCOPE_GLOW_THICKNESS)

    for &color, index in self.trace_colors {
        color = lerp_color(self.background, beam_color, self.visibility * self.trace_light[index])
    }
    draw_pieces(self, rect, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER)
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
