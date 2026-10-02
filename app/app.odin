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

// Show the signal stats and NSDF plots, e.g. `odin run app -debug -define:DEBUG_STATS=true`
DEBUG_STATS :: #config(DEBUG_STATS, false)

// The version and build from the Info.plist, e.g. "2.0 (1)", the bundle scripts pass it in. Shown after the
// settings' title.
VERSION :: #config(VERSION, "dev")

// The track presets the I key steps through
INTERVAL_OPTIONS: [3][core.MAX_BANDS]f32 : {
    {1, 2, 4, 0, 0},
    {1, 1.5, 2, 0, 0},
    {1, 2, 3, 0, 0},
}

// With nothing to show the screen updates less often, it saves the battery of a tuner left open, see App.quiet_time
IDLE_AFTER_S :: 2
IDLE_FPS :: 30
// Otherwise the display's rate up to ProMotion's, a faster monitor would only redraw the strobe more often
MAX_FPS :: 120


// What the main loop keeps from one frame to the next
App :: struct {
    config:             ^Config,
    tuner:              core.Tuner,
    pitch_detector:     core.PitchDetector, // follows the config, see apply_config
    phase_comparator:   ^core.PhaseComparator,
    scope:              core.Scope, // of the scope and the lamp display types, and the tracks the lamp turns
    audio_capture:      ^AudioCapture,
    audio_devices:      [dynamic]GuiOption,
    audio_device_index: int, // in audio_devices, picked in the settings
    strobe_display:     StrobeDisplay,
    cents_trace:        Trace,

    settings_menu:      SettingsMenu, // the dropdown whose menu is open
    settings_sheet:     Sheet,
    display_options:    bool, // the settings sheet shows the display's options, see gui_settings
    track_sheet:        Sheet, // a track's own, opened by tapping the track
    selected_track:     int,
    instrument_sheet:   Sheet, // the instruments and the presets, opened from the bottom left corner

    // The arrows on the strobe, see draw_tuning_arrows
    flat_arrow:         bool,
    sharp_arrow:        bool,

    readout_track:      int, // the strobe track the readout follows, see core.strobe_readout_track
    traced_track:       int, // the track the readout followed, the trace stays on it while its stripes show
    config_changed:     bool, // the tuner and the strobe need the new config, see apply_config
    unsaved:            bool, // the config changed since it was saved, see save_when_settled
    restart_audio:      bool, // opens the input again, after the background or an interruption
    quiet_time:         f32, // seconds with no signal and nobody touching anything, see IDLE_AFTER_S
}

// This frame's measurements, for the main screen
Reading :: struct {
    pitch:          core.PitchInfo, // the latest detection
    shown:          core.PitchInfo, // the latest detection measured like the readout, see core.tuner_readout
    steady:         core.PitchInfo, // the readout, the strong detections averaged
    out_of_range:   bool, // another note than a locked one is played, see core.tuner_out_of_range
    strobe_readout: bool, // the readout is the strobe track's, close to the note
}


