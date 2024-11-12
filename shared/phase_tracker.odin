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


MAX_BANDS :: 8


StrobeBand :: struct {
    freq_hz:           f32,
    norm_freq:         f32,
    freq_diff_hz:      f32,
    estimated_freq_hz: f32,
    angle:             f32,
    dft:               SingleFreqDFT,
    time_stretch:      f32,
    phase:             f32,
    amp:               f32,
}

PhaseTracker :: struct {
    using node:       AudioCaptureNode,
    sample_buffer:    []f32,
    window_size:      int,
    ringbuffer:       RingBuffer,
    ringbuffer_data:  []u8,
    phase_correction: f32,
    time_reference:   f32,
    bands:            [dynamic]StrobeBand,
    band_count:       int,
    samplerate:       f32,
}


init_phase_tracker :: proc(base_freq_hz: f32, samplerate: f32, band_count: int) -> ^PhaseTracker {
    self := new(PhaseTracker)
    self.window_size = 4096
    assert(band_count <= MAX_BANDS)

    rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
    self.ringbuffer = rb
    self.ringbuffer_data = rb_data
    self.sample_buffer = make([]f32, self.window_size)

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
    multiplier := 1

    for &band, i in self.bands {
        freq_hz := f32(multiplier) * base_freq_hz
        band.freq_hz = freq_hz
        band.norm_freq = freq_hz / self.samplerate
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

run_dft_analysis :: proc(self: ^PhaseTracker) -> Maybe(PhaseInfo) {

    phase_info := PhaseInfo {
        phase_correction = self.phase_correction,
        time_reference   = self.time_reference,
        band_count       = self.band_count,
    }

    available := frames_available_in_ringbuffer(&self.ringbuffer)

    if available <= 0 do return nil

    reference_interval := self.samplerate / self.bands[0].freq_hz

    if int(available) >= self.window_size {
        read_ringbuffer(&self.ringbuffer, self.sample_buffer[:], u32(available))
    } else {
        copy(self.sample_buffer, self.sample_buffer[available:self.window_size])
        offset := self.window_size - int(available)
        read_ringbuffer(&self.ringbuffer, self.sample_buffer[offset:], u32(available))
    }

    // phase runaway compensation
    self.time_reference += f32(available)

    num_periods := self.time_reference / reference_interval
    self.phase_correction = math.ceil(num_periods) * reference_interval - self.time_reference


    for &band, band_idx in self.bands {
        normalized_freq: f32 = band.freq_hz / self.samplerate

        // Calculate DFT for this band
        dft := run_single_dft(&band.dft, self.sample_buffer[:self.window_size])

        cos := real(dft)
        sin := imag(dft)
        phase := math.atan2(sin, cos) // [-π, π]
        amp := magnitude(dft)

        // Calculate estimated frequency
        angle := phase - normalized_freq * math.TAU * self.phase_correction
        phase_diff := angle - band.angle
        band.angle = angle

        // Unwrap phase diff
        //  shifts the angles by adding multiples of ±2π until the jump is less than π
        for phase_diff >= math.PI do phase_diff -= math.TAU

        for phase_diff <= -math.PI do phase_diff += math.TAU


        time_delta := f32(available) / f32(self.samplerate)
        band.freq_diff_hz = -(phase_diff / time_delta) / math.TAU
        estimated_freq := band.freq_hz + band.freq_diff_hz
        band.estimated_freq_hz = estimated_freq

        time_stretch_factor := 10.0 * reference_interval
        // gain: f32 = 1.0 // (amp + 0.1)

        // TODO can I fade out the band when the freq difference is significant
        // if band.freq_diff_hz > 15.0 || band.freq_diff_hz < -15.0 do gain = 1.0

        // Generate a (synthetic strobe) sinusoid based on detected phase & amplitude
        band.time_stretch = time_stretch_factor
        band.phase = phase
        band.amp = amp

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
