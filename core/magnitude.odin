package core

import "core:math"


// Complex number magnitude
magnitude :: proc(cpx: complex64) -> f32 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}
