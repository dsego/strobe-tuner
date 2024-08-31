package app

import "core:math"
import "core:fmt"


// Parabolic interpolation to find the more accurate peak location
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic :: proc (alpha: f32, beta: f32, gamma: f32) -> (f32, f32) {
    location := 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma)
    magnitude := beta - 0.25 * (alpha - gamma) * location
    return location, magnitude
}

arithmetic_mean :: proc (array: []f32) -> f32 {
    mean: f32 = 0.0

    for i in 0..<len(array) {
        mean += max(array[i], math.F32_EPSILON) // epsilon so it never goes to zero
    }

    mean /= f32(len(array))
    return mean
}


geometric_mean :: proc (array: []f32) -> f32 {
    geometric_mean: f32 = 0.0

    for i in 0..<len(array) {
        // need to avoid zeros, because ln(0) = -inf
        geometric_mean += math.ln(max(array[i], math.F32_EPSILON))
    }
    geometric_mean /= f32(len(array))
    geometric_mean = math.exp(geometric_mean)

    return geometric_mean
}


// Symmetric Blackmann-Harris
// https://en.wikipedia.org/wiki/Window_function
// https://github.com/JvanKatwijk/filter-demo/blob/master/blackman-harris.cpp#L18-L24
blackman_harris :: proc (i: f32, num: f32) -> f32 {
    a0 :: 0.35875
    a1 :: 0.48829
    a2 :: 0.14128
    a3 :: 0.01168

    seg1 := a1 * math.cos(2.0 * math.PI * i / (num - 1.0))
    seg2 := a2 * math.cos(4.0 * math.PI * i / (num - 1.0))
    seg3 := a3 * math.cos(6.0 * math.PI * i / (num - 1.0))
    res := a0 - seg1 + seg2 - seg3

    return res
}

freq_in_range :: proc (freq: f32) -> bool {
    return freq > MIN_FREQ && freq < MAX_FREQ
}

// Complex number magnitude
magnitude :: proc (cpx: complex64) -> f32 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}

square :: proc (cpx: complex64) -> f32 {
    return real(cpx) * real(cpx) + imag(cpx) * imag(cpx)
}
