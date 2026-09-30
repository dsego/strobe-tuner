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

import "../core"

sheet_bg_color: u32 = 0x40414AFF
strobe_bg_color: u32 = 0x15161AFF


INTERVAL_OPTIONS: [3][MAX_INTERVALS]f32 : {
    {1, 2, 4, 0, 0, 0, 0, 0},
    {1, 1.5, 2, 0, 0, 0, 0, 0},
    {1, 2, 3, 0, 0, 0, 0, 0},
}


// Show the signal stats and NSDF plots, e.g. `odin run app -debug -define:DEBUG_STATS=true`
DEBUG_STATS :: #config(DEBUG_STATS, false)

// A preset of the tracks for the I key, it replaces the partials and clears what was set on each track
apply_interval_preset :: proc(config: ^Config, index: int) {
    options := INTERVAL_OPTIONS
    defaults := config_defaults
    config.strobe_intervals_index = index
    config.strobe_intervals = options[index]
    config.strobe_offsets_cents = defaults.strobe_offsets_cents
    config.strobe_speeds = defaults.strobe_speeds
}

// Point the strobe at a new frequency with the current tracks, speed and mode
retune :: proc(phase_comparator: ^core.PhaseComparator, freq_hz: f32, config: ^Config) {
    core.set_phase_comparator_tracks(
        phase_comparator,
        config.strobe_intervals[:],
        config.strobe_offsets_cents[:],
        config.strobe_speeds[:],
    )
    core.set_phase_comparator_freq(
        phase_comparator,
        freq_hz,
        config.pitch_standard,
        config.strobe_speed,
        config.speed_multiplier,
        config.strobe_mode,
    )
}

