package core

import "core:math"
import "core:testing"
import rl "vendor:raylib"


// Parabolic interpolation to find the more accurate peak location
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic :: proc(alpha: f32, beta: f32, gamma: f32) -> (f32, f32) {
    location := 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma)
    magnitude := beta - 0.25 * (alpha - gamma) * location
    return location, magnitude
}

// Complex number magnitude
magnitude :: proc(cpx: complex64) -> f32 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}
