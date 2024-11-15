package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

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
    freq_changed_manually := true
    pitch_info := shared.PitchInfo{}
    cents_error_smooth := f32(0.0)

    detected_note := shared.Note{}
    detected_freq: f32 = 0.0
    freq_measurements: [20]f32

    freq_estimation_active := false
    freq_ewma: f32 = 0.0
    // freq_smoother := shared.init_smooth_block(512)


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    // rl.SetTargetFPS(120)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    phase_tracker := shared.init_phase_tracker(f32(target_freq), SAMPLERATE, STROBE_COUNT)
    defer shared.destroy_phase_tracker(phase_tracker)

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
    register_audio_node(audio_capture, phase_tracker)
    start_audio_capture(audio_capture)


    // oe_filter_ptr := oef.Create(60, 1, 1, 1)
    // defer oef.Destroy(oe_filter_ptr)


    for !rl.WindowShouldClose() {

        // Pick next or previous ukulele string
        if rl.IsKeyPressed(rl.KeyboardKey.RIGHT) {
            freqs_idx += 1
            freq_changed_manually = true
        }
        if rl.IsKeyPressed(rl.KeyboardKey.LEFT) {
            freqs_idx -= 1
            freq_changed_manually = true
        }


        // TODO: turn off pitch detector if rms is weak?
        pitch_info = shared.run_pitch_detection(&pitch_detector, pitch_info)


        // Keep previous measurement if there is no detected note
        // TODO: detect note onset?
        // TODO: different clarity for locking onto pitch and tracking frequency?
        if shared.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                target_freq = pitch_info.detected_note.frequency
                shared.set_phase_tracker_freq(phase_tracker, target_freq)
            }
            freq_estimation_active = true
        }

        if shared.is_weak_pitch(pitch_info) {
            freq_estimation_active = false
        }

        if freq_changed_manually {
            freqs_idx %= len(freqs)
            if freqs_idx < 0 do freqs_idx += len(freqs) // wrap around
            target_freq = freqs[freqs_idx]

            // TODO: remove
            // target_freq = 100
            // target_freq = 1975.533
            // target_freq = 82.4068892282175
            shared.set_phase_tracker_freq(phase_tracker, target_freq)
            freq_changed_manually = false
        }

        note := shared.find_note(f32(target_freq))

        // TODO: detect if new note
        cents_error: f32 = 0.0
        if freq_estimation_active {
            alpha: f32 = 0.3
            if freq_ewma < 1 {
                freq_ewma = pitch_info.detected_freq
            } else {
                freq_ewma = shared.ewma_filter(pitch_info.detected_freq, alpha, freq_ewma)
                cents := shared.freq_to_cents(freq_ewma)
                cents_error = cents - f32(detected_note.cents)
            }

        } else {
            freq_ewma = 0.0
        }

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            shared.run_dft_analysis(phase_tracker)

            rl.ClearBackground(rl.BLACK)
            draw_phase_tracker_display(&phase_tracker_display, phase_tracker)
            // draw_note(note, {20, 20}, 96)

            // draw_autocorrelation(rl.Rectangle{130, 50, SCREEN_WIDTH-180, 200}, &pitch_detector.autocorr)
            // draw_nsdf(rl.Rectangle{130, 280, SCREEN_WIDTH-200, 180}, &pitch_detector.nsdf, pitch_info.nsdf_peak)

            // Detected note
            draw_note(detected_note, {20, 300}, 64, rl.GOLD, rl.GRAY, freq_estimation_active)


            // fmt.println(smooth_freq, pitch_info.detected_freq)


            rl.DrawTextEx(font, fmt.ctprintf("%+.1fHz", freq_ewma), {400, 410}, 22, 0, rl.GOLD)
            draw_note_meter(
                rl.Rectangle{500, 410, 200, 25},
                detected_note,
                cents_error,
                rl.GOLD,
                rl.GRAY,
                active = freq_estimation_active,
            )

            rl.DrawTextEx(
                font,
                fmt.ctprintf("RMS %.4f", pitch_info.rms),
                {20, 420},
                24,
                0,
                rl.PINK,
            )
            rl.DrawRectangleV({20, 450}, {200 * pitch_info.rms, 4.0}, rl.PINK)
            rl.DrawRectangleLinesEx({20, 450, 200, 5}, 1, rl.PINK)

            rl.DrawTextEx(
                font,
                fmt.ctprintf("Cla %.4f", pitch_info.clarity),
                {20, 460},
                24,
                0,
                rl.ORANGE,
            )
            rl.DrawRectangleV({20, 490}, {200 * pitch_info.clarity, 4.0}, rl.ORANGE)
            rl.DrawRectangleLinesEx({20, 490, 200, 5}, 1, rl.ORANGE)

            rl.DrawFPS(SCREEN_WIDTH - 100, 10)
        }
    }
}
