// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package core

import "core:math"


blackman_window :: proc(index: f32, size: f32) -> f32 {
    a0: f32 = 0.42
    a1: f32 = 0.5
    a2: f32 = 0.08

    angle: f32 = math.TAU * index / (size - 1.0)
    return a0 - a1 * math.cos(angle) + a2 * math.cos(2.0 * angle)
}

// Gamma shaped (order 3), the weight of a 3-pole lock-in low-pass: it rises fast from the newest sample and
// falls off with age, so a tone is measured as of GAMMA_WINDOW_DELAY of the window back instead of half.
// The spread of the weights matches the Blackman's (0.16 of the window, σ = √3 τ), for about as narrow
// a band, and the mean matches its 0.42 so the levels are the same.
GAMMA_WINDOW_TAU :: 0.0921 // of the window size
GAMMA_WINDOW_DELAY :: 3 * GAMMA_WINDOW_TAU // the mean age, of the window size

gamma_window :: proc(index: f32, size: f32) -> f32 {
    age := (size - 1.0 - index) / (GAMMA_WINDOW_TAU * size)
    return 0.42 / (2.0 * GAMMA_WINDOW_TAU) * age * age * math.exp(-age)
}
