package core


import "core:math"
import "core:fmt"
import "core:testing"


MAX_BLOCK_SIZE :: 512


SmoothBlock :: struct {
    block: [MAX_BLOCK_SIZE]f32,
    size: int,
}

init_smooth_block :: proc(size: int) -> SmoothBlock {
    assert(size <= MAX_BLOCK_SIZE)
    self := SmoothBlock{}
    self.size = size
    return self
}

add_measurement :: proc (self: ^SmoothBlock, value: f32) {
    for i in 0..<self.size - 1 {
        self.block[i+1] = self.block[i]
    }
    self.block[0] = value
}


get_smoothed_value :: proc (self: ^SmoothBlock) -> f32 {
    return smooth_impulsive_noise(self.block[:self.size])
}



// Impulsive-noise smoothing algorithm, Lyons book, page 770
// TODO  maybe it can be optimized to cache values between invocations?
@(private="file")
smooth_impulsive_noise :: proc (block: []f32) -> f32 {
    // obtain arithmetic mean
    sum: f32 = 0.0
    for value in block do sum += value

    n := f32(len(block))
    mean := sum / n

    // find the correction term
    pos := 0 // count of values greater than mean
    neg := 0 // count of values less than mean
    dev: f32 = 0.0 // sum of deviations from the mean (only positive or negative)

    for value, i in block {
        if value < mean {
            neg += 1
            dev += (mean - value)
        } else if value > mean {
            pos += 1
        }
    }

    n_squared := n * n
    corrected_mean := mean + (f32(pos) - f32(neg)) * math.abs(dev) / n_squared
    return corrected_mean
}


@(test)
test_smooth_impulsive_noise :: proc(t: ^testing.T) {
    data: []f32 = {10, 10, 11, 9, 10, 10, 13, 10, 10, 10}
    result := smooth_impulsive_noise(data)
    testing.expect_value(t, result, 10.096)
}
