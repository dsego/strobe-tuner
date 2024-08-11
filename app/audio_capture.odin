package app

import "core:fmt"
import "core:math"
import "core:mem"
import "core:c"
import "core:slice"
import "base:runtime"


import pa "../odin-portaudio"
import pa_rb "../pa_ringbuffer"


// 4-channel ring buffer for strobe data
strobe_ringbuffers: [STROBE_COUNT]pa_rb.RingBuffer
strobe_ringbuffer_data: [STROBE_COUNT][]u8


pitch_ringbuffer: pa_rb.RingBuffer
pitch_ringbuffer_data: []u8

stream: ^pa.Stream
err: pa.Error


active_device: i32 = -1


init_audio_capture :: proc(samplerate: u32 = 44100) -> (ok: bool) {
    err = pa.Initialize()
    if check(err) do return false

    fmt.println("Initialized PortAudio")

    device_count := pa.GetDeviceCount()

    for i in 0..<device_count {
        info := pa.GetDeviceInfo(i)
        str := "  %v  ‣  %s (%v ch)\n"
        // if info.name == "BlackHole 2ch" {
        if info.name == "MacBook Pro Microphone" {
            str = "  %v [‣] %s (%v ch)\n"
            active_device = i
        }
        fmt.printf(str, i, info.name, info.maxInputChannels)
    }

    for i in 0..<STROBE_COUNT {
        strobe_ringbuffer_data[i] = make([]u8, DEFAULT_RB_SIZE * size_of(f32))
        pa_rb.InitializeRingBuffer(&strobe_ringbuffers[i], size_of(f32), DEFAULT_RB_SIZE, raw_data(strobe_ringbuffer_data[i]))
    }

    pitch_ringbuffer_data = make([]u8, DEFAULT_RB_SIZE * size_of(f32))
    pa_rb.InitializeRingBuffer(&pitch_ringbuffer, i32(size_of(f32)), DEFAULT_RB_SIZE, raw_data(pitch_ringbuffer_data))

    // err = pa.OpenDefaultStream(
    //     stream=&stream,
    //     numInputChannels=1,
    //     numOutputChannels=0,
    //     sampleFormat=pa.Float32,
    //     sampleRate=f64(samplerate),
    //     framesPerBuffer=pa.FramesPerBufferUnspecified,
    //     streamCallback=stream_callback,
    //     userData=nil,
    // )

    stream_params := pa.StreamParameters {
        device=active_device,
        channelCount=1,
        sampleFormat=pa.Float32,
        suggestedLatency=pa.GetDeviceInfo(active_device).defaultLowInputLatency,
        hostApiSpecificStreamInfo=nil,
    }

    err = pa.OpenStream(
        stream=&stream,
        inputParameters=&stream_params,
        outputParameters=nil,
        sampleRate=f64(samplerate),
        framesPerBuffer=pa.FramesPerBufferUnspecified,
        streamFlags=0,
        streamCallback=stream_callback,
        userData=nil,
    )

    if check(err) do return false

    fmt.println("Opened input stream")

    err = pa.StartStream(stream)
    if check(err) do return false

    fmt.println("Started input stream")

    return true
}


destroy_audio_capture :: proc() {
    err = pa.AbortStream(stream)
    check(err)
    fmt.println("Stopped input stream")

    err = pa.CloseStream(stream)
    check(err)

    fmt.println("Closed input stream")

    err = pa.Terminate()
    check(err)

    fmt.println("Terminated PortAudio")

    for i in 0..<STROBE_COUNT do delete(strobe_ringbuffer_data[i])
    delete(pitch_ringbuffer_data)
}


@(private)
stream_callback :: proc "c" (
    input: rawptr,
    output: rawptr,
    frameCount: c.ulong,
    timeInfo: ^pa.StreamCallbackTimeInfo,
    statusFlags: pa.StreamCallbackFlags,
    userData: rawptr,
) -> int {
    // context = runtime.default_context()
    process_strobe_ringbuffers(input, frameCount)

    pa_rb.WriteRingBuffer(&pitch_ringbuffer, input, i32(frameCount))
    return 0
}


@(private)
process_strobe_ringbuffers :: proc "c" (
    input: rawptr,
    frame_count: c.ulong
) {
    context = runtime.default_context()
    input_slice: []f32 = slice.from_ptr(cast([^]f32) input, int(frame_count))

    for i in 0..<STROBE_COUNT {
        // ringbuffer write regions
        region1: rawptr
        size1: i32
        region2: rawptr
        size2: i32

        num_written := pa_rb.GetRingBufferWriteRegions(
            &strobe_ringbuffers[i],
            i32(frame_count),
            &region1,
            &size1,
            &region2,
            &size2
        )

        // store interleaved samples for each strobe
        write_to_rb_region(region1, size1, input_slice, i)

        if size2 > 0 {
            write_to_rb_region(region2, size2, input_slice[size1:], i)
        }

        pa_rb.AdvanceRingBufferWriteIndex(&strobe_ringbuffers[i], num_written)
    }
}


@(private)
write_to_rb_region :: proc(region: rawptr, element_count: i32, input_slice: []f32, strobe_idx: int) {
    out_slice: []f32 = slice.from_ptr(cast([^]f32) region, int(element_count))
    for i in 0..<element_count {
        out_slice[i] = run_strobe(&strobes[strobe_idx], input_slice[i])
    }
}

advance_ringbuffer :: proc (rb_ptr: ^pa_rb.RingBuffer, frames_to_skip: i32) -> i32 {
    return pa_rb.AdvanceRingBufferReadIndex(rb_ptr, frames_to_skip)
}

frames_available_in_ringbuffer:: proc (rb_ptr: ^pa_rb.RingBuffer) -> i32 {
    return pa_rb.GetRingBufferReadAvailable(rb_ptr)
}

read_ringbuffer :: proc(
    rb_ptr: ^pa_rb.RingBuffer,
    samples: []f32,
    frame_count: u32,
) -> u32 {
    data_ptr : rawptr
    total_frames_read : u32 = 0

    assert(len(samples) >= int(frame_count))

    num_read := pa_rb.ReadRingBuffer(rb_ptr, raw_data(samples), i32(frame_count))
    return u32(num_read)
}

// read_interleaved_ringbuffer :: proc(
//     rb_ptr: ^pa_rb.RingBuffer,
//     samples: []InterleavedSamples,
//     element_count: u32,
// ) -> u32 {
//     data_ptr : rawptr
//     total_frames_read : u32 = 0

//     assert(len(samples) >= int(element_count))

//     num_read := pa_rb.ReadRingBuffer(rb_ptr, raw_data(samples), i32(element_count))
//     return u32(num_read)
// }


check :: proc(err: pa.Error) -> bool {
    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: %s", pa.GetErrorText(err))
        return true
    }
    return false
}
