package app

import "core:math"
import "core:fmt"


StrobeBand :: struct {
    biquad: Biquad,
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    framerate_state: FramerateState,
}

Strobe :: struct {
    using node: AudioCaptureNode,
    bands: [dynamic]StrobeBand,
}


init_strobe :: proc (freq_hz: f32, samplerate: f32, band_count: int) -> (self: Strobe) {
    for i in 0..<band_count {
        cents := freq_to_cents(freq_hz)
        bandwidth_hz := cents_to_freq(cents + 50) - cents_to_freq(cents - 50)
        norm_freq := freq_hz / samplerate
        norm_bandwidth := bandwidth_hz / samplerate

        band := StrobeBand{}
        band.biquad = biquad_resonator(f64(norm_freq), f64(norm_bandwidth))

        rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
        band.ringbuffer = rb
        band.ringbuffer_data = rb_data

        append(&self.bands, band)
    }

    self.stream_callback = strobe_audio_callback
    return
}

destroy_strobe :: proc(self: ^Strobe) {
    for band in self.bands {
        delete(band.ringbuffer_data)
    }
    delete(self.bands)
}

strobe_audio_callback :: proc (ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, Strobe, "node")
    for band in self.bands {
        process_strobe_band(band, input)
    }
}


process_strobe_band :: proc (band: StrobeBand, input: []f32)  {
    band := band
    out1, out2 := get_ringbuffer_write_regions(&band.ringbuffer, len(input))

    write_to_rb_region(band, out1, input)

    if len(out2) > 0 {
        write_to_rb_region(band, out2, input[len(out1):])
    }

    num_written := len(out1) + len(out2)

    advance_ringbuffer(&band.ringbuffer, i32(num_written))
}


write_to_rb_region :: proc(band: StrobeBand, output: []f32, input: []f32) {
    band := band

    for sample, i in input {
        output[i] = 100.0 * biquad_process_sample(&band.biquad, sample)
    }
}
