/* ------------------------------------------------------------------------------------------------



    Sweeping strobe - based on matching the sweep interval to desired frequency



 ------------------------------------------------------------------------------------------------ */


package app

import "core:math"
import "core:fmt"
import rl "vendor:raylib"


StrobeBand :: struct {
    biquad: Biquad,
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    framerate_state: FramerateState,
    freq_hz: f32,
    target_interval: f32,
    time_reference: int,
    display: StrobeBandDisplay,
}

StrobeBandDisplay :: struct {
    samples: []f32,
    filtered_samples: []f32,
    points: []rl.Vector2,
}

Strobe :: struct {
    using node: AudioCaptureNode,
    bands: [dynamic]StrobeBand,
    samplerate: f32,
}


init_strobe :: proc (base_freq_hz: f32, samplerate: f32, band_count: int) -> (self: Strobe) {
    freq_multiplier :f32 = 1.0

    for i in 0..<band_count {
        band := StrobeBand{}
        rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
        band.ringbuffer = rb
        band.ringbuffer_data = rb_data
        band.framerate_state = init_framerate()
        band.display.samples = make([]f32, MAX_SPECTRUM_DISPLAY_LEN)
        band.display.filtered_samples = make([]f32, MAX_SPECTRUM_DISPLAY_LEN)
        band.display.points = make([]rl.Vector2, MAX_SPECTRUM_DISPLAY_LEN)
        append(&self.bands, band)
    }

    self.samplerate = samplerate
    self.stream_callback = strobe_audio_callback

    set_strobe_freq(&self, base_freq_hz)

    return
}

destroy_strobe :: proc(self: ^Strobe) {
    for band in self.bands {
        delete(band.ringbuffer_data)
        delete(band.display.samples)
        delete(band.display.filtered_samples)
        delete(band.display.points)
    }
    delete(self.bands)
}

set_strobe_freq :: proc (self: ^Strobe, base_freq_hz: f32) {
    freq_multiplier: f32 = 1.0

    for &band in self.bands {
        freq_hz := freq_multiplier * base_freq_hz
        cents := freq_to_cents(freq_hz)
        bandwidth_hz := cents_to_freq(cents + 100) - cents_to_freq(cents - 100)
        norm_freq := freq_hz / self.samplerate
        norm_bandwidth := bandwidth_hz / self.samplerate

        band.biquad = biquad_resonator(f64(norm_freq), f64(norm_bandwidth), 2)

        flush_ringbuffer(&band.ringbuffer)

        reset_framerate(&band.framerate_state)

        // for strobe aim at a double interval, to show more of the wave shape and slow down the strobe movement
        band.freq_hz = freq_hz
        band.target_interval = 4.0 * self.samplerate / base_freq_hz

        // samples_per_period := self.samplerate / base_freq_hz
        // k := math.floor(800.0 / samples_per_period)
        // if k < 1 do k = 1
        // band.target_interval = k * self.samplerate / base_freq_hz


        freq_multiplier *= 2.0
    }
}

reset_strobe :: proc(self: ^Strobe) {
    for band in self.bands {
        band := band
        reset_framerate(&band.framerate_state)
    }
}


strobe_audio_callback :: proc (ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, Strobe, "node")
    for &band in self.bands {
        process_strobe_band(&band, input)
    }
}


process_strobe_band :: proc (band: ^StrobeBand, input: []f32)  {
    out1, out2, num_written := get_ringbuffer_write_regions(&band.ringbuffer, len(input))

    if len(out1) > 0 do write_to_rb_region(band, out1, input[:len(out1)])
    if len(out2) > 0 do write_to_rb_region(band, out2, input[len(out1):])

    advance_ringbuffer_write(&band.ringbuffer, i32(num_written))
}

@(private="file")
// TODO: just use copy
write_to_rb_region :: proc(band: ^StrobeBand, output: []f32, input: []f32) {
    for out, i in output {
        output[i] = input[i]
        // output[i] = biquad_process_sample(&band.biquad, input[i])
    }
}