run_app :: proc(config: ^Config) {
    app := App {
        config        = config,
        readout_track = -1,
        traced_track  = -1,
    }
    tuner := &app.tuner
    tuner^ = core.init_tuner(config.target_freq_hz, config.pitch_standard, config.note_switch_s, config.prevent_strobe_octave_jumps)
    configure_tuner(&app)
    // Saved for the next start
    defer config.target_freq_hz = tuner.target_note.frequency

    if !gfx_init(1200 when DEBUG_STATS else STROBE_WIDTH, DESKTOP_HEIGHT, APP_NAME) do return
    defer gfx_shutdown()
    // Loaded each frame for the screen's scale, see update_pixel_fonts
    defer unload_pixel_fonts()
    load_shapes()
    defer unload_shapes()

    app.phase_comparator = core.init_phase_comparator(
        config.target_freq_hz,
        f32(config.samplerate),
        config.strobe_intervals[:],
        config.strobe_mode,
        config.noise_floor_snr_db_threshold,
    )
    defer core.destroy_phase_comparator(app.phase_comparator)
    app.pitch_detector = pitch_detector_from_config(config)
    defer core.destroy_pitch_detector(&app.pitch_detector)
    app.scope = core.init_scope(f64(config.samplerate), SCOPE_COLUMNS, SCOPE_ROWS)
    defer core.destroy_scope(&app.scope)
    app.strobe_display = init_strobe_display(strobe_colors(config), strobe_bg_color)
    defer destroy_strobe_display(&app.strobe_display)
    app.cents_trace = create_trace()
    defer destroy_trace(&app.cents_trace)

    audio_capture, ok := init_audio_capture(u32(config.samplerate))
    if !ok do return
    defer destroy_audio_capture(audio_capture)
    app.audio_capture = audio_capture
    register_audio_node(audio_capture, &app.pitch_detector)
    register_audio_node(audio_capture, app.phase_comparator)
    register_audio_node(audio_capture, &app.scope)
    start_audio_capture(audio_capture)

    for index in 0 ..< audio_device_count(audio_capture) {
        append(&app.audio_devices, GuiOption{index, audio_device_name(audio_capture, index)})
    }
    defer delete(app.audio_devices)
    app.audio_device_index = int(audio_capture.active_device)

    retune(&app)

    for !gfx_should_close() {
        // The labels and readouts are formatted into the temp allocator, nothing in it outlives a frame
        defer free_all(context.temp_allocator)

        if gfx_in_background() {
            wait_in_background(&app)
            continue
        }
        if audio_interruption_ended(audio_capture) do app.restart_audio = true

        config_before := config^
        handle_keys(&app)
        if app.config_changed do apply_config(&app)
        reading := measure(&app)
        feed_scope(&app)

        window, safe := gfx_window_size(), gfx_safe_area()
        // The plots take the rest of the window on the right
        when DEBUG_STATS {
            window.x = STROBE_WIDTH
            safe.width = STROBE_WIDTH
        }
        layout := compute_layout(window, safe, shows_ruler(config), selected_preset(config) >= 0)
        update_pixel_fonts(layout.ruler_scale)

        gfx_begin_frame(hex(strobe_bg_color))
        defer gfx_end_frame()
        gui_press_taken = false

        if app.restart_audio || app.audio_devices[app.audio_device_index].id != audio_capture.active_device {
            switch_input(&app)
        }

        // The sheets slide up over the main screen, which keeps running under them and ignores taps until
        // they're all the way down again. They're drawn at the end of the frame.
        gui_disabled = false
        for sheet in ([]^Sheet{&app.settings_sheet, &app.track_sheet, &app.instrument_sheet}) {
            slide_sheet(sheet)
            if sheet.open || sheet.slide > 0 do gui_disabled = true
        }

        draw_main_screen(&app, layout, reading)
        draw_sheets(&app, layout)

        if config^ != config_before do app.unsaved = true
        save_when_settled(&app)
        limit_frame_rate(&app)
    }
}

// The strobe on the target note with the current tracks, speed and mode
retune :: proc(app: ^App) {
    config := app.config
    app.traced_track = -1 // the tracks are at another note now
    core.set_phase_comparator_tracks(
        app.phase_comparator,
        config.strobe_intervals[:],
        config.strobe_offsets_cents[:],
        config.strobe_speeds[:],
    )
    core.set_phase_comparator_freq(
        app.phase_comparator,
        core.tuner_target_freq(&app.tuner),
        config.pitch_standard,
        config.strobe_speed,
        config.speed_multiplier,
        config.strobe_mode,
    )
}

pitch_detector_from_config :: proc(config: ^Config) -> (detector: core.PitchDetector) {
    detector = core.init_pitch_detector(
        config.samplerate,
        config.pitch_detect_fft_size,
        config.pitch_detection_clarity_high,
        config.pitch_detection_clarity_low,
        config.pitch_detection_min_snr_db,
        config.noise_floor_snr_db_threshold,
        config.highpass_cutoff_hz,
    )
    detector.pitch_standard = config.pitch_standard
    return
}

// The tuner's settings from the config, all but the pitch standard, see apply_config
configure_tuner :: proc(app: ^App) {
    tuner, config := &app.tuner, app.config
    tuner.confirm_s = config.note_switch_s
    tuner.prevent_octave_jumps = config.prevent_strobe_octave_jumps
    tuner.octave_track = config.strobe_mode == .HARMONIC
    tuner.offsets_cents = active_note_offsets(config)
    core.set_tuner_strings(tuner, tuning_strings(config))
}

