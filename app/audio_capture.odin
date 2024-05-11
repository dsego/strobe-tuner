package app

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:runtime"
import ma "vendor:miniaudio"


device_config: ma.device_config
device: ma.device
ctx: ma.context_type
capture_devices: [^]ma.device_info
capture_device_count: u32


// 4-channel ring buffer for strobe data
strobe_ringbuffer: Ringbuffer

// 1-channel ring buffer for pitch detection
pitch_ringbuffer: Ringbuffer


@(private)
log_callback :: proc "c" (pUserData: rawptr, level: u32, pMessage: cstring) {
    context = runtime.default_context()
    // switch level {
    // case ma.log_level.LOG_LEVEL_DEBUG:
    // case ma.log_level.LOG_LEVEL_INFO:
    // case ma.log_level.LOG_LEVEL_WARNING:
    // case ma.log_level.LOG_LEVEL_ERROR:
    // case: // Ignore everything else
    // }

    fmt.println(pMessage)
}

@(private)
notification_callback :: proc "c" (pNotification: ^ma.device_notification) {
    // TODO
}

@(private)
audio_capture_callback :: proc "c" (
    device: ^ma.device,
    output: rawptr,
    input: rawptr,
    frame_count: u32
) {
    // write_to_ringbuffer(&pitch_ringbuffer, device, output, input, frame_count)
    process_strobe_ringbuffer(device, output, input, frame_count)
}

@(private)
write_to_ringbuffer :: proc "c" (
    rb: ^ma.pcm_rb,
    device: ^ma.device,
    output: rawptr,
    input: rawptr,
    frame_count: u32
) {
    data_ptr : rawptr
    frames_left := frame_count

    // context = runtime.default_context()

    // Capture samples and write to a ring buffer.
    for {
        frames_to_write := frames_left

        if ma.pcm_rb_acquire_write(rb, &frames_to_write, &data_ptr) != ma.result.SUCCESS {
            ma.log_post(
                ma.device_get_log(device),
                u32(ma.log_level.LOG_LEVEL_ERROR),
                "Failed to acquire capture PCM frames from ring buffer."
            )
            break
        }

        if frames_to_write == 0 {
            if ma.pcm_rb_pointer_distance(rb) == i32(ma.pcm_rb_get_subbuffer_size(rb)) {
                // fmt.println("OVERRUN")
                break // Overrun
            }
        }

        ma.copy_pcm_frames(data_ptr, input, u64(frames_to_write), ma.format.f32, 1)

        // fmt.println(frames_to_write)
        // data := (^f32)(input)

        // fmt.println(data^)

        if ma.pcm_rb_commit_write(rb, frames_to_write, data_ptr) != ma.result.SUCCESS {
            ma.log_post(
                ma.device_get_log(device),
                u32(ma.log_level.LOG_LEVEL_ERROR),
                "Failed to commit capture PCM frames to ring buffer."
            )
            break
        }

        frames_left -= frames_to_write
        if frames_left <= 0 do break
    }
}

@(private)
process_strobe_ringbuffer :: proc "c" (
    device: ^ma.device,
    output: rawptr,
    input: rawptr,
    frame_count: u32
) {
    context = runtime.default_context()

    data_ptr : rawptr
    frames_left := frame_count

    rb := &strobe_ringbuffer

    // Capture samples and write to a ring buffer.
    for {
        frames_to_write := frames_left

        if ma.pcm_rb_acquire_write(rb, &frames_to_write, &data_ptr) != ma.result.SUCCESS {
            ma.log_post(
                ma.device_get_log(device),
                u32(ma.log_level.LOG_LEVEL_ERROR),
                "Failed to acquire capture PCM frames from ring buffer."
            )
            break
        }

        if frames_to_write == 0 {
            if ma.pcm_rb_pointer_distance(rb) == i32(ma.pcm_rb_get_subbuffer_size(rb)) {
                // fmt.println("OVERRUN")
                break // Overrun
            }
        }

        data: []f32 = slice.from_ptr(cast([^]f32) data_ptr, int(frame_count * STROBE_COUNT))
        input_slice: []f32 = slice.from_ptr(cast([^]f32) input, int(frame_count))

        for i in 0..<frame_count {
            for s in 0..<u32(STROBE_COUNT) {
                //  run through iir biquad
                data[i+s] = run_strobe(&strobes[s], input_slice[i])
            }
        }

        // ma.copy_pcm_frames(data_ptr, input, u64(frames_to_write), ma.format.f32, 1)
        // fmt.println(frames_to_write)
        // data := (^f32)(input)

        // fmt.println(data^)

        if ma.pcm_rb_commit_write(rb, frames_to_write, data_ptr) != ma.result.SUCCESS {
            ma.log_post(
                ma.device_get_log(device),
                u32(ma.log_level.LOG_LEVEL_ERROR),
                "Failed to commit capture PCM frames to ring buffer."
            )
            break
        }

        frames_left -= frames_to_write
        if frames_left <= 0 do break
    }
}


