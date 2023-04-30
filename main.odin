package main

import "core:fmt"
import "core:os"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768

SIZE :: 1024

samples : [SIZE]f32
points: [SIZE]rl.Vector2

device: ma.device
ringbuffer: ma.pcm_rb

audio_capture_callback :: proc "cdecl" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    data_ptr : rawptr
    frames_left := frame_count

    // Capture samples and write to a ring buffer.
    for {
        frames_to_process := frames_left

        result := ma.pcm_rb_acquire_write(&ringbuffer, &frames_to_process, &data_ptr)
        if result != ma.result.SUCCESS {
            break
        }

        if frames_to_process == 0 do break

        ma.copy_pcm_frames(data_ptr, input, u64(frames_to_process), ma.format.f32, 1)

        result = ma.pcm_rb_commit_write(&ringbuffer, frames_to_process, data_ptr)
        if result != ma.result.SUCCESS {
            break
        }

        frames_left -= frames_to_process
    }

}

init_audio_capture :: proc() {
    config := ma.device_config_init(ma.device_type.capture)
    config.dataCallback = audio_capture_callback
    // config.notificationCallback = TODO
    config.capture.format = ma.format.f32
    config.capture.channels = 1

    result := ma.device_init(nil, &config, &device)
    if result != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio device!")
        return
    }

    result = ma.device_start(&device)
    if result != ma.result.SUCCESS {
        fmt.println("Failed to start audio device!")
        return
    }

    result = ma.pcm_rb_init(ma.format.f32, 1, 4096, nil, nil, &ringbuffer)
    if result != ma.result.SUCCESS {
        fmt.println("Failed to initialize ring buffer!")
        return
    }
}

destroy_audio_capture :: proc() {
    ma.device_stop(&device)
    ma.device_uninit(&device)
}

main :: proc() {
    init_audio_capture()
    defer destroy_audio_capture()

    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    rl.SetTargetFPS(60)

    for !rl.WindowShouldClose() {
        draw_screen()
    }
}

read_samples :: proc() {
    data_ptr : rawptr
    frame_count := u32(SIZE)
    for {
        result := ma.pcm_rb_acquire_read(&ringbuffer, &frame_count, &data_ptr)

        if result != ma.result.SUCCESS do break
        if frame_count == 0 do break

        ma.copy_pcm_frames(raw_data(samples[:]), data_ptr, u64(frame_count), ma.format.f32, 1)

        result = ma.pcm_rb_commit_read(&ringbuffer, frame_count, data_ptr)

        if result != ma.result.SUCCESS {
            // log
            break
        }
    }
}

draw_screen :: proc() {
    rl.BeginDrawing()
    defer rl.EndDrawing()


    read_samples()
    for _, i in points {
        points[i] = {f32(i), SCREEN_HEIGHT/2 + samples[i] * 100}
    }

    rl.ClearBackground(rl.BLACK)
    rl.DrawLineStrip(raw_data(points[:]), SCREEN_WIDTH, rl.PINK)
}