// The pitch detection, the tuner and the strobe brought up to the config
apply_config :: proc(app: ^App) {
    config, detector := app.config, &app.pitch_detector

    // A new FFT size needs new buffers. The device is closed while they're swapped, it waits for the audio
    // thread to finish with the old ones, and it's opened again later in the frame.
    if config.pitch_detect_fft_size != detector.nsdf.fft_size {
        close_device(app.audio_capture)
        core.destroy_pitch_detector(detector)
        detector^ = pitch_detector_from_config(config)
        app.restart_audio = true
    }
    detector.clarity_high = config.pitch_detection_clarity_high
    detector.clarity_low = config.pitch_detection_clarity_low
    detector.min_snr_db = config.pitch_detection_min_snr_db
    detector.noise_floor.snr_threshold_db = config.noise_floor_snr_db_threshold

    // Same notes, retuned to the pitch standard
    detector.pitch_standard = config.pitch_standard
    core.set_tuner_pitch_standard(&app.tuner, config.pitch_standard)
    configure_tuner(app)

    set_strobe_colors(&app.strobe_display, strobe_colors(config))
    retune(app)
    app.config_changed = false
}

// iOS suspends the app in the background and may end it there without warning. The config is saved on the
// way out, the input is opened again on the way back.
wait_in_background :: proc(app: ^App) {
    app.config.target_freq_hz = app.tuner.target_note.frequency
    save_config(app.config^)
    stop_audio_capture(app.audio_capture)
    gfx_wait_for_foreground()
    app.restart_audio = true
}

// The input picked in the settings, or the same one again, the measurements start afresh on it
switch_input :: proc(app: ^App) {
    app.restart_audio = false
    switch_audio_device(app.audio_capture, app.audio_devices[app.audio_device_index].id)
    core.reset_pitch_detector(&app.pitch_detector)
    core.reset_phase_comparator(app.phase_comparator)
}

handle_keys :: proc(app: ^App) {
    config := app.config

    if key_pressed(.R) {
        fmt.println("Reset config to defaults")
        reset_config(config)
        app.config_changed = true
    }
    if key_pressed(.X) do config.use_phase_average = !config.use_phase_average
    if key_pressed(.G) do config.strobe_glow = !config.strobe_glow
    if key_pressed(.TAB) {
        config.strobe_display_type = StrobeDisplayType((int(config.strobe_display_type) + 1) % len(StrobeDisplayType))
    }
    // The next preset of the tracks, it replaces the partials and clears what was set on each track
    if key_pressed(.I) && config.strobe_mode == .HARMONIC {
        options, defaults := INTERVAL_OPTIONS, config_defaults
        config.strobe_intervals_index = (config.strobe_intervals_index + 1) % len(options)
        config.strobe_intervals = options[config.strobe_intervals_index]
        config.strobe_offsets_cents = defaults.strobe_offsets_cents
        config.strobe_speeds = defaults.strobe_speeds
        retune(app)
    }

    // Debug builds only, Cmd+Shift+, reloads the config file and Cmd+, opens it in TextEdit, which can't be
    // started from the Mac App Store sandbox
    command := key_down(.LEFT_SUPER) || key_down(.RIGHT_SUPER)
    if ODIN_DEBUG && command && key_pressed(.COMMA) {
        if key_down(.LEFT_SHIFT) || key_down(.RIGHT_SHIFT) {
            config^ = load_config()
            app.config_changed = true
        } else {
            when ODIN_OS == .Darwin && !IOS {
                path := config_path()
                defer delete(path)
                libc.system(fmt.ctprintf("open -a TextEdit \"%s\"", path))
            }
        }
    }
}

