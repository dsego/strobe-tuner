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


/* ------------------------------------------------------------------------------------------------

    Phase comparator

    Runs two single bin DFTs separated by a hop size and compares their phases.
    The frequency deviation is detected by comparing the expected phase shift for the target frequency
    against the measured phase offset.

 -------------------------------------------------------------------------------------------------*/


package core

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:testing"


MIN_STROBE_FREQ_HZ :: 16.0
MAX_BANDS :: 8
MAX_WINDOW_SIZE :: 262_144
MAX_HOP_SIZE :: 4096


StrobeMode :: enum {
    HARMONIC_MODE, // each track display a harmonic frequency
    VERNIER_MODE, // displays the same frequency at different sensitivities
}


PhaseBand :: struct {
    hop_size:                     int, // number of samples between consecutive DFT windows, affects phase-based frequency tracking
    freq_hz:                      f32,
    interval:                     f32, // interval ratio, eg 1x for base note, 1.5x for perfect fifth,  2x for octave, etc
    note:                         Note,
    norm_freq:                    f32,
    freq_diff_hz:                 f32,
    estimated_freq_hz:            f32,
    smoothed_freq_hz:             f32,
    // ewma_state:        EwmaState,
    // moving_avg:                   MovingAvg,
    dft_config:                   SingleFreqDFT,
    time_stretch:                 f32,
    phase:                        f32, // actual measured phase
    amp:                          f32,
    phase_diff:                   f32, // phase difference between detection frames
    err_cents:                    f32,
    smoothed_err_cents:           f32,
    scaled_phase:                 f32, // phase scaled based on desired strobe speed

    // a number < 1 will slow down the strobe and > 1 will increase the strobe spinning rate
    speed:                        f32,
    snr_db:                       f32,
    noise_floor:                  f32,
    noise_floor_snr_db_threshold: f32,
}


PhaseComparator :: struct {
    using node:         AudioCaptureNode,
    base_freq_hz:       f32,
    speed_multiplier:   f32,
    pitch_standard:     f32,
    sample_buffer:      []f32,
    reference_interval: f64,
    bands:              [dynamic]PhaseBand,
    band_count:         int,
    samplerate:         f32,
    mode:               StrobeMode,
    available:          int,
}


init_phase_comparator :: proc(
    base_freq_hz: f32,
    samplerate: f32,
    strobe_intervals: []f32,
    mode: StrobeMode,
    noise_floor_snr_db_threshold: f32,
) -> ^PhaseComparator {
    self := new(PhaseComparator)

    init_audio_capture_node(self, "phase-tracker")

    self.sample_buffer = make([]f32, MAX_WINDOW_SIZE + MAX_HOP_SIZE)

    self.mode = mode
    self.base_freq_hz = base_freq_hz

    for interval, i in strobe_intervals {
        if interval >= 1.0 {
            band := PhaseBand{}
            band.interval = interval
            band.dft_config = init_dft(MAX_WINDOW_SIZE)
            band.noise_floor = 10e-6
            band.noise_floor_snr_db_threshold = noise_floor_snr_db_threshold
            // band.ewma_state = init_ewma(0.1)
            // band.moving_avg = init_moving_avg(5)

            append(&self.bands, band)
        }
    }


    self.samplerate = samplerate

    return self
}


destroy_phase_comparator :: proc(self: ^PhaseComparator) {
    destroy_audio_capture_node(self)
    delete(self.sample_buffer)
    for &band in self.bands {
        // destroy_moving_avg(&band.moving_avg)
        destory_dft(&band.dft_config)
    }
    delete(self.bands)
    free(self)
}

// FIXME: this will only work for the existing strobe bands, it won't add any new ones
// FIXME: need to call set_phase_comparator_freq after updating the intervals
set_phase_comparator_intervals :: proc(self: ^PhaseComparator, strobe_intervals: []f32) {
    if self.mode != .HARMONIC_MODE do return

    for interval, i in strobe_intervals {
        if interval >= 1.0 {
            band := &self.bands[i]
            band.interval = interval
        }
    }
}

set_phase_comparator_speed :: proc(self: ^PhaseComparator, base_speed: f32) {
    speed: f32 = base_speed

    if self.mode == .VERNIER_MODE {
        for &band in self.bands {
            band.speed = speed
            speed *= self.speed_multiplier
        }
    } else if self.mode == .HARMONIC_MODE {
        for &band in self.bands {
            band.speed = speed * band.interval
        }
    }
}


