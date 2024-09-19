package app

import "core:fmt"

import pa_rb "../pa_ringbuffer"


RingBuffer :: pa_rb.RingBuffer


init_ringbuffer :: proc(size: int) -> (RingBuffer, []u8) {
    rb := RingBuffer{}
    rb_data := make([]u8, size * size_of(f32))
    pa_rb.InitializeRingBuffer(&rb, i32(size_of(f32)), i32(size), raw_data(rb_data))
    return rb, rb_data
}

advance_ringbuffer :: proc (rb_ptr: ^RingBuffer, frames_to_skip: i32) -> i32 {
    return pa_rb.AdvanceRingBufferReadIndex(rb_ptr, frames_to_skip)
}

frames_available_in_ringbuffer:: proc (rb_ptr: ^RingBuffer) -> i32 {
    return pa_rb.GetRingBufferReadAvailable(rb_ptr)
}

flush_ringbuffer:: proc (rb_ptr: ^RingBuffer) {
    pa_rb.FlushRingBuffer(rb_ptr)
}

write_to_ringbuffer :: proc (rb_ptr: ^RingBuffer, input: []f32) {
    pa_rb.WriteRingBuffer(rb_ptr, raw_data(input), i32(len(input)))
}


read_ringbuffer :: proc(
    rb_ptr: ^RingBuffer,
    samples: []f32,
    frame_count: u32,
) -> u32 {
    data_ptr : rawptr
    total_frames_read : u32 = 0

    assert(len(samples) >= int(frame_count), fmt.aprintf("frame_count %v larger than samples size %v", frame_count, len(samples)))

    num_read := pa_rb.ReadRingBuffer(rb_ptr, raw_data(samples), i32(frame_count))
    return u32(num_read)
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
