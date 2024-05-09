package app

Strobe :: struct {
    size: int,
    samples: []f32,
    biquad: Biquad,
}

init_strobe :: proc (size: int, normalized_freq: f64) -> (strobe: ^Strobe) {
    bandwidth := 0.1 * normalized_freq
    strobe.biquad = biquad_resonator(normalized_freq, bandwidth)
    strobe.samples = make([]f32, size)
    return strobe
}

run_strobe :: proc (strobe: ^Strobe, in_samples: []f32) {
    // strobe.samples =
    // biquad_process(&strobe.biquad, in_samples, strobe.samples)
    // return strobe.samples
}

destroy_strobe :: proc(strobe: ^Strobe) {
    delete(strobe.samples)
    free(strobe)
}
