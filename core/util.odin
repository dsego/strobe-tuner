package core

import "core:math"
import "core:testing"
import rl "vendor:raylib"


// Complex number magnitude
magnitude :: proc(cpx: complex64) -> f32 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}
