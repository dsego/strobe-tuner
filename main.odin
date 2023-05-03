package main

import "core:fmt"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768

// SIZE :: 1024
SIZE :: 4096

samples : [SIZE]f32
points: [SIZE]rl.Vector2

device: ma.device
ringbuffer: ma.pcm_rb



// freq A1 = 55Hz
// target_size := 48000.0 / 55.0
target_size := 48000.0 / 32.70320
target_size_ceil := u32(math.ceil(target_size))


delta := 0.0
frame_counter := 0.0
frame_counter_integer := u32(0)
drift := 0.0


audio_capture_callback :: proc "cdecl" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    data_ptr : rawptr
    frames_left := frame_count

    // Capture samples and write to a ring buffer.
    for {
        frames_to_write := frames_left

        result := ma.pcm_rb_acquire_write(&ringbuffer, &frames_to_write, &data_ptr)
        if result != ma.result.SUCCESS {
            ma.log_post(
                ma.device_get_log(device),
                u32(ma.log_level.LOG_LEVEL_ERROR),
                "Failed to acquire capture PCM frames from ring buffer."
            )
            break
        }

        if frames_to_write == 0 {
            if ma.pcm_rb_pointer_distance(&ringbuffer) == i32(ma.pcm_rb_get_subbuffer_size(&ringbuffer)) {
                break // Overrun
            }
        }

        ma.copy_pcm_frames(data_ptr, input, u64(frames_to_write), ma.format.f32, 1)

        result = ma.pcm_rb_commit_write(&ringbuffer, frames_to_write, data_ptr)
        if result != ma.result.SUCCESS {
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

    result = ma.pcm_rb_init(ma.format.f32, 1, 96000, nil, nil, &ringbuffer)
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
        // break
    }
}

read_samples :: proc() {


    data_ptr : rawptr
    // frames_left := u32(SIZE)
    // fmt.println("READ SAMPLES")

    // for {
    frames_left := u32(target_size_ceil)
    // frames_available : u32

    // for {
    frames_available := ma.pcm_rb_available_read(&ringbuffer)

    // fmt.println("available", frames_available)
    if frames_available < u32(target_size_ceil) do return
    //     // to_skip := math.floor_div(frames_available, 2 * SIZE)
    //     if frames_available < 2 * SIZE do break

    //     ma.pcm_rb_seek_read(&ringbuffer, 2 * SIZE)
    // }

    frame_counter += target_size
    frame_counter_integer += target_size_ceil


    frame_counter_ceil := u32(math.ceil(frame_counter))
    delta := frame_counter_integer - frame_counter_ceil

    // adjust frame counter sample rate
    frame_counter_integer -= delta
    frames_left = u32(target_size_ceil - delta)


    // TODO: wrap around to avoid overflow
    // frame_counter = frame_counter, frame_counter_ceil


    // correct for sub-sample drift

    // fmt.println(frames_left, target_size)
    drift = f64(frame_counter_integer) - frame_counter
    // fmt.println(frame_counter, frame_counter_ceil, drift)

    for {
        frames_to_read := frames_left
        result := ma.pcm_rb_acquire_read(&ringbuffer, &frames_to_read, &data_ptr)
        // fmt.println(frames_to_read)
        if result != ma.result.SUCCESS {
            fmt.println("acquire failed")
            // log
            break
        }

        data := cast([^]f32) data_ptr
        for i in 0..<frames_to_read {
            samples[frames_left-i-1] = data[i]
        }

        result = ma.pcm_rb_commit_read(&ringbuffer, frames_to_read, data_ptr)

        if result != ma.result.SUCCESS {
            // fmt.println("commit failed", result, frames_to_read)
            // log
            break
        }

        frames_left -= frames_to_read
        if frames_left <= 0 do break
    }

}

draw_screen :: proc() {
    rl.BeginDrawing()
    defer rl.EndDrawing()

    // stretch samples to fit the screen width
    resolution := f32(SCREEN_WIDTH) / f32(target_size_ceil)
    drift_adj := f32(drift) * resolution
    xpos := f32(0.0)

    read_samples()
    for i in 0..<target_size_ceil {
        x := f32(xpos) - f32(drift)
        xpos += resolution
        y := SCREEN_HEIGHT/2 + samples[i] * 100
        points[i] = { x, y }
    }

    rl.ClearBackground(rl.BLACK)
    rl.DrawLineStrip(raw_data(points[:]), i32(target_size_ceil), rl.PINK)
}
