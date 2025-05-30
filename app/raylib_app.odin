package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "core:time"

import rl "vendor:raylib"

import "../core"

guitar_std_notes: [6]string = {"E2", "A2", "D3", "G3", "B3", "E4"}
ukulele_std_notes: [4]string = {"G4", "C4", "E4", "A4"}

run_raylib_app :: proc(config: ^Config) {

    target_freq_hz: f32 = config.target_freq_hz
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}

    // Note detected by the auto-correlation method
    detected_note := core.Note{}

    // Target note for tuning via the strobe effect
    target_note := core.Note{}


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.WINDOW_HIGHDPI})
    rl.InitWindow(800, 600, "Strobe Tuner")
    defer rl.CloseWindow()

    init_fonts()
    defer destroy_fonts()


    // GUI styles
    root_dir := filepath.dir(#file)
    defer delete(root_dir)
    raylib_style_path := filepath.join({root_dir, "../assets/style_cyber.rgs"})
    defer delete(raylib_style_path)

    rl.GuiLoadStyle(cstring(raw_data(raylib_style_path)))
    rl.GuiSetFont(font_store.size_32)
    rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 16)

    //  ------------------

    phase_comparator := core.init_phase_comparator(
        target_freq_hz,
        f32(config.samplerate),
        config.strobe_count,
        config.strobe_mode,
        config.apply_attenuation,
    )
    defer core.destroy_phase_comparator(phase_comparator)

    strobe_display := init_strobe_display(
        {0, 0},
        {400, 400},
        {config.strobe_color_1, config.strobe_color_2},
        config.strobe_bg_color,
        config.strobe_contrast,
        config.strobe_display_type,
    )
    defer destroy_strobe_display(&strobe_display)


    pitch_detector := core.init_pitch_detector(config.samplerate, config.pitch_detect_fft_size)
    defer core.destroy_pitch_detector(&pitch_detector)


    ok, audio_capture := init_audio_capture(u32(config.samplerate))
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, phase_comparator)
    start_audio_capture(audio_capture)

    core.set_phase_comparator_freq(
        phase_comparator,
        target_freq_hz,
        config.pitch_standard,
        config.strobe_speed,
        config.speed_multiplier,
        config.strobe_mode,
    )

    target_note = core.find_note(target_freq_hz)


    // --- GUI CONTROLS ----------------------------------------------------------------------------

    manual_detection_active := config.note_detection_mode == .MANUAL
    harmonic_mode_active := config.strobe_mode == .HARMONIC_MODE

    show_strobe_wheel := config.strobe_display_type == .SPINNING_WHEEL

    display_type_dropdown_active := false
    display_type_choice: i32 = i32(config.strobe_display_type)

    tuning_preset_dropdown_active := false
    tuning_preset_choice: i32 = i32(config.tuning_preset)

    strobe_speed_slider_value := config.strobe_speed

    selected_note_idx := 0


    // ---------------------------------------------------------------------------------------------

    // MAIN LOOP
    for !rl.WindowShouldClose() {

        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // TODO: detect strobe mode change and reset phase comparator
        // TODO: detect strobe speed change and reset phase comparator

        // Keep previous measurement if there is no detected note
        if core.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                if config.note_detection_mode == .AUTO {
                    target_note = detected_note
                }
                core.set_phase_comparator_freq(
                    phase_comparator,
                    target_note.frequency,
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
            if config.tuning_preset == .CHROMATIC {
                if rl.IsKeyPressed(.UP) {
                    target_note = core.octave_up(target_note)
                } else if rl.IsKeyPressed(.DOWN) {
                    target_note = core.octave_down(target_note)
                } else if rl.IsKeyPressed(.LEFT) {
                    target_note = core.prev_chromatic_note(target_note)
                } else if rl.IsKeyPressed(.RIGHT) {
                    target_note = core.next_chromatic_note(target_note)
                }
            } else {
                tuning_notes: []string = {}
                length := 0

                if config.tuning_preset == .UKULELE_STD do tuning_notes = ukulele_std_notes[:]
                if config.tuning_preset == .GUITAR_STD do tuning_notes = guitar_std_notes[:]

                if rl.IsKeyPressed(.LEFT) {
                    selected_note_idx -= 1
                } else if rl.IsKeyPressed(.RIGHT) {
                    selected_note_idx += 1
                }
                selected_note_idx = selected_note_idx %% len(tuning_notes)
                selected_note := tuning_notes[selected_note_idx]
                target_note, ok = core.new_note(selected_note)
            }
        }

        // TODO: explanation
        out_of_range := detected_note.cents != target_note.cents
        pitch_cents_err := core.cents_deviation(pitch_info.detected_freq, target_note.frequency)

        phase_freq_hz, phase_err_cents := core.run_phase_detection(phase_comparator)
        strobe_contrast_slider_value := math.log10(config.strobe_contrast)

        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.GetColor(config.window_bg_color))

            // TODO
            // when the detected note is too far away from the target, set a fixed spinning rate and attenuate strobe display ???
            draw_strobe_display(&strobe_display, phase_comparator, out_of_range)

            draw_note(target_note, {24, 320}, rl.WHITE if freq_estimation_active else rl.GRAY)

            // TODO
            // make sure it doesn't flash, build in some thresholds or smooth step
            if freq_estimation_active {
                if pitch_cents_err < -10 do rl.DrawTextEx(font_store.size_76, "◀", {0, 240}, 38, 0, rl.PURPLE)
                if pitch_cents_err > 10 do rl.DrawTextEx(font_store.size_76, "▶︎", {370, 240}, 38, 0, rl.PURPLE)
            }

            // TODO:
            // --- if detected note is outside of measurement scope -> use estimated freq
            // --- if detected note is close to target note -> use phase diff for fine freq display

            rl.DrawTextEx(
                font_store.size_48,
                fmt.ctprintf("Cents\n%+.1f", phase_err_cents),
                {128, 340},
                24,
                0,
                rl.GREEN,
            )
            rl.DrawTextEx(
                font_store.size_48,
                fmt.ctprintf("Hertz\n%+.1f ", phase_freq_hz),
                {256, 340},
                24,
                0,
                rl.PURPLE,
            )


            rl.GuiToggle(
                {424, 20, 120, 30},
                "MANUAL" if manual_detection_active else "AUTO",
                &manual_detection_active,
            )
            if manual_detection_active {
                config.note_detection_mode = .MANUAL
            } else {
                config.note_detection_mode = .AUTO
            }

            rl.GuiToggle(
                {424, 100, 120, 30},
                "HARMONIC" if harmonic_mode_active else "VERNIER",
                &harmonic_mode_active,
            )

            strobe_mode_changed := false
            if harmonic_mode_active && config.strobe_mode != .HARMONIC_MODE {
                config.strobe_mode = .HARMONIC_MODE
                strobe_mode_changed = true
            } else if !harmonic_mode_active && config.strobe_mode != .VERNIER_MODE {
                config.strobe_mode = .VERNIER_MODE
                strobe_mode_changed = true
            }

            if strobe_mode_changed {
                core.set_phase_comparator_freq(
                    phase_comparator,
                    target_note.frequency,
                    config.pitch_standard,
                    config.strobe_speed,
                    config.speed_multiplier,
                    config.strobe_mode,
                )
            }

            rl.DrawTextEx(font_store.size_32, "Contrast", {424, 140}, 16, 0, rl.GRAY)
            rl.GuiSlider({424, 160, 120, 15}, "", "", &strobe_contrast_slider_value, 0.0, 5.0)
            config.strobe_contrast = linalg.exp10(strobe_contrast_slider_value)

            rl.DrawTextEx(font_store.size_32, "Sensitivity", {424, 190}, 16, 0, rl.GRAY)
            rl.GuiSlider({424, 210, 120, 15}, "", "", &strobe_speed_slider_value, 0.001, 0.05)
            if strobe_speed_slider_value != config.strobe_speed {
                config.strobe_speed = strobe_speed_slider_value
                core.set_phase_comparator_speed(phase_comparator, strobe_speed_slider_value)
            }


            rl.GuiToggle(
                {424, 250, 120, 30},
                "WHEEL" if show_strobe_wheel else "TRACKS",
                &show_strobe_wheel,
            )
            if show_strobe_wheel {
                config.strobe_display_type = StrobeDisplayType.SPINNING_WHEEL
            } else {
                config.strobe_display_type = StrobeDisplayType.CURVED_TRACKS
            }

            // TODO: when changing to guitar, should reset starting note to low E

            if config.note_detection_mode == .AUTO {
                rl.GuiSetState(i32(rl.GuiState.STATE_DISABLED))
            }
            if rl.GuiDropdownBox(
                {424, 60, 120, 30},
                "CHROMATIC;GUITAR STD;UKULELE STD",
                &tuning_preset_choice,
                tuning_preset_dropdown_active,
            ) {
                tuning_preset_dropdown_active = !tuning_preset_dropdown_active
            }
            config.tuning_preset = TuningPreset(tuning_preset_choice)

            rl.GuiSetState(i32(rl.GuiState.STATE_NORMAL))

            setup_strobe_display(
                &strobe_display,
                config.strobe_contrast,
                config.strobe_display_type,
            )

            // pitch standard - 440hz - number spinner
            // microphone / audio input dropdown
            // color theme dropdown
        }
    }
}
