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
//   odin run sandbox/benchmark -o:speed -microarch:native
//
// Every result is added into a sum that's printed at the end, an unused one would be optimised away along
// with the loop that made it.
package benchmark

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:time"

import "../../src/core"
import fft "../../external/extreme_fft"

SAMPLERATE :: core.DEFAULT_SAMPLE_RATE
PITCH_FFT_SIZE :: 8192 // the pitch detection's at 48 kHz, see core.PITCH_WINDOW_S
ITERATIONS :: 1000
TRACKS :: core.MAX_BANDS // every track on the fundamental's window
FRAMES_PER_SECOND :: 120

main :: proc() {
    samples := make([]f32, core.sample_buffer_size(SAMPLERATE))
    defer delete(samples)
    for &sample in samples do sample = rand.float32_range(-1, 1)

    sink: f32

    {
        spectrum := make([]complex64, PITCH_FFT_SIZE / 2)
        defer delete(spectrum)
        plan := fft.create_quad_plan(PITCH_FFT_SIZE)
        defer fft.destroy_quad_plan(&plan)

        stopwatch: time.Stopwatch
        time.stopwatch_start(&stopwatch)
        for _ in 0 ..< ITERATIONS {
            fft.run_quad(&plan, samples[:PITCH_FFT_SIZE], spectrum)
            sink += real(spectrum[1])
        }
        time.stopwatch_stop(&stopwatch)
        microseconds := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS
        fmt.printfln("extreme_fft, %v points (pitch detection): %.1f µs", PITCH_FFT_SIZE, microseconds)
    }

    // The pitch detection's two ways a detection, see core.PitchMethod: the NSDF over the window, and the
    // harmonic stack's two transforms, the short one and the bass one, their backgrounds, peaks and stacks. Noise
    // has the most peaks to go through, a note the most stacks to score.
    {
        window := core.pitch_window(SAMPLERATE)
        bass_window := core.HARMONICS_BASS_WINDOWS * window
        lowest_hz := core.freq_at_cents(440, core.LOWEST_NOTE * 100 - 50)
        highest_hz := core.freq_at_cents(440, core.HIGHEST_NOTE * 100 + 50)
        top_hz := core.pitch_lowpass_hz(SAMPLERATE)

        nsdf := core.init_nsdf(2 * window, SAMPLERATE)
        defer core.destroy_nsdf(&nsdf)

        stack := core.init_harmonic_stack(window, SAMPLERATE)
        defer core.destroy_harmonic_stack(&stack)

        // A2's first 10 harmonics falling like a string's, about 45 dB over the noise
        note := make([]f32, bass_window)
        defer delete(note)
        for &sample, index in note {
            sample = 0.003 * samples[index]
            for harmonic in 1 ..= 10 {
                phase := math.TAU * 110 * f64(harmonic * index) / SAMPLERATE
                sample += f32(0.3 / f64(harmonic) * math.sin(phase))
            }
        }

        // The six open strings strummed, 60 partials for the most peaks
        chord := make([]f32, bass_window)
        defer delete(chord)
        for &sample, index in chord {
            sample = 0.003 * samples[index]
            for string_hz in ([]f64{82.41, 110, 146.83, 196, 246.94, 329.63}) {
                for harmonic in 1 ..= 10 {
                    phase := math.TAU * string_hz * f64(harmonic * index) / SAMPLERATE
                    sample += f32(0.05 / f64(harmonic) * math.sin(phase))
                }
            }
        }

        signals := []struct {
            name:    string,
            samples: []f32,
        }{{"noise", samples[:bass_window]}, {"A2 over noise", note}, {"open strings strummed", chord}}

        for signal in signals {
            stopwatch: time.Stopwatch
            time.stopwatch_start(&stopwatch)
            for _ in 0 ..< ITERATIONS {
                freq, _ := core.run_nsdf(&nsdf, signal.samples[bass_window - window:], lowest_hz)
                sink += freq
            }
            time.stopwatch_stop(&stopwatch)
            wave := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS

            stopwatch = {}
            time.stopwatch_start(&stopwatch)
            for _ in 0 ..< ITERATIONS {
                freq, _ := core.run_harmonic_stack(&stack, signal.samples, lowest_hz, top_hz, highest_hz = highest_hz)
                sink += freq
            }
            time.stopwatch_stop(&stopwatch)
            harmonics := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS

            // Of one core, a detection every display frame at 60 fps
            share :: proc(microseconds: f64) -> f64 {
                return 100 * microseconds * core.DETECTIONS_PER_SECOND / 1e6
            }
            fmt.printfln(
                "Pitch detection, %v (%v samples): NSDF %.1f µs, harmonic stack %.1f µs, at %v a second %.2f%% and %.2f%% of a core",
                signal.name,
                window,
                wave,
                harmonics,
                core.DETECTIONS_PER_SECOND,
                share(wave),
                share(harmonics),
            )
        }
    }

    // A track's window as set_strobe_lock_in_freq sizes it, the comb's box of one period included
    notes := []struct {
        name:    string,
        freq_hz: f32,
    }{{"E1", 41.2}, {"A2", 110}, {"A4", 440}}

    for note in notes {
        // A track per partial, each on the fundamental's window
        window_size := core.dft_window_size(note.freq_hz, SAMPLERATE, core.DFT_RESOLUTION_CENTS)
        window := core.gamma_comb_window(window_size, SAMPLERATE / note.freq_hz)
        dfts: [TRACKS]core.SingleFreqDFT
        tracks: [TRACKS]^core.SingleFreqDFT
        for &dft, index in dfts {
            core.set_dft_freq(&dft, f32(index + 1) * note.freq_hz / SAMPLERATE, window)
            tracks[index] = &dft
        }
        defer for &dft in dfts do core.destroy_dft(&dft)

        // Each track on its own, then all of them at once as run_phase_detection does
        stopwatch: time.Stopwatch
        time.stopwatch_start(&stopwatch)
        for _ in 0 ..< ITERATIONS {
            for &dft in dfts do sink += real(core.run_single_dft(&dft, samples))
        }
        time.stopwatch_stop(&stopwatch)
        separate := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS

        stopwatch = {}
        time.stopwatch_start(&stopwatch)
        for _ in 0 ..< ITERATIONS {
            core.run_single_dfts(tracks[:], samples)
            sink += real(dfts[0].dft)
        }
        time.stopwatch_stop(&stopwatch)
        fused := time.duration_microseconds(time.stopwatch_duration(stopwatch)) / ITERATIONS

        // Of one core, every track measured a hop apart through each frame's new samples, as
        // run_phase_detection does, the hops of a frame rounded up
        hops_per_frame := math.ceil(core.HOPS_PER_PERIOD * note.freq_hz / FRAMES_PER_SECOND)
        core_share := fused * f64(hops_per_frame) * FRAMES_PER_SECOND / 1e6
        fmt.printfln(
            "Single bin DFTs, %v (%v samples, %v tracks): %.1f µs apart, %.1f µs fused, %v hops a frame at %v fps %.2f%% of a core",
            note.name,
            dfts[0].window_size,
            TRACKS,
            separate,
            fused,
            hops_per_frame,
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
        scope.persistence_s = 18 / note.freq_hz // the app's default 18 periods

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
