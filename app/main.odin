package app

import rl "vendor:raylib"
import "core:fmt"
import "core:strings"



main :: proc() {

    bass_freqs: []f64 = {
        41.20344, // E1
        55.00000,  // A1
        73.41619, // D2
        97.99886, // G2
    }

    guitar_freqs: []f64 = {
        82.40689, // E2
        110.0000, // A2
        146.8324, // D3
        195.9977, // G3
        246.9417, // B3
        329.6276, // E4
    }

    ukulele_freqs: []f64 = {
        391.9954, // G4
        261.6256, // C4
        329.6276, // E4
        440.0000, // A4
    }

    freqs_idx := 1

    target_freq := 0.0
    freqs: []f64 = ukulele_freqs


    target_interval := 0.0

    // target_freq = 2500
    // target_freq = 88
    // target_freq = 1567.982
    // target_freq = 7902.133

    // target_freq = 440.0000 // A
    // target_freq = 329.6276 // E
    // target_freq = 261.6256 // C
    // target_freq = 391.9954 // G


    init_strobes(target_freq / SAMPLERATE)

    smooth_conf := init_smoothing(30)

    ok := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture()

    ac := ac_init(FFT_SIZE, SAMPLERATE)
    defer ac_destroy(&ac)

    samples: []f32 = make([]f32, FFT_SIZE/2)
    defer delete(samples)

    new_samples: []f32 = make([]f32, FFT_SIZE/2)
    defer delete(new_samples)


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    init_drawing_context()
    defer destroy_drawing_context()

    init_strobe_display()
    defer destroy_strobe_display()


    show_pattern := false

    detected_freq: f32
    detected_note: Note
    clarity: f32
    peak: Vec2

    // flatness: f32

    // freq_estimate: f32 = 260.0
    // freq_estimate_error:f32 = 0.5

    for !rl.WindowShouldClose() {

        // Toggle between scope view and strobe view
        if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
            show_pattern = !show_pattern
        }

        freq_changed := false

        // Pick next or previous ukulele string
        if rl.IsKeyPressed(rl.KeyboardKey.RIGHT) {
            freqs_idx += 1
            freq_changed = true
        }
        if rl.IsKeyPressed(rl.KeyboardKey.LEFT) {
            freqs_idx -= 1
            freq_changed = true
        }

        if freq_changed {
            freqs_idx %= len(freqs)
            if freqs_idx < 0 do freqs_idx += len(freqs) // wrap around
            reset_framerate()
        }

        // Pitch detection, use the first ringbuffer
        // TODO: run in a loop until all samples in ringbuffer are exhausted???
        // 44100 / 60fps = 735 samples, is 1000 a safe bet?
        new_count := read_ringbuffer(&pitch_ringbuffer, new_samples, 1000)

        if new_count > 0 {

            // move old samples back to make room for new samples
            copy(samples, samples[new_count:])

            // copy over new samples into the freed space
            copy(samples[u32(len(samples))-new_count:], new_samples[:new_count])

            // TODO: filter out high frequencies before autocorrelation?
            detected_freq = ac_pitch_detect(&ac, samples)
            detected_note = find_note(detected_freq)

            // Assume 1Hz error
            // freq_estimate, freq_estimate_error = kalman_filter(detected_freq_ac, freq_estimate, freq_estimate_error, 0.3)
        }

        target_freq = freqs[freqs_idx]
        note := find_note(f32(target_freq))

        // for strobe aim at a double interval, to show more of the wave shape and slow down the strobe movement
        target_interval = 2.0 * f64(SAMPLERATE) / target_freq

        // TODO: change to something meaningful ->
        // target_interval = min(max(target_interval, 1), 4096)

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            rl.DrawFPS(700, 20)

            draw_strobe_display(target_interval, show_pattern)
            draw_note(&note, {20, 20}, 64)


            // Show target frequency & interval
            rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", target_freq), {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, fmt.ctprintf("%.4f", target_interval), {20, 150}, 16, 0, rl.SKYBLUE)


            // Detected note - auto correlation
            if freq_in_range(detected_freq) {
                draw_note(&detected_note, {20, 250}, 48)
                rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", detected_freq), {20, 300}, 24, 0, rl.PURPLE)
            }

            draw_nsdf(rl.Rectangle{160, 200, SCREEN_WIDTH-180, 200}, &ac, peak)

            // draw_autocorrelation(rl.Rectangle{160, 450, SCREEN_WIDTH-180, 200}, &ac)

            draw_note_meter(rl.Rectangle{160, 400, 400, 100}, &detected_note, detected_freq)

            // rl.DrawTextEx(font, fmt.ctprintf("%.4f", flatness), {20, 620}, 24, 0, rl.PINK)
            // rl.DrawRectangleV({20, 650}, {100 * flatness, 4.0}, rl.PINK)

            rl.DrawTextEx(font, fmt.ctprintf("%.4f", clarity), {20, 660}, 24, 0, rl.LIME)
            rl.DrawRectangleV({20, 690}, {100 * clarity, 4.0}, rl.LIME)
        }
    }
}

