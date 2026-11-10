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

import "core:fmt"
import "core:math"

import "../core"
import "../gfx"

// The debug plots of the DEBUG_STATS build, the NSDF of the latest pitch detection. The harmonic stack's are in
// debug_spectrogram.odin.

// The NSDF over the first lags, a cross on each key maximum, the one the ratio picks pink and the one the
// detection used ringed. 1 at the top, the NSDF of the zero lag.
draw_nsdf :: proc(rect: gfx.Rect, nsdf: ^core.NSDF, font: gfx.Font) {
    LAGS :: 1500
    points: [LAGS][2]f32

    // A slow input's window has fewer lags, 1024 at 8 kHz
    shown := min(LAGS, len(nsdf.values))
    lag_width := rect.width / f32(LAGS - 1)
    middle := rect.y + rect.height / 2
    for &point, lag in points[:shown] {
        point = {rect.x + f32(lag) * lag_width, middle - nsdf.values[lag] * (rect.height / 2)}
    }

    draw_time_plot(rect, LAGS, 1000, font)
    gfx.draw_polyline(points[:shown], 1, gfx.GOLD)

    for peak, index in nsdf.peaks {
        cross := [2]f32{rect.x + peak.x * lag_width, middle - peak.y * (rect.height / 2)}
        if cross.x > rect.x + rect.width do break

        // A line down to the frequency, every other one lower so they don't overlap
        gfx.draw_line(cross, {cross.x, rect.y + rect.height}, 0.5, gfx.LIGHTGRAY)
        label_y := rect.y + rect.height + (24 if index % 2 == 0 else 8)
        gfx.draw_text(font, fmt.ctprintf("%.2fHz", nsdf.sample_rate / peak.x), {cross.x, label_y}, 12, 0, gfx.LIGHTGRAY)

        // The frame's own pick pink, by the ratio to the highest
        color := gfx.PINK if index == nsdf.ratio_peak else gfx.LIGHTGRAY
        gfx.draw_line(cross - {7, 0}, cross + {7, 0}, 2.0, color)
        gfx.draw_line(cross - {0, 7}, cross + {0, 7}, 2.0, color)

        // The pick the detection used, the followed pitch's held over the ratio's, ringed in white: gold
        // ran into the curve
        if index == nsdf.chosen_peak {
            RING_RADIUS :: 5.5
            RING_SEGMENTS :: 24
            ring: [RING_SEGMENTS][2]f32
            for &point, segment in ring {
                angle := f32(segment) / RING_SEGMENTS * math.TAU
                point = cross + RING_RADIUS * [2]f32{math.cos(angle), math.sin(angle)}
            }
            gfx.draw_polyline(ring[:], 1.5, gfx.WHITE, closed = true)
        }
    }
}


draw_time_plot :: proc(rect: gfx.Rect, len_samples: int, div_samples: int, font: gfx.Font) {
    // Horizontal lines at 1,0,-1
    gfx.draw_line({rect.x, rect.y}, {rect.x + rect.width, rect.y}, 0.5, gfx.LIGHTGRAY)
    draw_axis_label(rect, rect.y, "1", font)

    gfx.draw_line(
        {rect.x, rect.y + rect.height / 2},
        {rect.x + rect.width, rect.y + rect.height / 2},
        0.5,
        gfx.LIGHTGRAY,
    )
    draw_axis_label(rect, rect.y + rect.height / 2, "0", font)

    gfx.draw_line(
        {rect.x, rect.y + rect.height},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        gfx.LIGHTGRAY,
    )
    draw_axis_label(rect, rect.y + rect.height, "-1", font)

    // Vertical lines every div_samples
    sample_width := rect.width / f32(len_samples)
    for sample := 0; sample < len_samples; sample += div_samples {
        x := rect.x + f32(sample) * sample_width
        gfx.draw_line({x, rect.y}, {x, rect.y + rect.height}, 0.5, gfx.LIGHTGRAY)
    }

    gfx.draw_line(
        {rect.x + rect.width, rect.y},
        {rect.x + rect.width, rect.y + rect.height},
        0.5,
        gfx.LIGHTGRAY,
    )
}

// The name of a line across a plot at y, left of the plot and right aligned so the digits line up
draw_axis_label :: proc(rect: gfx.Rect, y: f32, text: cstring, font: gfx.Font) {
    GAP :: 6 // from the name to the plot

    width := gfx.measure_text(font, text, 12, 0).x
    gfx.draw_text(font, text, {rect.x - GAP - width, y - 6}, 12, 0, gfx.LIGHTGRAY)
}

