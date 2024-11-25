/* ------------------------------------------------------------------------------------------------


        Phase tracker
        - Generates a reference signal and detects the phase difference between the reference
            and target. The reference phase is calculated in the drawing method and synthesizes a strobe
            based on the detected phase difference.


 -------------------------------------------------------------------------------------------------*/


package shared

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"


MAX_BANDS :: 8


StrobeMode :: enum {
    HARMONIC_MODE, // each track display a harmonic frequency
    VERNIER_MODE, // displays the same frequency at different sensitivities
}


StrobeBand :: struct {
    freq_hz:              f32,
    norm_freq:            f32,
    freq_diff_hz:         f32,
    estimated_freq_hz:    f32,
    dft:                  SingleFreqDFT,
    time_stretch:         f32,
    freq_multiplier:      f32, // to get more or less stripes in the pattern
    phase:                f32,
    amp:                  f32,
    err_cents:            f32,

    // Schmitt trigger thresholds to avoid flickering ?
    cents_err_low:        f32,
    cents_err_high:       f32,
    prev_unwrapped_phase: f32,
    unwrapped_phase:      f32,
    scaled_phase:         f32,
    downscale_factor:     int,
    phase_iterator:       int,
}

PhaseTracker :: struct {
    using node:       AudioCaptureNode,
    base_freq_hz:     f32,
    sample_buffer:    []f32,
    window_size:      int,
    ringbuffer:       RingBuffer,
    ringbuffer_data:  []u8,
    phase_correction: f32,
    time_reference:   f32,
    bands:            [dynamic]StrobeBand,
    band_count:       int,
    samplerate:       f32,
    mode:             StrobeMode,
}


init_phase_tracker :: proc(
    base_freq_hz: f32,
    samplerate: f32,
    band_count: int,
    mode: StrobeMode,
) -> ^PhaseTracker {
    self := new(PhaseTracker)
    self.window_size = 4096
    assert(band_count <= MAX_BANDS)

    rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
    self.ringbuffer = rb
    self.ringbuffer_data = rb_data
    self.sample_buffer = make([]f32, self.window_size)
    self.mode = mode
    self.base_freq_hz = base_freq_hz

    for i in 0 ..< band_count {
        band := StrobeBand{}
        band.dft = init_dft(self.window_size)
        append(&self.bands, band)
    }

    set_phase_tracker_freq(self, base_freq_hz)

    self.samplerate = samplerate
    self.stream_callback = phase_tracker_audio_callback
    return self
}

destroy_phase_tracker :: proc(self: ^PhaseTracker) {
    delete(self.ringbuffer_data)
    delete(self.sample_buffer)
    for &band in self.bands {
        destory_dft(&band.dft)
    }
}

set_phase_tracker_freq :: proc(self: ^PhaseTracker, base_freq_hz: f32) {
    self.phase_correction = 0.0
    flush_ringbuffer(&self.ringbuffer)
    multiplier: f32 = 1.0
    self.base_freq_hz = base_freq_hz


    for &band, i in self.bands {
        band.phase_iterator = 0
        band.downscale_factor = 4
        if self.mode == .HARMONIC_MODE {
            band.freq_hz = f32(multiplier) * base_freq_hz
            band.cents_err_low = 40.0
            band.cents_err_high = 50.0
        }
        if self.mode == .VERNIER_MODE {
            band.freq_hz = base_freq_hz
            band.cents_err_low = 40.0 / multiplier
            band.cents_err_high = 50.0 / multiplier
        }

        band.norm_freq = band.freq_hz / self.samplerate
        set_dft_freq(&band.dft, band.norm_freq)
        multiplier *= 2
    }
}

phase_tracker_audio_callback :: proc(ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, PhaseTracker, "node")

    // fmt.println("audio callback", len(input))

    out1, out2, num_written := get_ringbuffer_write_regions(&self.ringbuffer, len(input))

    if len(out1) > 0 do write_to_rb_region(out1, input[:len(out1)])
    if len(out2) > 0 do write_to_rb_region(out2, input[len(out1):])

    advance_ringbuffer_write(&self.ringbuffer, i32(num_written))
}

// TODO: filtering ??
@(private = "file")
write_to_rb_region :: proc(output: []f32, input: []f32) {
    copy(output, input)
}


// Return this structure from C code,
//  needs to be compatible and kept in sync with struct in StrobeTuner-Bridging-Header.h
PhaseInfo :: struct {
    phase_correction: f32,
    time_reference:   f32,
    band_count:       int,
    strobes:          [MAX_BANDS]StrobeInfo,
}

StrobeInfo :: struct {
    freq_hz:           f32,
    norm_freq:         f32,
    freq_diff_hz:      f32,
    estimated_freq_hz: f32,
    time_stretch:      f32,
    phase:             f32,
    amp:               f32,
}

