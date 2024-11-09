package app

import "core:math"


Biquad :: struct {
    // delay line z1 = x[n-1], z2 = x[n-2]
    z1: [4]f64,
    z2: [4]f64,

    // number of cascading bi-quads
    cascade_count: u32,

    a0: f64,
    a1: f64,
    a2: f64,
    b1: f64,
    b2: f64
}

biquad_process :: proc(bq: ^Biquad, input: []f32, output: []f32) {
    for _, i in input {
        y := f64(0)
        x := f64(input[i])
        // Cascade into multiple bi-quad sections (stages)
        for stage in 0..<bq.cascade_count {
            // Transposed direct form II
            y = f64(x) * bq.a0 + bq.z1[stage]
            bq.z1[stage] = f64(x) * bq.a1 + bq.z2[stage] - bq.b1 * y
            bq.z2[stage] = f64(x) * bq.a2 - bq.b2 * y
            x = y
        }
        output[i] = f32(y)
    }
}

biquad_process_sample :: proc(bq: ^Biquad, input: f32) -> (output: f32) {
    y := f64(0)
    x := f64(input)
    // Cascade into multiple bi-quad sections (stages)
    for stage in 0..<bq.cascade_count {
        // Transposed direct form II
        y = f64(x) * bq.a0 + bq.z1[stage]
        bq.z1[stage] = f64(x) * bq.a1 + bq.z2[stage] - bq.b1 * y
        bq.z2[stage] = f64(x) * bq.a2 - bq.b2 * y
        x = y
    }
    output = f32(y)
    return output
}


biquad_resonator :: proc(normalized_freq: f64, normalized_bandwidth: f64, cascade_count: u32 = 1) -> (bq: Biquad) {
    angle := 2.0 * math.PI * normalized_freq
    cosine := math.cos(angle)
    radius := math.exp(-math.PI * normalized_bandwidth)
    radius_squared := radius * radius

    bq.a0 = (1.0 - radius_squared) / 2.0
    bq.a1 = 0.0
    bq.a2 = -bq.a0
    bq.b1 = -2.0 * radius * cosine
    bq.b2 = radius_squared

    bq.cascade_count = cascade_count
    return
}
