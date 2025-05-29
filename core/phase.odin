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
import "core:math/linalg"
import "core:testing"


MAX_BANDS :: 8
MAX_WINDOW_SIZE :: 32_768
MAX_HOP_SIZE :: 4096


StrobeMode :: enum {
    HARMONIC_MODE, // each track display a harmonic frequency
    VERNIER_MODE, // displays the same frequency at different sensitivities
}


PhaseBand :: struct {
    hop_size:          int, // number of samples between consecutive DFT windows, affects phase-based frequency tracking
    freq_hz:           f32,
    norm_freq:         f32,
    freq_diff_hz:      f32,
    estimated_freq_hz: f32,
    dft_config:        SingleFreqDFT,
    time_stretch:      f32,
    freq_multiplier:   f32, // to get more or less stripes in the pattern
    phase:             f32, // actual measured phase
    amp:               f32,
    phase_diff:        f32, // phase difference between detection frames
    err_cents:         f32,
    scaled_phase:      f32, // phase scaled based on desired strobe speed

    // a number < 1 will slow down the strobe and > 1 will increase the strobe spinning rate
    speed:             f32,

    // fade out if the spinning is too rapid
    attenuation:       f32,
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
    apply_attenuation:  bool,
}


init_phase_comparator :: proc(
    base_freq_hz: f32,
    samplerate: f32,
    band_count: int,
    mode: StrobeMode,
    apply_attenuation: bool,
) -> ^PhaseComparator {
    self := new(PhaseComparator)

    assert(band_count <= MAX_BANDS)

    init_audio_capture_node(self, "phase-tracker")

    self.sample_buffer = make([]f32, MAX_WINDOW_SIZE + MAX_HOP_SIZE)

    self.mode = mode
    self.base_freq_hz = base_freq_hz
    self.apply_attenuation = self.apply_attenuation

    for i in 0 ..< band_count {
        band := PhaseBand{}
        band.freq_multiplier = 1.0
        band.dft_config = init_dft(MAX_WINDOW_SIZE)
        append(&self.bands, band)
    }

    self.samplerate = samplerate

    return self
}


destroy_phase_comparator :: proc(self: ^PhaseComparator) {
    destroy_audio_capture_node(self)
    delete(self.sample_buffer)
    for &band in self.bands {
        destory_dft(&band.dft_config)
    }
    delete(self.bands)
    free(self)
}

set_phase_comparator_speed :: proc(self: ^PhaseComparator, base_speed: f32) {
    speed: f32 = base_speed * self.pitch_standard / self.base_freq_hz
    for &band, i in self.bands {
        band.speed = speed
        if self.mode == .VERNIER_MODE {
            speed *= self.speed_multiplier
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
    flush_audio_capture_ringbuffer(self)

    multiplier: f32 = 1.0
    self.base_freq_hz = base_freq_hz
    self.mode = mode
    self.pitch_standard = pitch_standard
    self.speed_multiplier = speed_multiplier
    self.reference_interval = f64(self.samplerate / base_freq_hz)

    speed: f32 = base_speed * pitch_standard / base_freq_hz

    for &band, i in self.bands {
        band.time_stretch = f32(self.reference_interval)
        band.phase = 0.0
        band.speed = speed
        if self.mode == .HARMONIC_MODE {
            band.freq_hz = f32(multiplier) * base_freq_hz
            multiplier *= 2
        }
        if self.mode == .VERNIER_MODE {
            band.freq_hz = base_freq_hz
            speed *= speed_multiplier
        }
        band.norm_freq = band.freq_hz / self.samplerate

        if self.mode == .HARMONIC_MODE || i == 0 {
            window_size := best_dft_window_size(band.freq_hz, self.samplerate, 100)
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


run_phase_detection :: proc(self: ^PhaseComparator) -> (f32, f32) {
    base_band := self.bands[0]

    // Need to keep this buffer slice relatively small to keep the display refresh without latency.
    available := audio_capture_read(self, self.sample_buffer[:base_band.dft_config.window_size])

    // Skip there are no new samples, the scaled phase stays the same
    if available <= 0 {
        return base_band.estimated_freq_hz, base_band.err_cents
    }

    self.available = int(available)

    for &band, band_idx in self.bands {
        determine_band_phase(self, &band, band_idx)
    }

    return base_band.estimated_freq_hz, base_band.err_cents
}


// Choose best window size for adaptive spectra leakage based on cents and not Hz
// A fixed window size in samples produces a constant frequency resolution in Hz, not in musical units like cents.
// For higher frequencies we need less samples to show the strobing effect.
best_dft_window_size :: proc(freq_hz: f32, samplerate: f32, cents_resolution: int) -> int {
    ratio := libc.exp2(f32(cents_resolution) / 1200.0)
    frequency_step := freq_hz * (ratio - 1.0)
    win := math.ceil(samplerate / frequency_step)
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


// Max hop size for staying within 100 cents tolerance
best_hop_size :: proc(cents_offset: int, freq_hz: f32, samplerate: f32) -> int {
    ratio := libc.exp2(f32(cents_offset) / 1200.0)
    freq_max := freq_hz * ratio
    freq_deviation := freq_max - freq_hz

    min_phase_delta_rad: f32 = 0.5 // ???

    hop := math.ceil(min_phase_delta_rad * samplerate / (math.TAU * freq_deviation))
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
    base_band := self.bands[0]

    // Harmonic mode - each band tracks a separate frequency
    // Run a single bin DFT and estimate frequency based on phase drift
    if self.mode == .HARMONIC_MODE || band_idx == 0 {
        dft = run_single_dft(&band.dft_config, self.sample_buffer)
        hop_size := best_hop_size(100, band.freq_hz, self.samplerate)

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

        band.phase_diff = phase_drift

        // Scale down by factor
        band.scaled_phase = band.scaled_phase - band.phase_diff * band.speed

        amp := magnitude(dft)

        // limit max amp to avoid jagged edges in the strobe display
        band.amp = clamp(amp, 0.0, 50.0)

    } else {
        // Vernier mode - only the base band needs to run the DFT, other bands display varying speeds
        band.amp = base_band.amp
        band.phase_diff = base_band.phase_diff
        band.scaled_phase = band.scaled_phase - band.phase_diff * band.speed
    }


    // Fade out strobe when it spins so rapidly to become distracting
    if self.apply_attenuation {
        band.attenuation = linalg.smoothstep(
            f32(0.01),
            f32(0.008),
            math.abs(band.phase_diff * band.speed),
        )
        band.amp *= band.attenuation
    }
}