// The pitch detection, the strobe and the tuner on the new audio
measure :: proc(app: ^App) -> (reading: Reading) {
    tuner := &app.tuner
    reading.pitch = core.run_pitch_detection(&app.pitch_detector, tuner.pitch)
    core.run_phase_detection(app.phase_comparator, app.config.use_phase_average, reading.pitch.is_tonal)

    // The track the readout follows. The strobe keeps the note lit while it shows it.
    ready: bool
    app.readout_track, ready = core.strobe_readout_track(app.phase_comparator, app.readout_track)
    if core.update_tuner(tuner, reading.pitch, core.strobe_shows_note(app.phase_comparator)) do retune(app)

    // The strobe stays an octave off the target while its own note still shows, see update_tuner. Once that
    // track is dark it follows the target, otherwise a strobe put an octave low by one wrong detection keeps
    // the real note on its octave track for good.
    off_target := app.phase_comparator.base_freq_hz != core.tuner_target_freq(tuner)
    if off_target && !core.strobe_shows_note(app.phase_comparator, fundamental_only = true) do retune(app)

    reading.out_of_range = core.tuner_out_of_range(tuner)
    reading.shown, reading.steady = core.tuner_readout(tuner)

    // Close to the note the readout is the strobe's, 0 where the fundamental's track stands still. The pitch
    // detection reads the whole wave, a real string's partials are a little sharp and pull it a few cents off
    // the track you see. The Hz move along with the cents.
    steady := &reading.steady
    reading.strobe_readout =
        ready && tuner.active && !reading.out_of_range && abs(steady.err_cents) <= core.READOUT_RANGE_CENTS
    if reading.strobe_readout {
        cents := app.phase_comparator.bands[app.readout_track].err_cents
        steady.detected_freq = core.cents_to_freq(cents - steady.err_cents, steady.detected_freq)
        steady.err_cents = cents
    }

    // The readout's cents, the strobe's close to the note so an in tune note is on the middle line, further
    // out every detection unaveraged. The track the readout followed carries on as the note decays and the
    // readout gives way, the line as lit as its stripes and dark with them, not the noisy weak detections.
    if reading.strobe_readout do app.traced_track = app.readout_track
    light: f32 = 1
    if app.traced_track >= 0 {
        band := app.phase_comparator.bands[app.traced_track]
        fade := core.STROBE_FADE_SNR_DB
        light = math.smoothstep(fade[0], fade[1], band.snr_db)
        if light == 0 || !band.in_range do app.traced_track = -1
    }
    detected := tuner.active && !reading.out_of_range && !reading.pitch.is_weak_pitch
    far := detected && abs(steady.err_cents) > core.READOUT_RANGE_CENTS
    traced_cents := math.nan_f32()
    if app.traced_track >= 0 && !reading.out_of_range && !far {
        traced_cents = app.phase_comparator.bands[app.traced_track].err_cents
    } else if detected {
        traced_cents, light = reading.shown.err_cents, 1
    }
    record_trace(&app.cents_trace, traced_cents, light, reading.pitch.fresh, gfx_frame_time())
    return
}

// The new audio onto the scope's screen, while its views or the tracks the lamp turns show it
feed_scope :: proc(app: ^App) {
    scope, config := &app.scope, app.config

    type := config.strobe_display_type
    if type != .SCOPE && type != .LAMP && !(type == .STROBE && config.strobe_source == .LAMP) {
        core.skip_scope(scope)
        // The lamp's tracks start over on a dark screen too, the phases they turned by are stale
        app.strobe_display.lamp_freq_hz = 0
        return
    }

    // At the strobe's frequency, not the target note's: that one jumps an octave with the detection while
    // the strobe stays, and every change starts with a dark screen
    strobe_hz := f64(app.phase_comparator.base_freq_hz)
    if scope.freq_hz != strobe_hz do core.set_scope_freq(scope, strobe_hz)
    // The lamp is the screen from above, it needs the sweep over time, and so do the tracks it turns
    sweep := config.scope_sweep if config.strobe_display_type == .SCOPE else .TIME
    if scope.sweep != sweep do core.set_scope_sweep(scope, sweep)
    scope.persistence_seconds = f64(config.scope_persistence_ms) / 1000
    scope.gain = config.scope_gain
    scope.noise_floor = app.pitch_detector.noise_floor.level
    core.update_scope(scope)
}

// An instrument's strings are always on the ruler
shows_ruler :: proc(config: ^Config) -> bool {
    return config.chromatic_ruler || current_setup(config).instrument != .CHROMATIC
}

