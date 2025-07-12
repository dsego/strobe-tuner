// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package app

import "core:c/libc"
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
strobe_bg_color: u32 = 0x15161AFF


INTERVAL_OPTIONS: [3][MAX_INTERVALS]f32 : {
    {1, 2, 4, 0, 0, 0, 0, 0},
    {1, 1.5, 2, 0, 0, 0, 0, 0},
    {1, 2, 3, 0, 0, 0, 0, 0},
}


// Add gui controls to choose strobe colors
COLOR_CONTROLS :: false

run_raylib_app :: proc(config: ^Config) {
    target_freq_hz: f32 = config.target_freq_hz
    freq_estimation_active := false

    pitch_info := core.PitchInfo{}
    last_good_pitch_info := core.PitchInfo{}

    // Note detected by the auto-correlation method
    // FIXME: assigning a dummy cents value for undefined note
    detected_note := core.Note {
        cents = -1,
    }

    // Target note for tuning via the strobe effect
    target_note := core.Note{}

    when ODIN_OS == .Darwin {
        // setup_mac_app()
        // theme_mac_titlebar(rl.GetWindowHandle(), strobe_bg_color)
    }

    rl.SetTraceLogLevel(rl.TraceLogLevel.WARNING)
    rl.SetConfigFlags({.WINDOW_HIGHDPI})
    rl.InitWindow(488, 800 if COLOR_CONTROLS else 532, APP_NAME)
    rl.SetTargetFPS(120)
    defer rl.CloseWindow()

    init_fonts()
    defer destroy_fonts()

    load_texture_atlas()
    defer unload_texture_atlas()

    //  --------------------------------------------------------------------------------------------

    phase_comparator := core.init_phase_comparator(
        target_freq_hz,
        f32(config.samplerate),
        config.strobe_intervals[:],
        config.strobe_mode,
    )
    defer core.destroy_phase_comparator(phase_comparator)


    strobe_display := init_strobe_display(
        {0, 0},
        {488, 560},
        get_strobe_colors(config),
        strobe_bg_color,
        config.strobe_contrast,
        config.strobe_display_type,
    )
    defer destroy_strobe_display(&strobe_display)


    pitch_detector := core.init_pitch_detector(
        config.samplerate,
        config.pitch_detect_fft_size,
        config.pitch_detection_clarity_high,
        config.pitch_detection_rms_high,
        config.pitch_detection_clarity_low,
        config.pitch_detection_rms_low,
    )
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

    audio_device_dropdown_index: int = 0
    audio_devices: [dynamic]GuiOption = {}
    defer delete(audio_devices)

    device_count := audio_device_count()
    for i in 0 ..< device_count {
        info := audio_device_info(i)
        if info.maxInputChannels > 0 {
            append(&audio_devices, GuiOption{i, string(info.name)})
        }
        if i == audio_capture.active_device {
            audio_device_dropdown_index = int(i)
        }
    }

    selected_note_idx := 0
    audio_device_dropdown_active := false
    tuning_preset_dropdown_active := false


    note_low_state := false
    note_high_state := false


    strobe_speed_slider_value := config.strobe_speed
    tuning_preset_choice := int(config.tuning_preset)
    color1 := rl.GetColor(config.strobe_color_1)
    color2 := rl.GetColor(config.strobe_color_2)

    interval_options := INTERVAL_OPTIONS
    config_changed := false

    // ---------------------------------------------------------------------------------------------


    // ------------------------------------------------
    //                   MAIN LOOP
    // ------------------------------------------------


    for !rl.WindowShouldClose() {

        if rl.IsKeyPressed(.R) {
            config_changed = true
            fmt.println("Reset config to defaults")
            config^ = get_config_defaults()
        }

        if rl.IsKeyPressed(.A) {
            config.auto_gain_control = !config.auto_gain_control
            fmt.println("Auto gain control:", config.auto_gain_control ? "ON" : "OFF")
        }

        super_key_down := rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER)
        pref_key_combo := super_key_down && rl.IsKeyPressed(.COMMA)
        if pref_key_combo {
            shift_key_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)

            // [Cmd + Shift + ,] - Reload config
            if shift_key_down {
                config^ = load_config()
                config_changed = true

                // [Cmd + ,] - Open config editor
            } else {
                // TODO: support windows & linux
                when ODIN_OS == .Darwin {
                    config_path := get_config_path()
                    defer delete(config_path)
                    libc.system(fmt.ctprintf("open -a TextEdit \"%s\"", config_path))
                }
            }
        }

        if config_changed {
            strobe_speed_slider_value = config.strobe_speed
            tuning_preset_choice = int(config.tuning_preset)
            set_strobe_colors(&strobe_display, get_strobe_colors(config))
            core.set_phase_comparator_intervals(phase_comparator, config.strobe_intervals[:])
            core.set_phase_comparator_freq(
                phase_comparator,
                target_note.frequency,
                config.pitch_standard,
                config.strobe_speed,
                config.speed_multiplier,
                config.strobe_mode,
            )
            config_changed = false // !!!!
        }

        pitch_info = core.run_pitch_detection(&pitch_detector, pitch_info)

        // Keep previous measurement if there is no detected note
        if pitch_info.is_strong_pitch {
            last_good_pitch_info = pitch_info
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

        if pitch_info.is_weak_pitch {
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

        // Ignore return values - the NSDF provides a steadier Hz/Cents response
        core.run_phase_detection(phase_comparator)


        if rl.IsKeyPressed(.TAB) {
            if config.strobe_display_type == .CURVED_TRACKS {
                config.strobe_display_type = .SPINNING_WHEEL
            } else {
                config.strobe_display_type = .CURVED_TRACKS
            }
        }

        if rl.IsKeyPressed(.I) && config.strobe_mode == .HARMONIC_MODE {
            config.strobe_intervals_index += 1
            if config.strobe_intervals_index >= len(interval_options) do config.strobe_intervals_index = 0
            config.strobe_intervals = interval_options[config.strobe_intervals_index]
            core.set_phase_comparator_intervals(phase_comparator, config.strobe_intervals[:])
            core.set_phase_comparator_freq(
                phase_comparator,
                target_note.frequency,
                config.pitch_standard,
                config.strobe_speed,
                config.speed_multiplier,
                config.strobe_mode,
            )
        }

        // Draw the GUI controls
        rl.BeginDrawing()
        defer rl.EndDrawing()
        {
            rl.ClearBackground(rl.GetColor(window_bg_color))

            // TODO
            // when the detected note is too far away from the target, set a fixed spinning rate and attenuate strobe display ???
            draw_strobe_display(&strobe_display, phase_comparator, out_of_range, config)

            agc, agc_changed := gui_agc_toggle({445, 50}, config.auto_gain_control)
            if agc_changed {
                config.auto_gain_control = agc
            }

            if freq_estimation_active {
                note_low_state = core.schmitt_trigger_neg(note_low_state, pitch_cents_err, -8, -10)
                note_high_state = core.schmitt_trigger(note_high_state, pitch_cents_err, 8, 10)

                if note_low_state do rl.DrawTextEx(font_store.medium_32, "◀", {10, 10}, 16, 0, rl.GetColor(0x82E2FFFF))
                else if note_high_state do rl.DrawTextEx(font_store.medium_32, "▶︎", {466, 10}, 16, 0, rl.GetColor(0x82E2FFFF))
            }


            // -------------------------------------------------------------------------------------

            draw_note(
                target_note,
                {16, 303},
                rl.GetColor(0xFBFBFBFF) if freq_estimation_active else rl.GetColor(0x7D7E8FFF),
            )

            rl.DrawTextEx(font_store.medium_32, "Hz", {147, 323}, 16, 1, rl.GetColor(0xFBFBFBFF))

            hz := pitch_info.detected_freq
            cents := pitch_info.err_cents

            if !freq_estimation_active && last_good_pitch_info.measured {
                hz = last_good_pitch_info.detected_freq
                cents = last_good_pitch_info.err_cents
            }

            show_placeholder := !freq_estimation_active || out_of_range

            rl.DrawTextEx(
                font_store.bold_36,
                "-" if show_placeholder else fmt.ctprintf("%.1f", hz),
                {147, 344},
                18,
                1,
                rl.GetColor(0xFBFBFBFF),
            )

            rl.DrawTextEx(
                font_store.medium_32,
                "Cents",
                {232, 323},
                16,
                1,
                rl.GetColor(0xFBFBFBFF),
            )

            cents_str := fmt.ctprintf("%.1f", math.abs(cents))
            show_minus_sign := cents < 0 && cents_str != "0.0"

            if show_minus_sign || !freq_estimation_active || out_of_range {
                rl.DrawTextEx(font_store.bold_36, "-", {232, 344}, 18, 1, rl.GetColor(0xFBFBFBFF))
            }

            rl.DrawTextEx(
                font_store.bold_36,
                "" if show_placeholder else cents_str,
                {242, 344},
                18,
                1,
                rl.GetColor(0xFBFBFBFF),
            )


            // -------------------------------------------------------------------------------------


            // Choose new audio input
            if audio_devices[audio_device_dropdown_index].id != audio_capture.active_device {
                switch_audio_device(audio_capture, audio_devices[audio_device_dropdown_index].id)
                core.flush_audio_capture_ringbuffer(&pitch_detector)
                core.flush_audio_capture_ringbuffer(phase_comparator)
            }

            setup_strobe_display(
                &strobe_display,
                config.strobe_contrast,
                config.strobe_display_type,
            )
            // rl.DrawLineEx({0, 306}, {488, 306}, 1.5, rl.GetColor(0x52535AFF))

            strobe_mode, strobe_mode_changed := gui_strobe_mode_toggle(
                {16, 456},
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
                {148, 456},
                config.note_detection_mode,
            )
            if note_detection_mode_changed {
                config.note_detection_mode = note_detection_mode
            }

            strobe_contrast_slider_value := math.log10(config.strobe_contrast)
            gui_contrast_slider({330, 320}, &strobe_contrast_slider_value)
            config.strobe_contrast = linalg.exp10(strobe_contrast_slider_value)

            gui_speed_slider({330, 352}, &strobe_speed_slider_value)
            if strobe_speed_slider_value != config.strobe_speed {
                config.strobe_speed = strobe_speed_slider_value
                core.set_phase_comparator_speed(phase_comparator, strobe_speed_slider_value)
            }

            // TODO: add refresh button to show newly connected devices
            audio_device_dropdown_active = gui_dropdown(
                {12, 496},
                240,
                audio_devices[:],
                &audio_device_dropdown_index,
                audio_device_dropdown_active,
                left_pad = 32,
            )

            // microphone icon
            rl.DrawTexturePro(
                texture_atlas,
                rl.Rectangle{96, 192, 32, 32},
                rl.Rectangle{20, 500, 16, 16},
                rl.Vector2{0, 0},
                0,
                rl.WHITE,
            )

            if config.note_detection_mode != .AUTO {
                tuning_preset_dropdown_active = gui_dropdown(
                    {262, 496},
                    140,
                    {{0, "CHROMATIC"}, {1, "GUITAR STD"}, {2, "UKULELE STD"}},
                    &tuning_preset_choice,
                    tuning_preset_dropdown_active,
                )
                config.tuning_preset = TuningPreset(tuning_preset_choice)
            }

            gui_feedback_button({461, 504})


            if COLOR_CONTROLS {
                rl.GuiColorPicker({20, 500, 200, 200}, nil, &color1)
                config.strobe_color_1 = rl.ColorToInt(color1)
                rl.DrawTextEx(
                    font_store.medium_32,
                    fmt.ctprintf("%x", config.strobe_color_1),
                    {20, 480},
                    16,
                    0,
                    rl.LIGHTGRAY,
                )

                rl.GuiColorPicker({300, 500, 200, 200}, nil, &color2)
                config.strobe_color_2 = rl.ColorToInt(color2)
                rl.DrawTextEx(
                    font_store.medium_32,
                    fmt.ctprintf("%x", config.strobe_color_2),
                    {300, 480},
                    16,
                    0,
                    rl.LIGHTGRAY,
                )

                set_strobe_colors(&strobe_display, {config.strobe_color_1, config.strobe_color_2})
            }


            // Draw input level
            // rl.DrawRectangleV({300, 500}, {100, 3}, rl.BLACK)
            rl.DrawRectangleV({44, 519}, {60 + pitch_info.rms_dbfs, 1}, rl.GetColor(0x82E2FFFF))

            // rl.DrawTextEx(
            //     font_store.medium_32,
            //     fmt.ctprintf("%-.1fdBFS", pitch_info.rms_dbfs),
            //     {300, 480},
            //     16,
            //     0,
            //     rl.LIGHTGRAY,
            // )


            // if pitch_info.rms_dbfs >= 0 do rl.DrawRectangleV({300, 500}, {10, 10}, rl.RED)
            // else if pitch_info.rms_dbfs >= -20 do rl.DrawRectangleV({300, 500}, {10, 10}, rl.ORANGE)
            // else if pitch_info.rms_dbfs >= -40 do rl.DrawRectangleV({300, 500}, {10, 10}, rl.YELLOW)
            // else if pitch_info.rms_dbfs >= -60 do rl.DrawRectangleV({300, 500}, {10, 10}, rl.GREEN)
            // else do rl.DrawRectangleV({300, 500}, {10, 10}, rl.BLACK)

            // TODO:
            // pitch standard - 440hz - number spinner
            // color theme dropdown
        }
    }
}
