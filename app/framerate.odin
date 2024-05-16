package app

import "core:math"
import "core:fmt"

import pa_rb "../pa_ringbuffer"


read_samples :: proc(rb_ptr: ^pa_rb.RingBuffer, samples: []f32, target_interval: f64) -> (u32, f64) {
    @(static) frame_counter_real := 0.0

    frames_available := frames_available_in_ringbuffer(rb_ptr)
    // fmt.println(frames_available)

    next_frame_count, frames_to_skip, frames_to_read := calculate_framerate(
        u32(frames_available),
        frame_counter_real,
        target_interval
    )

    // don't let the counter increase forever, we only need to keep the fractional part
    frame_counter_real = next_frame_count - math.floor(next_frame_count)

    // skip old samples to pick up slack and catch up with the writer
    if frames_to_skip > 0 do advance_ringbuffer(rb_ptr, i32(frames_to_skip))

    // consume one frequency interval of samples
    if frames_to_read > 0 do read_ringbuffer(rb_ptr, samples, frames_to_read, STROBE_COUNT)

    // correct for sub-sample drift
    drift := f64(1.0) - frame_counter_real

    return frames_to_read, drift
}


@(private="file")
calculate_framerate:: proc(
    frames_available: u32,
    frame_count: f64,
    target_interval: f64,
) -> (
    next_frame_count: f64,
    frames_to_skip,
    frames_to_read: u32)
{
    next_frame_count = frame_count

    frames_to_read = u32(0)
    frames_to_ingest := u32(0)
    prev_frames_ceil := u32(math.ceil(frame_count))

    // skip over N intervals and read one full interval to keep the reading rate consistent
    for frames_to_ingest < frames_available {
        prev_frame_count := next_frame_count
        next_frame_count += target_interval

        frames := u32(math.ceil(next_frame_count)) - u32(math.ceil(prev_frame_count))
        if frames_to_ingest + frames > frames_available {
            next_frame_count = prev_frame_count
            break
        }
        frames_to_read = frames
        frames_to_ingest += frames
    }

    frames_to_skip = frames_to_ingest - frames_to_read
    return
}
