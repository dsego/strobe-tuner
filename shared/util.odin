package shared

import "core:math"
import "core:testing"
import "core:fmt"
import rl "vendor:raylib"


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

// Complex number magnitude
magnitude :: proc (cpx: complex64) -> f32 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}

square :: proc (cpx: complex64) -> f32 {
    return real(cpx) * real(cpx) + imag(cpx) * imag(cpx)
}



// Exponentially Weighted Moving Average (https://github.com/jonnieZG/EWMA)
// Parameters:
//   alpha - smoothing factor in 0..1
//   prev_output
ewma_filter :: proc (
    input: f32,
    alpha: f32,
    prev_output: f32
) -> (output: f32) {
    output = (alpha * input + (1.0 - alpha) * prev_output)
    return
}


find_abs_max :: proc (slice: []f32) -> f32 {
    max: f32 = 0.0
    for i in 0..<len(slice) {
        abs_val := abs(slice[i])
        if abs_val > max {
            max = abs_val
        }
    }
    return max
}


lerp :: proc (a: f32, b: f32, t: f32) -> f32 {
  return a + t * (b - a)
}

convert_to_rgba :: proc (value: f32) -> rl.Color {
    value := value

    color_a := rl.Color{226, 101, 70, 255}
    color_b := rl.Color{84, 32, 43, 255}

    // TODO optimize, no need to calculate per sample
    dr := color_a.r - color_b.r
    dg := color_a.g - color_b.g
    db := color_a.b - color_b.b


    // convert from range -1.0 - 1.0 to range 0 - 255
    value = 0.5 * value + 0.5
    // val := 0.5 * factor * band_display.samples[i] + 0.5
    value = math.max(math.min(value, 1.0), 0.0)

    r := u8(f32(color_b.r) + f32(dr) * value)
    g := u8(f32(color_b.g) + f32(dg) * value)
    b := u8(f32(color_b.b) + f32(db) * value)

    return rl.Color{r, g, b, 255}
}


// TODO: cache cosines to optimize?
blackmann_window :: proc (k: f32, size: f32) -> f32 {
    a0:f32 = 0.42
    a1:f32 = 0.5
    a2:f32 = 0.08

    l:f32 = math.TAU * k / (size - 1.0)
    return a0 - a1 * math.cos(l) + a2 * math.cos(2.0 * l)
}


// https://www.recordingblogs.com/wiki/flat-top-window
flattop_window :: proc (k: f32, size: f32) -> f32 {
    return (0.21557895
        - 0.41663158  * math.cos(2 * math.PI * k / (size - 1))
        + 0.277263158 * math.cos(4 * math.PI * k / (size - 1))
        - 0.083578947 * math.cos(6 * math.PI * k / (size - 1))
        + 0.006947368 * math.cos(8 * math.PI * k / (size - 1)))
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


snap_number :: proc (value: f32, eps: f32) -> f32 {
    rounded := math.round(value)
    if math.abs(rounded - value) <= eps {
        return rounded
    }
    return value
}

@(test)
test_snap_number :: proc(t: ^testing.T) {
    testing.expect_value(t, snap_number(0.99, 0.01), 1.00)
    testing.expect_value(t, snap_number(0.98, 0.01), 0.98)
    testing.expect_value(t, snap_number(0.01, 0.01), 0.00)
    testing.expect_value(t, snap_number(0.02, 0.01), 0.02)
}
