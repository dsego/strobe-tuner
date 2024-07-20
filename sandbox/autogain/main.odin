package pitch

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:math"

import rl "vendor:raylib"

import helpers "../helpers"


SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768
SAMPLERATE :: 44100
SAMPLE_COUNT :: 8192


main :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Autogain")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    defer rl.CloseWindow()

    font := rl.LoadFontEx("../assets/NotoSansMono-Medium.ttf", 64, nil, 0)
    defer rl.UnloadFont(font)


    // path: cstring = "./media/ukulele_A4.wav"
    path: cstring = "./media/acoustic_A2.wav"
    // path: cstring = "./media/bass_G2.wav"

    // read in the whole file
    // ability to scrub with right-left arrows
    // path: cstring = "./media/bass_E1.wav"
    // path: cstring = "./media/strat_A2.wav"
    // path: cstring = "./media/bass_D2.wav"

    // we want a large buffer of ~2MB to accommodate the whole wav file
    audio_buffer := make([]f32, 2000000)
    rms := make([]f32, 2000000)

    // buffer auto gain corrected samples
    agc_audio := make([]f32, 2000000)

    defer delete(audio_buffer)
    defer delete(rms)
    defer delete(agc_audio)

    helpers.read_wav(path=path, samples=audio_buffer)


    squared: f32
    rms_window_size := 2048
    window_counter := 0

    for i in 0..<len(audio_buffer) {
        squared += audio_buffer[i] * audio_buffer[i]
        if window_counter >= rms_window_size {
            squared -= audio_buffer[i - rms_window_size] * audio_buffer[i - rms_window_size]
        }
        window_counter += 1
        rms[i] = math.sqrt(squared / f32(rms_window_size))
    }

    // https://github.com/sile/dagc/blob/main/src/lib.rs
    // -------------------------
    // target_rms := f32(0.1)
    // gain := f32(1.0)
    // distortion_factor := f32(0.01)

    // for i in 0..<len(audio_buffer) {
    //     agc_audio[i] = audio_buffer[i] * gain

    //     y := (agc_audio[i] * agc_audio[i]) / target_rms
    //     z := 1.0 + distortion_factor * (1.0 - y)
    //     gain *= z
    // }
    // -------------------------



    // TODO: how to apply gain only above certain threshold...  make it logarithmic?

    // target_rms := f32(0.5)
    // for i in 0..<len(audio_buffer) {
    //     gain := target_rms / rms[i]
    //     agc_audio[i] = audio_buffer[i] * gain
    // }

    position: = 0
    moved_window := true


    for !rl.WindowShouldClose() {

        if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {
            position += 100
            moved_window = true
            if position > len(audio_buffer) - SAMPLE_COUNT do position = len(audio_buffer) - SAMPLE_COUNT
        }
        else if rl.IsKeyDown(rl.KeyboardKey.LEFT) {
            position -= 100
            moved_window = true
            if position <= 0 do position = 0
        }

        samples := audio_buffer[position:position+SAMPLE_COUNT]

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rect := rl.Rectangle{20, 20, SCREEN_WIDTH-40, 200}
        helpers.draw_timeplot_box(rect)
        helpers.draw_samples(rect, samples, rl.PINK, 1.0)
        helpers.draw_samples(rect, rms[position:position+SAMPLE_COUNT], rl.GOLD, 1.0)
        helpers.draw_samples(rect, agc_audio[position:position+SAMPLE_COUNT], rl.SKYBLUE, 1.0)

    }
}

