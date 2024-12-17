/* ------------------------------------------------------------------------------------------------

    Phase tracker
    - Generates a reference signal and detects the phase difference between the reference
        and target. The reference phase is calculated in the drawing method and synthesizes a strobe
        based on the detected phase difference.

 -------------------------------------------------------------------------------------------------*/


package core

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"


MAX_BANDS :: 8


StrobeMode :: enum {
    HARMONIC_MODE, // each track display a harmonic frequency
    VERNIER_MODE, // displays the same frequency at different sensitivities
}


DataPoint :: struct {
    amp:           f32,
    phase:         f32,
    freq_diff_hz:  f32,
    err_cents:     f32,
    // err_cents_avg: f32,
}


StrobeBand :: struct {
    freq_hz:              f32,
    norm_freq:            f32,
    freq_diff_hz:         f32,
    estimated_freq_hz:    f32,
    dft:                  SingleFreqDFT, // harmonic mode
    time_stretch:         f32,
    freq_multiplier:      f32, // to get more or less stripes in the pattern
    phase:                f32,
    amp:                  f32,
    phase_diff:           f32,
    err_cents:            f32,
    err_cents_avg:        f32,
    prev_unwrapped_phase: f32,
    unwrapped_phase:      f32,
    scaled_phase:         f32,
    detected:             bool,

    // a number < 1 will slow down the strobe and > 1 will increase the strobe spinning rate
    sensitivity:          f32,
}

PhaseTracker :: struct {
    using node:       AudioCaptureNode,
    base_freq_hz:     f32,
    sample_buffer:    []f32,
    window_size:      int,
    phase_correction: f64,
    time_reference:   f64,
    bands:            [dynamic]StrobeBand,
    band_count:       int,
    samplerate:       f32,
    mode:             StrobeMode,
    dft:              SingleFreqDFT, // vernier mode
    data_points:      []DataPoint,
    data_points_head: int,
    // moving_avg:           MovingAvg,
}


init_phase_tracker :: proc(
    base_freq_hz: f32,
    samplerate: f32,
    band_count: int,
    window_size: int,
    mode: StrobeMode,
    pitch_standard: f32,
) -> ^PhaseTracker {
    self := new(PhaseTracker)
    self.window_size = window_size
    assert(band_count <= MAX_BANDS)

    init_audio_capture_node(self, "phase-tracker")

    // zero pad to get more DFT precision & smoother response (?)
    fft_size := self.window_size * 2.0

    self.sample_buffer = make([]f32, fft_size)
    self.data_points = make([]DataPoint, 1024)
    self.mode = mode
    self.base_freq_hz = base_freq_hz

    self.dft = init_dft(fft_size)
    // self.moving_avg = init_moving_avg(64)

    for i in 0 ..< band_count {
        band := StrobeBand{}
        band.dft = init_dft(fft_size)
        append(&self.bands, band)
    }

    set_phase_tracker_freq(self, base_freq_hz, pitch_standard)

    self.samplerate = samplerate
    return self
}

destroy_phase_tracker :: proc(self: ^PhaseTracker) {
    destroy_audio_capture_node(self)
    delete(self.data_points)
    delete(self.sample_buffer)
    destory_dft(&self.dft)
    // destroy_moving_avg(&self.moving_avg)
    for &band in self.bands {
        destory_dft(&band.dft)
    }
}

set_phase_tracker_freq :: proc(self: ^PhaseTracker, base_freq_hz: f32, pitch_standard: f32) {
    flush_audio_capture_ringbuffer(self)

    self.phase_correction = 0.0
    multiplier: f32 = 1.0
    self.base_freq_hz = base_freq_hz

    if self.mode == .VERNIER_MODE {
        set_dft_freq(&self.dft, base_freq_hz / self.samplerate)
    }

    // TODO: move to config
    pitch_standard: f32 = 440.0
    sensitivity: f32 = 0.01 * pitch_standard / base_freq_hz

    for &band, i in self.bands {
        band.phase = 0.0
        band.sensitivity = sensitivity
        if self.mode == .HARMONIC_MODE {
            band.freq_hz = f32(multiplier) * base_freq_hz
            multiplier *= 2
        }
        if self.mode == .VERNIER_MODE {
            band.freq_hz = base_freq_hz
            sensitivity *= 2.0
        }
        band.norm_freq = band.freq_hz / self.samplerate

        if self.mode == .HARMONIC_MODE {
            set_dft_freq(&band.dft, band.norm_freq)
        }
    }
}

