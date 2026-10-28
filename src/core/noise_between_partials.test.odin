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
import "core:math/rand"
import "core:testing"


// What a scenario plays: a note's partials over noise, and whatever else the gaps between them may hold
NoiseScenario :: struct {
    name:         string,
    base_hz:      f64,
    duration_s:   f64,
    noise_rms:    f64, // white, before the low-pass
    partials_rms: f64, // the note's first 8 partials, the nth 1/n of it
    lowpass_hz:   f64, // a one-pole low-pass colouring the noise, 0 leaves it white
    tones:        []NoiseTone, // a resonance, another note's or a ringing string's partials
    bursts:       []NoiseBurst, // the noise louder for a while
}

NoiseTone :: struct {
    freq_hz, rms: f64,
}

NoiseBurst :: struct {
    from_s, to_s, gain: f64,
}

// Within the couple of dB the median swings by
NOISE_TOLERANCE_DB :: 3


// White noise of a known level, alone and under a note's partials: each track reads the noise between them as
// the noise its own window lets through. A clean input's partials stand far over the noise, their sidelobes
// stay under it in the gaps.
@(test)
test_noise_between_partials :: proc(t: ^testing.T) {
    for base_hz in ([]f64{41.2, 55, 73.4, 110, 146.8, 220, 293.7, 440, 587.3, 1046.5}) {
        for partials_rms in ([]f64{0, 0.3}) {
            scenario := NoiseScenario {
                base_hz      = base_hz,
                duration_s   = 2,
                noise_rms    = 0.001,
                partials_rms = partials_rms,
            }
            for error_db, index in run_noise_scenario(scenario) {
                testing.expectf(
                    t,
                    abs(error_db) < NOISE_TOLERANCE_DB,
                    "%v Hz, track %v, partials %v: noise off by %.1f dB",
                    base_hz,
                    index,
                    partials_rms,
                    error_db,
                )
            }
        }
    }
}

// What a real input adds to the noise on A2: coloured noise, the noise rising mid-note, bursts shorter and
// longer than the median's half of its history, a resonance in a gap. The noise is still read as the track
// sees it.
@(test)
test_noise_between_partials_disturbed :: proc(t: ^testing.T) {
    A2 :: 110.0
    scenarios := []NoiseScenario {
        {name = "noise falling 6 dB an octave over 200 Hz", lowpass_hz = 200},
        {name = "noise 12 dB louder from 1 s, 0.6 s on", duration_s = 1.6, bursts = {{1, 99, 4}}},
        {name = "a 50 ms burst 20 dB louder just before", duration_s = 1.3, bursts = {{1.2, 1.25, 10}}},
        {name = "half a second 20 dB louder, 0.6 s after", duration_s = 2.1, bursts = {{1, 1.5, 10}}},
        {name = "a resonance at 190 Hz", tones = {{190, 0.01}}},
    }

    for &scenario in scenarios {
        scenario.base_hz = A2
        scenario.duration_s = scenario.duration_s if scenario.duration_s > 0 else 2
        scenario.noise_rms = 0.001
        scenario.partials_rms = 0.03

        for error_db, index in run_noise_scenario(scenario) {
            testing.expectf(t, abs(error_db) < NOISE_TOLERANCE_DB, "%v, track %v: noise off by %.1f dB", scenario.name, index, error_db)
        }
    }
}

// Another harmonic series in the gaps is signal, not noise: a fifth played along, a low E ringing with the
// A string. It fills the gaps the note leaves, the tracks read more noise than there is and dim early. Never
// less, a track doesn't light up on it.
@(test)
test_noise_between_partials_other_notes :: proc(t: ^testing.T) {
    harmonic_series :: proc(base_hz, rms: f64) -> []NoiseTone {
        tones := make([]NoiseTone, 8, context.temp_allocator)
        for &tone, index in tones do tone = {base_hz * f64(index + 1), rms / f64(index + 1)}
        return tones
    }

    scenarios := []NoiseScenario {
        {name = "E3 played along", tones = harmonic_series(164.81, 0.03)},
        {name = "the low E ringing 10 dB under", tones = harmonic_series(82.41, 0.01)},
    }

    for &scenario in scenarios {
        scenario.base_hz = 110
        scenario.duration_s = 2
        scenario.noise_rms = 0.001
        scenario.partials_rms = 0.03

        errors_db := run_noise_scenario(scenario)
        for error_db, index in errors_db {
            testing.expectf(t, error_db > -NOISE_TOLERANCE_DB, "%v, track %v: noise off by %.1f dB", scenario.name, index, error_db)
        }
        log.infof("%v: noise off by %.1f, %.1f and %.1f dB", scenario.name, errors_db[0], errors_db[1], errors_db[2])
    }
}

// The scenario through the strobe's 1×, 2× and 4× tracks: how far each track's noise between the partials is
// from the noise its window lets through at the end, in dB
run_noise_scenario :: proc(scenario: NoiseScenario) -> (errors_db: [3]f32) {
    sample_rate := f32(DEFAULT_SAMPLE_RATE)
    intervals := []f32{1, 2, 4}
    lock_in := init_strobe_lock_in(f32(scenario.base_hz), intervals, .HARMONIC, sample_rate)
    defer destroy_strobe_lock_in(lock_in)

    set_strobe_lock_in_freq(lock_in, f32(scenario.base_hz), 440, 0.025, 2, .HARMONIC)

    // The low-pass's smoothing a sample, 1 passes the noise as it is
    smoothing: f64 = 1
    if scenario.lowpass_hz > 0 do smoothing = 1 - math.exp(-math.TAU * scenario.lowpass_hz / f64(sample_rate))
    coloured: f64

    frame := make([]f32, int(sample_rate) / 60)
    defer delete(frame)

    sample_index := 0
    for f64(sample_index) < scenario.duration_s * f64(sample_rate) {
        for &sample in frame {
            time_s := f64(sample_index) / f64(sample_rate)
            coloured += smoothing * (rand.norm_float64() - coloured)

            value := scenario.noise_rms * noise_gain(scenario.bursts, time_s) * coloured
            for number in 1 ..= 8 {
                value += scenario.partials_rms * math.SQRT_TWO / f64(number) * math.sin(math.TAU * scenario.base_hz * f64(number) * time_s)
            }
            for tone in scenario.tones do value += tone.rms * math.SQRT_TWO * math.sin(math.TAU * tone.freq_hz * time_s)

            sample = f32(value)
            sample_index += 1
        }

        audio_capture_write(lock_in, frame)
        run_phase_detection(lock_in)
    }

    // The noise at each track, through the low-pass
    end_gain := noise_gain(scenario.bursts, scenario.duration_s)
    for band, index in lock_in.bands {
        omega := math.TAU * f64(band.freq_hz) / f64(sample_rate)
        held := 1 - smoothing
        response := smoothing * smoothing / (1 - 2 * held * math.cos(omega) + held * held)
        expected := scenario.noise_rms * end_gain * math.sqrt(response * f64(lock_in.window_noise_gain))
        errors_db[index] = f32(20 * math.log10(f64(band.noise_between) / expected))
    }
    return
}

// How much louder the noise is at time_s, during a burst
noise_gain :: proc(bursts: []NoiseBurst, time_s: f64) -> f64 {
    for burst in bursts {
        if time_s >= burst.from_s && time_s < burst.to_s do return burst.gain
    }
    return 1
}
