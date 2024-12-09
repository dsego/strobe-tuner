//  One Euro filter
//
//  https://gery.casiez.net/1euro/
//  https://jaantollander.com/post/noise-filtering-using-one-euro-filter/
//

package core

import "core:math"


OneEuroFilter :: struct {
    min_cutoff_hz: f32, // Minimum cutoff frequency:
    beta:          f32, // Cutoff slope (speed coefficient)
    der_cutoff_hz: f32, // Cutoff frequency for derivate

    // Previous values
    x_hat_prev:    f32,
    dx_prev:       f32,
    time_prev:     f64,
}


// Decreasing the minimum cutoff frequency decreases slow speed jitter.
// Increasing the speed coefficient beta decreases speed lag.
init_one_euro_filter :: proc(min_cutoff_hz: f32, beta: f32, der_cutoff_hz: f32) -> OneEuroFilter {
    self := OneEuroFilter{}
    self.min_cutoff_hz = min_cutoff_hz
    self.beta = beta
    self.der_cutoff_hz = der_cutoff_hz
    return self
}

run_one_euro_filter :: proc(self: ^OneEuroFilter, time: f64, x: f32) -> f32 {
    time_elapsed := time - self.time_prev
    rate := 1.0 / f32(time_elapsed)

    // The filtered derivative of the signal
    dx := (x - self.x_hat_prev) * rate
    dx_hat := exponential_smoothing(alpha(rate, self.der_cutoff_hz), dx, self.dx_prev)

    // The filtered signal
    cutoff := self.min_cutoff_hz + self.beta * math.abs(dx_hat)
    x_hat := exponential_smoothing(alpha(rate, cutoff), x, self.x_hat_prev)

    // Memorize the previous values
    self.x_hat_prev = x_hat
    self.dx_prev = dx_hat
    self.time_prev = time

    return x_hat
}

// Filter method of Low-pass filter
exponential_smoothing :: proc(alpha: f32, x: f32, x_hat_prev: f32) -> f32 {
    x_hat := x_hat_prev + alpha * (x - x_hat_prev)
    return x_hat
}

// Alpha smoothing factor
alpha :: proc(rate: f32, cutoff_hz: f32) -> f32 {
    return 1.0 / (1.0 + rate / math.TAU * cutoff_hz)
}
