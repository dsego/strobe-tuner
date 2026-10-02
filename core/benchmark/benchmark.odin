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
//   odin run core/benchmark -o:speed -microarch:native
//
// Every result is added into a sum that's printed at the end, an unused one would be optimised away along
// with the loop that made it.
package benchmark

import "core:fmt"
import "core:math/rand"
import "core:time"

import ".."
import pffft "../../external/odin-pffft"

SAMPLERATE :: 48_000
ITERATIONS :: 1000
PITCH_FFT_SIZE :: 8192 // config_defaults.pitch_detect_fft_size
TRACKS :: 5 // core.MAX_BANDS, every track on the fundamental's window
FRAMES_PER_SECOND :: 120

main :: proc() {
    samples := make([]f32, core.MAX_WINDOW_SIZE)
    defer delete(samples)
    for &sample in samples do sample = rand.float32_range(-1, 1)

    sink: f32

    {
        out := make([]f32, PITCH_FFT_SIZE)
        defer delete(out)
        setup := pffft.new_setup(PITCH_FFT_SIZE, pffft.Transform.REAL)
        defer pffft.destroy_setup(setup)

        stopwatch: time.Stopwatch
        time.stopwatch_start(&stopwatch)
        for _ in 0 ..< ITERATIONS {
            pffft.transform_ordered(setup, raw_data(samples), raw_data(out), nil, pffft.Direction.FORWARD)
            sink += out[1]
        }
        time.stopwatch_stop(&stopwatch)
        microseconds := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS
        fmt.printfln("pffft, %v points (pitch detection): %.1f µs", PITCH_FFT_SIZE, microseconds)
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
        core.set_dft_freq(&dft, note.freq_hz / SAMPLERATE, window_size, comb_samples = SAMPLERATE / note.freq_hz)

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

    fmt.println("(sum", sink, "keeps the results)")
}
