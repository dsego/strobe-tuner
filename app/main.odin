package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

import "../core"
import rl "vendor:raylib"


main :: proc() {
    target_freq_hz: f32 = 110.0

    freq_changed_manually := true
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}
    detected_note := core.Note{}
    selected_note := core.Note{}

    timestamp := time.now()


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    phase_tracker := core.init_phase_tracker(
        target_freq_hz,
        f32(config.samplerate),
        config.strobe_count,
        config.strobe_window_size,
        config.strobe_mode,
    )
    defer core.destroy_phase_tracker(phase_tracker)

    phase_tracker_display := init_phase_tracker_display()
    defer destroy_phase_tracker_display(&phase_tracker_display)


    pitch_detector := core.init_pitch_detector(config.samplerate, config.pitch_detect_fft_size)
    defer core.destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(u32(config.samplerate))
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    init_drawing_context()
    defer destroy_drawing_context()

    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, phase_tracker)
    start_audio_capture(audio_capture)

    core.set_phase_tracker_freq(phase_tracker, target_freq_hz)

    freq_ewma := core.init_ewma(alpha = 0.05)
    cents_ewma := core.init_ewma(alpha = 0.05)

    measured_freq: f32 = 0.0
    measured_cents: f32 = 0.0
    freq_smooth: f32 = 0.0
    cents_err_smooth: f32 = 0.0

    for !rl.WindowShouldClose() {
        seconds_elapsed := time.duration_seconds(time.since(timestamp))

        refresh_measurements := false
        if seconds_elapsed > 0.1 {
            refresh_measurements = true
            timestamp = time.now()
        }

        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // Keep previous measurement if there is no detected note
        if core.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                target_freq_hz = pitch_info.detected_note.frequency
                core.set_phase_tracker_freq(phase_tracker, target_freq_hz)
            }
            freq_estimation_active = true
            core.reset_ewma(&cents_ewma)
            core.reset_ewma(&freq_ewma)
        }

        if core.is_weak_pitch(pitch_info) {
            freq_estimation_active = false
        }

        // prev_note := core.prev_note_in_scale(detected_note)
        // prev_note_2 := core.prev_note_in_scale(prev_note)
        // next_note := core.next_note_in_scale(detected_note)
        // next_note_2 := core.next_note_in_scale(next_note)
        core.run_dft_analysis(phase_tracker)

        if refresh_measurements {
            measured_freq = phase_tracker.bands[0].estimated_freq_hz
            measured_cents = phase_tracker.bands[0].err_cents
            freq_smooth = core.ewma_filter(&freq_ewma, measured_freq)
            cents_err_smooth = core.ewma_filter(&cents_ewma, measured_cents)
        }

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            draw_phase_tracker_display(&phase_tracker_display, phase_tracker)
            draw_note(
                detected_note,
                {280, 340},
                96,
                rl.WHITE if freq_estimation_active else rl.GRAY,
            )

            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.1fc", cents_err_smooth),
                {400, 340},
                24,
                0,
                rl.WHITE,
            )

            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.1fc", measured_cents),
                {500, 340},
                24,
                0,
                rl.LIGHTGRAY,
            )

            rl.DrawTextEx(font, fmt.ctprintf("%+.1fHz", freq_smooth), {400, 400}, 24, 0, rl.WHITE)
            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.1fHz", measured_freq),
                {500, 400},
                24,
                0,
                rl.LIGHTGRAY,
            )

            // Detected note
            /*
            draw_note(prev_note_2, {160, 460}, 48, rl.GRAY, false)
            draw_note(prev_note, {220, 460}, 48, rl.GRAY, false)
            draw_note(detected_note, {280, 460}, 48, rl.GRAY, false)
            draw_note(next_note, {340, 460}, 48, rl.GRAY, false)
            draw_note(next_note_2, {400, 460}, 48, rl.GRAY, false)
            */
        }
    }
}
