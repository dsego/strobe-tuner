package app

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../core"
import rl "vendor:raylib"


run_raylib_app :: proc() {
    // target_freq_hz: f32 = 329.6275569128699
    target_freq_hz: f32 = 110.0
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}

    // Note detected by the auto-correlation method
    detected_note := core.Note{}

    // Target note for tuning via the strobe effect
    target_note := core.Note{}

    // root_dir := filepath.dir(#file)
    // raylib_style_path := filepath.join({root_dir, "../assets/style_dark.txt.rgs"})

    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.WINDOW_HIGHDPI})
    // rl.SetTargetFPS(120)
    rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 16)
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()

    init_font(192)
    defer destroy_font()


    phase_tracker := core.init_phase_tracker(
        target_freq_hz,
        f32(config.samplerate),
        config.strobe_count,
        config.strobe_window_size,
        config.strobe_mode,
    )
    defer core.destroy_phase_tracker(phase_tracker)


    strobe_display := init_strobe_display(
        {0, 0},
        {SCREEN_WIDTH, 240},
        config.strobe_color,
        config.strobe_bg_color,
        config.strobe_contrast,
    )
    defer destroy_strobe_display(&strobe_display)


    pitch_detector := core.init_pitch_detector(config.samplerate, config.pitch_detect_fft_size)
    defer core.destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(u32(config.samplerate))
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, phase_tracker)
    start_audio_capture(audio_capture)

    core.set_phase_tracker_freq(
        phase_tracker,
        target_freq_hz,
        config.pitch_standard,
        config.strobe_speed,
        config.speed_multiplier,
        config.strobe_mode,
    )

    target_note = core.find_note(target_freq_hz)

    always_track_detected_note := false

    for !rl.WindowShouldClose() {

        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // Keep previous measurement if there is no detected note
        if core.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                if config.note_detection_mode == .AUTO {
                    target_note = detected_note
                }
                core.set_phase_tracker_freq(
                    phase_tracker,
                    detected_note.frequency if always_track_detected_note else target_note.frequency,
                    config.pitch_standard,
                    config.strobe_speed,
                    config.speed_multiplier,
                    config.strobe_mode,
                )

            }
            freq_estimation_active = true
        }

        if core.is_weak_pitch(pitch_info) {
            freq_estimation_active = false
        }

        if config.note_detection_mode == .MANUAL {
            // TODO: let the user choose the active note
            // if rl.IsKeyPressed(.LEFT) {
            // }
            // if rl.IsKeyPressed(.RIGHT) {
            // }
        }

        // TODO: explanation
        out_of_range := detected_note.cents != target_note.cents

        core.run_phase_detection(phase_tracker, config.apply_attenuation)
        base_band := phase_tracker.bands[0]

        err_cents := core.cents_deviation(base_band.estimated_freq_hz, target_note.frequency)

        // update_strobe_display(&strobe_display, phase_tracker, false)

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.GetColor(config.window_bg_color))

            draw_strobe_display(&strobe_display, phase_tracker, out_of_range)

            draw_note(target_note, {24, 280}, 96, rl.WHITE if freq_estimation_active else rl.GRAY)

            rl.DrawTextEx(
                font,
                fmt.ctprintf(
                    "Detected: %v%v%v",
                    detected_note.name,
                    "♯" if detected_note.is_accidental else "",
                    detected_note.octave,
                ),
                {24, 380},
                18,
                0,
                rl.GRAY,
            )
            rl.DrawTextEx(
                font,
                // Deviation from the target frequency, not the detected frequency
                fmt.ctprintf("Cents\n%+.1f", err_cents),
                {128, 300},
                24,
                0,
                rl.GREEN,
            )
            rl.DrawTextEx(
                font,
                fmt.ctprintf("Hertz\n%+.1f", base_band.estimated_freq_hz),
                {256, 300},
                24,
                0,
                rl.PURPLE,
            )
        }
    }
}