valid_strobe_freq :: proc (freq: f32) -> bool {
    return freq > MIN_STROBE_FREQ && freq < MAX_STROBE_FREQ
}


convolve :: proc (input: []f32, kernel: []f32, output: []f32) {
    for i in 0..<len(kernel) {
        for j in 0..<len(input) {
            output[i+j] += kernel[i] * input[i]
        }
    }
}




// -------------------------------------------------------------------------------------------------
//  Drawing methods
// -------------------------------------------------------------------------------------------------


draw_strobe :: proc(self: ^Strobe) {
    rl.DrawTextEx(font, "strobe", {160, 30}, 14, 0, rl.GOLD)

    for &band, band_idx in self.bands {
        frame_count, drift := read_framerate_samples(
            &band.framerate_state,
            rb_ptr=&band.ringbuffer,
            samples=band.display.samples,
            target_interval=f64(band.target_interval),
        )
        rect := rl.Rectangle{160, f32(50 + 110 * band_idx), 800, 100}
        rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)

        if band.target_interval >= MAX_SPECTRUM_DISPLAY_LEN {
            continue
        }

        // rl.DrawTextEx(font, fmt.ctprintf("Drift %.6f", drift), {20, 90 + 110 * f32(band_idx)}, 20, 0, rl.PINK)
        // rl.DrawRectangleV({20, 120 + 110 * f32(band_idx)}, {120 * f32(drift), 4.0}, rl.PINK)
        // rl.DrawRectangleLinesEx({20, 120 + 110 * f32(band_idx), 120, 5}, 1, rl.PINK)

        // draw_fake_strobe_band_pattern(
        //     rect,
        //     self.texture,
        //     &self.bands[i],
        //     band.freq_hz,
        //     band.target_interval,
        //     frame_count,
        //     drift,
        //     i,
        // )

        max_peak := find_abs_max(band.display.samples[:frame_count])
        gain: f32 = 100.0 / (max_peak + 0.01)
        // gain= 1.0



        for k in 0..<frame_count do band.display.filtered_samples[k] = band.display.samples[k]

        // TODO test with FIR filter instead ? --- goertzel (filter bank)
        amp := reconstruct_from_dft(
            band.freq_hz,
            band.display.samples[:frame_count],
            band.display.filtered_samples[:frame_count],
            self.samplerate,
            drift,
        )

        // Linear interpolation to correct drift
        // for k in 0..<frame_count-1 {
        //     band_display.filtered_samples[k] = band_display.samples[k] + (1.0 - f32(drift)) * (band_display.samples[k+1] - band_display.samples[k])
        // }

        // draw_strobe_lines_drift(rect, &self.bands[i], band.target_interval, frame_count, drift)

        draw_strobe_band_pattern(rect, &band.display, band.target_interval, band.freq_hz, frame_count, gain)
        // draw_strobe_lines(rect, &band.display, band.target_interval, frame_count, gain)
    }
}


draw_strobe_lines :: proc(
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    frame_count: u32,
    gain: f32,
) {
    // fmt.println(target_interval, frame_count, drift)
    resolution := rect.width / f32(target_interval)

    x:f32 = f32(rect.x) + f32(rect.width)
    factor := (rect.height/2.0 - 1.0) * gain

    for i in 0..<frame_count {
        y := rect.y + rect.height/2.0 + band_display.filtered_samples[i] * factor
        band_display.points[i] = { x, y }
        x -= resolution
    }

    // fmt.println(band_display.samples[:frame_count], target_interval, frame_count, drift)

    rl.DrawLineStrip(raw_data(band_display.points), i32(frame_count), rl.GOLD)

}


draw_strobe_lines_drift :: proc(
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    frame_count: u32,
    drift: f64,
) {
    // fmt.println(target_interval, frame_count, drift)
    resolution := rect.width / f32(target_interval)
    drift_adj := f32(drift) * resolution

    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj

    peak: f32 = find_abs_max(band_display.samples[:frame_count])
    gain := 1.0 / (peak + 0.1)

    factor := (rect.height/2.0 - 1.0) * gain

    for i in 0..<frame_count {
        y := rect.y + rect.height/2.0 + band_display.samples[i] * factor
        band_display.points[i] = { x, y }
        x -= resolution
    }

    // fmt.println(band_display.samples[:frame_count], target_interval, frame_count, drift)

    rl.DrawLineStrip(raw_data(band_display.points), i32(frame_count), rl.PINK)
}


