/* ------------------------------------------------------------------------------------------------


    Phase tracker
    - Generates a reference signal and detects the phase difference between the reference
      and target. The reference phase is calculated in the drawing method and synthesizes a strobe
      based on the detected phase difference.


 -------------------------------------------------------------------------------------------------*/


package app

import "core:math"
import "core:fmt"
import rl "vendor:raylib"


PhaseTrackerBand :: struct {
    freq_hz: f32,
    freq_diff_hz: f32,
    display: PhaseTrackerBandDisplay,
    estimated_freq_hz: f32,
    angle: f32,
    dft: SingleFreqDFT,
}

PhaseTrackerBandDisplay :: struct {
    strobe_buffer: []f32,
    // width, height, etc
}

PhaseTracker :: struct {
    using node: AudioCaptureNode,
    sample_buffer: []f32,
    window_size: int,
    overlap_size: int,
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    phase_correction: f32,
    time_reference: f32,
    bands: [dynamic]PhaseTrackerBand,
    samplerate: f32,
}



init_phase_tracker :: proc (base_freq_hz: f32, samplerate: f32, band_count: int) -> (self: PhaseTracker) {
    self.window_size = 4096
    self.overlap_size = 256

    rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
    self.ringbuffer = rb
    self.ringbuffer_data = rb_data
    self.sample_buffer = make([]f32, self.window_size)

    for i in 0..<band_count {
        band := PhaseTrackerBand{}
        band.display.strobe_buffer = make([]f32, MAX_SPECTRUM_DISPLAY_LEN)
        band.dft = init_dft(self.window_size)

        append(&self.bands, band)
    }



    set_phase_tracker_freq(&self, base_freq_hz)

    self.samplerate = samplerate
    self.stream_callback = phase_tracker_audio_callback
    return
}

destroy_phase_tracker :: proc(self: ^PhaseTracker) {
    delete(self.ringbuffer_data)
    delete(self.sample_buffer)
    for &band in self.bands {
        delete(band.display.strobe_buffer)
        destory_dft(&band.dft)
    }
    delete(self.bands)
}

set_phase_tracker_freq :: proc (self: ^PhaseTracker, base_freq_hz: f32) {
    self.phase_correction = 0.0
    flush_ringbuffer(&self.ringbuffer)

    for &band, i in self.bands {
        freq_hz := f32(i + 1) * base_freq_hz
        band.freq_hz = freq_hz
        norm_freq := freq_hz / self.samplerate
        set_dft_freq(&band.dft, norm_freq)
    }
}


phase_tracker_audio_callback :: proc (ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, PhaseTracker, "node")

    out1, out2, num_written := get_ringbuffer_write_regions(&self.ringbuffer, len(input))

    if len(out1) > 0 do write_to_rb_region(out1, input[:len(out1)])
    if len(out2) > 0 do write_to_rb_region(out2, input[len(out1):])

    advance_ringbuffer_write(&self.ringbuffer, i32(num_written))
}

// TODO: filtering ??
@(private="file")
write_to_rb_region :: proc(output: []f32, input: []f32) {
    copy(output, input)
}


// -------------------------------------------------------------------------------------------------
//  Drawing methods
// -------------------------------------------------------------------------------------------------


draw_strobe_bands :: proc (self: ^PhaseTracker) {
    rl.DrawTextEx(font, "phase", {160, 30}, 14, 0, rl.GOLD)

    for &band, band_idx in self.bands {
        // Draw frame
        rect := rl.Rectangle{160, f32(50 + 110 * band_idx), 800, 100}

        rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)
        x := rect.x + 1.0
        dx: f32 = (rect.width - 1.0) / f32(self.window_size)

        for i in 0..<self.window_size {
            signal_value := band.display.strobe_buffer[i]
            color := convert_to_rgba(band.display.strobe_buffer[i])

            // Draw strobe pattern
            rl.DrawLineEx(
                {x - dx/2, rect.y},
                {x - dx/2, rect.y + rect.height},
                dx,
                color,
            )
            x += dx
        }

        rl.DrawTextEx(
            font,
            fmt.ctprintf("%+.4fHz", band.estimated_freq_hz),
            {20, 280 + 110 * f32(band_idx)},
            22,
            0,
            rl.GOLD
        )
    }
}

run_dft_analysis :: proc(self: ^PhaseTracker) {
    available := frames_available_in_ringbuffer(&self.ringbuffer)

    if available <= 0 do return

    reference_interval := self.samplerate / self.bands[0].freq_hz

    copy(self.sample_buffer, self.sample_buffer[available:self.window_size])
    offset := self.window_size - int(available)
    read_ringbuffer(&self.ringbuffer, self.sample_buffer[offset:], u32(available))


    // phase runaway compensation
    self.time_reference += f32(available)

    num_periods := self.time_reference / reference_interval
    self.phase_correction = math.ceil(num_periods) * reference_interval - self.time_reference

    for &band, band_idx in self.bands {
        normalized_freq:f32 = band.freq_hz / self.samplerate

        // Calculate DFT for this band
        dft := run_single_dft(&band.dft, self.sample_buffer[:self.window_size])

        cos := real(dft)
        sin := imag(dft)
        phase := math.atan2(sin, cos) // [-pi, pi]
        amp := magnitude(dft)

        // Calculate estimated frequency
        angle :=  phase - normalized_freq * math.TAU * self.phase_correction
        phase_diff := angle - band.angle
        band.angle = angle
        // Unwrap phase diff
        //  shifts the angles by adding multiples of ±2π until the jump is less than π
        for phase_diff >= math.PI {
            phase_diff -= math.TAU
        }

        for phase_diff <= -math.PI {
            phase_diff += math.TAU
        }

        time_delta := f32(available) / f32(self.samplerate)
        band.freq_diff_hz = -(phase_diff / time_delta) / math.TAU
        estimated_freq := band.freq_hz + band.freq_diff_hz
        band.estimated_freq_hz = estimated_freq

        time_stretch_factor := 4.0 * reference_interval/ f32(self.window_size)
        gain: f32 = 1.0 // (amp + 0.1)

        // TODO can I fade out the band when the freq difference is significant
        // if band.freq_diff_hz > 15.0 || band.freq_diff_hz < -15.0 do gain = 1.0

        // Generate a (synthetic strobe) sinusoid based on detected phase & amplitude
        for i in 0..<self.window_size {
            time := f32(i) * time_stretch_factor

            signal_value := amp * math.sin(normalized_freq * math.TAU * (time - self.phase_correction) + phase)
            band.display.strobe_buffer[i] = signal_value * gain
        }





    }
}

draw_phase_tracker_display :: proc(self: ^PhaseTracker) {
    run_dft_analysis(self)
    draw_strobe_bands(self)
}


