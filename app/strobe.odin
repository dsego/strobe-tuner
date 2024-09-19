package app

import "core:math"
import "core:fmt"


// StrobeConfig :: struct {
//     biquad: Biquad,
//     strobe_ringbuffers: pa_rb.RingBuffer,
//     strobe_ringbuffer_data: []u8,
//     framerate_state: FramerateState,
// }


// for i in 0..<STROBE_COUNT {
//     strobe_ringbuffer_data[i] = make([]u8, DEFAULT_RB_SIZE * size_of(f32))
//     pa_rb.InitializeRingBuffer(&strobe_ringbuffers[i], size_of(f32), DEFAULT_RB_SIZE, raw_data(strobe_ringbuffer_data[i]))
// }


// for i in 0..<STROBE_COUNT do delete(strobe_ringbuffer_data[i])



// init_strobe :: proc (freq_hz: f64, samplerate: f64) -> (self: Strobe) {
//     cents := freq_to_cents(freq_hz)
//     bandwidth_hz := cents_to_freq(cents + 50) - cents_to_freq(cents - 50)
//     norm_freq := freq_hz / samplerate
//     norm_bandwidth := bandwidth_hz / samplerate
//     self.biquad = biquad_resonator(norm_freq, norm_bandwidth)
//     return
// }

// destroy_strobe :: proc() {

// }


// process_strobes :: proc (self: ^Strobe, in_sample: []f32, out_samples: []f32)  {
//     // return sample * 100.0
//     return 100.0 * biquad_process_sample(&self.biquad, sample)
// }



// @(private)
// process_strobe_ringbuffers :: proc "c" (
//     strobe_idx: int,
//     input: rawptr,
//     frame_count: c.ulong
// ) {
//     context = runtime.default_context()
//     input_slice: []f32 = slice.from_ptr(cast([^]f32) input, int(frame_count))

//     // ringbuffer write regions
//     region1: rawptr
//     size1: i32
//     region2: rawptr
//     size2: i32

//     num_written := pa_rb.GetRingBufferWriteRegions(
//         &strobe_ringbuffers[strobe_idx],
//         i32(frame_count),
//         &region1,
//         &size1,
//         &region2,
//         &size2
//     )

//     write_to_rb_region(region1, size1, input_slice, strobe_idx)

//     if size2 > 0 {
//         write_to_rb_region(region2, size2, input_slice[size1:], strobe_idx)
//     }

//     pa_rb.AdvanceRingBufferWriteIndex(&strobe_ringbuffers[strobe_idx], num_written)

// }

// @(private)
// write_to_rb_region :: proc(region: rawptr, element_count: i32, input_slice: []f32, strobe_idx: int) {
//     out_slice: []f32 = slice.from_ptr(cast([^]f32) region, int(element_count))
//     process_strobe(&strobes[strobe_idx], in_slice, out_slice)
// }
