package app


import rl "vendor:raylib"
import "core:fmt"
import "core:path/filepath"
import "core:strings"



import ma "vendor:miniaudio"

// Simplify by using a constant number of ringbuffers instead of a dynamic list.
// NOTE: Needs to be a power of 2 for portaudio ring buffers!
DEFAULT_RB_SIZE :: 65536

STROBE_COUNT :: 1

// FFT size for pitch detection
FFT_SIZE :: 4096

SAMPLERATE :: 44100
SAMPLE_SIZE :: 2048

SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768


Ringbuffer :: ma.pcm_rb

sharp : cstring = "♯"
font_atlas := "ABCDEFGHz♯♭/1234567890."
font: rl.Font

target_freq: f64

// Root directory relative to this file
root_dir := filepath.dir(#file)


main :: proc() {

    ukulele_freqs: []f64 = {
        391.9954, // G
        261.6256, // C
        329.6276, // E
        440.0000, // A
    }

    ukulele_freqs_idx := 0

    target_freq = ukulele_freqs[0]

    // target_freq = 2500
    // target_freq = 88
    // target_freq = 1567.982
    // target_freq = 7902.133

    // target_freq = 440.0000 // A
    // target_freq = 329.6276 // E
    // target_freq = 261.6256 // C
    // target_freq = 391.9954 // G


    init_strobes(target_freq / SAMPLERATE)

    ok := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture()

    // pitch := pitch_init(FFT_SIZE, SAMPLERATE)
    // defer pitch_destroy(pitch)

    // samples: []f32 = make([]f32, FFT_SIZE)
    // new_samples: []f32 = make([]f32, FFT_SIZE)
    // defer delete(samples)

    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()


    count := i32(0)
    codepoints := rl.LoadCodepoints(raw_data(font_atlas), &count)
    defer rl.UnloadCodepoints(codepoints)

    font_path := strings.clone_to_cstring(filepath.join({root_dir, "../assets/NotoSansMono-Medium.ttf"}))
    font = rl.LoadFontEx(font_path, 128, codepoints, count)
    defer rl.UnloadFont(font)

    init_strobe_display()
    defer destroy_strobe_display()

    show_pattern := false

    for !rl.WindowShouldClose() {


        // Toggle between scope view and strobe view
        if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
            show_pattern = !show_pattern
        }


        freq_changed := false

        // Pick next or previous ukulele string
        if rl.IsKeyPressed(rl.KeyboardKey.RIGHT) {
            ukulele_freqs_idx += 1
            freq_changed = true
        }
        if rl.IsKeyPressed(rl.KeyboardKey.LEFT) {
            ukulele_freqs_idx -= 1
            freq_changed = true
        }

        if (freq_changed) {
            ukulele_freqs_idx %= len(ukulele_freqs)
            if ukulele_freqs_idx < 0 do ukulele_freqs_idx += len(ukulele_freqs) // wrap around
            reset_framerate()
        }

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

        target_freq = ukulele_freqs[ukulele_freqs_idx]

        note := find_note(f32(target_freq))

        // aim at a double interval, to show more of the wave shape and slow down the strobe movement
        target_interval := 2.0 * f64(SAMPLERATE) / target_freq

        frame_count, drift := read_samples(
            rb_ptr=&strobe_ringbuffer,
            samples=strobe_samples[:],
            target_interval=target_interval,
        )



        load_strobe_texture(frame_count)
        defer unload_strobe_texture()

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            draw_strobes(
                target_interval,
                drift,
                frame_count,
                show_pattern,
            )

            // fmt.println(target_freq, note)

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


            formatted_freq := strings.clone_to_cstring(fmt.aprintf("%.1fHz", target_freq))
            formatted_interval := strings.clone_to_cstring(fmt.aprintf("%.2f", target_interval))
            rl.DrawTextEx(font, formatted_freq, {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, formatted_interval, {20, 150}, 16, 0, rl.SKYBLUE)

        }
    }
}