sign: f32 = 1
scale_down_phase :: proc(self: ^StrobeBand) {

    // Unwrap phase to range [0, 2π]
    unwrapped_phase := self.phase
    for unwrapped_phase < 0.0 do unwrapped_phase += math.TAU
    for unwrapped_phase > math.PI do unwrapped_phase -= math.TAU

    phase_diff := unwrapped_phase - self.prev_unwrapped_phase

    // Handle the jump from 2π to 0 or 0 to 2π
    // (need to handle both rotation directions)
    if phase_diff > math.PI do phase_diff -= math.TAU
    if phase_diff < -math.PI do phase_diff += math.TAU

    // Output is scaled down by factor
    self.scaled_phase += phase_diff / f32(self.downscale_factor)

    // Technically not necessary to unwrap the phase,
    // Question: is there a benefit to doing so?
    for self.scaled_phase < 0.0 do self.scaled_phase += math.TAU
    for self.scaled_phase > math.PI do self.scaled_phase -= math.TAU

    self.prev_unwrapped_phase = unwrapped_phase
}

run_dft_analysis :: proc(self: ^PhaseTracker) -> Maybe(PhaseInfo) {

    phase_info := PhaseInfo {
        phase_correction = self.phase_correction,
        time_reference   = self.time_reference,
        band_count       = self.band_count,
    }

    available := frames_available_in_ringbuffer(&self.ringbuffer)

    if available <= 0 do return nil


    if int(available) >= self.window_size {
        read_ringbuffer(&self.ringbuffer, self.sample_buffer[:], u32(self.window_size))
    } else {
        copy(self.sample_buffer, self.sample_buffer[available:self.window_size])
        offset := self.window_size - int(available)
        read_ringbuffer(&self.ringbuffer, self.sample_buffer[offset:], u32(available))
    }

    sensitivity: f32 = 1.0

    // phase runaway compensation
    self.time_reference += f32(available)
    reference_interval := self.samplerate / self.bands[0].freq_hz
    num_periods := self.time_reference / reference_interval
    // Note, trunc and ceil seem to have the same effect here
    self.phase_correction = math.trunc(num_periods) * reference_interval - self.time_reference

    for &band, band_idx in self.bands {
        normalized_freq: f32 = band.freq_hz / self.samplerate

        // Calculate DFT for this band
        dft := run_single_dft(&band.dft, self.sample_buffer[:self.window_size])

        cos := real(dft)
        sin := imag(dft)
        phase := math.atan2(sin, cos) // [-π, π]
        amp := magnitude(dft)

        // Phase correction, this can move the phase outside of the -π, π range
        phase = phase - self.phase_correction * math.TAU * normalized_freq

        // Unwrap back to -π to π range
        for phase > math.PI do phase -= math.TAU
        for phase < -math.PI do phase += math.TAU

        // Calculate estimated frequency
        phase_diff := phase - band.phase

        band.phase = phase

        if band_idx == 0 {
            scale_down_phase(&band)
            // fmt.println(band.phase, band.scaled_phase, band.phase_iterator)
        } else do band.scaled_phase = band.phase

        // band.phase =+ math.PI * 0.5// adding π/2 aligns phases to get the stripes lined up

        time_delta := f32(available) / f32(self.samplerate)
        band.freq_diff_hz = -(phase_diff / time_delta) / math.TAU
        band.estimated_freq_hz = band.freq_hz + band.freq_diff_hz
        band.err_cents = freq_to_cents(band.estimated_freq_hz) - freq_to_cents(band.freq_hz)

        // Generate a (synthetic strobe) sinusoid based on detected phase & amplitude
        band.time_stretch = reference_interval
        band.amp = amp
        band.freq_multiplier = 1.0

        edge1: f32 = 40.0
        edge2: f32 = 20.0
        if band_idx == 1 {
            edge1 = 25.0
            edge2 = 15.0
        }

        if band_idx == 2 {
            edge1 = 5.0
            edge2 = 1.0
        }

        // Fade out track that is spinning too fast
        // attenuation :f32 = linalg.smootherstep(f32(edge1), edge2, math.abs(band.err_cents))
        attenuation: f32 = 1.0

        // band.amp *= attenuation

        if self.mode == .VERNIER_MODE {
            // band.phase *= sensitivity
            // band.norm_freq = (self.base_freq_hz / self.samplerate) * sensitivity
            // band.time_stretch /= sensitivity
            // band.freq_multiplier *= sensitivity
            //     sensitivity *= 2.0
        }


        phase_info.strobes[band_idx] = {
            freq_hz           = band.freq_hz,
            norm_freq         = band.norm_freq,
            freq_diff_hz      = band.freq_diff_hz,
            estimated_freq_hz = band.estimated_freq_hz,
            time_stretch      = band.time_stretch,
            phase             = band.phase,
            amp               = band.amp,
        }
    }

    return phase_info
}