init_audio_capture :: proc(samplerate: u32 = 44100) -> (ok: bool) {

    // Init ringbuffers
    pcm_rb_status := ma.pcm_rb_init(ma.format.f32, 1, DEFAULT_RB_SIZE, nil, nil, &pitch_ringbuffer)
    if pcm_rb_status != ma.result.SUCCESS {
        fmt.println("Failed to initialize ring buffer.")
        return false
    }

    pcm_rb_status = ma.pcm_rb_init(ma.format.f32, STROBE_COUNT, DEFAULT_RB_SIZE, nil, nil, &strobe_ringbuffer)
    if pcm_rb_status != ma.result.SUCCESS {
        fmt.println("Failed to initialize ring buffer.")
        return false
    }


    // Configure audio device info
    device_config = ma.device_config_init(ma.device_type.capture)
    device_config.dataCallback = audio_capture_callback
    device_config.notificationCallback = notification_callback
    device_config.capture.format = ma.format.f32
    device_config.sampleRate = samplerate
    device_config.capture.channels = 1
    // device_config.periodSizeInFrames = 1024



    if ma.context_init(nil, 0, nil, &ctx) != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio context.")
        return false
    }

    if ma.context_get_devices(
        &ctx,
        nil,
        nil,
        &capture_devices,
        &capture_device_count
    ) != ma.result.SUCCESS {
        ma.context_uninit(&ctx)
        fmt.println("Failed to retrieve device information.")
        return false
    }

    // set BlackHole 2ch device for capture
    device_config.capture.pDeviceID = &capture_devices[1].id

    if ma.device_init(
        &ctx,
        &device_config,
        &device
    ) != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio device.")
        ma.context_uninit(&ctx)
        return false
    }

    fmt.println("\n..................................")
    fmt.println(" Audio capture devices:")
    for i := u32(0); i < capture_device_count; i += 1 {
        if device.capture.id == capture_devices[i].id {
            fmt.printf("  ‣ [ %v %s ]\n", i, capture_devices[i].name)
        } else {
            fmt.printf("      %v %s\n", i, capture_devices[i].name)
        }
    }
    fmt.println("..................................\n")

    // Set up logging
    ma.log_register_callback(ma.device_get_log(&device), ma.log_callback_init(log_callback, nil))


    if ma.device_start(&device) != ma.result.SUCCESS {
        ma.device_uninit(&device)
        fmt.println("Failed to start audio device.")
        return false
    }

    return true
}

destroy_audio_capture :: proc() {
    ma.device_stop(&device)
    ma.device_uninit(&device)
    ma.context_uninit(&ctx)
    ma.pcm_rb_uninit(&pitch_ringbuffer)
    ma.pcm_rb_uninit(&strobe_ringbuffer)
}


advance_ringbuffer :: proc (
    ringbuffer: ^Ringbuffer,
    frames_to_skip: u32,
) {
    ma.pcm_rb_seek_read(ringbuffer, frames_to_skip)
}


frames_available_in_ringbuffer:: proc (ringbuffers: ^Ringbuffer) -> u32 {
    return ma.pcm_rb_available_read(ringbuffers)
}


read_ringbuffer :: proc(
    rb_ptr: ^Ringbuffer,
    samples: []f32,
    frame_count: u32
) -> u32 {
    data_ptr : rawptr
    total_frames_read : u32 = 0

    channel_count := ma.pcm_rb_get_channels(rb_ptr)
    assert(len(samples) >= int(channel_count * frame_count))

    // The ring buffer can return fewer frames than requested if the position is near the end of the buffer.
    // We want to loop until we get all the needed frames.
    for total_frames_read < frame_count {

        frames_to_read: u32 = frame_count - total_frames_read

        acquire_result := ma.pcm_rb_acquire_read(rb_ptr, &frames_to_read, &data_ptr)
        if acquire_result != ma.result.SUCCESS {
            fmt.println("Failed to acquire read pointer from ring buffer.", ma.result_description(acquire_result))
            break
        }

        if frames_to_read == 0 do break // end of ringbuffer

        offset := total_frames_read * channel_count

        ma.copy_pcm_frames(
            raw_data(samples[offset:]),
            data_ptr,
            u64(frames_to_read),
            ma.format.f32,
            channel_count,
        )

        commit_result := ma.pcm_rb_commit_read(rb_ptr, frames_to_read, data_ptr)

        // if ringbuffer at end we still want to continue trying to acquire read
        if commit_result != ma.result.SUCCESS && commit_result != ma.result.AT_END {
            fmt.println("Failed to commit read on ring buffer.", ma.result_description(commit_result))
            break
        }

        total_frames_read += frames_to_read
    }

    // need to return how many frames we managed to read in case the commit fails
    return total_frames_read
}



