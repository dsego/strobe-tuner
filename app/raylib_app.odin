package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:path/filepath"

import "../core"
import rl "vendor:raylib"

root_dir := filepath.dir(#file)
raylib_style_path := filepath.join({root_dir, "../assets/style_dark.txt.rgs"})


run_raylib_app :: proc() {
    target_freq_hz: f32 = 110.0
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}
    detected_note := core.Note{}

    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
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
        config.pitch_standard,
    )
    defer core.destroy_phase_tracker(phase_tracker)

    spinning_wheel_display := init_spinning_wheel_display()
    defer destroy_spinning_wheel_display(&spinning_wheel_display)


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
        config.base_sensitivity,
        config.sensitivity_multiplier,
    )

    text_buffer: [1024]u8

    for !rl.WindowShouldClose() {
        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // Keep previous measurement if there is no detected note
        if core.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                target_freq_hz = pitch_info.detected_note.frequency
                core.set_phase_tracker_freq(
                    phase_tracker,
                    target_freq_hz,
                    config.pitch_standard,
                    config.base_sensitivity,
                    config.sensitivity_multiplier,
                )
            }
            freq_estimation_active = true
        }

        if core.is_weak_pitch(pitch_info) {
            freq_estimation_active = false
        }

        core.run_dft_analysis(phase_tracker)

        base_band := phase_tracker.bands[0]

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.BLACK)

            draw_spinning_wheel_display(&spinning_wheel_display, phase_tracker)
            draw_cent_deviation(phase_tracker)

            draw_note(
                detected_note,
                {160, 280},
                96,
                rl.WHITE if freq_estimation_active else rl.GRAY,
            )
            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.1fc", base_band.err_cents),
                {300, 300},
                24,
                0,
                rl.GREEN,
            )
            rl.DrawTextEx(
                font,
                fmt.ctprintf("%+.1fHz", base_band.estimated_freq_hz),
                {400, 300},
                24,
                0,
                rl.PURPLE,
            )
        }
    }
}