draw_main_screen :: proc(app: ^App, layout: Layout, reading: Reading) {
    config := app.config

    draw_strobe_area(app, layout)
    draw_tuning_arrows(app, layout, reading)
    draw_note_controls(app, layout, reading)

    // The strong detections averaged, a raw one each frame is too jumpy to read. Nothing to measure on another
    // note than a locked one.
    draw_measurements(
        layout.measurements,
        layout.readout_align,
        reading.steady.detected_freq,
        reading.steady.err_cents,
        reading.steady.measured && !reading.out_of_range,
        app.tuner.active,
    )

    // The trace and the scope's views don't spin
    if config.strobe_display_type == .STROBE {
        if speed, speed_changed := gui_response_toggle(layout.response, config.strobe_speed); speed_changed {
            config.strobe_speed = speed
            core.set_phase_comparator_speed(app.phase_comparator, speed)
        }
    }
    // Opens on the settings, not the display's options it was closed on
    if gui_settings_button(layout.settings) {
        app.settings_sheet.open = true
        app.display_options = false
    }
    if gui_instrument_button(layout.instrument, config) do app.instrument_sheet.open = true

    // The input level, the microphone icon marks it as the input. The level is the rounded track cut off flat
    // where it ends.
    draw_icon(ICON_MICROPHONE, layout.level_meter + {0, -6}, icon_color)
    meter := layout.level_meter + {20, 0}
    track := Rect{meter.x, meter.y, 60, 4}
    draw_rounded_rect(track, 2, pill_dark)
    begin_scissor({meter.x, meter.y, 60 + clamp(reading.pitch.rms_dbfs, -60, 0), 4})
    draw_rounded_rect(track, 2, accent_color)
    end_scissor()

    when DEBUG_STATS do draw_debug_stats(app, layout, reading.pitch, meter)
}

// The strobe, or the trace or the scope's view in its place. Tapping a track opens its sheet, tapping the scope
// flips its sweep.
draw_strobe_area :: proc(app: ^App, layout: Layout) {
    config, display := app.config, &app.strobe_display
    type := config.strobe_display_type

    // The selected track stands out as its sheet comes up
    display.selected_track = app.selected_track
    display.selection = app.track_sheet.slide

    if type == .STROBE {
        // Turned by the lock-in or by the lamp's screen
        comparator := app.phase_comparator
        bands := comparator.bands[:]
        if config.strobe_source == .LAMP {
            bands = lamp_bands(display, &app.scope, bands, app.pitch_detector.snr_db)
        }
        draw_strobe_display(display, layout.strobe, layout.strobe_scale, bands, comparator.mode, config)

        // Fine mode shows the same pitch on every track, there's nothing to set on one
        if config.strobe_mode == .HARMONIC && !microphone_denied() && gui_button(layout.strobe) {
            track := strobe_track_at(config.strobe_shape, layout.strobe, layout.strobe_scale, len(app.phase_comparator.bands), mouse_position())
            if track >= 0 {
                app.selected_track = track
                app.track_sheet.open = true
            }
        }
    } else {
        // The trace and the scope's views start under the readout, the background behind it
        view := layout.strobe
        view.y = layout.strobe_top
        view.height -= layout.strobe_top
        draw_rect({layout.strobe.x, layout.strobe.y}, {layout.strobe.width, layout.strobe_top}, hex(strobe_bg_color))

        if type == .TRACE {
            colors := strobe_colors(config)
            seconds, range := config.trace_seconds, config.trace_range_cents
            draw_cents_trace(&app.cents_trace, view, seconds, range, hex(colors.x), hex(colors.y), hex(strobe_bg_color))
        } else {
            draw_scope_display(display, &app.scope, view, config, app.pitch_detector.snr_db)
            // Between the wave over time and the Lissajous figure
            if type == .SCOPE && !microphone_denied() && gui_button(layout.strobe) {
                config.scope_sweep = .XY if config.scope_sweep == .TIME else .TIME
            }
        }
        // Over the whole strobe area like the strobe's, the readout's part included
        draw_strobe_shadow(display, layout.strobe)
    }

    // A denied microphone only gives silence and the strobe would just stand still, say why instead
    if microphone_denied() {
        strobe := layout.strobe
        draw_rect({strobe.x, strobe.y}, {strobe.width, strobe.height}, hex(strobe_bg_color))
        center := [2]f32{strobe.x + strobe.width / 2, strobe.y + strobe.height / 2}
        title: cstring = "Microphone access is off"
        hint: cstring = "Tap to allow it in Settings"
        title_size := measure_label(pixel_fonts.title, title)
        hint_size := measure_label(pixel_fonts.label, hint)
        draw_label(pixel_fonts.title, title, center - {title_size.x / 2, title_size.y + 4}, text_color_white)
        draw_label(pixel_fonts.label, hint, center - {hint_size.x / 2, -4}, text_color_muted)
        if gui_button(strobe) do gfx_open_url("app-settings:")
    }
}

