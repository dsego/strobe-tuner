package main

import "core:fmt"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768

// TODO: ability to choose sample rate
SAMPLERATE :: u32(48000)

// SIZE :: 1024
SIZE :: 4096

samples : [SIZE]f32
points: [SIZE]rl.Vector2

device: ma.device
ringbuffer: ma.pcm_rb
ctx: ma.context_type
capture_devices: [^]ma.device_info
capture_device_count: u32


// NOTE: aiming to fetch a number of samples close to the horizontal resolution, eg 1024px.
// freq A1 = 55Hz

// target_freq := 55.0
// target_freq := 65.406
// target_freq := 82.407
target_freq := 49.00
// target_freq := 440.0
target_interval := f64(SAMPLERATE) / target_freq
frame_counter_real := 0.0

audio_capture_callback :: proc "cdecl" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
    data_ptr : rawptr
    frames_left := frame_count

    // Capture samples and write to a ring buffer.
    for {
        frames_to_write := frames_left

        if ma.pcm_rb_acquire_write(&ringbuffer, &frames_to_write, &data_ptr) != ma.result.SUCCESS {
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

        if ma.pcm_rb_commit_write(&ringbuffer, frames_to_write, data_ptr) != ma.result.SUCCESS {
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
    config.sampleRate = SAMPLERATE

    if ma.context_init(nil, 0, nil, &ctx) != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio context.")
        return
    }

    if ma.context_get_devices(&ctx, nil, nil, &capture_devices, &capture_device_count) != ma.result.SUCCESS {
        fmt.println("Failed to retrieve device information.")
        return
    }

    fmt.println("\n..................................")
    fmt.println(" Audio capture devices:")
    for i := u32(0); i < capture_device_count; i += 1 {
        fmt.printf("  %v ‣ %s\n", i, capture_devices[i].name)
    }
    fmt.println("..................................\n")

    // set BlackHole 2ch device for capture
    config.capture.pDeviceID = &capture_devices[0].id

    // Internal Mic
    // config.capture.pDeviceID = &capture_devices[1].id

    if ma.device_init(&ctx, &config, &device) != ma.result.SUCCESS {
        fmt.println("Failed to initialize audio device.")
        return
    }

    if ma.device_start(&device) != ma.result.SUCCESS {
        fmt.println("Failed to start audio device.")
        return
    }

    if ma.pcm_rb_init(ma.format.f32, 1, 96000, nil, nil, &ringbuffer) != ma.result.SUCCESS {
        fmt.println("Failed to initialize ring buffer.")
        return
    }
}

destroy_audio_capture :: proc() {
    ma.device_stop(&device)
    ma.device_uninit(&device)
    ma.context_uninit(&ctx)
    ma.pcm_rb_uninit(&ringbuffer)
}

main :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({rl.ConfigFlags.WINDOW_HIGHDPI})

    init_audio_capture()
    defer destroy_audio_capture()

    for !rl.WindowShouldClose() {
        draw_screen()
    }
}

calculate_framerate:: proc(
    frames_available: u32,
    frame_count: f64,
    target_interval: f64,
) -> (
    next_frame_count: f64,
    frames_to_skip,
    frames_to_read: u32)
{
    next_frame_count = frame_count

    frames_to_read = u32(0)
    frames_to_ingest := u32(0)
    prev_frames_ceil := u32(math.ceil(frame_count))

    // skip over N intervals and read one full interval to keep the reading rate consistent
    for frames_to_ingest < frames_available {
        prev_frame_count := next_frame_count
        next_frame_count += target_interval

        frames := u32(math.ceil(next_frame_count)) - u32(math.ceil(prev_frame_count))
        if frames_to_ingest + frames > frames_available {
            next_frame_count = prev_frame_count
            break
        }
        frames_to_read = frames
        frames_to_ingest += frames
    }

    frames_to_skip = frames_to_ingest - frames_to_read
    return
}

read_samples :: proc() -> (u32, f64) {
    frames_available := ma.pcm_rb_available_read(&ringbuffer)

    next_frame_count, frames_to_skip, frames_to_read := calculate_framerate(
        frames_available,
        frame_counter_real,
        target_interval
    )

    // don't let the counter increase forever, we only need to keep the fractional part
    frame_counter_real = next_frame_count - math.floor(next_frame_count)

    // skip old samples to pick up slack and catch up with the writer
    if frames_to_skip > 0 do ma.pcm_rb_seek_read(&ringbuffer, frames_to_skip)

    // consume one frequency interval of samples
    if frames_to_read > 0 do read_ring_buffer(frames_to_read)

    // correct for sub-sample drift
    drift := f64(1.0) - frame_counter_real

    return frames_to_read, drift
}

read_ring_buffer :: proc(frame_count: u32) {
    data_ptr : rawptr
    frames_left := frame_count

    // The ring buffer can return fewer frames than requested if the position is near the end of the buffer.
    // We want to loop until we get all the needed frames.
    for {
        frames_to_read := frames_left
        if ma.pcm_rb_acquire_read(&ringbuffer, &frames_to_read, &data_ptr) != ma.result.SUCCESS {
            fmt.println("Failed to acquire read pointer from ring buffer.")
            break
        }

        data := cast([^]f32) data_ptr
        for i in 0..<frames_to_read {
            samples[frames_left-i-1] = data[i]
        }

        if ma.pcm_rb_commit_read(&ringbuffer, frames_to_read, data_ptr) != ma.result.SUCCESS {
            // fmt.println("Failed to commit read on ring buffer.")
            break
        }

        frames_left -= frames_to_read
        if frames_left <= 0 do break
    }
}

draw_screen :: proc() {
    // fmt.println(drift)
    rl.BeginDrawing()
    defer rl.EndDrawing()


    xpos := f32(20.0)
    // xpos := f32(10.0)

    frame_count, drift := read_samples()

    // stretch samples to fit the screen width
    resolution := f32(SCREEN_WIDTH-40) / f32(target_interval-1)
    drift_adj := f32(drift) * resolution

    // fmt.println(target_interval)
    x := xpos - drift_adj

    for i in 0..<frame_count {
        // note that y is flipped (negative)
        y := SCREEN_HEIGHT/2 - samples[i] * 1000
        points[i] = { x, y }
        x += resolution
    }

    PADDING :: 20
    BOX_HEIGHT :: SCREEN_HEIGHT - PADDING * 2
    BOX_WIDTH :: SCREEN_WIDTH - PADDING * 2

    rl.ClearBackground(rl.BLACK)

    // Draw grid lines
    dy := i32(100)
    for y := i32(0); y < BOX_HEIGHT; y += dy {
        rl.DrawLine(PADDING, y, BOX_WIDTH+PADDING, y, rl.DARKGRAY)
    }

    dx := i32(100)
    for x := i32(0); x < BOX_WIDTH; x += dx {
        rl.DrawLine(x, PADDING, x, BOX_HEIGHT+PADDING, rl.DARKGRAY)
    }

    rl.DrawRectangleLines(PADDING, PADDING, BOX_WIDTH, BOX_HEIGHT, rl.GRAY)
    rl.DrawLineStrip(raw_data(points[:]), i32(frame_count), rl.PINK)
}
