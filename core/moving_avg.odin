package core

import "core:fmt"
import "core:testing"

// Nice efficient implementation using a circular buffer
// courtesy of Gergely Bencsik (https://youtu.be/7STwpe9Ojic)
MovingAvg :: struct {
    buffer:  []f32,
    average: f32,
    index:   int,
}

init_moving_avg :: proc(size: int) -> MovingAvg {
    self := MovingAvg{}
    self.buffer = make([]f32, size)
    return self
}

destroy_moving_avg :: proc(self: ^MovingAvg) {
    delete(self.buffer)
}

run_moving_avg :: proc(self: ^MovingAvg, input: f32) -> f32 {
    size := len(self.buffer)

    self.average -= self.buffer[self.index] / f32(size)

    // replace the oldest entry with the newest
    self.buffer[self.index] = input
    self.average += input / f32(size)

    self.index += 1
    if self.index >= size do self.index = 0
    return self.average
}


@(test)
test_moving_avg :: proc(t: ^testing.T) {
    avg := init_moving_avg(5)
    defer destroy_moving_avg(&avg)

    // (4 + 2 + 1 + 8 + 2 ) / 5
    run_moving_avg(&avg, 4)
    run_moving_avg(&avg, 2)
    run_moving_avg(&avg, 1)
    run_moving_avg(&avg, 8)
    r := run_moving_avg(&avg, 2)

    testing.expect_value(t, r, 3.4)

    // ( 8 + 2 + 3 + 3 + 7)  / 5
    run_moving_avg(&avg, 3)
    run_moving_avg(&avg, 3)
    r = run_moving_avg(&avg, 7)

    testing.expect_value(t, r, 4.6)

}
