package app

import "core:math"

Strobe :: struct {
    size: int,
    samples: []f32,
    biquad: Biquad,
}

strobes: [STROBE_COUNT] Strobe


squared: f32
rms_window_size := 4096
window_counter := 0



init_strobes :: proc (normalized_freq: f64) {
    freq := normalized_freq

    for i in 0..<STROBE_COUNT {
        bandwidth := 0.5 * freq
        strobes[i] = Strobe {}
        strobes[i].biquad = biquad_resonator(freq, bandwidth)
        // strobes[i].samples = make([]f32, size)
        freq *= 2.0
    }
}

run_strobe :: proc (strobe: ^Strobe, sample: f32) -> f32 {

    // rolling square average
    squared -= squared / f32(rms_window_size)
    squared += (sample * sample) / f32(rms_window_size)
    rms := math.sqrt(squared) * 2.0

    // apply auto gain
    target_rms := f32(0.4)
    gain := target_rms / rms
    agc_sample := sample * gain

    return biquad_process_sample(&strobe.biquad, agc_sample)
}

destroy_strobes :: proc() {
    for i in 0..<STROBE_COUNT {
        delete(strobes[i].samples)
    }
}
