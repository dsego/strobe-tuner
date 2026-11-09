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
        fade := slat_fade(note_periods = 1)
        for measurement in 0 ..< 40 {
            swing := scatter if measurement % 2 == 0 else -scatter
            add_slat_measurement(&slats.measurements[0], complex(1, swing), fade)
        }
        return strobe_slat_level(&slats, 0)
    }

    testing.expect(t, level_of(0) > 0.99)
    testing.expect(t, level_of(0.2) > 0.99)
    middle := level_of(0.5)
    testing.expect(t, middle > 0.1 && middle < 0.9)
    testing.expect_value(t, level_of(1), 0)

    one: StrobeSlats
    add_slat_measurement(&one.measurements[0], 1, slat_fade(note_periods = 1))
    testing.expect_value(t, strobe_slat_level(&one, 0), 0)

    // An attack: one direction growing from a tenth of the partial to all of it isn't scatter
    attack: StrobeSlats
    for measurement in 0 ..< 8 {
        size := min(0.1 + 0.3 * f32(measurement), 1)
        add_slat_measurement(&attack.measurements[0], complex(size, 0), slat_fade(note_periods = 1))
    }
    testing.expect(t, strobe_slat_level(&attack, 0) > 0.99)
}

// A clean note off the reference: its partials go round steadily in the measurements, the drift the stripes show.
// It isn't noise, every track stays fully lit, the 4× one turning four times as fast as the 1×.
@(test)
test_slat_level_off_the_reference :: proc(t: ^testing.T) {
    FRAME :: 400
    E2 :: 82.41

    for detune_cents in ([]f32{-30, 10, 30}) {
        lock_in := test_lock_in(E2, {1, 2, 4})
        defer destroy_strobe_lock_in(lock_in)

        samples := test_samples(2)
        add_partials(samples, f64(freq_at_cents(E2, detune_cents)), {0.2, 0.1, 0, 0.05})
        played := 0
        for _ in play_frames(lock_in, samples, &played, FRAME) {}

        for band, index in lock_in.bands {
            testing.expectf(t, band.slat_level == 1, "%+.0f cents: track %v lit at %.2f", detune_cents, index, band.slat_level)
        }
    }
}

// C8 55 cents sharp, the top of sandbox/accuracy, in noise 20 dB under it as there: the 1× track's stripes stay at
// least half lit, the strobe keeps the note when the pitch detection loses it
@(test)
test_slat_level_high_note_in_noise :: proc(t: ^testing.T) {
    FRAME :: 800 // a 60th of a second
    C8 :: 4186.01
    TONE_RMS :: 0.1

    lock_in := test_lock_in(C8, {1, 2, 4})
    defer destroy_strobe_lock_in(lock_in)

    samples := test_samples(2.5)
    add_partials(samples, f64(freq_at_cents(C8, 55)), {math.SQRT_TWO * TONE_RMS})
    add_noise(samples, 0.1 * TONE_RMS, ACCURACY_NOISE_SEED)

    lowest: f32 = 1
    played := 0
    for end_s in play_frames(lock_in, samples, &played, FRAME) {
        // Past the first second, the stripes lit by then
        if end_s > 1 do lowest = min(lowest, lock_in.bands[0].visibility)
    }
    testing.expectf(t, lowest >= 0.5, "the 1× track's stripes went down to %.2f", lowest)
}

// A clean pluck after a little hiss: how soon its stripes light, at A2 a period of the note is 9.1 ms. Its first
// windows only partly hold the note, their measurements grow into it as they point the same way.
@(test)
test_slat_level_lights_a_pluck :: proc(t: ^testing.T) {
    FRAME :: 400 // a 120th of a second
    A2 :: 110.0
    PLUCK_S :: 0.5

    lock_in := test_lock_in(A2, {1, 2, 4})
    defer destroy_strobe_lock_in(lock_in)

    samples := test_samples(1)
    add_noise(samples, 1e-4)
    add_partials(samples, A2, {0.3, 0.15, 0, 0.075}, from_s = PLUCK_S, decay_s = 1.5)

    lit_s, full_s, half_drawn_s: f64 = -1, -1, -1
    played := 0
    for end_s in play_frames(lock_in, samples, &played, FRAME) {
        since_s := end_s - PLUCK_S
        if since_s < 0 do continue

        first := lock_in.bands[0]
        if lit_s < 0 && first.slat_level > 0 do lit_s = since_s
        if full_s < 0 && first.slat_level >= 1 do full_s = since_s
        if half_drawn_s < 0 && first.visibility >= 0.5 do half_drawn_s = since_s
    }
    log.infof("A2 plucked, 1×: lit after %.0f ms, full %.0f ms, half drawn %.0f ms", 1000 * lit_s, 1000 * full_s, 1000 * half_drawn_s)
    testing.expectf(t, half_drawn_s >= 0, "the 1× track never lit")
}

