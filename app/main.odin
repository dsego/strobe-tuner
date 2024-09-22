package app

import rl "vendor:raylib"
import "core:fmt"
import "core:strings"
import "core:math"


main :: proc() {

    bass_freqs: []f64 = {
        41.20344, // E1
        55.00000, // A1
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

    target_freq := 55.0
    freqs: []f64 = guitar_freqs


    target_interval := 0.0

    // target_freq = 2500
    // target_freq = 88
    // target_freq = 1567.982
    // target_freq = 7902.133

    // target_freq = 440.0000 // A
    // target_freq = 329.6276 // E
    // target_freq = 261.6256 // C
    // target_freq = 391.9954 // G

    // strobes: [dynamic]Strobe
    // defer delete(strobes)

    // s1 := init_strobe(target_freq, SAMPLERATE)
    // s2 := init_strobe(target_freq * 2.0, SAMPLERATE)
    // append(&strobes, s1)
    // append(&strobes, s2)


    pitch_detector := init_pitch_detector()
    defer destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    init_drawing_context()
    defer destroy_drawing_context()

    // init_strobe_display()
    // defer destroy_strobe_display()
    register_audio_node(audio_capture, &pitch_detector)
    start_audio_capture(audio_capture)

    show_pattern := false

    // flatness: f32

    // freq_estimate: f32 = 260.0
    // freq_estimate_error:f32 = 0.5

    // set initial frequency
    freq_changed := true
    pitch_info := PitchInfo{}
    cents_error_mean := f32(0.0)
    // smooth := init_smoothing(15)

    for !rl.WindowShouldClose() {

        // Toggle between scope view and strobe view
        if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
            show_pattern = !show_pattern
        }

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

            // reset_strobe_display()
            target_freq = freqs[freqs_idx]

            // set_strobes(target_freq)

            // for strobe aim at a double interval, to show more of the wave shape and slow down the strobe movement
            target_interval = 2.0 * f64(SAMPLERATE) / target_freq
            // target_interval = 4.0 * f64(SAMPLERATE) / target_freq

            freq_changed = false
        }
        note := find_note(f32(target_freq))

        pitch_info = run_pitch_detection(&pitch_detector, pitch_info)

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            rl.DrawFPS(700, 20)

            // draw_strobe_display(target_freq, target_interval, show_pattern)
            draw_note(note, {20, 20}, 64)


            // Show target frequency & interval
            rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", target_freq), {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, fmt.ctprintf("%.4f", target_interval), {20, 150}, 16, 0, rl.SKYBLUE)


            draw_nsdf(rl.Rectangle{160, 180, SCREEN_WIDTH-180, 200}, &pitch_detector.autocorr, pitch_info.nsdf_peak)
            // draw_autocorrelation(rl.Rectangle{160, 500, SCREEN_WIDTH-180, 200}, &pitch_detector.autocorr)


            // convert to cents, because we need the log scale
            cents := freq_to_cents(pitch_info.detected_freq)
            cents_error := cents - f32(pitch_info.detected_note.cents)


            draw_note_meter(rl.Rectangle{160, 420, 400, 100}, pitch_info, cents_error)

            // Smooth the meter by applying a weighted mean average
            // Applying to the relative cents error measurement instead of frequency to
            //  prevent the meter needle from jumping around.
            if math.is_inf(cents) {
                cents_error_mean = 0.0
            } else {
                alpha: f32 = 0.2
                cents_error_mean = ewma_filter(cents_error, alpha, cents_error_mean)
            }

            draw_note_meter(rl.Rectangle{160, 560, 400, 100}, pitch_info, cents_error_mean)
            // rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", pitch_info.detected_freq), {100, 550}, 18, 0, rl.GREEN)

            // rl.DrawTextEx(font, fmt.ctprintf("%.4f", flatness), {20, 620}, 24, 0, rl.PINK)
            // rl.DrawRectangleV({20, 650}, {100 * flatness, 4.0}, rl.PINK)

            rl.DrawTextEx(font, fmt.ctprintf("%.6f", pitch_info.clarity), {20, 660}, 24, 0, rl.LIME)
            rl.DrawRectangleV({20, 690}, {100 * pitch_info.clarity, 4.0}, rl.LIME)
        }
    }
}