// draw strobe pattern directly from samples
draw_strobe_band_pattern :: proc (
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    target_freq: f32,
    frame_count: u32,
    gain: f32,
) {
    resolution := rect.width / f32(frame_count)
    x: f32 = f32(rect.x) + f32(rect.width)



    // rl.DrawText(fmt.ctprintf("%.2f", amp), 120, i32(rect.y) + 50, 14, rl.GRAY)

    // color_a := rl.Color{181, 242, 219, 255}
    // color_b := rl.Color{107, 61, 125, 255}



    // Need to up-sample to get smoother motion on the pattern strobe,
    // because it's not interpolating like the lines - otherwise we get wavering effect


    // if f32(frame_count) < rect.width {
    //     out_size := rect.width
    //     in_size := frame_count
    //     interval: f32 = f32(in_size) / out_size

    //     time: f32 = 0.0
    //     in_idx :u32 = 0
    //     out_idx :u32 = 0

    //     in_data := band_display.filtered_samples[:frame_count]

    //     for in_idx < (in_size - 1)  {
    //         out := lerp(in_data[in_idx], in_data[in_idx+1], time)

    //         color := convert_to_rgba(factor * out)
    //         rl.DrawLineEx(
    //             {x - resolution/2, rect.y},
    //             {x - resolution/2, rect.y + rect.height},
    //             resolution,
    //             color,
    //         )

    //         time += interval
    //         in_idx = u32(math.trunc(time))
    //         x -= 1.0
    //     }

    // } else {

        for i in 0..<frame_count {
            color := convert_to_rgba(band_display.filtered_samples[i] * gain)

            // byte_val := u8(val * 255)
            rl.DrawLineEx(
                {x - resolution/2, rect.y},
                {x - resolution/2, rect.y + rect.height},
                resolution,
                color,
            )
            x -= resolution
        }
    // }



}


// TODO
// TODO
// TODO
//  Precalculate sin/cos stuff (phase_angle) just once per frequency
reconstruct_from_dft :: proc(
    freq_hz: f32,
    samples: []f32,
    output: []f32,
    samplerate: f32,
    drift: f64,
) -> f32 {
    dft: complex64 = complex(0, 0)

    // interval := samplerate/freq_hz
    // trunc_interval := math.trunc(interval)
    // fraction := interval - trunc_interval
    // freq_hz := samplerate / trunc_interval

    freq_bin := freq_hz / samplerate

    n := f32(len(samples))

    for i in 0..<len(samples) {
        output[i] = samples[i] // * blackmann_window(f32(i), n)
        // output[i] = samples[i] * blackman_harris(f32(i), f32(len(samples)))
    }


    for sample, i in output {
        // Fourier formula: cos(2πft) - i×sin(2πft)
        // -----------------------------------------------
        // PROMISING! Makes the strobe pattern stationary - not quite?
        // -----------------------------------------------
        time := f32(i)
        ft := freq_bin * 2.0 * math.PI * (time + f32(drift)) // 2πft

        // -----------------------------------------------
        win := blackmann_window(time, f32(n))
        re := sample * math.cos(ft) * win
        im := sample * math.sin(ft) * win


        dft += complex(re, im)
    }
    // one bin DFT overly aggressive filtering??

    sin := real(dft)
    cos := imag(dft)
    phase := math.atan2(sin, cos)
    amp := magnitude(dft)

    state := 1
    half_interval := samplerate / freq_hz / 2.0
    next_flip := half_interval * phase / math.PI

    for _, i in output {
        output[i] = amp * math.sin(freq_bin * 2.0 * math.PI * f32(i) + phase)
        // if f32(i) > next_flip {
        //     state = -state
        //     next_flip += interval
        // }
        // output[i] = amp * f32(state)
        output[i] /= f32(len(output))
    }

    return amp
}
