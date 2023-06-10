package filter

import "core:fmt"
import "core:log"
import "core:os"
import "core:mem"
// import "core:os"
import "core:math"
import "core:runtime"

import rl "vendor:raylib"
import ma "vendor:miniaudio"


import "../pffft"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100
SIZE :: 4096


AppContext :: struct {
    font: rl.Font
}

ctx := AppContext{}

// path: cstring = "./media/ukulele_A3.wav"
// path: cstring = "./media/acoustic_A1.wav"
// path: cstring = "./media/bass_A0.wav"
// path: cstring = "./media/strat_A1.wav"

read_wav :: proc(path: cstring, from: u64, to: u64, samples: []f32) {
    assert(from < to && to < u64(len(samples)))

    decoder: ma.decoder
    config := ma.decoder_config_init(ma.format.f32, 1, 44100)
    if ma.decoder_init_file(path, &config, &decoder) != ma.result.SUCCESS {
        fmt.println("Failed to decode wav file '%s'.", path)
        return
    }
    defer ma.decoder_uninit(&decoder)

    frames_to_read : u64 = to - from

    ma.decoder_seek_to_pcm_frame(&decoder, 1000)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples[:]), frames_to_read, nil)
}

run_filter :: proc(samples: []f32, impulse: []f32, out: []f32) {
    taps := len(impulse)

    // naive, can optimize by leveraging symmetry
    for n in taps..<len(samples) {
        for k in 0..<taps {
            out[n] += samples[n-k] * impulse[k]
        }
    }
}

gaussian :: proc(data: []f32, amp: f32, spread: f32) {
    len := f32(len(data))
    for d, i in data {
        x := f32(i) - len/2.0
        data[i] = amp * math.exp(-x * x / spread)
    }
}


init_window :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Filter")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    ctx.font = rl.LoadFontEx("./media/JetBrainsMono-Regular.ttf", 64, nil, 0)
}

cleanup :: proc() {
    rl.CloseWindow()
    rl.UnloadFont(ctx.font)
}

main :: proc() {

    init_window()
    defer cleanup()

    // read_wav()

    for !rl.WindowShouldClose() {
        draw_screen()
    }
}

draw_samples :: proc(
    samples: []f32,
    x1: f32,
    y1: f32,
    width: f32,
    height: f32,
    color: rl.Color,
    gain: f32 = 1.0,
) {
    l := len(samples)
    points: []rl.Vector2

    // stretch samples to fit the box width
    resolution := f32(width) / f32(l -1)

    x := x1
    for i in 0..<l {
        // stretch to fit the box height and apply gain
        y := y1 + (height/2) - samples[i] * (height / 2) * gain
        points[i] = { x, y }
        x += resolution
    }
    rl.DrawLineStrip(raw_data(points[:]), i32(l), color)
}

draw_grid :: proc() {
    // DrawTextEx(Font font, const char *text, Vector2 position, float fontSize, float spacing, Color tint)
    // DrawLineEx(Vector2 startPos, Vector2 endPos, float thick, Color color)
}

draw_screen :: proc() {

    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.BLACK)
    rl.DrawTextEx(ctx.font, "free fonts included with raylib", rl.Vector2{250, 20}, 16, 1, rl.LIGHTGRAY);

    // draw_samples(samples[:SIZE], 0, 0, SCREEN_WIDTH, 100, rl.PINK, 2.0)

    // draw_samples(magnitude_data[:], 0, 110, SCREEN_WIDTH, 100, rl.ORANGE)
    // draw_samples(bq_filtered[0][:SIZE], 0, 110, SCREEN_WIDTH, 100, rl.ORANGE)
    // draw_samples(bq_filtered[1][:SIZE], 0, 230, SCREEN_WIDTH, 100, rl.SKYBLUE)


    // draw_samples(fir_filtered[0][:SIZE], 0, 340, SCREEN_WIDTH, 100, rl.YELLOW)
    // draw_samples(fir_filtered[1][:SIZE], 0, 450, SCREEN_WIDTH, 100, rl.YELLOW)
}
