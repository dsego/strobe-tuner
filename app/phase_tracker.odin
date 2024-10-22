/* ------------------------------------------------------------------------------------------------


    Phase tracker
    - Generates a reference signal and detects the phase difference between the reference
      and target. The reference phase is calculated in the drawing method and assumes
      it isn't skipping any samples from the input ring buffer. Alternatively, this could be
      done in the audio callback (TBD).


 -------------------------------------------------------------------------------------------------*/


package app

import "core:math"
import "core:fmt"
import rl "vendor:raylib"


PhaseTrackerBand :: struct {
    freq_hz: f32,
    phase: f32,
    display: PhaseTrackerBandDisplay,
    biquad: Biquad,
    estimated_freq_hz: f32,
    angle: f32,
}

PhaseTrackerBandDisplay :: struct {
    color_values: []f32,
    sample_points: []rl.Vector2,
    reference_points: []rl.Vector2,
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
        band.display.color_values = make([]f32, MAX_SPECTRUM_DISPLAY_LEN)
        band.display.sample_points = make([]rl.Vector2, MAX_SPECTRUM_DISPLAY_LEN)
        band.display.reference_points = make([]rl.Vector2, MAX_SPECTRUM_DISPLAY_LEN)
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
    for band in self.bands {
        delete(band.display.color_values)
        delete(band.display.sample_points)
        delete(band.display.reference_points)
    }
    delete(self.bands)
}

