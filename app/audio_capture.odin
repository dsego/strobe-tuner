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
strobe_ringbuffer: pa_rb.RingBuffer
strobe_ringbuffer_data: []u8


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
        device_name := pa.GetDeviceInfo(i).name
        str := "  %v  ‣  %s\n"
        // if device_name == "BlackHole 2ch" {
        if device_name == "MacBook Pro Microphone" {
            str = "  %v [‣] %s\n"
            active_device = i
        }
        fmt.printf(str, i, device_name)
    }


    interleaved_bytes := size_of(f32) * STROBE_COUNT
    strobe_ringbuffer_data = make([]u8, DEFAULT_RB_SIZE * interleaved_bytes)
    pa_rb.InitializeRingBuffer(&strobe_ringbuffer, i32(interleaved_bytes), DEFAULT_RB_SIZE, raw_data(strobe_ringbuffer_data))

    pitch_ringbuffer_data = make([]u8, DEFAULT_RB_SIZE * size_of(f32))
    pa_rb.InitializeRingBuffer(&pitch_ringbuffer, i32(interleaved_bytes), DEFAULT_RB_SIZE, raw_data(pitch_ringbuffer_data))

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

    delete(strobe_ringbuffer_data)
    delete(pitch_ringbuffer_data)
}


@(private)
stream_callback :: proc "c" (
    input : rawptr,
    output : rawptr,
    frameCount : c.ulong,
    timeInfo : ^pa.StreamCallbackTimeInfo,
    statusFlags : pa.StreamCallbackFlags,
    userData : rawptr,
) -> int {
    process_ringbuffer(&strobe_ringbuffer , input, frameCount)
    process_ringbuffer(&pitch_ringbuffer , input, frameCount)
    return 0
    // write_to_ringbuffer(&pitch_ringbuffer, device, output, input, frame_count)
}


@(private)
process_ringbuffer :: proc "c" (
    rb_ptr: ^pa_rb.RingBuffer,
    input: rawptr,
    frame_count: c.ulong
) {
    context = runtime.default_context()

    input_slice: []f32 = slice.from_ptr(cast([^]f32) input, int(frame_count))

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
        &size2
    )

    // fmt.println("num written", num_written, size1, size2)

    // store interleaved samples for each strobe
    write_to_rb_region(region1, size1, input_slice)

    if size2 > 0 {
        write_to_rb_region(region2, size2, input_slice[size1:])
    }

    pa_rb.AdvanceRingBufferWriteIndex(rb_ptr, num_written)
}


@(private)
write_to_rb_region :: proc(region: rawptr, size: i32, input_slice: []f32) {
    // store interleaved samples for each strobe
    out_slice: []f32 = slice.from_ptr(cast([^]f32) region, int(size * STROBE_COUNT))
    for i in 0..<size {
        for s in 0..<i32(STROBE_COUNT) {
            out_slice[i+s] = run_strobe(&strobes[s], input_slice[i])
        }
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
    channel_count: u32,
) -> u32 {
    data_ptr : rawptr
    total_frames_read : u32 = 0

    element_count := frame_count * channel_count
    assert(len(samples) >= int(element_count))

    num_read := pa_rb.ReadRingBuffer(rb_ptr, raw_data(samples), i32(element_count))
    return u32(num_read)
}



check :: proc(err: pa.Error) -> bool {
    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: %s", pa.GetErrorText(err))
        return true
    }
    return false
}
