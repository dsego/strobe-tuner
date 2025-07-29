package pitch

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"

import rl "vendor:raylib"

import helpers "../helpers"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100
SAMPLE_COUNT :: 4096


AppContext :: struct {
    font: rl.Font,
}

ctx := AppContext{}


init :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Pitch")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
}

cleanup :: proc() {
    rl.CloseWindow()
    rl.UnloadFont(ctx.font)
}

main :: proc() {
    init()
    defer cleanup()

    font := rl.LoadFontEx("media/JetBrainsMono-Regular.ttf", 64, nil, 0)
    ctx.font = font
    defer rl.UnloadFont(font)

    // path: cstring = "./media/ukulele_A4.wav"
    // path: cstring = "./media/acoustic_A2.wav"
    // path: cstring = "./media/bass_G2.wav"

    // read in the whole file
    // ability to scrub with right-left arrows
    path: cstring = "./media/bass_E1.wav"
    // path: cstring = "./media/strat_A2.wav"
    // path: cstring = "./media/bass_D2.wav"

    // we want a large buffer of ~2MB to accommodate the whole wav file
    audio_buffer := make([]f32, 2000000)
    defer delete(audio_buffer)

    helpers.read_wav(path=path, samples=audio_buffer)


    pitch_config := pitch_init(fft_size=SAMPLE_COUNT, samplerate=SAMPLERATE)
    defer pitch_destroy(pitch_config)

    position: = 0
    moved_window := true
    freq: f32 = 0
    lag: f32 = 0
    val: f32 = 0

    for !rl.WindowShouldClose() {

        if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {
            position += 50
            moved_window = true
            if position > len(audio_buffer) - SAMPLE_COUNT do position = len(audio_buffer) - SAMPLE_COUNT
        }
        else if rl.IsKeyDown(rl.KeyboardKey.LEFT) {
            position -= 50
            moved_window = true
            if position <= 0 do position = 0
        }

        samples := audio_buffer[position:position+SAMPLE_COUNT]

        if moved_window {
            freq, lag, val = pitch_detect(pitch_config, samples)
            moved_window = false
        }

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rect := rl.Rectangle{20, 20, SCREEN_WIDTH-40, 200}
        helpers.draw_time_plot(rect, len(samples), 9.0, SAMPLERATE, ctx.font)
        helpers.draw_samples(rect, samples, rl.PINK, 1.0)

        gain: = 1.0 / pitch_config.autocorrelation[0]

        rect2 := rl.Rectangle{20, 300, SCREEN_WIDTH-40, 200}
        helpers.draw_time_plot(rect2, len(pitch_config.autocorrelation), 9.0, SAMPLERATE, ctx.font)
        helpers.draw_samples(rect2, pitch_config.autocorrelation, rl.GOLD, gain)

        rl.DrawTextEx(font, fmt.ctprintf("%.1f Hz", freq), {20, 550}, 32, 0, rl.GRAY)

        // Mark lag position with a cross
        cx := rect2.x + lag * f32(rect.width) / f32(len(samples) - 1)
        cy := rect2.y + (rect2.height/2.0) - val * (rect2.height / 2.0)

        rl.DrawLineEx({rect2.x, cy}, {rect2.x+rect2.width, cy}, 0.5, rl.GRAY)
        rl.DrawLineEx({cx-7.0, cy}, {cx+7.0, cy}, 2.0, rl.LIGHTGRAY)
        rl.DrawLineEx({cx, cy-7.0}, {cx, cy+7.0}, 2.0, rl.LIGHTGRAY)

    }
}