set_phase_comparator_freq :: proc(
    self: ^PhaseComparator,
    base_freq_hz: f32,
    pitch_standard: f32,
    base_speed: f32,
    speed_multiplier: f32,
    mode: StrobeMode,
) {

    if base_freq_hz <= MIN_STROBE_FREQ_HZ {
        fmt.printf(
            "Frequency %.1fHz too low for strobe display, minimum frequency is %.1fHz\n",
            base_freq_hz,
            MIN_STROBE_FREQ_HZ,
        )
        return
    }

    flush_audio_capture_ringbuffer(self)

    self.base_freq_hz = base_freq_hz
    self.mode = mode
    self.pitch_standard = pitch_standard
    self.speed_multiplier = speed_multiplier
    self.reference_interval = f64(self.samplerate / base_freq_hz)

    speed: f32 = base_speed


    for &band, i in self.bands {
        // reset_ewma(&band.ewma_state)
        band.time_stretch = f32(self.reference_interval)
        band.phase = 0.0
        band.noise_floor = 10e-6

        if self.mode == .HARMONIC_MODE {
            band.freq_hz = band.interval * base_freq_hz
            band.speed = speed * band.interval
        } else if self.mode == .VERNIER_MODE {
            band.freq_hz = base_freq_hz
            band.speed = speed
            speed *= speed_multiplier
        }
        band.note = find_note(band.freq_hz)
        band.norm_freq = band.freq_hz / self.samplerate

        if self.mode == .HARMONIC_MODE || i == 0 {
            window_size := best_dft_window_size(band.freq_hz, self.samplerate, 25)
            set_dft_freq(&band.dft_config, band.norm_freq, window_size)
        }
    }
}

// Handle the jump from 2π to 0 or 0 to 2π (both rotation directions)
unwrap_phase :: proc(phase: f32) -> f32 {
    phase := phase
    for phase > math.PI do phase -= math.TAU
    for phase < -math.PI do phase += math.TAU
    return phase
}


run_phase_detection :: proc(self: ^PhaseComparator) -> (f32, f32, bool) {
    base_band := &self.bands[0]

    // Need to keep this buffer slice relatively small to keep the display refresh without latency.
    available := audio_capture_read(self, self.sample_buffer[:base_band.dft_config.window_size])

    // Skip when there are no new samples, the scaled phase stays the same
    if available <= 0 {
        // fmt.println(base_band.err_cents)
        return base_band.estimated_freq_hz, base_band.err_cents, true
    }

    self.available = int(available)

    for &band, band_idx in self.bands {
        determine_band_phase(self, &band, band_idx)
        update_band_noise_floor(self, &band, band_idx)
    }

    // fmt.println(">>", base_band.moving_avg)
    // fmt.println(">", base_band.estimated_freq_hz, base_band.err_cents)


    return base_band.estimated_freq_hz, base_band.err_cents, false
}


// Choose best window size for adaptive spectra leakage based on cents and not Hz
// A fixed window size in samples produces a constant frequency resolution in Hz, not in musical units like cents.
// For higher frequencies we need less samples to show the strobing effect.
// The cents_resolution determines how finely we want to distinguish two frequencies.
best_dft_window_size :: proc(freq_hz: f32, samplerate: f32, cents_resolution: int) -> int {
    ratio := libc.exp2(f32(cents_resolution) / 1200.0)
    freq_resolution := freq_hz * (ratio - 1.0)
    win := math.ceil(samplerate / freq_resolution)
    // fmt.println(freq_hz, cents_resolution, win)
    return int(win)
}


@(test)
test_best_dft_window_size :: proc(t: ^testing.T) {
    v1 := best_dft_window_size(110.0, 48_000, 100)
    v2 := best_dft_window_size(440.0, 48_000, 100)
    v3 := best_dft_window_size(4186.0, 48_000, 100)

    testing.expect_value(t, v1, 7339)
    testing.expect_value(t, v2, 1835)
    testing.expect_value(t, v3, 193)
}


// Max hop size for staying within cents offset tolerance
// The cents_offset is the smallest tuning drift to track per update.
best_hop_size :: proc(cents_offset: int, freq_hz: f32, samplerate: f32) -> int {
    ratio := libc.exp2(f32(cents_offset) / 1200.0)
    freq_max := freq_hz * ratio
    freq_deviation := freq_max - freq_hz

    // Range 0.0 to 1.0
    // Hop size increases or decreases proportionally from.
    // Larger values result in longer time between updates but more robust to noise/jitter.
    // Smaller values decrease hop size and get finer resolution but more vulnerable to phase noise.
    target_phase_shift: f32 = 0.5

    hop := math.ceil(target_phase_shift * samplerate / (math.TAU * freq_deviation))
    // fmt.println("hop", freq_hz, hop)
    return int(hop)
}

