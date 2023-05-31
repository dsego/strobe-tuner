// https://stackoverflow.com/questions/8835806/c-c-goertzel-algorithm-with-complex-output-or-magnitudephase
package main

import "core:math"

GoertzelSetup :: struct {
    coeff: f64,
    sine: f64,
    cosine: f64,
}

goertzel_init :: proc (normalized_freq: f64) -> (g: GoertzelSetup) {
    w := 2 * math.PI * normalized_freq // angle
    wr := math.cos(w)
    wi := math.sin(w)
    g.coeff = 2 * wr
    g.cosine = wr
    g.sine = wi
    return g
}

goertzel_process :: proc (g: GoertzelSetup, samples: []f32, size: u32) -> complex64 {
    prev_sample_1 := 0.0
    prev_sample_2 := 0.0
    for n in 0..<size {
        s := f64(samples[n]) + g.coeff * prev_sample_1 - prev_sample_2
        prev_sample_2 = prev_sample_1
        prev_sample_1 = s
    }

    re := prev_sample_1 * g.cosine - prev_sample_2
    im := -prev_sample_1 * g.sine
    return complex(re, im)
}
