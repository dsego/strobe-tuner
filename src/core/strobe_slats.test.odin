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
#+build !js
package core

import "core:log"
import "core:math"
import "core:testing"


// Measurements of the same partial are full stripes. Measurements that scatter around it gray them by how
// uncertain their average is, a little scatter not at all. One isn't enough to tell.
@(test)
test_strobe_slat_level :: proc(t: ^testing.T) {
    // 40 measurements a period of the note apart, the partial at 1 and its phase swinging up and down by scatter
    level_of :: proc(scatter: f32) -> f32 {
        slats: StrobeSlats
        for measurement in 0 ..< 40 {
            swing := scatter if measurement % 2 == 0 else -scatter
            add_slat_measurement(&slats.measurements[0], 1, swing, 1)
        }
        return strobe_slat_level(&slats, 0)
    }

    when !STROBE_SLATS_HALVES {
        testing.expect(t, level_of(0) > 0.99)
        testing.expect(t, level_of(0.3) > 0.99)
        middle := level_of(0.7)
        testing.expect(t, middle > 0.1 && middle < 0.9)
        testing.expect_value(t, level_of(1.2), 0)

        one: StrobeSlats
        add_slat_measurement(&one.measurements[0], 1, 0, 1)
        testing.expect_value(t, strobe_slat_level(&one, 0), 0)
    }
}

// A clean note off the reference: its partials go round steadily in the measurements, the drift the stripes show.
// It isn't noise, every track stays fully lit, the 4× one turning four times as fast as the 1×.
@(test)
test_slat_level_off_the_reference :: proc(t: ^testing.T) {
    when STROBE_SLATS_HALVES do return

    FRAME :: 400
    E2 :: 82.41

    for detune_cents in ([]f32{-30, 10, 30}) {
        lock_in := init_strobe_lock_in(E2, {1, 2, 4}, .HARMONIC)
        defer destroy_strobe_lock_in(lock_in)
        set_strobe_lock_in_freq(lock_in, E2, 440, 0.025, 2, .HARMONIC)

        freq_hz := f64(freq_at_cents(E2, detune_cents))
        chunk: [FRAME]f32
        clock := 0
        for _ in 0 ..< 2 * int(DEFAULT_SAMPLE_RATE) / FRAME {
            for &sample in chunk {
                phase := math.TAU * freq_hz * f64(clock) / f64(DEFAULT_SAMPLE_RATE)
                sample = f32(0.2 * math.sin(phase) + 0.1 * math.sin(2 * phase) + 0.05 * math.sin(4 * phase))
                clock += 1
            }
            audio_capture_write(lock_in, chunk[:])
            run_phase_detection(lock_in, is_tonal = true)
        }

        for band, index in lock_in.bands {
            testing.expectf(t, band.slat_level == 1, "%+.0f cents: track %v lit at %.2f", detune_cents, index, band.slat_level)
        }
    }
}

// C8 55 cents sharp, the top of sandbox/accuracy, in noise 20 dB under it as there: the 1× track's stripes stay at
// least half lit, the strobe keeps the note when the pitch detection loses it
@(test)
test_slat_level_high_note_in_noise :: proc(t: ^testing.T) {
    when STROBE_SLATS_HALVES do return

    FRAME :: 800 // a 60th of a second
    C8 :: 4186.01
    TONE_RMS :: 0.1

    lock_in := init_strobe_lock_in(C8, {1, 2, 4}, .HARMONIC)
    defer destroy_strobe_lock_in(lock_in)
    set_strobe_lock_in_freq(lock_in, C8, 440, 0.025, 2, .HARMONIC)

    freq_hz := f64(freq_at_cents(C8, 55))
    noise_rms := TONE_RMS * math.pow(f32(10), -20.0 / 20)
    random := u32(0x9e3779b9)
    chunk: [FRAME]f32
    clock := 0
    lowest: f32 = 1
    for frame in 0 ..< 150 {
        for &sample in chunk {
            random ~= random << 13
            random ~= random >> 17
            random ~= random << 5
            uniform := f32(random) / f32(max(u32)) * 2 - 1
            tone := math.SQRT_TWO * TONE_RMS * math.sin(math.TAU * freq_hz * f64(clock) / f64(DEFAULT_SAMPLE_RATE))
            sample = f32(tone) + noise_rms * math.SQRT_THREE * uniform
            clock += 1
        }
        audio_capture_write(lock_in, chunk[:])
        run_phase_detection(lock_in, is_tonal = true)

        first := lock_in.bands[0]
        if frame >= 60 do lowest = min(lowest, first.visibility)
        if frame % 15 == 14 {
            log.infof(
                "%.2f s: 1× level %.2f, stripes %.2f, drift %.1f cents, envelope SNR %.1f dB",
                f32(clock) / DEFAULT_SAMPLE_RATE,
                first.slat_level,
                first.visibility,
                first.drift_cents,
                first.envelope_snr_db,
            )
        }
    }
    testing.expectf(t, lowest >= 0.5, "the 1× track's stripes went down to %.2f", lowest)
}