set_phase_tracker_freq :: proc (self: ^PhaseTracker, base_freq_hz: f32) {
    self.phase_correction = 0.0
    flush_ringbuffer(&self.ringbuffer)

    for &band, i in self.bands {
        freq_hz := f32(i + 1) * base_freq_hz

        cents := freq_to_cents(freq_hz)
        bandwidth_hz := cents_to_freq(cents + 100) - cents_to_freq(cents - 100)
        norm_freq := freq_hz / self.samplerate
        norm_bandwidth := bandwidth_hz / self.samplerate
        band.biquad = biquad_resonator(f64(norm_freq), f64(norm_bandwidth), 2)
        band.freq_hz = freq_hz
        // band.phase_correction = 0.0
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
    for out, i in output {
        output[i] = input[i]
        // output[i] = biquad_process_sample(&band.biquad, input[i])
    }
}


// -------------------------------------------------------------------------------------------------
//  Drawing methods
// -------------------------------------------------------------------------------------------------

draw_phase_tracker_display :: proc(self: ^PhaseTracker) {
    rl.DrawTextEx(font, "phase", {160, 30}, 14, 0, rl.GOLD)

    available := frames_available_in_ringbuffer(&self.ringbuffer)
    has_new_samples := available > 0
    // phase_correction_diff: f32 = 0.0


    // read 512 samples while available > 512, run dft, find phase, re-run and average?

    reference_interval := self.samplerate / self.bands[0].freq_hz

    // copy over new samples into the freed space
    if has_new_samples {
        copy(self.sample_buffer, self.sample_buffer[available:self.window_size])
        offset := self.window_size - int(available)
        read_ringbuffer(&self.ringbuffer, self.sample_buffer[offset:], u32(available))


        // phase runaway compensation
        self.time_reference += f32(available)

        num_periods := self.time_reference / reference_interval
        new_phase_correction := math.ceil(num_periods) * reference_interval - self.time_reference
        // phase_correction_diff = new_phase_correction - self.phase_correction
        self.phase_correction = new_phase_correction
    }

    for &band, band_idx in self.bands {
        // Draw frame
        rect := rl.Rectangle{160, f32(50 + 110 * band_idx), 800, 100}
        // rect := rl.Rectangle{160, f32(300 + 110 * band_idx), 800, 100}


        rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)

        // Generate ref. signal
        vertical_gain := (rect.height/2.0 - 1.0)
        dx: f32 = (rect.width - 1.0) / f32(self.window_size)
        normalized_freq := band.freq_hz / self.samplerate

        /*
        x := rect.x + f32(rect.width)
        for i in 0..<window_size {
            // 2πft
            ft := 2.0 * math.PI * normalized_freq * (f32(i) + band.time_reference + band.phase_correction)
            ref_signal_value: f32 = math.sin(ft)
            band.display.reference_points[i] = {
                x,
                rect.y + rect.height/2.0 + ref_signal_value * vertical_gain
            }
            x -= dx
        }
        rl.DrawLineStrip(raw_data(band.display.reference_points), i32(window_size), rl.GOLD)
        */
        time_stretch_factor := 4.0 * reference_interval/ f32(self.window_size)

        if has_new_samples {

            // phase runaway compensation
            // reference_interval := self.samplerate / band.freq_hz
            // num_periods := self.time_reference / reference_interval
            // band.phase_correction = math.ceil(num_periods) * reference_interval - self.time_reference

            // Calculate DFT
            dft: complex64 = complex(0, 0)
            for i in 0..<self.window_size {
                // Fourier formula: cos(2πft) - i×sin(2πft)
                time := f32(i)
                ft := normalized_freq * 2.0 * math.PI * time  // 2πft
                win: f32 = blackmann_window(time, f32(self.window_size))
                re := self.sample_buffer[i] * win * math.cos(ft)
                im := self.sample_buffer[i] * win * math.sin(ft)
                dft += complex(re, im)
            }
            cos := real(dft)
            sin := imag(dft)
            phase := math.atan2(sin, cos) // [-pi, pi]

            amp := magnitude(dft)

            // Generate sinusoid based on detected phase & amplitude
            x := rect.x + 1.0


            for i in 0..<self.window_size {
                time := f32(i) * time_stretch_factor
                // TODO: can I apply identities to precalculate things?
                // sin(A + B) = sinA cosB + cosA sinB
                signal_value := amp * math.sin(normalized_freq * 2.0 * math.PI * (time - self.phase_correction) + phase)
                band.display.color_values[i] = signal_value
                band.display.sample_points[i] = {
                    x,
                    rect.y + rect.height/2.0 + signal_value * vertical_gain
                }
                x += dx
            }

            if band_idx == 0 && has_new_samples {


                angle :=  normalized_freq * 2.0 * math.PI * (0.0 - self.phase_correction) + phase


                phase_diff := angle - band.angle
                band.angle = angle


                // Unwrap phase diff
                //  shifts the angles by adding multiples of ±2π until the jump is less than π
                for phase_diff >= math.PI {
                    phase_diff -= 2.0 * math.PI
                }

                for phase_diff <= -math.PI {
                    phase_diff += 2.0 * math.PI
                }

                time_delta := f32(available) / f32(self.samplerate)

                freq_diff_hz := (phase_diff / time_delta) / (2.0 * math.PI)
                // band.estimated_freq_hz = band.freq_hz - freq_diff_hz

                estimated_freq := band.freq_hz - freq_diff_hz
                band.estimated_freq_hz = math.round(estimated_freq * 100.0) / 100.0
            }



        }

        rl.DrawTextEx(
            font,
            fmt.ctprintf("%+.2fHz", band.estimated_freq_hz),
            {20, 280 + 110 * f32(band_idx)},
            22,
            0,
            rl.GOLD
        )

        // Draw strobe pattern
        // ------------------------------------------------
        x := rect.x + 1
        for i in 0..<self.window_size {
            color := convert_to_rgba(band.display.color_values[i])
            // color := rl.Color{100, 100, 100, 255}
            rl.DrawLineEx(
                {x - dx/2, rect.y},
                {x - dx/2, rect.y + rect.height},
                dx,
                color,
            )
            x += dx
        }
        // ------------------------------------------------

        // DRAW INPUT SAMPLES TO DEBUG
        // ------------------------------------------------
        // points: [4096]rl.Vector2
        // x := rect.x + rect.width - 1.0
        // for i in 0..<4096 {
        //     points[i] = {
        //         x,
        //         rect.y + rect.height/2.0 + self.sample_buffer[i] * vertical_gain
        //     }
        //     x -= dx
        // }
        // rl.DrawLineStrip(raw_data(points[:]), i32(self.window_size), rl.PINK)
        // ------------------------------------------------


    }



}