run_app :: proc(config: ^Config) {
    target_freq_hz: f32 = config.target_freq_hz

    tuner := core.init_tuner(
        target_freq_hz,
        config.pitch_standard,
        config.note_switch_confirmations,
        config.prevent_strobe_octave_jumps,
    )
    tuner.offsets_cents = active_note_offsets(config)

    // Save target note to config when exiting the app
    defer config.target_freq_hz = tuner.target_note.frequency

    if !gfx_init(1200 when DEBUG_STATS else STROBE_WIDTH, DESKTOP_HEIGHT, APP_NAME) do return
    defer gfx_shutdown()

    // Loaded each frame for the screen's scale, see update_pixel_fonts
    defer unload_pixel_fonts()

    load_shapes()
    defer unload_shapes()

    //  --------------------------------------------------------------------------------------------

    phase_comparator := core.init_phase_comparator(
        target_freq_hz,
        f32(config.samplerate),
        config.strobe_intervals[:],
        config.strobe_mode,
        config.noise_floor_snr_db_threshold,
    )
    defer core.destroy_phase_comparator(phase_comparator)


    strobe_display := init_strobe_display(
        strobe_colors(config),
        strobe_bg_color,
        config.strobe_display_type,
    )
    defer destroy_strobe_display(&strobe_display)


    // Follows the config, see config_changed
    pitch_detector := core.init_pitch_detector(
        config.samplerate,
        config.pitch_detect_fft_size,
        config.pitch_detection_clarity_high,
        config.pitch_detection_clarity_low,
        config.pitch_detection_min_snr_db,
        config.noise_floor_snr_db_threshold,
    )
    defer core.destroy_pitch_detector(&pitch_detector)
    pitch_detector.pitch_standard = config.pitch_standard


    ok, audio_capture := init_audio_capture(u32(config.samplerate), config.highpass_cutoff_hz)
    if !ok do return
    defer destroy_audio_capture(audio_capture)


    register_audio_node(audio_capture, &pitch_detector)
    register_audio_node(audio_capture, phase_comparator)

    // The scope and the ribbon display types
    scope := core.init_scope(f64(config.samplerate), SCOPE_COLUMNS, SCOPE_ROWS)
    defer core.destroy_scope(&scope)
    register_audio_node(audio_capture, &scope)

    start_audio_capture(audio_capture)

    retune(phase_comparator, core.tuner_target_freq(&tuner), config)


    // --- GUI CONTROLS ----------------------------------------------------------------------------

    audio_device_dropdown_index: int = 0
    audio_devices: [dynamic]GuiOption = {}
    defer delete(audio_devices)

    for i in 0 ..< audio_device_count(audio_capture) {
        append(&audio_devices, GuiOption{i, audio_device_name(audio_capture, i)})
    }
    audio_device_dropdown_index = int(audio_capture.active_device)

    audio_device_dropdown_active := false

    settings_sheet: Sheet
    // A track's own sheet, opened by tapping the track
    track_sheet: Sheet
    selected_track := 0
    // The note offsets' sheet, opened from the slot next to the settings
    offsets_sheet: Sheet
    sheets := [?]^Sheet{&settings_sheet, &track_sheet, &offsets_sheet}

    note_low_state := false
    note_high_state := false
    arrow_pulse_phase: f32 = 0

    cents_trace := create_trace()
    defer destroy_trace(&cents_trace)


    interval_options := INTERVAL_OPTIONS
    config_changed := false

    // Open the input again, after the app was in the background or an interruption stopped it
    restart_audio := false

    // Seconds with no signal and nobody touching anything, see IDLE_AFTER_S
    quiet_time: f32 = 0


    // ---------------------------------------------------------------------------------------------


    // ------------------------------------------------
    //                   MAIN LOOP
    // ------------------------------------------------


    for !gfx_should_close() {
        // The labels and readouts are formatted into the temp allocator, nothing in it outlives a frame
        defer free_all(context.temp_allocator)

        // iOS suspends the app in the background and may end it there without warning, so the config is
        // saved on the way out
        if gfx_in_background() {
            stop_audio_capture(audio_capture)
            config.target_freq_hz = tuner.target_note.frequency
            save_config(config^)
            gfx_wait_for_foreground()
            restart_audio = true
            continue
        }
        if audio_interruption_ended(audio_capture) do restart_audio = true

        if key_pressed(.R) {
            config_changed = true
            fmt.println("Reset config to defaults")
            reset_config(config)
        }

        if key_pressed(.X) {
            config.use_phase_average = !config.use_phase_average
        }

        // Debug builds only, TextEdit can't be started from the Mac App Store sandbox
        super_key_down := key_down(.LEFT_SUPER) || key_down(.RIGHT_SUPER)
        pref_key_combo := super_key_down && key_pressed(.COMMA)
        if ODIN_DEBUG && pref_key_combo {
            shift_key_down := key_down(.LEFT_SHIFT) || key_down(.RIGHT_SHIFT)

            // [Cmd + Shift + ,] - Reload config
            if shift_key_down {
                config^ = load_config()
                config_changed = true

                // [Cmd + ,] - Open config editor
            } else {
                // TODO: support windows & linux
                when ODIN_OS == .Darwin && !IOS {
                    path := config_path()
                    defer delete(path)
                    libc.system(fmt.ctprintf("open -a TextEdit \"%s\"", path))
                }
            }
        }

        if config_changed {
            // A new FFT size needs new buffers, the device is closed while they're swapped, it waits for
            // the audio thread to finish with the old ones, and opened again below
            if config.pitch_detect_fft_size != pitch_detector.nsdf.fft_size {
                close_device(audio_capture)
                core.destroy_pitch_detector(&pitch_detector)
                pitch_detector = core.init_pitch_detector(
                    config.samplerate,
                    config.pitch_detect_fft_size,
                    config.pitch_detection_clarity_high,
                    config.pitch_detection_clarity_low,
                    config.pitch_detection_min_snr_db,
                    config.noise_floor_snr_db_threshold,
                )
                restart_audio = true
            }
            pitch_detector.clarity_high = config.pitch_detection_clarity_high
            pitch_detector.clarity_low = config.pitch_detection_clarity_low
            pitch_detector.min_snr_db = config.pitch_detection_min_snr_db
            pitch_detector.noise_floor.snr_threshold_db = config.noise_floor_snr_db_threshold

            // Same notes, retuned to the pitch standard
            pitch_detector.pitch_standard = config.pitch_standard
            core.set_tuner_pitch_standard(&tuner, config.pitch_standard)
            tuner.confirmations = config.note_switch_confirmations
            tuner.prevent_octave_jumps = config.prevent_strobe_octave_jumps
            tuner.offsets_cents = active_note_offsets(config)

            set_strobe_colors(&strobe_display, strobe_colors(config))
            retune(phase_comparator, core.tuner_target_freq(&tuner), config)
            config_changed = false
        }


        pitch_info := core.run_pitch_detection(&pitch_detector, tuner.pitch)
        if core.update_tuner(&tuner, pitch_info) do retune(phase_comparator, core.tuner_target_freq(&tuner), config)

        out_of_range := core.tuner_out_of_range(&tuner)
        shown_pitch_info, steady_pitch_info := core.tuner_readout(&tuner)

        // Every detection unaveraged so the vibrato shows, a gap while there's no pitch
        traced_cents := math.nan_f32()
        if tuner.active && !out_of_range do traced_cents = shown_pitch_info.err_cents
        record_trace(&cents_trace, traced_cents, pitch_info.fresh, gfx_frame_time())

        // Ignore return values - the NSDF provides a steadier Hz/Cents response
        core.run_phase_detection(phase_comparator, config.use_phase_average, pitch_info.is_tonal)

        when DEBUG_STATS do scope_keys(config)

        // The strobe's frequency, not the target note's: that one jumps an octave with the detection
        // while the strobe stays, and every change starts with a dark screen
        if scope.freq_hz != f64(phase_comparator.base_freq_hz) {
            core.set_scope_freq(&scope, f64(phase_comparator.base_freq_hz))
        }
        // The ribbon is the screen from above, it needs the sweep over time
        sweep := config.scope_sweep if config.strobe_display_type == .SCOPE else .TIME
        if scope.sweep != sweep do core.set_scope_sweep(&scope, sweep)
        scope.persistence_seconds = f64(config.scope_persistence_ms) / 1000
        scope.noise_floor = pitch_detector.noise_floor.level
        core.update_scope(&scope)

        if key_pressed(.TAB) {
            config.strobe_display_type = StrobeDisplayType((int(config.strobe_display_type) + 1) % len(StrobeDisplayType))
        }

        if key_pressed(.G) {
            config.strobe_glow = !config.strobe_glow
        }

        if key_pressed(.I) && config.strobe_mode == .HARMONIC {
            apply_interval_preset(config, (config.strobe_intervals_index + 1) % len(interval_options))
            retune(phase_comparator, core.tuner_target_freq(&tuner), config)
        }

        window, safe := gfx_window_size(), gfx_safe_area()
        // The plots take the rest of the window on the right
        when DEBUG_STATS {
            window.x = STROBE_WIDTH
            safe.width = STROBE_WIDTH
        }
        layout := compute_layout(window, safe, config.chromatic_ruler)
        update_pixel_fonts(layout.ruler_scale)

        // Draw the GUI controls
        gfx_begin_frame(hex(strobe_bg_color))
        defer gfx_end_frame()
        gui_press_taken = false

        // Choose new audio input, or reopen the same one
        if restart_audio || audio_devices[audio_device_dropdown_index].id != audio_capture.active_device {
            restart_audio = false
            switch_audio_device(audio_capture, audio_devices[audio_device_dropdown_index].id)
            core.flush_audio_capture_ringbuffer(&pitch_detector)
            core.reset_noise_floor(&pitch_detector.noise_floor)
            core.flush_audio_capture_ringbuffer(phase_comparator)
            core.reset_phase_noise_floor(phase_comparator)
        }

        // The sheets slide up over the main screen, which keeps running under them and ignores taps until
        // they're all the way down again. They're drawn at the end of the frame.
        gui_disabled = false
        for sheet in sheets {
            slide_sheet(sheet)
            if sheet.open || sheet.slide > 0 do gui_disabled = true
        }

        {

            setup_strobe_display(&strobe_display, config.strobe_display_type)
            // The selected track stands out as its sheet comes up
            strobe_display.selected_track = selected_track
            strobe_display.selection = track_sheet.slide

            if config.strobe_display_type == .TRACE {
                trace_rect := layout.strobe
                trace_rect.y = layout.strobe_top
                trace_rect.height -= layout.strobe_top
                draw_rect({layout.strobe.x, layout.strobe.y}, {layout.strobe.width, layout.strobe_top}, hex(strobe_bg_color))
                colors := strobe_colors(config)
                draw_cents_trace(&cents_trace, trace_rect, hex(colors.x), hex(colors.y), hex(strobe_bg_color))
            } else if config.strobe_display_type == .SCOPE || config.strobe_display_type == .RIBBON {
                scope_rect := layout.strobe
                scope_rect.y = layout.strobe_top
                scope_rect.height -= layout.strobe_top
                draw_rect({layout.strobe.x, layout.strobe.y}, {layout.strobe.width, layout.strobe_top}, hex(strobe_bg_color))
                draw_scope_display(&strobe_display, &scope, scope_rect, config, pitch_detector.snr_db)

                // Tapping the scope switches it between the wave over time and the Lissajous figure
                if config.strobe_display_type == .SCOPE && !microphone_denied() && gui_button(layout.strobe) {
                    config.scope_sweep = .XY if config.scope_sweep == .TIME else .TIME
                }
            } else {
                // TODO
                // when the detected note is too far away from the target, set a fixed spinning rate and attenuate strobe display ???
                draw_strobe_display(
                    &strobe_display,
                    layout.strobe,
                    layout.strobe_scale,
                    phase_comparator,
                    out_of_range,
                    config,
                )

                // Tapping a track opens its sheet, fine mode shows the same pitch on every track
                if config.strobe_mode == .HARMONIC && !microphone_denied() && gui_button(layout.strobe) {
                    track := strobe_track_at(
                        config.strobe_display_type,
                        layout.strobe,
                        layout.strobe_scale,
                        len(phase_comparator.bands),
                        mouse_position(),
                    )
                    if track >= 0 {
                        selected_track = track
                        track_sheet.open = true
                    }
                }
            }

            // A denied microphone only gives silence and the strobe would just stand still, say why instead
            if microphone_denied() {
                draw_rect({layout.strobe.x, layout.strobe.y}, {layout.strobe.width, layout.strobe.height}, hex(strobe_bg_color))
                center := [2]f32{layout.strobe.x + layout.strobe.width / 2, layout.strobe.y + layout.strobe.height / 2}
                title: cstring = "Microphone access is off"
                hint: cstring = "Tap to allow it in Settings"
                title_size := measure_label(pixel_fonts.title, title)
                hint_size := measure_label(pixel_fonts.label, hint)
                draw_label(pixel_fonts.title, title, center - {title_size.x / 2, title_size.y + 4}, text_color_white)
                draw_label(pixel_fonts.label, hint, center - {hint_size.x / 2, -4}, text_color_muted)
                if gui_button(layout.strobe) do gfx_open_url("app-settings:")
            }

            // Only the strong readings, a fading note drifts and would flash the arrows
            arrow_cents_err := core.cents_deviation(tuner.last_good_pitch.detected_freq, core.tuner_target_freq(&tuner))
            distance := abs(arrow_cents_err)

            // Without a lock, further than half a semitone is a neighbouring note that isn't confirmed yet
            if tuner.active && (tuner.locked || distance <= 50) {
                note_low_state = core.schmitt_trigger_neg(note_low_state, arrow_cents_err, -8, -10)
                note_high_state = core.schmitt_trigger(note_high_state, arrow_cents_err, 8, 10)

                // Far from a locked note the strobe means nothing, the arrow pulses instead: slowly an octave
                // or more away, quicker as the string comes closer, steady within 50 cents
                arrow_color := hex(0x82E2FFFF)
                if tuner.locked && distance > 50 {
                    closeness := clamp((1200 - distance) / (1200 - 50), 0, 1)
                    pulse_hz := math.lerp(f32(0.5), 2.5, closeness)
                    arrow_pulse_phase = math.mod(arrow_pulse_phase + pulse_hz * gfx_frame_time(), 1)
                    // A gentle breathing between half and full brightness
                    brightness := 0.75 + 0.25 * math.cos(2 * math.PI * arrow_pulse_phase)
                    arrow_color.a = u8(255 * brightness)
                } else {
                    arrow_pulse_phase = 0
                }

                // On the side the pitch is off to, pointing inwards the way to tune: flat on the left pointing
                // right to tune up, like higher notes are to the right on the ruler
                arrow := pixel_fonts.strobe_arrow
                arrow_y := layout.strobe_top + 10
                if note_low_state {
                    position := snap_to_pixels({layout.strobe.x + 10, arrow_y})
                    draw_text(arrow.font, "▶", position, arrow.size, 0, arrow_color)
                } else if note_high_state {
                    arrow_width := measure_text(arrow.font, "◀", arrow.size, 0).x
                    position := snap_to_pixels({layout.strobe.x + layout.strobe.width - 10 - arrow_width, arrow_y})
                    draw_text(arrow.font, "◀", position, arrow.size, 0, arrow_color)
                }
            }


            // -------------------------------------------------------------------------------------

            // The lock button (or space) locks the note, tapping another note on the ruler (or the arrows)
            // locks that one instead
            // A transposing instrument reads the written note, only what's shown moves, the steps are
            // relative and work the same either way
            config.transpose = gui_transpose(layout.transpose, ((config.transpose % 12) + 12) % 12)
            shown_note := core.cents_to_note(
                f32(tuner.target_note.cents + 100 * config.transpose),
                tuner.target_note.pitch_standard,
            )
            // No pitch yet, nothing to show
            if tuner.target_note.frequency == 0 do shown_note.frequency = 0

            step, browse: int
            if config.chromatic_ruler {
                step, browse = gui_note_ruler(layout.ruler, shown_note, tuner.active)
            } else {
                draw_note(shown_note, layout.note, tuner.active)
                step = gui_note_arrows(layout.note, tuner.locked)
            }
            lock_toggled := gui_lock_toggle(layout.lock, tuner.locked)
            if !gui_disabled {
                if key_pressed(.SPACE) do lock_toggled = true
                if key_pressed(.LEFT) do step = -1
                if key_pressed(.RIGHT) do step = 1
            }

            if lock_toggled || step != 0 do quiet_time = 0

            retune_target := false
            if lock_toggled && core.toggle_note_lock(&tuner) do retune_target = true
            if core.step_target_note(&tuner, step) do retune_target = true
            if retune_target do retune(phase_comparator, core.tuner_target_freq(&tuner), config)

            // A note that's tuned off pitch says so between the letter and the lock, the strobe and the
            // readout are on the offset note, see gui_note_offsets. While swiping the ruler, of the note in the middle.
            middle_note := tuner.target_note
            if browse != 0 do middle_note = core.cents_to_note(f32(middle_note.cents + 100 * browse), middle_note.pitch_standard)
            if offset := core.note_offset_cents(&tuner, middle_note); offset != 0 && shown_note.frequency != 0 {
                text := fmt.ctprintf("%+.1f¢", offset)
                width := measure_label(pixel_fonts.label, text, 1).x
                // Like the note, white while there's a pitch
                color := text_color_white if tuner.active else text_color_muted
                draw_label(pixel_fonts.label, text, layout.note_offset - {width / 2, LABEL_SIZE / 2}, color, 1)
            }

            draw_measurements(
                layout.measurements,
                layout.readout_align,
                steady_pitch_info,
                tuner.active,
            )


            // -------------------------------------------------------------------------------------


            // Only the strobe spins, the trace and the scope's views have no speed to change
            if config.strobe_display_type == .CURVED_TRACKS || config.strobe_display_type == .SPINNING_WHEEL {
                if speed, speed_changed := gui_response_toggle(layout.response, config.strobe_speed); speed_changed {
                    config.strobe_speed = speed
                    core.set_phase_comparator_speed(phase_comparator, speed)
                }
            }

            if gui_settings_button(layout.settings) do settings_sheet.open = true
            if gui_note_offsets_indicator(layout.offsets_led, config) do config_changed = true
            if gui_note_offsets_button(layout.note_offsets) do offsets_sheet.open = true


            // Draw input level, the microphone icon marks it as the input
            {
                draw_icon(ICON_MICROPHONE, layout.level_meter + {0, -6}, icon_color)

                meter := layout.level_meter + {20, 0}
                track := Rect{meter.x, meter.y, 60, 4}
                draw_rounded_rect(track, 2, pill_dark)
                // The level is the rounded track cut off flat where it ends
                begin_scissor({meter.x, meter.y, 60 + clamp(pitch_info.rms_dbfs, -60, 0), 4})
                draw_rounded_rect(track, 2, hex(0x82E2FFFF))
                end_scissor()

                when DEBUG_STATS {
                    floor_level := core.dbfs(pitch_info.noise_floor)
                    draw_rect(meter + {0, 4}, {60, 3}, hex(strobe_bg_color))
                    draw_rect(meter + {0, 4}, {60 + floor_level, 3}, PURPLE)

                    draw_text(
                        pixel_fonts.label_small.font,
                        fmt.ctprintf("RMS %.1f", pitch_info.rms_dbfs),
                        layout.stats + {130, 0},
                        12,
                        0,
                        text_color_white,
                    )

                    draw_text(
                        pixel_fonts.label_small.font,
                        fmt.ctprintf("NF %.1f", floor_level),
                        layout.stats + {130, 15},
                        12,
                        0,
                        text_color_white,
                    )

                    draw_text(
                        pixel_fonts.label_small.font,
                        fmt.ctprintf("SNR %.1f", pitch_info.snr_db),
                        layout.stats + {130, 30},
                        12,
                        0,
                        text_color_white,
                    )
                }
            }

            when DEBUG_STATS {

                draw_text(
                    pixel_fonts.label_small.font,
                    fmt.ctprintf("Band SNR %.1f", phase_comparator.bands[0].snr_db),
                    layout.stats,
                    12,
                    0,
                    text_color_white,
                )

                draw_text(
                    pixel_fonts.label_small.font,
                    fmt.ctprintf("Band NF %.1f", core.dbfs(phase_comparator.bands[0].noise_floor.level)),
                    layout.stats + {0, 15},
                    12,
                    0,
                    text_color_white,
                )


                draw_text(
                    pixel_fonts.label_large.font,
                    fmt.ctprintf("Clarity %.3f", pitch_info.clarity),
                    {500, 10},
                    16,
                    0,
                    text_color_white,
                )
                if pitch_info.is_strong_pitch {
                    draw_text(
                        pixel_fonts.label_large.font,
                        fmt.ctprintf("strong"),
                        {600, 10},
                        16,
                        0,
                        ORANGE,
                    )

                }
                if pitch_info.is_weak_pitch {
                    draw_text(
                        pixel_fonts.label_large.font,
                        fmt.ctprintf("weak"),
                        {600, 10},
                        16,
                        0,
                        PURPLE,
                    )
                }

                draw_nsdf(
                    Rect{520, 40, 660, 200},
                    &pitch_detector.nsdf,
                    pitch_info.nsdf_peak,
                    pixel_fonts.label_small.font,
                )

                draw_freq_plot(
                    Rect{520, 300, 660, 200},
                    &pitch_detector.nsdf,
                    pixel_fonts.label_small.font,
                )
            }
        }

        if settings_sheet.slide > 0 {
            sheet_layout, swiped := begin_sheet(&settings_sheet, SETTINGS_ROWS, &strobe_display, layout.strobe)
            close, changed := gui_settings(
                sheet_layout,
                config,
                audio_devices[:],
                &audio_device_dropdown_index,
                &audio_device_dropdown_active,
            )
            if changed do config_changed = true
            grab_sheet(&settings_sheet, sheet_layout)

            // Tapping the strobe above the sheet closes it too
            if gui_button(above_sheet(sheet_layout)) || key_pressed(.ESCAPE) || swiped do close = true

            if close {
                close_sheet(&settings_sheet)
                audio_device_dropdown_active = false
                exclusive_control_mode = false
            }
        }

        if track_sheet.slide > 0 {
            sheet_layout, swiped := begin_sheet(&track_sheet, TRACK_SETTINGS_ROWS, &strobe_display, layout.strobe)
            selected_track = min(selected_track, len(phase_comparator.bands) - 1)
            close, changed := gui_track_settings(
                sheet_layout,
                config,
                selected_track,
                phase_comparator.bands[selected_track],
            )
            if changed do config_changed = true
            grab_sheet(&track_sheet, sheet_layout)

            // Tapping another track above the sheet switches to it, anywhere else closes the sheet
            if gui_button(above_sheet(sheet_layout)) {
                track := strobe_track_at(
                    config.strobe_display_type,
                    layout.strobe,
                    layout.strobe_scale,
                    len(phase_comparator.bands),
                    mouse_position(),
                )
                if track >= 0 do selected_track = track
                else do close = true
            }

            if key_pressed(.ESCAPE) || swiped do close = true
            if close do close_sheet(&track_sheet)
        }

        if offsets_sheet.slide > 0 {
            // Over the whole window, room for every offset of a slot
            sheet_layout, swiped := begin_sheet(
                &offsets_sheet,
                NOTE_OFFSET_ROWS,
                &strobe_display,
                layout.strobe,
                gfx_window_size().y,
            )

            // A new offset starts on the note the tuner is on
            target := -1
            if index, in_range := core.note_index(tuner.target_note); in_range && tuner.target_note.frequency != 0 {
                target = index
            }
            close, changed := gui_note_offsets(sheet_layout, config, target)
            if changed do config_changed = true
            grab_sheet(&offsets_sheet, sheet_layout)

            // Tapping the strobe above the sheet closes it too
            if gui_button(above_sheet(sheet_layout)) || key_pressed(.ESCAPE) || swiped do close = true

            if close {
                close_sheet(&offsets_sheet)
                note_offset_selected = -1
            }
        }

        // With nothing to show the screen updates less often, it saves the battery of a tuner left open. The
        // strobe is dark while no band is above the background noise, and the pitch detection still runs
        // often enough to wake it up.
        signal := tuner.active
        for band in phase_comparator.bands {
            if band.snr_db > STROBE_FADE_SNR_DB[0] do signal = true
        }
        touched := mouse_down() || mouse_pressed() || mouse_wheel() != 0
        sliding := ruler_swipe.coast != 0
        for sheet in sheets {
            if sheet.slide != f32(int(sheet.open)) do sliding = true
        }
        if signal || touched || sliding {
            quiet_time = 0
        } else {
            quiet_time += gfx_frame_time()
        }
        gfx_limit_fps(IDLE_FPS if quiet_time > IDLE_AFTER_S else 0)
    }
}

// See quiet_time in run_app
IDLE_AFTER_S :: 2
IDLE_FPS :: 30
