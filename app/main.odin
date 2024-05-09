package app


import rl "vendor:raylib"
import "core:fmt"
import "core:strings"



// FFT size for pitch detection
FFT_SIZE :: 4096
SAMPLERATE :: 44100
SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768


font: rl.Font
font_atlas := "ABCDEFGHz♯♭/1234567890."


main :: proc() {
    /*
    ok := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture()

    pitch := pitch_init(FFT_SIZE, SAMPLERATE)
    defer pitch_destroy(pitch)

    samples: []f32 = make([]f32, FFT_SIZE)
    new_samples: []f32 = make([]f32, FFT_SIZE)
    defer delete(samples)

    freq : f32 = 261.6256
    strobe_band := init_strobe(1024, f64(freq/SAMPLERATE))
    defer destroy_strobe(strobe_band)
    */

    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()


    count := i32(0)
    codepoints := rl.LoadCodepoints(raw_data(font_atlas), &count)
    defer rl.UnloadCodepoints(codepoints)

    font = rl.LoadFontEx("../assets/NotoSansMono-Medium.ttf", 128, codepoints, count)
    defer rl.UnloadFont(font)

    for !rl.WindowShouldClose() {

        /* DISABLE PITCH DETECTION
        // Pitch detection, use the first ringbuffer
        new_count := read_ringbuffer(0, new_samples, FFT_SIZE/2)

        if new_count > 0 {

            // move old samples back to make room for new samples
            copy(samples, samples[new_count:])

            // copy over new samples into the freed space
            copy(samples[FFT_SIZE-new_count:], new_samples[:new_count])

        }

        // TODO: add to delay line (moving average of 5-10 samples)
        // TODO: no need to run pitch detect if samples haven't changed
        freq, _, _ := pitch_detect(pitch, samples)
        note := find_note(freq)

        */
        rl.BeginDrawing()
        {
            draw_screen()
        }
        rl.EndDrawing()
    }
}


@(private)
draw_screen :: proc() {

    rl.ClearBackground(rl.BLACK)


    // freq : f32 = 293.6648  // D4
    freq : f32 = 138.5913 // C#
    // freq : f32 = 261.6256
    note := find_note(freq)

    sharp : cstring = "♯"

    // fmt.println(note)

    // TODO: make draw_note() method
    if note.is_accidental {
        rl.DrawTextEx(font, cstring(&note.name), {20, 20}, 64, 0, rl.PURPLE)
        rl.DrawTextEx(font, sharp, {50, 20}, 32, 0, rl.PURPLE)
        rl.DrawTextEx(font, sharp, {50, 20}, 32, 0, rl.PURPLE)
    } else {
        rl.DrawTextEx(font, cstring(&note.name), {20, 20}, 64, 0, rl.PURPLE)
    }

    // run_strobe(strobe_band, )
    // fmt.println(note.name, note.semitone_index)

    // rl.DrawText("A1", 10, 10, 30, rl.PURPLE)

    formatted_freq := strings.clone_to_cstring(fmt.aprintf("%.1fHz", freq))
    rl.DrawTextEx(font, formatted_freq, {20, 100}, 32, 0, rl.PURPLE)

}
