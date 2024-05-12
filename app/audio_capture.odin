package app

import "core:fmt"
import "core:math"
import "core:mem"
import "core:c"
import "core:slice"
import "core:runtime"


import pa "../odin-portaudio"
import pa_rb "../pa_ringbuffer"


// 4-channel ring buffer for strobe data
strobe_ringbuffer: pa_rb.RingBuffer
strobe_ringbuffer_data: []u8
stream: ^pa.Stream
err: pa.Error



init_audio_capture :: proc(samplerate: u32 = 44100) -> (ok: bool) {

    strobe_ringbuffer_data = make([]u8, DEFAULT_RB_SIZE * size_of(f32) * STROBE_COUNT)
    pa_rb.InitializeRingBuffer(&strobe_ringbuffer, size_of(f32) * STROBE_COUNT, DEFAULT_RB_SIZE, raw_data(strobe_ringbuffer_data))

    err = pa.Initialize()
    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: %s", pa.GetErrorText(err))
        return false
    }

    err = pa.OpenDefaultStream(
        stream=&stream,
        numInputChannels=1,
        numOutputChannels=0,
        sampleFormat=pa.Float32,
        sampleRate=f64(samplerate),
        framesPerBuffer=pa.FramesPerBufferUnspecified,
        streamCallback=stream_callback,
        userData=nil,
    )

    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: %s", pa.GetErrorText(err))
        return false
    }


    return true
}


destroy_audio_capture :: proc() {
    err = pa.CloseStream(stream)
    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: %s", pa.GetErrorText(err))
        return
    }

    err = pa.Terminate()
    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: %s", pa.GetErrorText(err))
        return
    }

    delete(strobe_ringbuffer_data)
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

    return 0
    // write_to_ringbuffer(&pitch_ringbuffer, device, output, input, frame_count)
    // process_strobe_ringbuffer(device, output, input, frame_count)
}

