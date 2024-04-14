package app

import "core:fmt"
import "core:math"
import "core:runtime"
import ma "vendor:miniaudio"


AudioCapture :: struct {
    device_config: ma.device_config,
    device: ma.device,
    ringbuffers: [dynamic]ma.pcm_rb,
    ctx: ma.context_type,
    capture_devices: [^]ma.device_info,
    capture_device_count: u32,
}


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
    output,
    input: rawptr,
    frame_count: u32
) {
    config := (cast(^AudioCapture) device.pUserData)^
    for _, i in config.ringbuffers {
        write_to_ringbuffer(&config.ringbuffers[i], device, output, input, frame_count)
    }
}

@(private)
write_to_ringbuffer :: proc "c" (
    ringbuffer_pt: ^ma.pcm_rb,
    device: ^ma.device,
    output,
    input: rawptr,
    frame_count: u32
) {
    data_ptr : rawptr
    frames_left := frame_count

    // Capture samples and write to a ring buffer.
    for {
        frames_to_write := frames_left

        if ma.pcm_rb_acquire_write(ringbuffer_pt, &frames_to_write, &data_ptr) != ma.result.SUCCESS {
            ma.log_post(
                ma.device_get_log(device),
                u32(ma.log_level.LOG_LEVEL_ERROR),
                "Failed to acquire capture PCM frames from ring buffer."
            )
            break
        }

        if frames_to_write == 0 {
            if ma.pcm_rb_pointer_distance(ringbuffer_pt) == i32(ma.pcm_rb_get_subbuffer_size(ringbuffer_pt)) {
                break // Overrun
            }
        }

        ma.copy_pcm_frames(data_ptr, input, u64(frames_to_write), ma.format.f32, 1)

        if ma.pcm_rb_commit_write(ringbuffer_pt, frames_to_write, data_ptr) != ma.result.SUCCESS {
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

init_audio_capture :: proc(samplerate: u32 = 44100) -> (config: ^AudioCapture, ok: bool) {
    config = new(AudioCapture)

    config.device_config = ma.device_config_init(ma.device_type.capture)
    config.device_config.dataCallback = audio_capture_callback
    config.device_config.notificationCallback = notification_callback
    config.device_config.capture.format = ma.format.f32
    config.device_config.sampleRate = samplerate
    config.device_config.capture.channels = 1
    config.device_config.pUserData = config

    if ma.context_init(nil, 0, nil, &config.ctx) != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio context.")
        return {}, false
    }

    if ma.context_get_devices(
        &config.ctx,
        nil,
        nil,
        &config.capture_devices,
        &config.capture_device_count
    ) != ma.result.SUCCESS {
        ma.context_uninit(&config.ctx)
        fmt.println("Failed to retrieve device information.")
        return {}, false
    }

    if ma.device_init(
        &config.ctx,
        &config.device_config,
        &config.device
    ) != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio device.")
        ma.context_uninit(&config.ctx)
        return {}, false
    }

    fmt.println("\n..................................")
    fmt.println(" Audio capture devices:")
    for i := u32(0); i < config.capture_device_count; i += 1 {
        if config.device.capture.id == config.capture_devices[i].id {
            fmt.printf("  ‣ [ %v %s ]\n", i, config.capture_devices[i].name)
        } else {
            fmt.printf("      %v %s\n", i, config.capture_devices[i].name)
        }
    }
    fmt.println("..................................\n")

    // Set up logging
    ma.log_register_callback(ma.device_get_log(&config.device), ma.log_callback_init(log_callback, nil))

    if ma.device_start(&config.device) != ma.result.SUCCESS {
        ma.device_uninit(&config.device)
        fmt.println("Failed to start audio device.")
        return {}, false
    }

    return config, true
}

destroy_audio_capture :: proc(config: ^AudioCapture) {
    ma.device_stop(&config.device)
    ma.device_uninit(&config.device)
    ma.context_uninit(&config.ctx)

    for _, i in config.ringbuffers {
        rb := config.ringbuffers[i]
        ma.pcm_rb_uninit(&rb)
    }

    clear(&config.ringbuffers)
    free(config)
}

add_ringbuffer :: proc(config: ^AudioCapture, size: u32 = 96000) -> int {
    rb: ma.pcm_rb
    if ma.pcm_rb_init(ma.format.f32, 1, size, nil, nil, &rb) != ma.result.SUCCESS {
        fmt.println("Failed to initialize ring buffer.")
        return -1
    }
    append(&config.ringbuffers, rb)

    ringbuffer_id := len(config.ringbuffers) - 1
    return ringbuffer_id
}


advance_ringbuffer :: proc (
    config: ^AudioCapture,
    ringbuffer_id: int,
    frames_to_skip: u32,
) {
    rb : = config.ringbuffers[ringbuffer_id]
    ma.pcm_rb_seek_read(&rb, frames_to_skip)
}

read_ringbuffer :: proc(
    config: ^AudioCapture,
    ringbuffer_id: int,
    samples: []f32,
    frame_count: u32
) {
    rb : = config.ringbuffers[ringbuffer_id]
    data_ptr : rawptr
    frames_left := frame_count

    // The ring buffer can return fewer frames than requested if the position is near the end of the buffer.
    // We want to loop until we get all the needed frames.
    for {
        frames_to_read := frames_left
        if ma.pcm_rb_acquire_read(&rb, &frames_to_read, &data_ptr) != ma.result.SUCCESS {
            fmt.println("Failed to acquire read pointer from ring buffer.")
            break
        }

        data := cast([^]f32) data_ptr
        for i in 0..<frames_to_read {
            samples[frames_left-i-1] = data[i]
        }

        if ma.pcm_rb_commit_read(&rb, frames_to_read, data_ptr) != ma.result.SUCCESS {
            fmt.println("Failed to commit read on ring buffer.")
            break
        }

        frames_left -= frames_to_read
        if frames_left <= 0 do break
    }
}