// A hum stopping into silence lets go within a few periods, it held a bass's low E over a second while the
// remembered measurements faded. A note fading out is held as long as before, still at -70 dBFS.
@(test)
test_slat_level_lets_go_of_a_stop :: proc(t: ^testing.T) {
    FRAME :: 400 // a 120th of a second
    STOP_S :: 1.5
    PARTIALS :: []f64{0.06, 0.025, 0, 0.008} // -24, -32 and -42 dBFS
    FADE_S :: 0.25 // to a third, the fundamental at -70 dBFS 1.31 s in
    FADED_S :: 1.3

    for note_hz in ([]f64{41.20, 92.50}) {
        stopped := test_lock_in(f32(note_hz), {1, 2, 4})
        defer destroy_strobe_lock_in(stopped)

        samples := test_samples(2.5)
        add_partials(samples[:int(STOP_S * f64(DEFAULT_SAMPLE_RATE))], note_hz, PARTIALS)
        held_at_stop := false
        let_go_s: f64 = -1
        played := 0
        for end_s in play_frames(stopped, samples, &played, FRAME) {
            if end_s <= STOP_S do held_at_stop = strobe_shows_note(stopped)
            if end_s > STOP_S && let_go_s < 0 && !strobe_shows_note(stopped) do let_go_s = end_s - STOP_S
        }
        log.infof("%.1f Hz stopped, let go after %.0f ms", note_hz, 1000 * let_go_s)
        testing.expectf(t, held_at_stop, "%.1f Hz: not held before it stopped", note_hz)
        testing.expectf(t, let_go_s >= 0 && let_go_s < 0.25, "%.1f Hz: let go %.2f s after it stopped", note_hz, let_go_s)

        fading := test_lock_in(f32(note_hz), {1, 2, 4})
        defer destroy_strobe_lock_in(fading)

        faded := test_samples(FADED_S)
        add_partials(faded, note_hz, PARTIALS, decay_s = FADE_S)
        played = 0
        for _ in play_frames(fading, faded, &played, FRAME) {}
        testing.expectf(t, strobe_shows_note(fading), "%.1f Hz: let go of a note fading out at -70 dBFS", note_hz)
    }
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

// A low note's 2nd partial alone, no fundamental: the 1× track has nothing of its own and stays gray. Measured
// over one span, a box, the 2× cancelled only on the reference: 7 and 23 cents off, as on the P-bass recordings
// shifted that far, it leaked in 40 dB under, louder than a bass's fundamental. The windows keep it out.
@(test)
test_slat_level_without_the_fundamental :: proc(t: ^testing.T) {
    FRAME :: 400
    C1 :: 32.70
    LEVEL :: 0.5 // the 2nd partial's peak

    for detune_cents in ([]f32{0, -7, 23}) {
        lock_in := test_lock_in(C1, {1, 2})
        defer destroy_strobe_lock_in(lock_in)

        samples := test_samples(3)
        add_partials(samples, f64(freq_at_cents(2 * C1, detune_cents)), {LEVEL})
        played := 0
        for _ in play_frames(lock_in, samples, &played, FRAME) {}

        // What the 1× track's slots and its lock-in hear of the 2×, in dB under it
        sums := lock_in.slats.measurements[0]
        slots_db := 20 * math.log10(abs(sums.sum) / sums.weight / LEVEL)
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
        // Well under a low string's fundamental, 58 to 65 dB under its 2nd partial on a bass. Gray too, though
        // that's the silence under STROBE_SLATS_SILENCE_DBFS this far down.
        testing.expectf(t, slots_db < -75, "%+.0f cents: the 2× leaks into the 1× slots %.1f dB under", detune_cents, slots_db)
        testing.expectf(t, first.slat_level == 0, "%+.0f cents: the 1× track lit at %.2f", detune_cents, first.slat_level)
    }
}