// An arrow on the side the pitch is off to, pointing inwards the way to tune: flat on the left pointing right
// to tune up, like higher notes are to the right on the ruler
draw_tuning_arrows :: proc(app: ^App, layout: Layout, reading: Reading) {
    tuner := &app.tuner

    // Only the strong readings, a fading note drifts and would flash the arrows. The strobe's close to the
    // note, like the readout. On another note than the locked one, as far as the notes are apart.
    cents := core.tuner_cents_off(tuner, tuner.last_good_pitch.detected_freq)
    if reading.strobe_readout do cents = reading.steady.err_cents
    if reading.out_of_range do cents = f32(tuner.detected_note.cents - tuner.target_note.cents)
    distance := abs(cents)
    measures_target := core.measures_target(tuner)

    // Without a lock or a string, further than half a semitone is a neighbouring note that isn't confirmed yet
    if !tuner.active || (!measures_target && distance > 50) do return

    app.flat_arrow = core.schmitt_trigger_neg(app.flat_arrow, cents, -8, -10)
    app.sharp_arrow = core.schmitt_trigger(app.sharp_arrow, cents, 8, 10)

    arrow := pixel_fonts.strobe_arrow
    arrow_y := layout.strobe_top + 10
    if app.flat_arrow {
        draw_text(arrow.font, "▶", snap_to_pixels({layout.strobe.x + 10, arrow_y}), arrow.size, 0, accent_color)
    } else if app.sharp_arrow {
        width := measure_text(arrow.font, "◀", arrow.size, 0).x
        position := snap_to_pixels({layout.strobe.x + layout.strobe.width - 10 - width, arrow_y})
        draw_text(arrow.font, "◀", position, arrow.size, 0, accent_color)
    }
}

