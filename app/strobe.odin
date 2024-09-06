package app

import "core:math"

Strobe :: struct {
    size: int,
    samples: []f32,
    biquad: Biquad,
    // smooth: SmoothConfig,
}

strobes: [STROBE_COUNT] Strobe

init_strobes :: proc (normalized_freq: f64) {
    freq := normalized_freq

    for i in 0..<STROBE_COUNT {
        bandwidth := 0.5 * freq
        strobes[i] = Strobe {}
        strobes[i].biquad = biquad_resonator(freq, bandwidth)
        // strobes[i].smooth = init_smoothing(2048)
        // strobes[i].samples = make([]f32, size)
        freq *= 2.0
    }
}

// TODO: optimize to not run per sample?
run_strobe :: proc (strobe: ^Strobe, sample: f32) -> f32 {
    // return sample //* 10.0

    // rolling square average
    // squared := sample * sample
    // squared_avg := smooth(&strobe.smooth, squared)

    // rms := math.sqrt(squared_avg) * 2.0

    // // apply auto gain
    // target_rms := f32(0.4)
    // gain := target_rms / rms
    // gain := f32(1.0)
    // agc_sample := sample * gain

    return biquad_process_sample(&strobe.biquad, sample)
}

destroy_strobes :: proc() {
    for i in 0..<STROBE_COUNT {
        // delete(strobes[i].samples)
    }
}
