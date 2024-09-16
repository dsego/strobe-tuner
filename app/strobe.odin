package app

import "core:math"
import "core:fmt"

Strobe :: struct {
    size: int,
    samples: []f32,
    biquad: Biquad,
    // smooth: SmoothConfig,
}

strobes: [STROBE_COUNT] Strobe

set_strobes :: proc (base_freq_hz: f64) {
    freq_hz := base_freq_hz

    for i in 0..<STROBE_COUNT {
        strobes[i] = Strobe {}
        cents := freq_to_cents(f32(freq_hz))
        bandwidth_hz := cents_to_freq(f32(cents) + 50) - cents_to_freq(f32(cents) - 50)

        norm_freq := freq_hz / SAMPLERATE
        norm_bandwidth := bandwidth_hz / SAMPLERATE

        fmt.println(bandwidth_hz, freq_hz)
        strobes[i].biquad = biquad_resonator(norm_freq, f64(norm_bandwidth))
        // strobes[i].smooth = init_smoothing(2048)
        // strobes[i].samples = make([]f32, size)
        freq_hz *= 2.0
    }
}

// TODO: optimize to not run per sample?
run_strobe :: proc (strobe: ^Strobe, sample: f32) -> f32 {
    // return sample * 100.0

    // rolling square average
    // squared := sample * sample
    // squared_avg := smooth(&strobe.smooth, squared)

    // rms := math.sqrt(squared_avg) * 2.0

    // // apply auto gain
    // target_rms := f32(0.4)
    // gain := target_rms / rms
    // gain := f32(1.0)
    // agc_sample := sample * gain

    return 100.0 * biquad_process_sample(&strobe.biquad, sample)
}

destroy_strobes :: proc() {
    for i in 0..<STROBE_COUNT {
        // delete(strobes[i].samples)
    }
}