scale_phase :: proc(band: ^StrobeBand) {
    // Unwrap phase to range [0, 2π]
    unwrapped_phase := band.phase
    for unwrapped_phase < 0.0 do unwrapped_phase += math.TAU
    for unwrapped_phase > math.PI do unwrapped_phase -= math.TAU

    phase_diff := unwrapped_phase - band.prev_unwrapped_phase

    // Handle the jump from 2π to 0 or 0 to 2π
    // (need to handle both rotation directions)
    if phase_diff > math.PI do phase_diff -= math.TAU
    if phase_diff < -math.PI do phase_diff += math.TAU

    band.phase_diff = phase_diff

    // Output is scaled down by factor
    band.scaled_phase += phase_diff * band.sensitivity


    // Technically not necessary to unwrap the phase,
    // Question: is there a benefit to doing so?
    for band.scaled_phase < 0.0 do band.scaled_phase += math.TAU
    for band.scaled_phase > math.PI do band.scaled_phase -= math.TAU

    band.prev_unwrapped_phase = unwrapped_phase
}

run_dft_analysis :: proc(self: ^PhaseTracker) {
    available := audio_capture_read(self, self.sample_buffer)

    if available <= 0 do return

    time_delta := math.TAU * f64(available) / f64(self.samplerate)

    sensitivity: f32 = 1.0

    // phase runaway compensation
    self.time_reference += f64(available)
    reference_interval := f64(self.samplerate / self.bands[0].freq_hz)
    num_periods := self.time_reference / reference_interval

    // wrap back closer to zero, only interested in relative time reference
    full_periods := math.trunc(num_periods) * f64(reference_interval)
    self.time_reference -= full_periods
    self.phase_correction = full_periods - self.time_reference

    // We can run only one phase calculation since all bands are tracking the same frequency
    dft: complex64 = complex(0, 0)
    if self.mode == .VERNIER_MODE {
        dft = run_single_dft(&self.dft, self.sample_buffer)
    }

    for &band, band_idx in self.bands {

        // Calculate DFT for this band in harmonic mode
        if self.mode == .HARMONIC_MODE {
            dft = run_single_dft(&band.dft, self.sample_buffer)
        }

        cos := real(dft)
        sin := imag(dft)

        // if both cos & sin are zero or close to zero, that means there is nothing detected
        band.detected = math.abs(cos) > DETECTION_THRESHOLD && math.abs(sin) > DETECTION_THRESHOLD

        if !band.detected {
            continue
        }

        phase := math.atan2(sin, cos) // [-π, π]
        amp := magnitude(dft)

        angle_freq: f32 = math.TAU * band.freq_hz / self.samplerate

        // Phase correction, this can move the phase outside of the -π, π range
        phase = phase - f32(self.phase_correction) * angle_freq

        band.phase = phase

        // fmt.println(phase)

        // Adding π/2 aligns phases to get the stripes lined up ???
        // FIXME: This used to work before the phase scaling was added
        // phase += math.PI * 0.5

        // Calculate estimated frequency
        scale_phase(&band)

        band.freq_diff_hz = -band.phase_diff / f32(time_delta)
        band.estimated_freq_hz = band.freq_hz + band.freq_diff_hz
        band.err_cents = cents_deviation(band.estimated_freq_hz, band.freq_hz)


        // Exponentially Weighted Moving Average
        // band.err_cents_avg += 0.1 * (band.err_cents - band.err_cents_avg)
        // band.err_cents_avg = 0 //run_moving_avg(&band.moving_avg, band.err_cents)


        // Generate a (synthetic strobe) sinusoid based on detected phase & amplitude
        band.time_stretch = f32(reference_interval)
        band.amp = amp
        band.freq_multiplier = 1.0
    }

    self.data_points[self.data_points_head] = DataPoint {
        self.bands[0].amp,
        self.bands[0].scaled_phase,
        self.bands[0].freq_diff_hz,
        self.bands[0].err_cents,
        // self.bands[0].err_cents_avg,
    }
    self.data_points_head = (self.data_points_head + 1) % len(self.data_points)
}
