package app

import "core:fmt"
import "core:math"
import "core:strings"

import oef "../one_euro_filter"
import "../shared"
import rl "vendor:raylib"


main :: proc() {

    bass_freqs: []f32 = {
        41.20344, // E1
        55.00000, // A1
        73.41619, // D2
        97.99886, // G2
    }

    guitar_freqs: []f32 = {
        82.40689, // E2
        110.0000, // A2
        146.8324, // D3
        195.9977, // G3
        246.9417, // B3
        329.6276, // E4
    }

    ukulele_freqs: []f32 = {
        391.9954, // G4
        261.6256, // C4
        329.6276, // E4
        440.0000, // A4
    }

    freqs: []f32 = guitar_freqs
    freqs_idx := 0
    target_freq := freqs[freqs_idx]

    // TODO: remove
    // target_freq = 100
    // target_freq = 1975.533
    // target_freq = 82.4068892282175


    // set initial frequency
    freq_changed := true
    pitch_info := shared.PitchInfo{}
    cents_error_smooth := f32(0.0)

    detected_note := shared.Note{}
    detected_freq: f32 = 0.0
    freq_mean: f32 = 0.0
    freq_ewma: f32 = 0.0
    freq_measurements: [20]f32

    time := 0.0


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    // rl.SetTargetFPS(120)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    phase_tracker := shared.init_phase_tracker(f32(target_freq), SAMPLERATE, 2)
    defer shared.destroy_phase_tracker(&phase_tracker)

    phase_tracker_display := init_phase_tracker_display()
    defer destroy_phase_tracker_display(&phase_tracker_display)


    pitch_detector := shared.init_pitch_detector(SAMPLERATE)
    defer shared.destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(SAMPLERATE)
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    init_drawing_context()
    defer destroy_drawing_context()

    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, &phase_tracker)
    start_audio_capture(audio_capture)


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


        // TODO: turn off pitch detector if rms is weak?
        pitch_info = shared.run_pitch_detection(&pitch_detector, pitch_info)


        // TODO:
        // Update freq measurement 5 times per second
        // new_time := rl.GetTime()
        // Keep previous measurement if there is no detected note

        // TODO: detect note onset?

        // TODO: different clarity for locking onto pitch and tracking frequency?
        // TODO: apply impulse noise smoothing algorithm to freq measurement
        if shared.is_strong_pitch(pitch_info) &&
           detected_note.cents != pitch_info.detected_note.cents {
            detected_note = pitch_info.detected_note
            detected_freq = pitch_info.detected_freq
            target_freq = pitch_info.detected_note.frequency
            shared.set_phase_tracker_freq(&phase_tracker, target_freq)
        }


        if freq_changed {
            freqs_idx %= len(freqs)
            if freqs_idx < 0 do freqs_idx += len(freqs) // wrap around
            target_freq = freqs[freqs_idx]

            // TODO: remove
            // target_freq = 100
            // target_freq = 1975.533
            // target_freq = 82.4068892282175
            shared.set_phase_tracker_freq(&phase_tracker, target_freq)


            freq_changed = false
        }

        note := shared.find_note(f32(target_freq))


        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            shared.run_dft_analysis(&phase_tracker)

            draw_phase_tracker_display(&phase_tracker_display, &phase_tracker)


            draw_note(note, {20, 20}, 96)

            // Show target frequency
            rl.DrawTextEx(font, fmt.ctprintf("%.2fHz", target_freq), {20, 120}, 24, 0, rl.PURPLE)

            // draw_autocorrelation(rl.Rectangle{130, 50, SCREEN_WIDTH-180, 200}, &pitch_detector.autocorr)
            // draw_nsdf(rl.Rectangle{130, 280, SCREEN_WIDTH-200, 180}, &pitch_detector.nsdf, pitch_info.nsdf_peak)

            // Detected note
            draw_note(detected_note, {20, 300}, 64, rl.GOLD)

            // convert to cents, because we need the log scale
            if false {
                cents := shared.freq_to_cents(detected_freq)
                cents_error := cents - f32(detected_note.cents)
                draw_note_meter(
                    rl.Rectangle{500, 550, 200, 25},
                    detected_freq,
                    detected_note,
                    cents_error,
                    rl.BEIGE,
                )
                rl.DrawTextEx(
                    font,
                    fmt.ctprintf("%+.2fHz", pitch_info.detected_freq),
                    {400, 550},
                    22,
                    0,
                    rl.BEIGE,
                )
            }

            // if false {
            //     cents := freq_to_cents(freq_mean)
            //     cents_error := cents - f32(detected_note.cents)
            //     rl.DrawTextEx(font, fmt.ctprintf("%+.2fHz", freq_mean), {400, 580}, 22, 0, rl.PURPLE)
            //     draw_note_meter(rl.Rectangle{500, 580, 200, 25}, freq_mean, detected_note, cents_error, rl.PURPLE)
            // }

            if false {
                alpha: f32 = 0.5
                freq_ewma = shared.ewma_filter(pitch_info.detected_freq, alpha, freq_ewma)
                cents := shared.freq_to_cents(freq_ewma)
                cents_error := cents - f32(detected_note.cents)

                rl.DrawTextEx(
                    font,
                    fmt.ctprintf("%+.2fHz", freq_ewma),
                    {400, 610},
                    22,
                    0,
                    rl.SKYBLUE,
                )
                draw_note_meter(
                    rl.Rectangle{500, 610, 200, 25},
                    freq_ewma,
                    detected_note,
                    cents_error,
                    rl.SKYBLUE,
                )
            }


            rl.DrawTextEx(
                font,
                fmt.ctprintf("RMS %.4f", pitch_info.rms),
                {20, 620},
                24,
                0,
                rl.PINK,
            )
            rl.DrawRectangleV({20, 650}, {200 * pitch_info.rms, 4.0}, rl.PINK)
            rl.DrawRectangleLinesEx({20, 650, 200, 5}, 1, rl.PINK)

            rl.DrawTextEx(
                font,
                fmt.ctprintf("Cla %.4f", pitch_info.clarity),
                {20, 660},
                24,
                0,
                rl.ORANGE,
            )
            rl.DrawRectangleV({20, 690}, {200 * pitch_info.clarity, 4.0}, rl.ORANGE)
            rl.DrawRectangleLinesEx({20, 690, 200, 5}, 1, rl.ORANGE)

            rl.DrawFPS(SCREEN_WIDTH - 100, 10)
        }
    }
}
