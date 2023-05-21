package main

import "core:fmt"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: u32(48000)
SIZE :: 4096

samples: [SIZE]f32
points: [SIZE]rl.Vector2


decoder: ma.decoder


read_wav :: proc() {
    path: cstring = "./media/strat_A1.wav"
    config := ma.decoder_config_init(ma.format.f32, 1, 44100)
    if ma.decoder_init_file(path, &config, &decoder) != ma.result.SUCCESS {
        fmt.println("Failed to decode wav file '%s'.", path)
        return
    }
    defer ma.decoder_uninit(&decoder)

    frames_to_read : u64 = SIZE
    frames : [SIZE]f32
    frames_read: u64
    ma.decoder_read_pcm_frames(&decoder, raw_data(frames[:]), frames_to_read, &frames_read)


    for f, i in frames {
        samples[i] = f32(f)
    }

}

main :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({rl.ConfigFlags.WINDOW_HIGHDPI})

    read_wav()

    for !rl.WindowShouldClose() {
        draw_screen()
    }
}

draw_screen :: proc() {
    // fmt.println(drift)
    rl.BeginDrawing()
    defer rl.EndDrawing()

    frame_count: u32 = 4096

    // stretch samples to fit the screen width
    resolution := f32(SCREEN_WIDTH) / f32(frame_count -1)
    x := f32(0)

    for i in 0..<frame_count {
        y := SCREEN_HEIGHT/4 - samples[i] * 200
        points[i] = { x, y }
        x += resolution
    }

    rl.ClearBackground(rl.BLACK)
    rl.DrawLineStrip(raw_data(points[:]), i32(frame_count), rl.PINK)
}