// Windows SLAT_WINDOW_SPANS spans long, one closing every span, share the noise where they overlap: white noise
// through two of them a span apart is as correlated as their weights overlap, and two spans apart. One and twice
// those is how many measurements share as much noise as one.
@(test)
test_slat_window_overlap :: proc(t: ^testing.T) {
    SAMPLES :: 3000 // across a window

    squares: f64 = 0
    shared: [SLAT_WINDOW_SPANS]f64
    for index in 0 ..< SAMPLES {
        weight := slat_window((f64(index) + 0.5) / SAMPLES)
        squares += weight * weight
        for later in 1 ..< SLAT_WINDOW_SPANS {
            shifted := index + later * SAMPLES / SLAT_WINDOW_SPANS
            if shifted < SAMPLES do shared[later] += weight * slat_window((f64(shifted) + 0.5) / SAMPLES)
        }
    }

    overlap: f64 = 1
    for later in 1 ..< SLAT_WINDOW_SPANS do overlap += 2 * shared[later] / squares
    log.infof("the windows overlap by %.3f", overlap)
    testing.expectf(t, abs(overlap - SLAT_WINDOW_OVERLAP) < 0.005, "the windows overlap by %.3f", overlap)
}

// A low note's 2nd partial alone, no fundamental: the 1× track has nothing of its own and stays gray. A span is a
// period of the reference, it cancels the 2× only while the note is on the reference. Off it, as on the P-bass
// recordings shifted by 7 and 23 cents, the 2× leaks in and turns slowly from span to span.
@(test)
test_slat_level_without_the_fundamental :: proc(t: ^testing.T) {
    FRAME :: 400
    C1 :: 32.70
    LEVEL :: 0.5 // the 2nd partial's peak

    for detune_cents in ([]f32{0, -7, 23}) {
        lock_in := init_strobe_lock_in(C1, {1, 2}, .HARMONIC)
        defer destroy_strobe_lock_in(lock_in)
        set_strobe_lock_in_freq(lock_in, C1, 440, 0.025, 2, .HARMONIC)

        freq_hz := f64(freq_at_cents(2 * C1, detune_cents))
        chunk: [FRAME]f32
        clock := 0
        for _ in 0 ..< 3 * int(DEFAULT_SAMPLE_RATE) / FRAME {
            for &sample in chunk {
                sample = f32(LEVEL * math.sin(math.TAU * freq_hz * f64(clock) / f64(DEFAULT_SAMPLE_RATE)))
                clock += 1
            }
            audio_capture_write(lock_in, chunk[:])
            run_phase_detection(lock_in, is_tonal = true)
        }

        // What the 1× track's slots and its lock-in hear of the 2×, in dB under it
        sums := lock_in.slats.measurements[0]
        slots_db := 20 * math.log10(math.sqrt(sums.cosine * sums.cosine + sums.sine * sums.sine) / sums.weight / LEVEL)
        lock_in_db := 20 * math.log10(lock_in.bands[0].amp / lock_in.bands[1].amp)
        first := lock_in.bands[0]
        log.infof(
            "2× alone %+.0f cents: 1× slots %.1f dB, lock-in %.1f dB under the 2×, level %.2f, stripes %.2f",
            detune_cents,
            slots_db,
            lock_in_db,
            first.slat_level,
            first.visibility,
        )
        testing.expectf(t, first.slat_level == 0, "%+.0f cents: the 1× track lit at %.2f", detune_cents, first.slat_level)
    }
}

// The slots' halves: a track's own partial in the slots is full stripes, under a 2nd partial as loud and a 3×
// five times as loud too. Noise on both halves of every slot grays them by how much it weighs against the
// partial.
@(test)
test_slat_halves_level :: proc(t: ^testing.T) {
    // The track's partial and its 2× and 3× at these levels, noise on both halves of every slot
    fill :: proc(slats: ^StrobeSlats, levels: [3]f32, noise: f32) {
        for bin in 0 ..< SLAT_BINS {
            angle := math.TAU * f32(bin) / SLAT_BINS
            value: f32 = 0
            for level, index in levels do value += level * math.cos(f32(index + 1) * angle)

            slats.positive[0][bin] = max(value, 0) + noise
            slats.negative[0][bin] = max(-value, 0) + noise
            slats.weight[0][bin] = 1
        }
    }

    slats: StrobeSlats
    fill(&slats, {1, 0, 0}, 0)
    testing.expect(t, abs(slat_halves_level(&slats, 0) - 1) < 0.01)
    fill(&slats, {1, 1, 0}, 0)
    testing.expect(t, abs(slat_halves_level(&slats, 0) - 1) < 0.01)
    fill(&slats, {0.2, 0, 1}, 0)
    testing.expect(t, abs(slat_halves_level(&slats, 0) - 1) < 0.01)

    // Noise 0.9 of the partial's level in every slot, 0.1 left, times the gain
    fill(&slats, {1, 0, 0}, 0.9)
    testing.expect(t, abs(slat_halves_level(&slats, 0) - min(0.1 * STROBE_SLATS_GAIN, 1)) < 0.01)

    // Nothing came in, gray
    empty: StrobeSlats
    testing.expect_value(t, slat_halves_level(&empty, 0), 0)
}

// The 2× track's slots span a period of the note, two of its own. A fundamental twice as loud as the 2×
// partial stands still in them, on one side of zero in each, the 2× track's stripes are full.
@(test)
test_slat_halves_level_octave :: proc(t: ^testing.T) {
    slats: StrobeSlats
    slats.periods[0] = 2
    for bin in 0 ..< 2 * SLAT_BINS {
        angle := math.TAU * f32(bin) / (2 * SLAT_BINS) // of the note
        value := math.cos(angle) + 0.5 * math.cos(2 * angle)
        slats.positive[0][bin] = max(value, 0)
        slats.negative[0][bin] = max(-value, 0)
        slats.weight[0][bin] = 1
    }
    testing.expect(t, abs(slat_halves_level(&slats, 0) - 1) < 0.01)
}
