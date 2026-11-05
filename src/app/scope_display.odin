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
import "core:time"

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

// The graticule over time, fixed like an oscilloscope's, its times change with the note: SCOPE_DIVISIONS across
// the two periods, a quarter period each, and as many up, a quarter of full scale each. The times are under
// every other line.
SCOPE_DIVISIONS :: 8
SCOPE_AXIS_PIXELS :: 2 // the line through zero

// Round the circle a sweep that doesn't end where it started, the newest alone with a note off, fades in over
// this much of its way at the start and out over as much at the end, so its ends don't meet in a step. As far
// as they're apart: a step SCOPE_END_GAP wide or more fades them out altogether, a hair's step barely, the
// circle of a note just off keeps no dark notch at the top.
SCOPE_END_FADE :: 0.06
SCOPE_END_GAP :: 4 * SCOPE_TRACE_THICKNESS // points

// The circle's afterglow, the Afterglow setting: behind the newest sweep the circle as it was a moment ago,
// SCOPE_AFTERGLOW_SWEEPS times SCOPE_AFTERGLOW_DELAY_S apart, each further back SCOPE_AFTERGLOW_SHRINK times as
// big and SCOPE_AFTERGLOW_FADE times as bright. Each is the trace from that long ago held at its size, not one
// shrinking as it ages: an in tune note stands still as nested copies of itself, a detuned one turns them apart,
// the older further round. The website's Circle pane draws the same.
SCOPE_AFTERGLOW_SWEEPS :: 3
SCOPE_AFTERGLOW_DELAY_S :: 0.1
SCOPE_AFTERGLOW_SHRINK :: 0.94
SCOPE_AFTERGLOW_FADE :: 0.3 // 0.5 was too much
// The traces it picks from, kept no more often than this, and as many as cover the oldest delay at that rate,
// 27, and a few over
SCOPE_AFTERGLOW_KEEP_S :: 1.0 / 90
SCOPE_AFTERGLOW_FRAMES :: 32

// What the scope's and the lamp's views keep from one frame to the next
ScopeDisplay :: struct {
    background:   gfx.Color,
    // the scope beam's visibility, see draw_scope_display
    visibility:   f32,
    // the beam's line, a color a point for it and the phosphor's light, see draw_scope_trace
    trace:        [dynamic][2]f32,
    trace_colors: [dynamic]gfx.Color,
    trace_light:  [dynamic]f32,
    // the circle's afterglow, a ring of the latest traces, glow_newest the newest of glow_count, see
    // keep_afterglow_frame
    glow_frames:  [SCOPE_AFTERGLOW_FRAMES]ScopeAfterglowFrame,
    glow_newest:  int,
    glow_count:   int,
}

// A trace the afterglow keeps: when, its points from the middle of the circle, and the phosphor's light
ScopeAfterglowFrame :: struct {
    tick:   time.Tick,
    points: [dynamic][2]f32,
    light:  [dynamic]f32,
}

init_scope_display :: proc(background: u32) -> (self: ScopeDisplay) {
    self.background = gfx.hex(background)
    return
}

