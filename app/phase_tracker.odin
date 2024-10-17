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
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    reference_phase: f32,
    freq_hz: f32,
    time_reference: int,
    display: PhaseTrackerBandDisplay,
}

PhaseTrackerBandDisplay :: struct {
    samples: []f32,
    sample_points: []rl.Vector2,
    reference_points: []rl.Vector2,
}

PhaseTracker :: struct {
    using node: AudioCaptureNode,
    bands: [dynamic]PhaseTrackerBand,
    samplerate: f32,
}



init_phase_tracker :: proc (base_freq_hz: f32, samplerate: f32, band_count: int) -> (self: PhaseTracker) {

    freq_multiplier :f32 = 1.0

    for i in 0..<band_count {
        band := PhaseTrackerBand{}
        rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
        band.ringbuffer = rb
        band.ringbuffer_data = rb_data
        band.display.samples = make([]f32, MAX_SPECTRUM_DISPLAY_LEN)
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
    for band in self.bands {
        delete(band.ringbuffer_data)
        delete(band.display.samples)
        delete(band.display.sample_points)
        delete(band.display.reference_points)
    }
    delete(self.bands)
}

set_phase_tracker_freq :: proc (self: ^PhaseTracker, base_freq_hz: f32) {
    freq_multiplier: f32 = 1.0

    for &band in self.bands {
        freq_hz := freq_multiplier * base_freq_hz
        band.freq_hz = freq_hz
        band.reference_phase = 0.0
        flush_ringbuffer(&band.ringbuffer)
        freq_multiplier *= 2.0
    }
}


phase_tracker_audio_callback :: proc (ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, PhaseTracker, "node")
    for &band in self.bands {
        process_phase_tracker_band(&band, input)
    }
}


process_phase_tracker_band :: proc (band: ^PhaseTrackerBand, input: []f32)  {
    out1, out2, num_written := get_ringbuffer_write_regions(&band.ringbuffer, len(input))

    if len(out1) > 0 do write_to_rb_region(band, out1, input[:len(out1)])
    if len(out2) > 0 do write_to_rb_region(band, out2, input[len(out1):])

    advance_ringbuffer_write(&band.ringbuffer, i32(num_written))
}

// TODO: filtering ??
@(private="file")
write_to_rb_region :: proc(band: ^PhaseTrackerBand, output: []f32, input: []f32) {
    for out, i in output {
        output[i] = input[i]
    }
}


// -------------------------------------------------------------------------------------------------
//  Drawing methods
// -------------------------------------------------------------------------------------------------


draw_phase_tracker_display :: proc(self: ^PhaseTracker) {
    for &band, band_idx in self.bands {

        // Draw frame
        rect := rl.Rectangle{160, f32(50 + 110 * band_idx), 800, 100}
        rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)


        window_size := 1024

        available := frames_available_in_ringbuffer(&band.ringbuffer)

        // IMPORTANT: keep the sweep interval consistent
        if int(available) > window_size {
            read_ringbuffer(&band.ringbuffer, band.display.samples[:window_size], u32(window_size))
        }



        // Generate ref. signal
        vertical_gain := (rect.height/2.0 - 1.0)
        dx := rect.width / f32(window_size)
        x := rect.x + f32(rect.width)

        normalized_freq := band.freq_hz / self.samplerate

        for i in 0..<window_size {
            // 2πft
            // ft := 2.0 * math.PI * normalized_freq * (f32(i) + band.reference_phase)
            ref_signal_value: f32 = band.display.samples[i] // math.sin(ft)
            band.display.reference_points[i] = {
                x,
                rect.y + rect.height/2.0 + ref_signal_value * vertical_gain
            }
            x -= dx
        }
        rl.DrawLineStrip(raw_data(band.display.reference_points), i32(window_size), rl.GOLD)


        // dft: complex64 = complex(0, 0)
        // for i in 0..<window_size {
        //     // Fourier formula: cos(2πft) - i×sin(2πft)
        //     ft := normalized_freq * 2.0 * math.PI * (f32(i) - band.reference_phase)  // 2πft
        //     blackmann: f32 = 1.0 //blackmann_window(f32(i), f32(window_size))
        //     re := band.display.samples[i] * blackmann * math.cos(ft)
        //     im := band.display.samples[i] * blackmann * math.sin(ft)
        //     dft += complex(re, im)
        // }

        // cos := real(dft)
        // sin := imag(dft)
        // phase := math.atan2(sin, cos) // [-pi, pi]
        // amp := magnitude(dft) / f32(window_size)

        // x = rect.x + f32(rect.width)


        // correct phase by diffing against reference
        // phase = phase / math.PI + 1.0
        // fmt.println(phase)
        // normalized_phase := reference_interval * phase / math.PI

        // fmt.println(normalized_phase, band.reference_phase)

        // max_peak := find_abs_max(band.display.samples[:window_size])
        // signal_gain: f32 = 1.0 // 1.0 / (max_peak + 0.1)


        // for i in 0..<window_size {
        //     signal_value := amp * math.sin(normalized_freq * 2.0 * math.PI * (f32(i) + band.reference_phase) + phase)
        //     band.display.sample_points[i] = {
        //         x,
        //         rect.y + rect.height/2.0 + signal_value * vertical_gain * signal_gain
        //     }
        //     x -= dx
        // }

        // rl.DrawLineStrip(raw_data(band.display.sample_points), i32(window_size), rl.PINK)



        // reference_interval := self.samplerate / band.freq_hz



    }
}
