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
import "core:testing"


schmitt_trigger :: proc(
    prev_state: bool,
    value: f32,
    low_threshold: f32,
    high_threshold: f32,
) -> bool {
    if !prev_state && value > high_threshold {
        return true
    } else if prev_state && value < low_threshold {
        return false
    }
    return prev_state
}


@(test)
test_positive_values :: proc(t: ^testing.T) {
    state := schmitt_trigger(false, 3.0, 1.0, 2.0)
    testing.expect_value(t, state, true)

    state = schmitt_trigger(true, 1.5, 1.0, 2.0)
    testing.expect_value(t, state, true)

    state = schmitt_trigger(true, 0.5, 1.0, 2.0)
    testing.expect_value(t, state, false)
}


schmitt_trigger_neg :: proc(
    prev_state: bool,
    value: f32,
    low_threshold: f32,
    high_threshold: f32,
) -> bool {
    if !prev_state && value < high_threshold {
        return true
    } else if prev_state && value > low_threshold {
        return false
    }
    return prev_state
}

@(test)
test_negative_values :: proc(t: ^testing.T) {
    state := schmitt_trigger_neg(false, -3.0, -1.0, -2.0)
    testing.expect_value(t, state, true)

    state = schmitt_trigger_neg(true, -1.5, -1.0, -2.0)
    testing.expect_value(t, state, true)

    state = schmitt_trigger_neg(true, -0.5, -1.0, -2.0)
    testing.expect_value(t, state, false)
}
