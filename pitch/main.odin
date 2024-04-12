package pitch

import "core:fmt"
import "core:os"
import "core:runtime"

import rl "vendor:raylib"

import helpers "../helpers"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100
SAMPLE_COUNT :: 2048


AppContext :: struct {
    font: rl.Font,
}

ctx := AppContext{}


init :: proc() {
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
    init()
    defer cleanup()

    // path: cstring = "./media/ukulele_A4.wav"
    // path: cstring = "./media/acoustic_A2.wav"
    path: cstring = "./media/bass_A1.wav"
    // path: cstring = "./media/strat_A2.wav"

    samples := make([]f32, SAMPLE_COUNT)
    defer delete(samples)

    helpers.read_wav(path=path, from=1150, frames_to_read=SAMPLE_COUNT, samples=samples)


    pitch_config := pitch_init(fft_size=SAMPLE_COUNT, samplerate=SAMPLERATE)
    defer pitch_destroy(pitch_config)

    pitch_detect(pitch_config, samples)

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rect := rl.Rectangle{20, 20, SCREEN_WIDTH-40, 200}
        helpers.draw_time_plot(rect, len(samples), 9.0, SAMPLERATE, ctx.font)
        helpers.draw_samples(rect, samples, rl.PINK, 1.0)

        rect2 := rl.Rectangle{20, 300, SCREEN_WIDTH-40, 200}
        helpers.draw_time_plot(rect2, len(pitch_config.autocorrelation), 9.0, SAMPLERATE, ctx.font)
        helpers.draw_samples(rect2, pitch_config.autocorrelation, rl.GOLD, 0.000005)
    }
}

