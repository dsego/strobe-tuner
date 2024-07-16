package app

import "core:math"
import "core:fmt"
import "core:testing"

import pa_rb "../pa_ringbuffer"

EPS := 0.000001


// TODO: make this a state object {
frame_counter_real := 0.0
overlap_sample := 0.0
// }



reset_framerate :: proc() {
    frame_counter_real = 0.0
    overlap_sample = 0.0
}


read_samples :: proc(rb_ptr: ^pa_rb.RingBuffer, samples: []f32, target_interval: f64) -> (u32, f64) {
/*
    Example:

                      【         target interval = 7.xx      】↱ fractional part
    +-------------------------------------------------------------------------------+
    |    |    |    |    |    |    |    |    |    |    |    |    |    |    |    |    |
    +-------------------------------------------------------------------------------+
                     ↑ 【                                       】
     samples      1 overlap         samples to read = 8              extra samples
     skipped       sample

*/
    frames_available := frames_available_in_ringbuffer(rb_ptr)

    frames_to_read, frames_to_skip, fractional_part := calculate_framerate(
        u32(frames_available),
        target_interval,
        &frame_counter_real
    )

    if frames_to_read > 0 && frames_to_skip == 0 {
        // Capturing the next adjacent period, keep the overlap sample for interpolation
        if frames_to_read > u32(math.trunc(target_interval)) {
            read_ringbuffer(rb_ptr, samples[:], frames_to_read, STROBE_COUNT)
        } else {
            samples[0] = f32(overlap_sample)
            read_ringbuffer(rb_ptr, samples[1:], frames_to_read, STROBE_COUNT)
        }
    } else {
        // Next period to read not adjacent, skip a number of intervals and read an entire interval of samples
        advance_ringbuffer(rb_ptr, i32(frames_to_skip)) // skip old samples to pick up slack and catch up with the writer
        read_ringbuffer(rb_ptr, samples, frames_to_read, STROBE_COUNT)
    }

    count := u32(math.ceil(target_interval))

    if frames_to_read > 0 {
        overlap_sample = f64(samples[count-1])
    }

    // correct for sub-sample drift
    return count, fractional_part
}


@(private="file")
calculate_framerate :: proc(
    frames_available: u32,
    target_interval: f64,
    frame_counter_real: ^f64, // this is our "reading head" that moves to the end of the interval
) -> (u32, u32, f64) {
/*
    Skip over N intervals and read one full interval to keep the reading rate consistent.
    The target interval can be non-integer size, there are 3 cases to cover:
        1. Not enough new frames available to consume the target interval.
        2. There is a one-sample overlap with the previous interval.
        3. Skip a number of intervals to pick up the slack and read only the latest interval.

    Overlap frame happens whenever the number of samples is not a whole number
*/
    frames_to_read := u32(0)
    frames_to_skip := u32(0)
    next_frame_counter_real := frame_counter_real^

    // case 1. not enough new frames
    if f64(frames_available) < frame_counter_real^ + target_interval {
        return frames_to_read, frames_to_skip, math.ceil(frame_counter_real^) - frame_counter_real^

    // case 2. there is overlap with the previous interval (if there is a previous frame)
    } else if f64(frames_available) - frame_counter_real^ - target_interval < target_interval {

        // 7.2 + 7.2 = 14.4 -> 15 frames, 8 + 7 -> .2 + 7.2 = 7.4  ~ 7 new samples to read
        // 7.8 + 7.8 = 15.6 -> 16 frames, 8 + 8 -> .8 + 7.8 = 8.6  ~ 8 new samples to read
        if frame_counter_real^ > EPS {
            frames_to_read = u32(math.trunc(frame_counter_real^ + target_interval))
        } else {
            // no overlap sample stored yet, read the number of samples rounded up
            frames_to_read = u32(math.ceil(target_interval))
        }
        frames_to_skip = u32(0)
        next_frame_counter_real += target_interval

    // case 3. we can skip a few intervals and read the most recent interval
    } else {
        interval_count := math.trunc(f64(frames_available) / target_interval)
        next_frame_counter_real = frame_counter_real^ + target_interval * interval_count
        frames_to_read = u32(math.ceil(target_interval))
        frames_to_skip = u32(math.ceil(next_frame_counter_real)) - frames_to_read - u32(math.ceil(frame_counter_real^))
    }

    fractional_part := math.ceil(next_frame_counter_real) - next_frame_counter_real

    // reset counter to just the fractional part to prevent it from growing endlessly and rolling over
    frame_counter_real^ = next_frame_counter_real - math.trunc(next_frame_counter_real)


    return frames_to_read, frames_to_skip, fractional_part
}



/* Spreadsheet
  https://docs.google.com/spreadsheets/d/1_o23-ur2s9EVfnyznhk1twtaAVEvpiY1cWs-0mvSFAc/edit

  Frame count real  Interval        Frame count     Frames to read  Drift (move left)  Has Overlap?
    35.28               35.28           36              36              0.72             True
    70.56               35.28           71              35              0.44             True
    105.84              35.28           106             35              0.16             True
    141.12              35.28           142             36              0.88             True
    176.40              35.28           177             35              0.60             True
    211.68              35.28           212             35              0.32             True
    246.96              35.28           247             35              0.04             True
    282.24              35.28           283             36              0.76             True
    317.52              35.28           318             35              0.48             True
    352.80              35.28           353             35              0.20             True
    388.08              35.28           389             36              0.92             True
    423.36              35.28           424             35              0.64             True
    458.64              35.28           459             35              0.36             True
    493.92              35.28           494             35              0.08             True
    529.20              35.28           530             36              0.80             True
    564.48              35.28           565             35              0.52             True
    599.76              35.28           600             35              0.24             True
    ...
    ...
    811.44              35.28           812             35              0.56             True
    846.72              35.28           847             35              0.28             True
    882.00              35.28           882             35              0.00             FALSE
    917.28              35.28           918             36              0.72             True


*/