// The target note on the ruler with the gauge under it, or on its own with arrows, the lock, and the note's
// offset. The lock button (or space) locks the note, tapping another note on the ruler (or the arrows) locks
// that one instead.
draw_note_controls :: proc(app: ^App, layout: Layout, reading: Reading) {
    config, tuner := app.config, &app.tuner
    string_mode := current_setup(config).instrument != .CHROMATIC

    // A transposing instrument reads the written note, only what's shown moves, the steps are relative and
    // work the same either way. With a capo the strings sound higher and keep the names of the open strings,
    // like the chord shapes played over it.
    setup := current_setup(config)
    transpose := -capo_fret(setup) if string_mode else transpose_key(setup)
    shown_note := core.cents_to_note(f32(tuner.target_note.cents + 100 * transpose), tuner.target_note.pitch_standard)
    // No pitch yet, nothing to show
    if tuner.target_note.frequency == 0 do shown_note.frequency = 0

    step, browse: int
    if shows_ruler(config) {
        // The strings, or every note of a piano with the target among them
        ruler_notes: []core.Note
        target: int
        if shown_note.frequency == 0 {
            // Nothing on the ruler
        } else if string_mode {
            ruler_notes = make([]core.Note, tuner.string_count, context.temp_allocator)
            for &note, index in ruler_notes {
                note = core.cents_to_note(f32(100 * (tuner.strings[index] + transpose)), shown_note.pitch_standard)
            }
            target = tuner.string_index
        } else {
            ruler_notes = make([]core.Note, core.NOTE_COUNT, context.temp_allocator)
            for &note, index in ruler_notes {
                note = core.cents_to_note(f32(100 * (core.LOWEST_NOTE + index + transpose)), shown_note.pitch_standard)
            }
            target = clamp(tuner.target_note.cents / 100 - core.LOWEST_NOTE, 0, core.NOTE_COUNT - 1)
        }
        step, browse = gui_note_ruler(layout.ruler, ruler_notes, target, tuner.active)

        // Within half a semitone of the note, or a few semitones of a string. Another note than a locked one
        // pins it at the end on that side.
        cents := reading.steady.err_cents
        lit := tuner.active && (reading.steady.measured || reading.out_of_range)
        if reading.out_of_range do cents = 1200 * core.tuner_out_of_range_side(tuner)
        // Further than the gauge reaches from any string, e.g. a guitar's low E on a ukulele, it says so instead
        // of the gauge stuck at its end, and which way
        if string_mode && lit && abs(cents) > 100 * GAUGE_SEMITONE_TICKS {
            label: cstring = "TOO FLAT" if cents < 0 else "TOO SHARP"
            width := measure_label(pixel_fonts.label, label, 1).x
            label_y := layout.gauge.y + (GAUGE_HEIGHT - LABEL_SIZE) / 2
            draw_label(pixel_fonts.label, label, {layout.gauge.x - width / 2, label_y}, text_color_light, 1)
        } else {
            draw_cents_gauge(layout.gauge, cents, lit, string_mode, hex(strobe_colors(config).x))
        }
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
    if lock_toggled || step != 0 do app.quiet_time = 0
    retune_target := lock_toggled && core.toggle_note_lock(tuner)
    if core.step_target_note(tuner, step) do retune_target = true
    if retune_target do retune(app)

    // A note that's tuned off pitch says so between the letter and the lock, the strobe and the readout are on
    // the offset note, see gui_note_offsets. While swiping the ruler, of the note in the middle.
    middle_note := tuner.target_note
    if browse != 0 && string_mode {
        middle_note = core.string_note(tuner, tuner.string_index + browse)
    } else if browse != 0 {
        middle_note = core.cents_to_note(f32(middle_note.cents + 100 * browse), middle_note.pitch_standard)
    }
    if offset := core.note_offset_cents(tuner, middle_note); offset != 0 && shown_note.frequency != 0 {
        text := fmt.ctprintf("%+.1f¢", offset)
        width := measure_label(pixel_fonts.label, text, 1).x
        // Like the note, white while there's a pitch
        color := text_color_white if tuner.active else text_color_muted
        draw_label(pixel_fonts.label, text, layout.note_offset - {width / 2, LABEL_SIZE / 2}, color, 1)
    }
}

// The levels next to the input meter and the NSDF plots on the right
draw_debug_stats :: proc(app: ^App, layout: Layout, pitch: core.PitchInfo, meter: [2]f32) {
    stat :: proc(text: cstring, position: [2]f32, color := text_color_white, large := false) {
        font := pixel_fonts.label_large if large else pixel_fonts.label_small
        draw_text(font.font, text, position, 16 if large else 12, 0, color)
    }

    floor_level := core.dbfs(pitch.noise_floor)
    draw_rect(meter + {0, 4}, {60, 3}, hex(strobe_bg_color))
    draw_rect(meter + {0, 4}, {60 + floor_level, 3}, PURPLE)

    base_band := app.phase_comparator.bands[0]
    stat(fmt.ctprintf("Band SNR %.1f", base_band.snr_db), layout.stats)
    stat(fmt.ctprintf("Band NF %.1f", core.dbfs(base_band.noise_floor.level)), layout.stats + {0, 15})
    stat(fmt.ctprintf("RMS %.1f", pitch.rms_dbfs), layout.stats + {130, 0})
    stat(fmt.ctprintf("NF %.1f", floor_level), layout.stats + {130, 15})
    stat(fmt.ctprintf("SNR %.1f", pitch.snr_db), layout.stats + {130, 30})

    stat(fmt.ctprintf("Clarity %.3f", pitch.clarity), {500, 10}, large = true)
    if pitch.is_strong_pitch do stat("strong", {600, 10}, ORANGE, large = true)
    if pitch.is_weak_pitch do stat("weak", {600, 10}, PURPLE, large = true)

    font := pixel_fonts.label_small.font
    draw_nsdf(Rect{520, 40, 660, 200}, &app.pitch_detector.nsdf, font)
    draw_freq_plot(Rect{520, 300, 660, 200}, &app.pitch_detector.nsdf, font)
}

// The sheets that are up, over the main screen
draw_sheets :: proc(app: ^App, layout: Layout) {
    config := app.config

    // A tap on the strobe above a sheet closes it, like the ✕, Escape or a swipe down
    closes :: proc(sheet_layout: SheetLayout, swiped: bool) -> bool {
        return gui_button(above_sheet(sheet_layout)) || key_pressed(.ESCAPE) || swiped
    }

    if app.settings_sheet.slide > 0 {
        sheet := &app.settings_sheet
        sheet_layout, swiped := begin_sheet(sheet, SETTINGS_ROWS, &app.strobe_display, layout.strobe)
        close, changed := gui_settings(
            sheet_layout,
            config,
            app.audio_devices[:],
            &app.audio_device_index,
            &app.settings_menu,
            &app.display_options,
        )
        if changed do app.config_changed = true
        grab_sheet(sheet, sheet_layout)
        // Escape goes back from the display's options like the ‹
        if app.display_options && key_pressed(.ESCAPE) {
            app.display_options = false
        } else if close || closes(sheet_layout, swiped) {
            close_sheet(sheet)
            app.settings_menu = .NONE
            exclusive_control_mode = false
        }
    }

    if app.track_sheet.slide > 0 {
        sheet := &app.track_sheet
        bands := app.phase_comparator.bands[:]
        sheet_layout, swiped := begin_sheet(sheet, TRACK_SETTINGS_ROWS, &app.strobe_display, layout.strobe)
        app.selected_track = min(app.selected_track, len(bands) - 1)
        close, changed := gui_track_settings(sheet_layout, config, app.selected_track, bands[app.selected_track])
        if changed do app.config_changed = true
        grab_sheet(sheet, sheet_layout)

        // Tapping another track above the sheet switches to it, anywhere else closes the sheet
        if gui_button(above_sheet(sheet_layout)) {
            track := strobe_track_at(config.strobe_shape, layout.strobe, layout.strobe_scale, len(bands), mouse_position())
            if track >= 0 do app.selected_track = track
            else do close = true
        }
        if close || key_pressed(.ESCAPE) || swiped do close_sheet(sheet)
    }

    if app.instrument_sheet.slide > 0 {
        sheet := &app.instrument_sheet
        // Over the whole window, room for every note offset of a preset
        sheet_layout, swiped := begin_sheet(sheet, 0, &app.strobe_display, layout.strobe, gfx_window_size().y)

        // A new offset starts on the note the tuner is on
        target := -1
        if index, in_range := core.note_index(app.tuner.target_note); in_range && app.tuner.target_note.frequency != 0 {
            target = index
        }
        close, changed := gui_instrument(sheet_layout, config, &app.settings_menu, target)
        if changed {
            app.config_changed = true
            // Other notes on the ruler, it starts again on the target
            ruler_initialized = false
        }
        grab_sheet(sheet, sheet_layout)
        if close || closes(sheet_layout, swiped) {
            close_sheet(sheet)
            app.settings_menu = .NONE
            exclusive_control_mode = false
            reset_note_offsets_editing()
        }
    }
}

// Written once the sheets are down, a quit that skips the save at the end keeps what was changed: the stop
// button of a debugger, Ctrl+C in the terminal, a crash
save_when_settled :: proc(app: ^App) {
    sheets_open := app.settings_sheet.open || app.track_sheet.open || app.instrument_sheet.open
    if !app.unsaved || sheets_open do return
    save_config(app.config^)
    app.unsaved = false
}

// Fewer frames with nothing to show. The strobe is dark while no band is above the background noise, and the
// pitch detection still runs often enough to wake it up.
limit_frame_rate :: proc(app: ^App) {
    signal := app.tuner.active
    for band in app.phase_comparator.bands {
        if band.snr_db > core.STROBE_FADE_SNR_DB[0] do signal = true
    }
    touched := mouse_down() || mouse_pressed() || mouse_wheel() != 0
    sliding := ruler_swipe.gesture == .COASTING
    for sheet in ([]Sheet{app.settings_sheet, app.track_sheet, app.instrument_sheet}) {
        if sheet.slide != f32(int(sheet.open)) do sliding = true
    }

    if signal || touched || sliding {
        app.quiet_time = 0
    } else {
        app.quiet_time += gfx_frame_time()
    }
    gfx_limit_fps(IDLE_FPS if app.quiet_time > IDLE_AFTER_S else MAX_FPS)
}
