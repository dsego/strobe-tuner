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
