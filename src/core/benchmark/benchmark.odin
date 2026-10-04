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


// What the strobe's and the pitch detection's transforms cost a frame, with the window sizes the app uses:
//
//   odin run src/core/benchmark -o:speed -microarch:native
//
// Every result is added into a sum that's printed at the end, an unused one would be optimised away along
// with the loop that made it.
package benchmark

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:time"

import ".."
import pffft "../../../external/odin-pffft"

SAMPLERATE :: core.SAMPLERATE
ITERATIONS :: 1000
TRACKS :: 5 // core.MAX_BANDS, every track on the fundamental's window
FRAMES_PER_SECOND :: 120

main :: proc() {
    samples := make([]f32, core.MAX_WINDOW_SIZE)
    defer delete(samples)
    for &sample in samples do sample = rand.float32_range(-1, 1)

    sink: f32

    {
        out := make([]f32, core.PITCH_FFT_SIZE)
        defer delete(out)
        setup := pffft.new_setup(core.PITCH_FFT_SIZE, pffft.Transform.REAL)
        defer pffft.destroy_setup(setup)

        stopwatch: time.Stopwatch
        time.stopwatch_start(&stopwatch)
        for _ in 0 ..< ITERATIONS {
            pffft.transform_ordered(setup, raw_data(samples), raw_data(out), nil, pffft.Direction.FORWARD)
            sink += out[1]
        }
        time.stopwatch_stop(&stopwatch)
        microseconds := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS
        fmt.printfln("pffft, %v points (pitch detection): %.1f µs", core.PITCH_FFT_SIZE, microseconds)
    }

    // A track's window as set_phase_comparator_freq sizes it, the comb's box of one period included
    notes := []struct {
        name:    string,
        freq_hz: f32,
    }{{"E1", 41.2}, {"A2", 110}, {"A4", 440}}

    for note in notes {
        window_size := core.dft_window_size(note.freq_hz, SAMPLERATE, core.DFT_RESOLUTION_CENTS)
        dft: core.SingleFreqDFT
        defer core.destroy_dft(&dft)
        core.set_dft_freq(&dft, note.freq_hz / SAMPLERATE, core.gamma_comb_window(window_size, SAMPLERATE / note.freq_hz))

        stopwatch: time.Stopwatch
        time.stopwatch_start(&stopwatch)
        for _ in 0 ..< ITERATIONS {
            sink += real(core.run_single_dft(&dft, samples))
        }
        time.stopwatch_stop(&stopwatch)
        microseconds := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS

        // Of one core, with every track measured on every frame
        core_share := microseconds * TRACKS * FRAMES_PER_SECOND / 1e6
        fmt.printfln(
            "Single bin DFT, %v (%v samples): %.1f µs, %v tracks at %v fps %.2f%% of a core",
            note.name,
            dft.window_size,
            microseconds,
            TRACKS,
            FRAMES_PER_SECOND,
            100 * core_share,
        )
    }

    // The scope's screen as the app makes it (STROBE_WIDTH × SCOPE_ROWS) at the default persistence. A frame's
    // samples swept onto it, the screen from above for the lamp, and how many of its cells are lit, the dots
    // the scope shader draws (draw_scope_screen's cut-off, a third of a column's dwell is full brightness).
    // An in tune note draws a thin line, a detuned one smears over more cells.
    SCOPE_COLUMNS :: 488
    SCOPE_ROWS :: 240
    SCOPE_FRAME :: SAMPLERATE / 60
    SCOPE_FRAMES :: 300

    scope_notes := []struct {
        name:    string,
        freq_hz: f64,
        cents:   f64,
    }{{"A2 in tune", 110, 0}, {"A2 +30¢", 110, 30}, {"A4 in tune", 440, 0}}

    for note in scope_notes {
        scope := core.init_scope(SCOPE_COLUMNS, SCOPE_ROWS)
        defer core.destroy_scope(&scope)
        core.set_scope_freq(&scope, note.freq_hz)
        scope.persistence_seconds = 0.04

        played_hz := note.freq_hz * math.pow(2, note.cents / 1200)
        chunk: [SCOPE_FRAME]f32
        sweep, from_above: time.Duration
        for _ in 0 ..< SCOPE_FRAMES {
            clock := scope.sample_clock
            for &sample, index in chunk do sample = f32(0.5 * math.sin(math.TAU * played_hz * f64(clock + i64(index)) / SAMPLERATE))

            start := time.tick_now()
            core.sweep_samples(&scope, chunk[:])
            sweep += time.tick_since(start)

            start = time.tick_now()
            heights, _ := core.scope_from_above(&scope, .HALF_RECTIFIED)
            from_above += time.tick_since(start)
            sink += heights[0]
        }

        total: f32 = 0
        for dwell in scope.screen do total += dwell
        full := total / SCOPE_COLUMNS
        lit := 0
        for dwell in scope.screen {
            if 3 * dwell / full >= 0.02 do lit += 1
        }

        fmt.printfln(
            "Scope %v: sweep %.1f µs, from above %.1f µs a frame, %v of %v cells lit",
            note.name,
            time.duration_microseconds(sweep) / SCOPE_FRAMES,
            time.duration_microseconds(from_above) / SCOPE_FRAMES,
            lit,
            SCOPE_COLUMNS * SCOPE_ROWS,
        )
    }

    fmt.println("(sum", sink, "keeps the results)")
}
