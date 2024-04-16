package app

import "core:fmt"
import "core:math"
import "core:mem"
import "core:runtime"
import ma "vendor:miniaudio"


// Simplify by using a constant number of ringbuffers instead of a dynamic list.
MAX_RB_COUNT :: 2
DEFAULT_RB_SIZE :: 96000


device_config: ma.device_config
device: ma.device
ringbuffers: [MAX_RB_COUNT] ma.pcm_rb
ctx: ma.context_type
capture_devices: [^]ma.device_info
capture_device_count: u32



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
    for &rb in ringbuffers {
        write_to_ringbuffer(&rb, device, output, input, frame_count)
    }
    // write_to_ringbuffer(&rb, device, output, input, frame_count)
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

init_audio_capture :: proc(samplerate: u32 = 44100) -> (ok: bool) {
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
        // ma.context_uninit(&ctx)
        fmt.println("Failed to retrieve device information.")
        return false
    }

    // set BlackHole 2ch device for capture
    device_config.capture.pDeviceID = &capture_devices[2].id

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

    // Init ringbuffers
    for &rb in ringbuffers {
        if ma.pcm_rb_init(ma.format.f32, 1, DEFAULT_RB_SIZE, nil, nil, &rb) != ma.result.SUCCESS {
            fmt.println("Failed to initialize ring buffer.")
            return false
        }
    }


    return true
}

destroy_audio_capture :: proc() {
    ma.device_stop(&device)
    ma.device_uninit(&device)
    ma.context_uninit(&ctx)

    for &rb in ringbuffers {
        ma.pcm_rb_uninit(&rb)
    }
}

// rb: ma.pcm_rb

// NOTE: comment out for now, we can use a static list
// add_ringbuffer :: proc(config: ^AudioCapture, size: u32 = 96000) -> int {
//     // rb: ma.pcm_rb
//     if ma.pcm_rb_init(ma.format.f32, 1, size, nil, nil, &rb) != ma.result.SUCCESS {
//         fmt.println("Failed to initialize ring buffer.")
//         return -1
//     }
//     // append(&ringbuffers, rb)

//     ringbuffer_id := len(config.ringbuffers) - 1
//     return ringbuffer_id
// }


advance_ringbuffer :: proc (
    rb_index: int,
    frames_to_skip: u32,
) {
    ma.pcm_rb_seek_read(&ringbuffers[rb_index], frames_to_skip)
}



read_ringbuffer :: proc(
    rb_index: int,
    samples: []f32,
    frame_count: u32
) -> u32 {
    data_ptr : rawptr
    rb_pt := &ringbuffers[rb_index]

    total_frames_read : u32 = 0

    // The ring buffer can return fewer frames than requested if the position is near the end of the buffer.
    // We want to loop until we get all the needed frames.
    for total_frames_read < frame_count {

        frames_to_read: u32 = frame_count - total_frames_read

        acquire_result := ma.pcm_rb_acquire_read(rb_pt, &frames_to_read, &data_ptr)
        if acquire_result != ma.result.SUCCESS {
            fmt.println("Failed to acquire read pointer from ring buffer.", ma.result_description(acquire_result))
            break
        }

        if frames_to_read == 0 do break // end of ringbuffer

        ma.copy_pcm_frames(raw_data(samples[total_frames_read:]), data_ptr, u64(frames_to_read), ma.format.f32, 1)

        commit_result := ma.pcm_rb_commit_read(rb_pt, frames_to_read, data_ptr)

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