@(test)
test_best_hop_size :: proc(t: ^testing.T) {
    v1 := best_hop_size(100, 110.0, 48_000)
    v2 := best_hop_size(100, 440.0, 48_000)
    v3 := best_hop_size(100, 4186.0, 48_000)

    testing.expect_value(t, v1, 584)
    testing.expect_value(t, v2, 146)
    testing.expect_value(t, v3, 16)
}


determine_band_phase :: proc(self: ^PhaseComparator, band: ^PhaseBand, band_idx: int) {
    dft: complex64 = complex(0, 0)

    // Harmonic mode - each band tracks a separate frequency
    // Run a single bin DFT and estimate frequency based on phase drift
    if self.mode == .HARMONIC_MODE || band_idx == 0 {
        dft = run_single_dft(&band.dft_config, self.sample_buffer[:])
        hop_size := best_hop_size(25, band.freq_hz, self.samplerate)

        dft_hop := run_single_dft(&band.dft_config, self.sample_buffer[hop_size:])

        // measured phase difference
        phase_delta := cmplx.phase(dft_hop) - cmplx.phase(dft)
        phase_delta = unwrap_phase(phase_delta)

        // how much the phase of a bin should rotate over HOP samples for a signal at frequency f
        expected_delta := math.TAU * f32(hop_size) * band.norm_freq
        expected_delta = unwrap_phase(expected_delta)

        phase_drift := phase_delta - expected_delta
        phase_drift = unwrap_phase(phase_drift)

        // Frequency estimation from phase drift
        band.freq_diff_hz = self.samplerate * phase_drift / (math.TAU * f32(hop_size))
        band.estimated_freq_hz = band.freq_hz + band.freq_diff_hz

        band.err_cents = cents_deviation(band.estimated_freq_hz, band.freq_hz)

        // adjust the EWMA when large jumps occur
        // if math.abs(band.smoothed_err_cents - band.err_cents) > 10.0 {
        //     reset_ewma(&band.ewma_state)
        // }

        // band.smoothed_freq_hz = ewma_filter(&band.ewma_state, band.estimated_freq_hz)
        // band.smoothed_err_cents = run_moving_avg(&band.moving_avg, band.err_cents)

        // Convert to cents only after smoothing:
        // band.smoothed_err_cents = cents_deviation(band.smoothed_freq_hz, band.freq_hz)
        // band.smoothed_err_cents = cents_deviation(band.smoothed_freq_hz, band.freq_hz)

        band.phase_diff = phase_drift

        // Scale down by factor
        band.scaled_phase = band.scaled_phase - band.phase_diff * band.speed
        band.amp = abs(dft)
    } else {
        // Vernier mode - only the base band needs to run the DFT, other bands display varying speeds
        base_band := self.bands[0]
        band.amp = base_band.amp
        band.phase_diff = base_band.phase_diff
        band.scaled_phase = band.scaled_phase - band.phase_diff * band.speed
    }
}


@(private)
// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_band_noise_floor :: proc(self: ^PhaseComparator, band: ^PhaseBand, band_idx: int) {
    if self.mode == .HARMONIC_MODE || band_idx == 0 {
        // Avoid the noise floor dropping to zero (-120 dB)
        MIN_FLOOR :: 1e-6

        if band.amp >= MIN_FLOOR {
            // current SNR
            EPS :: 1e-8 // to avoid divide by zero
            band.snr_db = 20.0 * math.log10((band.amp + EPS) / (band.noise_floor + EPS))

            // Pause updating when signal is loud, based on an SNR threshold
            if band.snr_db < band.noise_floor_snr_db_threshold {
                if band.amp < band.noise_floor {
                    band.noise_floor = band.amp
                } else {
                    ALPHA: f32 : 0.01
                    band.noise_floor += ALPHA * (band.amp - band.noise_floor)
                }
            }
        }
    } else {
        // Vernier mode - only the base band needs to calculate the noise floor
        base_band := self.bands[0]
        band.noise_floor = base_band.noise_floor
        band.snr_db = base_band.snr_db
    }
}
