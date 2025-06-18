package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:sort"
import "core:strings"

import rl "vendor:raylib"

import "../core"

guitar_std_notes: [6]string = {"E2", "A2", "D3", "G3", "B3", "E4"}
ukulele_std_notes: [4]string = {"G4", "C4", "E4", "A4"}
window_bg_color: u32 = 0x40414AFF
strobe_bg_color: u32 = 0x15141BFF


// Add gui controls to choose strobe colors
COLOR_CONTROLS :: false

run_raylib_app :: proc(config: ^Config) {
    // when ODIN_OS == .Darwin {
    //     setup_mac_app()
    // }

    target_freq_hz: f32 = config.target_freq_hz
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}

    // Note detected by the auto-correlation method
    // FIXME: assigning a dummy cents value for undefined note
    detected_note := core.Note {
        cents = -1,
    }

    // Target note for tuning via the strobe effect
    target_note := core.Note{}


    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.WINDOW_HIGHDPI})
    rl.InitWindow(650, 800 if COLOR_CONTROLS else 488, "Strobe Tuner")
    defer rl.CloseWindow()


    // Bring the window to front
    // [NSApp activateIgnoringOtherApps:YES];

    init_fonts()
    defer destroy_fonts()

    load_texture_atlas()
    defer unload_texture_atlas()


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
        strobe_bg_color,
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


    audio_devices := list_audio_devices(audio_capture)
    defer delete(audio_devices)

    audio_devices_str := strings.join(audio_devices[:], ";")
    defer delete(audio_devices_str)

    audio_device_choice: i32 = audio_capture.active_device
    audio_device_dropdown_active := false

    manual_detection_active := config.note_detection_mode == .MANUAL
    harmonic_mode_active := config.strobe_mode == .HARMONIC_MODE

    show_strobe_wheel := config.strobe_display_type == .SPINNING_WHEEL

    display_type_dropdown_active := false
    display_type_choice: i32 = i32(config.strobe_display_type)

    tuning_preset_dropdown_active := false
    tuning_preset_choice: i32 = i32(config.tuning_preset)

    strobe_speed_slider_value := config.strobe_speed

    selected_note_idx := 0


    note_low_state := false
    note_high_state := false


    color1 := rl.GetColor(config.strobe_color_1)
    color2 := rl.GetColor(config.strobe_color_2)

    // ---------------------------------------------------------------------------------------------


    // ------------------------------------------------
    //                   MAIN LOOP
    // ------------------------------------------------


    for !rl.WindowShouldClose() {

        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // Keep previous measurement if there is no detected note
        if core.is_strong_pitch(pitch_info) {
            if detected_note.cents != pitch_info.detected_note.cents {
                detected_note = pitch_info.detected_note
                if config.note_detection_mode == .AUTO {
                    target_note = detected_note
                    core.set_phase_comparator_freq(
                        phase_comparator,
                        target_note.frequency,
                        config.pitch_standard,
                        config.strobe_speed,
                        config.speed_multiplier,
                        config.strobe_mode,
                    )
                }
            }
            freq_estimation_active = true
        }

        if core.is_weak_pitch(pitch_info) {
            freq_estimation_active = false
        }

        // Keyboard arrow navigation for choosing target notes manually
        if config.note_detection_mode == .MANUAL {
            prev_target_note := target_note

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

            if prev_target_note != target_note {
                core.set_phase_comparator_freq(
                    phase_comparator,
                    target_note.frequency,
                    config.pitch_standard,
                    config.strobe_speed,
                    config.speed_multiplier,
                    config.strobe_mode,
                )
            }
        }

        // TODO: explanation
        out_of_range := detected_note.cents != target_note.cents

        pitch_cents_err := core.cents_deviation(pitch_info.detected_freq, target_note.frequency)

        // TODO: calculate cents deviation based on rounded freq to make the reading more steady?
        phase_freq_hz, phase_err_cents, no_change := core.run_phase_detection(phase_comparator)
        strobe_contrast_slider_value := math.log10(config.strobe_contrast)


        if rl.IsKeyPressed(.TAB) {
            if config.strobe_display_type == .CURVED_TRACKS {
                config.strobe_display_type = .SPINNING_WHEEL
            } else {
                config.strobe_display_type = .CURVED_TRACKS
            }
        }

        // Draw the GUI controls
        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.GetColor(window_bg_color))

            // TODO
            // when the detected note is too far away from the target, set a fixed spinning rate and attenuate strobe display ???
            draw_strobe_display(&strobe_display, phase_comparator, out_of_range)

            draw_note(target_note, {24, 320}, rl.WHITE if freq_estimation_active else rl.GRAY)

            if freq_estimation_active {
                note_low_state = core.schmitt_trigger_neg(note_low_state, pitch_cents_err, -8, -10)
                note_high_state = core.schmitt_trigger(note_high_state, pitch_cents_err, 8, 10)

                if note_low_state do rl.DrawTextEx(font_store.size_76, "◀", {0, 240}, 38, 0, rl.PURPLE)
                else if note_high_state do rl.DrawTextEx(font_store.size_76, "▶︎", {370, 240}, 38, 0, rl.PURPLE)
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

            // if config.note_detection_mode == .AUTO {
            //     rl.GuiSetState(i32(rl.GuiState.STATE_DISABLED))
            // }
            // if rl.GuiDropdownBox(
            //     {424, 130, 200, 30},
            //     "CHROMATIC;GUITAR STD;UKULELE STD",
            //     &tuning_preset_choice,
            //     tuning_preset_dropdown_active,
            // ) {
            //     tuning_preset_dropdown_active = !tuning_preset_dropdown_active
            // }
            // config.tuning_preset = TuningPreset(tuning_preset_choice)

            // rl.GuiSetState(i32(rl.GuiState.STATE_NORMAL))

            audio_device_dropdown_active = gui_dropdown(
                {424, 80},
                200,
                audio_devices[:],
                &audio_device_choice,
                audio_device_dropdown_active,
            )

            // TODO: add refresh button to show newly connected devices
            // if rl.GuiDropdownBox(
            //     {424, 20, 200, 30},
            //     cstring(raw_data(audio_devices_str)),
            //     &audio_device_choice,
            //     audio_device_dropdown_active,
            // ) {
            //     audio_device_dropdown_active = !audio_device_dropdown_active
            // }

            // Choose new audio input
            if audio_device_choice != audio_capture.active_device {
                switch_audio_device(audio_capture, audio_device_choice)
                core.flush_audio_capture_ringbuffer(&pitch_detector)
                core.flush_audio_capture_ringbuffer(phase_comparator)
            }

            setup_strobe_display(
                &strobe_display,
                config.strobe_contrast,
                config.strobe_display_type,
            )

            strobe_mode, strobe_mode_changed := gui_strobe_mode_toggle(
                {100, 410},
                config.strobe_mode,
            )
            if strobe_mode_changed {
                config.strobe_mode = strobe_mode
                core.set_phase_comparator_freq(
                    phase_comparator,
                    target_note.frequency,
                    config.pitch_standard,
                    config.strobe_speed,
                    config.speed_multiplier,
                    config.strobe_mode,
                )
            }

            note_detection_mode, note_detection_mode_changed := gui_note_detection_mode_toggle(
                {232, 410},
                config.note_detection_mode,
            )
            if note_detection_mode_changed {
                config.note_detection_mode = note_detection_mode
            }

            gui_contrast_slider({400, 400}, &strobe_contrast_slider_value)
            config.strobe_contrast = linalg.exp10(strobe_contrast_slider_value)

            gui_speed_slider({400, 432}, &strobe_speed_slider_value)
            if strobe_speed_slider_value != config.strobe_speed {
                config.strobe_speed = strobe_speed_slider_value
                core.set_phase_comparator_speed(phase_comparator, strobe_speed_slider_value)
            }

            if COLOR_CONTROLS {
                rl.GuiColorPicker({20, 500, 200, 200}, nil, &color1)
                config.strobe_color_1 = rl.ColorToInt(color1)
                rl.DrawTextEx(
                    font_store.size_32,
                    fmt.ctprintf("%x", config.strobe_color_1),
                    {20, 480},
                    16,
                    0,
                    rl.LIGHTGRAY,
                )

                rl.GuiColorPicker({300, 500, 200, 200}, nil, &color2)
                config.strobe_color_2 = rl.ColorToInt(color2)
                rl.DrawTextEx(
                    font_store.size_32,
                    fmt.ctprintf("%x", config.strobe_color_2),
                    {300, 480},
                    16,
                    0,
                    rl.LIGHTGRAY,
                )

                set_strobe_colors(&strobe_display, {config.strobe_color_1, config.strobe_color_2})
            }

            // TODO:
            // pitch standard - 440hz - number spinner
            // color theme dropdown
        }
    }
}
