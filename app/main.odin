package app

import "core:fmt"
import "core:strings"
import "core:math"

import rl "vendor:raylib"
import oef "../one_euro_filter"



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

    freqs: []f64 = bass_freqs
    freqs_idx := 0
    target_freq := freqs[freqs_idx]

    target_interval := 0.0


    strobe := init_strobe(f32(target_freq), SAMPLERATE, 2)
    defer destroy_strobe(&strobe)

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

    strobe_display := init_strobe_display(MAX_SPECTRUM_DISPLAY_LEN, &strobe)
    defer destroy_strobe_display(&strobe_display)

    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, &strobe)

    start_audio_capture(audio_capture)

    // set initial frequency
    freq_changed := true
    pitch_info := PitchInfo{}
    cents_error_smooth := f32(0.0)

    // oe_filter_ptr := oef.Create(60, 1, 1, 1)
    // defer oef.Destroy(oe_filter_ptr)


    for !rl.WindowShouldClose() {

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


            target_freq = freqs[freqs_idx]

            set_strobe_freq(&strobe, f32(target_freq), SAMPLERATE)


            freq_changed = false
        }

        note := find_note(f32(target_freq))

        // TODO: turn of pitch detector if rms is weak?
        prev_pitch_info := PitchInfo{}
        pitch_info = run_pitch_detection(&pitch_detector, pitch_info)


        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            rl.DrawFPS(700, 20)


            draw_strobe_display(&strobe_display)
            draw_note(note, {20, 20}, 64)


            // Show target frequency & interval
            rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", target_freq), {20, 100}, 32, 0, rl.PURPLE)
            rl.DrawTextEx(font, fmt.ctprintf("%.4f", target_interval), {20, 150}, 16, 0, rl.SKYBLUE)


            // draw_autocorrelation(rl.Rectangle{130, 50, SCREEN_WIDTH-180, 200}, &pitch_detector.autocorr)
            // draw_nsdf(rl.Rectangle{130, 300, SCREEN_WIDTH-180, 200}, &pitch_detector.autocorr, pitch_info.nsdf_peak)

            // convert to cents, because we need the log scale
            cents := freq_to_cents(pitch_info.detected_freq)
            cents_error := cents - f32(pitch_info.detected_note.cents)


            draw_note_meter(rl.Rectangle{300, 500, 400, 100}, pitch_info, cents_error)


            // Smooth the meter by applying a weighted mean average
            // Applying to the relative cents error measurement instead of frequency to
            //  prevent the meter needle from making big jumps.
            if math.is_inf(cents) {
                cents_error_smooth = 0.0
            } else {
                alpha: f32 = 0.1
                cents_error_smooth = ewma_filter(cents_error, alpha, cents_error_smooth)
                // cents_error_smooth = oef.Do(oe_filter_ptr, cents_error)
            }

            draw_note_meter(rl.Rectangle{300, 600, 400, 100}, pitch_info, cents_error_smooth)
            rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", pitch_info.detected_freq), {100, 550}, 18, 0, rl.GREEN)

            rl.DrawTextEx(font, fmt.ctprintf("RMS %.4f", pitch_info.rms), {20, 620}, 24, 0, rl.PINK)
            rl.DrawRectangleV({20, 650}, {200 * pitch_info.rms, 4.0}, rl.PINK)
            rl.DrawRectangleLinesEx({20, 650, 200, 5}, 1, rl.PINK)

            rl.DrawTextEx(font, fmt.ctprintf("Cla %.4f", pitch_info.clarity), {20, 660}, 24, 0, rl.ORANGE)
            rl.DrawRectangleV({20, 690}, {200 * pitch_info.clarity, 4.0}, rl.ORANGE)
            rl.DrawRectangleLinesEx({20, 690, 200, 5}, 1, rl.ORANGE)
        }
    }
}

