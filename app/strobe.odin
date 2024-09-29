package app

import "core:math"
import "core:fmt"


StrobeBand :: struct {
    biquad: Biquad,
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    framerate_state: FramerateState,
    target_interval: f32,
}

Strobe :: struct {
    using node: AudioCaptureNode,
    bands: [dynamic]StrobeBand,
}


init_strobe :: proc (base_freq_hz: f32, samplerate: f32, band_count: int) -> (self: Strobe) {

    freq_multiplier :f32 = 1.0

    for i in 0..<band_count {
        band := StrobeBand{}
        rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
        band.ringbuffer = rb
        band.ringbuffer_data = rb_data
        band.framerate_state = init_framerate()
        append(&self.bands, band)
    }

    set_strobe_freq(&self, base_freq_hz, samplerate)

    self.stream_callback = strobe_audio_callback
    return
}

set_strobe_freq :: proc (self: ^Strobe, base_freq_hz: f32, samplerate: f32) {
    freq_multiplier: f32 = 1.0

    for &band in self.bands {
        freq_hz := freq_multiplier * base_freq_hz
        cents := freq_to_cents(freq_hz)
        bandwidth_hz := cents_to_freq(cents + 50) - cents_to_freq(cents - 50)
        norm_freq := freq_hz / samplerate
        norm_bandwidth := bandwidth_hz / samplerate

        band.biquad = biquad_resonator(f64(norm_freq), f64(norm_bandwidth))
        reset_framerate(&band.framerate_state)

        // for strobe aim at a double interval, to show more of the wave shape and slow down the strobe movement
        band.target_interval = 2.0 * samplerate / base_freq_hz
        freq_multiplier *= 2.0
    }
}

reset_strobe :: proc(self: ^Strobe) {
    for band in self.bands {
        band := band
        reset_framerate(&band.framerate_state)
    }
}

destroy_strobe :: proc(self: ^Strobe) {
    for band in self.bands {
        delete(band.ringbuffer_data)
    }
    delete(self.bands)
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


write_to_rb_region :: proc(band: ^StrobeBand, output: []f32, input: []f32) {
    for out, i in output {
        output[i] = biquad_process_sample(&band.biquad, input[i])
    }
}