destroy_scope_display :: proc(self: ^ScopeDisplay) {
    delete(self.trace)
    delete(self.trace_colors)
    delete(self.trace_light)
    for &frame in self.glow_frames {
        delete(frame.points)
        delete(frame.light)
    }
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
// color. The beam is a line through the sweeps' average or the newest sweep, see draw_scope_trace. It dims
// with the display's visibility, 1 is full.
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
// Round the circle with the afterglow on, the circle of a moment ago is behind it, see draw_afterglow.
draw_scope_trace :: proc(
    self: ^ScopeDisplay,
    rect: gfx.Rect,
    scope: ^core.Scope,
    beam: ScopeBeam,
    afterglow: bool,
    beam_color: gfx.Color,
) {
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
    resize(&self.trace_light, len(self.trace))

    if beam == .SOLID {
        slice.fill(self.trace_light[:], 1)
    } else {
        // How far the beam goes from one point to the next on a flat line, a sweep's way at the wave's zero
        way := rect.width
        if scope.sweep == .CIRCLE do way = math.TAU * core.SCOPE_CIRCLE_REACH * core.SCOPE_CIRCLE_RING * rect.width
        flat := way / f32(len(self.trace) - 1)

        // Each point as far as the beam goes to the next one, or from the one before where it starts over
        for &light, index in self.trace_light {
            next := index + 1
            if next == len(self.trace) || wraps(self, rect, index, next) do next = max(index - 1, 0)

            delta := self.trace[next] - self.trace[index]
            distance := math.sqrt(delta.x * delta.x + delta.y * delta.y)
            light = min(SCOPE_PHOSPHOR_EXPOSURE * flat / max(distance, 1e-6), 1)
        }
    }

    // The ends of a circle that doesn't close faded, see SCOPE_END_FADE
    if scope.sweep == .CIRCLE {
        gap := self.trace[len(self.trace) - 1] - self.trace[0]
        depth := clamp(math.sqrt(gap.x * gap.x + gap.y * gap.y) / SCOPE_END_GAP, 0, 1)
        count := len(self.trace)
        ends := max(int(SCOPE_END_FADE * f32(count)), 1)
        for index in 0 ..< min(ends, count / 2) {
            ramp := math.lerp(f32(1), math.smoothstep(f32(0), f32(1), f32(index) / f32(ends)), depth)
            self.trace_light[index] *= ramp
            self.trace_light[count - 1 - index] *= ramp
        }
    }

    // The circle of a moment ago behind it. Off, or over time, it forgets what it kept, so it starts afresh.
    if afterglow && scope.sweep == .CIRCLE {
        center := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}
        keep_afterglow_frame(self, center)
        draw_afterglow(self, center, beam, beam_color)
    } else {
        self.glow_count = 0
    }

    // Solid, as bright all along but for the circle's faded ends
    if beam == .SOLID {
        for &color, index in self.trace_colors {
            color = lerp_color(self.background, beam_color, self.visibility * self.trace_light[index])
        }
        draw_pieces(self, rect, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER)
        return
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

// Keeps the newest trace for the afterglow, its points from the middle and their light, unless the last one
// kept is too recent. A display hidden for a while comes back to frames too old to be picked.
keep_afterglow_frame :: proc(self: ^ScopeDisplay, center: [2]f32) {
    now := time.tick_now()
    newest := &self.glow_frames[self.glow_newest]
    if self.glow_count > 0 && time.duration_seconds(time.tick_diff(newest.tick, now)) < SCOPE_AFTERGLOW_KEEP_S do return

    self.glow_newest = (self.glow_newest + 1) % SCOPE_AFTERGLOW_FRAMES
    self.glow_count = min(self.glow_count + 1, SCOPE_AFTERGLOW_FRAMES)
    frame := &self.glow_frames[self.glow_newest]
    frame.tick = now
    resize(&frame.points, len(self.trace))
    resize(&frame.light, len(self.trace))
    for point, index in self.trace do frame.points[index] = point - center
    copy(frame.light[:], self.trace_light[:])
}

// The afterglow's sweeps, the oldest first so the newer are drawn over it: for each delay the kept trace nearest
// that long ago, smaller and dimmer about the middle. None where nothing was kept near that long ago, as when
// the circle has only just come up. Phosphor, each glows under its line like the newest.
draw_afterglow :: proc(self: ^ScopeDisplay, center: [2]f32, beam: ScopeBeam, beam_color: gfx.Color) {
    now := time.tick_now()
    for sweep := SCOPE_AFTERGLOW_SWEEPS; sweep >= 1; sweep -= 1 {
        delay := f64(sweep) * SCOPE_AFTERGLOW_DELAY_S
        nearest, miss := -1, max(f64)
        for back in 0 ..< self.glow_count {
            index := (self.glow_newest - back + SCOPE_AFTERGLOW_FRAMES) % SCOPE_AFTERGLOW_FRAMES
            age := time.duration_seconds(time.tick_diff(self.glow_frames[index].tick, now))
            if abs(age - delay) < miss do nearest, miss = index, abs(age - delay)
        }
        if nearest < 0 || miss > SCOPE_AFTERGLOW_DELAY_S / 2 do continue

        frame := &self.glow_frames[nearest]
        if len(frame.points) < 2 do continue

        size := math.pow(f32(SCOPE_AFTERGLOW_SHRINK), f32(sweep))
        brightness := self.visibility * math.pow(f32(SCOPE_AFTERGLOW_FADE), f32(sweep))
        points := make([][2]f32, len(frame.points), context.temp_allocator)
        colors := make([]gfx.Color, len(frame.points), context.temp_allocator)
        for point, index in frame.points do points[index] = center + size * point

        // Closed like the newest, where it ends where it started
        gap := frame.points[len(frame.points) - 1] - frame.points[0]
        closed := abs(gap.x) + abs(gap.y) < 0.01

        if beam == .PHOSPHOR {
            for &color, index in colors {
                color = lerp_color(self.background, beam_color, brightness * frame.light[index] * SCOPE_GLOW)
            }
            gfx.draw_soft_polyline(points, colors, SCOPE_GLOW_THICKNESS, 0.5 * SCOPE_GLOW_THICKNESS, closed)
        }
        for &color, index in colors do color = lerp_color(self.background, beam_color, brightness * frame.light[index])
        gfx.draw_soft_polyline(points, colors, SCOPE_TRACE_THICKNESS, SCOPE_TRACE_FEATHER, closed)
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
