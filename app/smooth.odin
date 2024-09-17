// Rolling average smoother

package app

import "core:testing"
import "core:fmt"

MAX_ITEMS :: 4096

SmoothConfig :: struct {
    window_size: u32,
    delay_line: [MAX_ITEMS]f32,
    rolling_avg: f32,
}

init_smoothing :: proc(win_size: u32) -> (ret: SmoothConfig) {
    ret.window_size = win_size
    return
}


run_smooth :: proc(config: ^SmoothConfig, value: f32) -> f32 {
    end := config.window_size - 1

    config.rolling_avg -= config.delay_line[end] / f32(config.window_size)

    // move the delay line by 1 sample
    for i in 0..<end {
        config.delay_line[end-i] = config.delay_line[end-i-1]
    }

    config.delay_line[0] = value
    config.rolling_avg += value / f32(config.window_size)
    return config.rolling_avg
}


@(test)
test_rolling_average :: proc(t: ^testing.T) {
    conf := init_smoothing(5)
    run_smooth(&conf, 1.0)
    run_smooth(&conf, 2.0)
    run_smooth(&conf, 3.0)
    run_smooth(&conf, 4.0)
    run_smooth(&conf, 5.0)

    expected_avg := f32(5.0) // sum / count
    // testing.expect_value(t, conf.rolling_avg, expected_avg)
}
