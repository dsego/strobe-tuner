/* ------------------------------------------------------------------------------------------------

    Phase tracker
    - Generates a reference signal and detects the phase difference between the reference
        and target. The reference phase is calculated in the drawing method and synthesizes a strobe
        based on the detected phase difference.

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
    unwrapped_phase:   f32,
    scaled_phase:      f32, // phase scaled based on desired strobe speed
    // dummy_phase:       f32,
    detected:          bool,

    // a number < 1 will slow down the strobe and > 1 will increase the strobe spinning rate
    speed:             f32,

    // fade out if the spinning is too rapid
    attenuation:       f32,
}


PhaseComparator :: struct {
    using node:         AudioCaptureNode,
    base_freq_hz:       f32,
    sample_buffer:      []f32,
    phase_correction:   f64,
    reference_interval: f64,
    time_reference:     f64,
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
) -> ^PhaseComparator {
    self := new(PhaseComparator)

    assert(band_count <= MAX_BANDS)

    init_audio_capture_node(self, "phase-tracker")

    self.sample_buffer = make([]f32, MAX_WINDOW_SIZE + MAX_HOP_SIZE)

    self.mode = mode
    self.base_freq_hz = base_freq_hz

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


set_phase_comparator_freq :: proc(
    self: ^PhaseComparator,
    base_freq_hz: f32,
    pitch_standard: f32,
    base_speed: f32,
    speed_multiplier: f32,
    mode: StrobeMode,
) {
    flush_audio_capture_ringbuffer(self)

    self.phase_correction = 0.0
    multiplier: f32 = 1.0
    self.base_freq_hz = base_freq_hz
    self.mode = mode

    speed: f32 = base_speed * pitch_standard / base_freq_hz

    for &band, i in self.bands {
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


unwrap_phase :: proc(phase: f32) -> f32 {
    unwrapped_phase := phase
    for unwrapped_phase < 0.0 do unwrapped_phase += math.TAU
    for unwrapped_phase > math.TAU do unwrapped_phase -= math.TAU
    return unwrapped_phase
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

    // phase runaway compensation
    self.time_reference += f64(available)
    self.reference_interval = f64(self.samplerate / base_band.freq_hz)
    num_periods := self.time_reference / self.reference_interval

    // wrap back closer to zero, only interested in relative time reference
    full_periods := math.trunc(num_periods) * self.reference_interval
    self.time_reference -= full_periods
    self.phase_correction = full_periods - self.time_reference

    for &band, band_idx in self.bands {
        determine_band_phase(self, &band, band_idx)
    }

    return base_band.estimated_freq_hz, base_band.err_cents
}


// Choose best window size for adaptive spectra leakage based on cents and not Hz
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
    v1 := best_hop_size(110.0, 48_000, 100)
    v2 := best_hop_size(440.0, 48_000, 100)
    v3 := best_hop_size(4186.0, 48_000, 100)

    testing.expect_value(t, v1, 584)
    testing.expect_value(t, v2, 146)
    testing.expect_value(t, v3, 16)
}


determine_band_phase :: proc(self: ^PhaseComparator, band: ^PhaseBand, band_idx: int) {
    dft: complex64 = complex(0, 0)

    // Harmonic mode - each band tracks a separate frequency
    // Vernier mode - only the baser band needs to run the DFT

    // Run a single bin DFT and estimate frequency based on phase drift
    if self.mode == .HARMONIC_MODE || band_idx == 0 {
        dft = run_single_dft(&band.dft_config, self.sample_buffer)
        hop_size := best_hop_size(100, band.freq_hz, self.samplerate)

        dft_hop := run_single_dft(&band.dft_config, self.sample_buffer[hop_size:])

        // measured phase difference
        phase_delta := cmplx.phase(dft_hop) - cmplx.phase(dft)

        // how much the phase of a bin rotates over HOP samples for a signal at frequency f
        expected_delta := math.TAU * f32(hop_size) * band.norm_freq

        for expected_delta > math.PI do expected_delta -= math.TAU
        for expected_delta < -math.PI do expected_delta += math.TAU


        // Handle the jump from 2π to 0 or 0 to 2π (both rotation directions)
        for phase_delta > math.PI do phase_delta -= math.TAU
        for phase_delta < -math.PI do phase_delta += math.TAU

        phase_drift := phase_delta - expected_delta

        // Frequency estimation from phase drift
        band.freq_diff_hz = self.samplerate * phase_drift / (math.TAU * f32(hop_size))

        band.estimated_freq_hz = band.freq_hz + band.freq_diff_hz
        band.err_cents = cents_deviation(band.estimated_freq_hz, band.freq_hz)

        band.phase_diff = phase_drift
    }


    // // TODO: fix threshold
    // band.detected = math.abs(dft) > DETECTION_THRESHOLD

    // if !band.detected {
    //     return
    // }


    phase := -cmplx.phase(dft) // [-π, π]
    amp := magnitude(dft)

    // rotation 2πf/FS
    w: f32 = math.TAU * band.norm_freq

    // Phase correction - this can move the phase outside of the -π, π range
    // phase = phase - f32(self.phase_correction) * w
    // band.phase = phase



    // Unwrap phase to range [0, 2π]
    // unwrapped_phase := unwrap_phase(band.phase)

    // band.phase_diff = unwrapped_phase - band.unwrapped_phase

    // Handle the jump from 2π to 0 or 0 to 2π (both rotation directions)
    // for band.phase_diff > math.PI do band.phase_diff -= math.TAU
    // for band.phase_diff < -math.PI do band.phase_diff += math.TAU

    // Remember the phase for next diff
    // band.unwrapped_phase = unwrapped_phase

    // Scale down by factor and unwrap
    band.scaled_phase = band.scaled_phase - band.phase_diff * band.speed

    // Adding π/2 aligns phases to get the stripes lined up ???
    // FIXME: This used to work before the phase scaling was added
    // phase += math.PI * 0.5


    // TODO: Fake a steady strobing effect for frequencies that are out of range of phase comparison

    band.time_stretch = f32(self.reference_interval)

    // TODO: slower attenuation slope
    band.attenuation = linalg.smoothstep(
        f32(0.14),
        f32(0.01),
        math.abs(band.freq_diff_hz * band.speed),
    )

    band.amp = amp

    // limit max amp to avoid jagged edges in the strobe display
    // TODO: different amp per strobe track
    band.amp = clamp(band.amp, 0.0, 50.0)

    // apply attenuation after clamping to get the desired effect
    if self.apply_attenuation do band.amp *= band.attenuation
}