@(test)
test_calculate_framerate :: proc(t: ^testing.T) {
    {
        frame_counter_real := 0.0
        read, skip, drift := calculate_framerate(100, 35.28, &frame_counter_real)
        expected_counter_real := 0.56
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 35)
        testing.expect_value(t, read, 36)
    }


    // start 317.52, expected to end up at 599.76 (600)
    // 318 + 246 + 36
    // -------------------------------------------------
    //     317.52      318         0.52          1
    //     352.80                 35.8
    //     388.08                 71.08
    //     423.36                106.36
    //     458.64                141.64
    //     493.92                176.92
    //     529.20                212.2
    //     564.48                247.48
    //     599.76     600        282.76         283
    //
    //     600 - 318 = 282
    //     599.76 - 317.52 = 282.24
    //
    //     283 - 1   - 282
    //     282.76 - 0.52 = 282.24
    {
        frame_counter_real := 0.52
        read, skip, drift := calculate_framerate(300, 35.28, &frame_counter_real)
        expected_counter_real := 0.76
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 246)
        testing.expect_value(t, read, 36)
    }

    // 35.28 + 35.28 = 70.56
    //  81 samples, 36 + 35
    {
        frame_counter_real := 0.28
        read, skip, drift := calculate_framerate(40, 35.28, &frame_counter_real)
        expected_counter_real := 0.56
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 0)
        testing.expect_value(t, read, 35)
    }

    // reading the first period
    {
        frame_counter_real := 0.0
        read, skip, drift := calculate_framerate(40, 35.28, &frame_counter_real)
        expected_counter_real := 0.28
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 0)
        testing.expect_value(t, read, 36)
    }


    // Frame count real        Frame count    Frames to read  Drift (move left)   Has overlap
    //      10.50       10.5        11         11              0.50                TRUE
    //      21.00       10.5        21         10              0.00                FALSE
    //      31.50       10.5        32         11              0.50                TRUE
    //      42.00       10.5        42         10              0.00                FALSE
    //      52.50       10.5        53         11              0.50                TRUE
    //      63.00       10.5        63         10              0.00                FALSE
    //      73.50       10.5        74         11              0.50                TRUE
    //      84.00       10.5        84         10              0.00                FALSE
    //      94.50       10.5        95         11              0.50                TRUE
    //      105.00      10.5        105        10              0.00                FALSE
    {
        frame_counter_real := 0.0
        read, skip, drift := calculate_framerate(80, 10.5, &frame_counter_real)
        expected_counter_real := 0.5
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 63)
        testing.expect_value(t, read, 11)
    }

    // 7.20    7.2 8   8   0.80    TRUE
    // 14.40   7.2 15  7   0.60    FALSE
    // 21.60   7.2 22  7   0.40    FALSE
    // 28.80   7.2 29  7   0.20    FALSE
    // 36.00   7.2 36  7   0.00    FALSE
    // 43.20   7.2 44  8   0.80    TRUE
    // 50.40   7.2 51  7   0.60    FALSE
    {
        frame_counter_real := 0.0
        read, skip, drift := calculate_framerate(40, 7.2, &frame_counter_real)
        expected_counter_real := 0.0
        expected_drift := 0.0
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 28)
        testing.expect_value(t, read, 8)
    }
    {
        frame_counter_real := 0.0
        read, skip, drift := calculate_framerate(10, 7.2, &frame_counter_real)
        expected_counter_real := 0.2
        expected_drift := 0.8
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 0)
        testing.expect_value(t, read, 8)
    }
    {
        frame_counter_real := 0.6
        read, skip, drift := calculate_framerate(10, 7.2, &frame_counter_real)
        expected_counter_real := 0.8
        expected_drift := 0.2
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 0)
        testing.expect_value(t, read, 7)
    }

    // 35.8 + 35.8
    {
        frame_counter_real := 0.8
        read, skip, drift := calculate_framerate(40, 35.8, &frame_counter_real)
        expected_counter_real := 0.6
        expected_drift := 0.4
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 0)
        testing.expect_value(t, read, 36)
    }

    // 0 5619.0683061733916 267.57468124635199 5733
    {
        frame_counter_real := 0.0
        read, skip, drift := calculate_framerate(5733, 267.57468124635199, &frame_counter_real)
        expected_counter_real := 0.0683061733916
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 5352)
        testing.expect_value(t, read, 268)
    }

    // 0.93898083777560259 536.08834333047957 267.57468124635199 646
    {
        frame_counter_real := 0.93898083777560259
        read, skip, drift := calculate_framerate(646, 267.57468124635199, &frame_counter_real)
        expected_counter_real := 0.08834333047957
        expected_drift := 1.0 - expected_counter_real
        testing.expect(t, math.abs(expected_drift - drift) < EPS, fmt.tprintf("expected %v, got %v", expected_drift, drift))
        testing.expect(t, math.abs(expected_counter_real - frame_counter_real) < EPS, fmt.tprintf("expected %v, got %v", expected_counter_real, frame_counter_real))
        testing.expect_value(t, skip, 268)
        testing.expect_value(t, read, 268)
    }
}
