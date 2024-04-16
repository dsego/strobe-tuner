package app


import rl "vendor:raylib"
import "core:fmt"
import "core:strings"



// FFT size for pitch detection
FFT_SIZE :: 2048
SAMPLERATE :: 44100
SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768



@(private)
draw_screen :: proc() {
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.BLACK)
}


main :: proc() {
    ok := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture()

    pitch := pitch_init(FFT_SIZE, SAMPLERATE)
    defer pitch_destroy(pitch)

    samples: []f32 = make([]f32, FFT_SIZE)
    new_samples: []f32 = make([]f32, FFT_SIZE)
    defer delete(samples)


    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    font := rl.LoadFontEx("./assets/NotoSansMono-Medium.ttf", 128, nil, 0)
    defer rl.UnloadFont(font)


    for !rl.WindowShouldClose() {

        // Pitch detection, use the first ringbuffer
        count := read_ringbuffer(0, new_samples, FFT_SIZE/2)

        // move old samples back to make room for new samples
        copy(samples, samples[FFT_SIZE/2:])

        // copy over new samples into the freed space
        copy(samples[FFT_SIZE/2:], new_samples[:FFT_SIZE/2])



        // TODO: add to delay line (moving average of 5-10 samples)
        freq := pitch_detect(pitch, samples)

        note := find_note(freq)
        formatted_note := strings.clone_to_cstring(note.name)
        // fmt.println(note.name, note.semitone_index)

        // rl.DrawText("A1", 10, 10, 30, rl.PURPLE)
        rl.DrawTextEx(font, formatted_note, {20, 20}, 64, 0, rl.PURPLE)
        formatted_freq := strings.clone_to_cstring(fmt.aprintf("%.1f Hz", freq))
        rl.DrawTextEx(font, formatted_freq, {20, 100}, 32, 0, rl.PURPLE)

        draw_screen()
    }
}



