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

    phase_tracker := shared.init_phase_tracker(
        f32(target_freq),
        f32(config.samplerate),
        config.strobe_count,
        config.strobe_window_size,
        config.strobe_mode,
    )
    defer shared.destroy_phase_tracker(phase_tracker)

    phase_tracker_display := init_phase_tracker_display()
    defer destroy_phase_tracker_display(&phase_tracker_display)


    pitch_detector := shared.init_pitch_detector(config.samplerate, config.pitch_detect_fft_size)
    defer shared.destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(u32(config.samplerate))
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
        new_note_detected := false
        if shared.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                new_note_detected = true
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

            shared.set_phase_tracker_freq(phase_tracker, target_freq)
            freq_changed_manually = false
        }

        note := shared.find_note(f32(target_freq))

        cents_error: f32 = 0.0
        if freq_estimation_active {
            alpha: f32 = 0.3
            if freq_ewma < 1 || new_note_detected {
                freq_ewma = pitch_info.detected_freq
            } else {
                freq_ewma = shared.ewma_filter(pitch_info.detected_freq, alpha, freq_ewma)
                cents := shared.freq_to_cents(freq_ewma)
                cents_error = cents - f32(detected_note.cents)
            }

        } else {
            freq_ewma = 0.0
        }
        shared.run_dft_analysis(phase_tracker)

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)
            draw_phase_tracker_display(&phase_tracker_display, phase_tracker)

            prev_note := shared.prev_note_in_scale(detected_note)
            prev_note_2 := shared.prev_note_in_scale(prev_note)
            next_note := shared.next_note_in_scale(detected_note)
            next_note_2 := shared.next_note_in_scale(next_note)

            // Detected note
            draw_note(prev_note_2, {160, 400}, 48, rl.GRAY, false)
            draw_note(prev_note, {220, 400}, 48, rl.GRAY, false)
            draw_note(detected_note, {280, 380}, 96, rl.WHITE if freq_estimation_active else rl.GRAY)
            draw_note(next_note, {360, 400}, 48, rl.GRAY, false)
            draw_note(next_note_2, {420, 400}, 48, rl.GRAY, false)
        }
    }
}
