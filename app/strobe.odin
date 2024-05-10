package app

Strobe :: struct {
    size: int,
    samples: []f32,
    biquad: Biquad,
}

strobes: [STROBE_COUNT] Strobe

init_strobes :: proc (size: int, normalized_freq: f64) {
    freq := normalized_freq

    for i in 0..<STROBE_COUNT {
        bandwidth := 0.1 * freq
        strobes[i] = Strobe {}
        strobes[i].biquad = biquad_resonator(freq, bandwidth)
        strobes[i].samples = make([]f32, size)
        freq *= 2.0
    }
}

run_strobe :: proc (strobe: ^Strobe, sample: f32) -> f32 {
    return biquad_process_sample(&strobe.biquad, sample)
}

destroy_strobes :: proc() {
    for i in 0..<STROBE_COUNT {
        delete(strobes[i].samples)
    }
}
