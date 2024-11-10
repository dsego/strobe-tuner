package shared

import "base:runtime"
import "core:fmt"
import "core:slice"

import pa_rb "../pa_ringbuffer"


RingBuffer :: pa_rb.RingBuffer


init_ringbuffer :: proc "c" (size: int) -> (RingBuffer, []u8) {
    context = runtime.default_context()

    rb := RingBuffer{}
    rb_data := make([]u8, size * size_of(f32))
    pa_rb.InitializeRingBuffer(&rb, i32(size_of(f32)), i32(size), raw_data(rb_data))
    return rb, rb_data
}

advance_ringbuffer_read :: proc "c" (rb_ptr: ^RingBuffer, frames_to_skip: i32) -> i32 {
    return pa_rb.AdvanceRingBufferReadIndex(rb_ptr, frames_to_skip)
}

advance_ringbuffer_write :: proc "c" (rb_ptr: ^RingBuffer, frames_to_skip: i32) -> i32 {
    return pa_rb.AdvanceRingBufferWriteIndex(rb_ptr, frames_to_skip)
}

frames_available_in_ringbuffer :: proc "c" (rb_ptr: ^RingBuffer) -> i32 {
    return pa_rb.GetRingBufferReadAvailable(rb_ptr)
}

flush_ringbuffer :: proc "c" (rb_ptr: ^RingBuffer) {
    pa_rb.FlushRingBuffer(rb_ptr)
}

write_to_ringbuffer :: proc "c" (rb_ptr: ^RingBuffer, input: []f32) {
    pa_rb.WriteRingBuffer(rb_ptr, raw_data(input), i32(len(input)))
}


read_ringbuffer :: proc "c" (rb_ptr: ^RingBuffer, samples: []f32, frame_count: u32) -> u32 {
    context = runtime.default_context()

    data_ptr: rawptr
    total_frames_read: u32 = 0

    assert(
        len(samples) >= int(frame_count),
        fmt.aprintf("frame_count %v larger than samples size %v", frame_count, len(samples)),
    )

    num_read := pa_rb.ReadRingBuffer(rb_ptr, raw_data(samples), i32(frame_count))
    return u32(num_read)
}

get_ringbuffer_write_regions :: proc "c" (
    rb_ptr: ^RingBuffer,
    frame_count: int,
) -> (
    []f32,
    []f32,
    int,
) {
    // context = runtime.default_context()

    // ringbuffer write regions
    region1: rawptr
    size1: i32

    region2: rawptr
    size2: i32

    num_written := pa_rb.GetRingBufferWriteRegions(
        rb_ptr,
        i32(frame_count),
        &region1,
        &size1,
        &region2,
        &size2,
    )

    if size1 < 0 do size1 = 0
    if size2 < 0 do size2 = 0

    out1: []f32 = slice.from_ptr(cast([^]f32)region1, int(size1))
    out2: []f32 = slice.from_ptr(cast([^]f32)region2, int(size2))

    return out1, out2, int(num_written)
}


// read_interleaved_ringbuffer :: proc(
//     rb_ptr: ^RingBuffer,
//     samples: []InterleavedSamples,
//     element_count: u32,
// ) -> u32 {
//     data_ptr : rawptr
//     total_frames_read : u32 = 0

//     assert(len(samples) >= int(element_count))

//     num_read := pa_rb.ReadRingBuffer(rb_ptr, raw_data(samples), i32(element_count))
//     return u32(num_read)
// }
