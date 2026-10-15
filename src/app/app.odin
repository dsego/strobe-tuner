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

import "core:fmt"
import "core:math"

import "../audio"
import "../core"
import "../gfx"

APP_NAME :: "Strobie"

// Show the signal stats and NSDF plots, e.g. `odin run app -debug -define:DEBUG_STATS=true`
DEBUG_STATS :: #config(DEBUG_STATS, false)

// The version and build from the Info.plist, e.g. "2.0 (1)", the bundle scripts pass it in. Shown after the
// settings' title.
VERSION :: #config(VERSION, "dev")

// With nothing to show the screen updates less often, it saves the battery of a tuner left open, see App.quiet_time
IDLE_AFTER_S :: 2
IDLE_FPS :: 30

// Otherwise the display's rate up to ProMotion's, a faster monitor would only redraw the strobe more often
MAX_FPS :: 120

// The config is written once it stopped changing this long, see save_when_settled
SAVE_SETTLE_S :: 0.5

// Vernier mode, each track turns this much faster than the one under it
VERNIER_SPEED_MULTIPLIER :: 2


// What the main loop keeps from one frame to the next
App :: struct {
    config:             ^Config,
    note_target:        core.NoteTarget,
    pitch_detector:     core.PitchDetector, // follows the pitch standard, see apply_config
    strobe_lock_in:     ^core.StrobeLockIn,
    scope:              core.Scope, // of the scope and the lamp display types, and the tracks the lamp turns
    strobe_lamp:        core.StrobeLamp, // the tracks the lamp turns, strobe_source LAMP
    input:              AudioInput,
    glow_targets:       GlowTargets, // shared by the displays that glow
    strobe_display:     StrobeDisplay,
    scope_display:      ScopeDisplay, // the scope's and the lamp's views
    trace_display:      TraceDisplay,
    spectrum_display:   SpectrumDisplay,

    open_dropdown:      Dropdown, // the dropdown whose menu is open
    settings_sheet:     Sheet,
    display_options:    bool, // the settings sheet shows the display's options, see gui_settings
    reset_confirm:      bool, // RESET on the settings sheet was tapped once and asks
    menu:               MenuCommand, // the menu bar's item chosen this frame, see handle_keys
    track_sheet:        Sheet, // a track's own, opened by tapping the track
    selected_track:     int,
    instrument_sheet:   Sheet, // the instruments and the presets, opened from the bottom left corner
    input_sheet:        Sheet, // the picker, the rate and the levels, opened by tapping the input's level

    // The arrows on the strobe, see draw_tuning_arrows
    flat_arrow:         bool,
    sharp_arrow:        bool,

    readout_track:      int, // the strobe track the readout follows, see core.strobe_readout_track
    in_tune_s:          f32, // how long the readout has held in tune, see update_in_tune_tap
    in_tune_tapped:     bool, // and it tapped, not again until the readout moves away
    held_readout:       HeldReadout, // the last one shown while the note was lit, see measure
    traced_track:      int, // the track the readout followed, the trace stays on it while its stripes show
    config_changed:     bool, // the note target and the strobe need the new config, see apply_config
    unsaved:            bool, // the config changed since it was saved, see save_when_settled
    unsaved_s:          f32, // since it last changed
    quiet_time:         f32, // seconds with no signal and nobody touching anything, see IDLE_AFTER_S
}

// This frame's measurements, for the main screen
Reading :: struct {
    pitch:          core.PitchInfo, // the latest detection
    steady:         core.PitchInfo, // the readout, the strong detections averaged
    out_of_range:   bool, // another note than a locked one is played, see core.out_of_range
    strobe_readout: bool, // the readout is the strobe track's, none without one, see measure
}

// The readout as the note went dark
HeldReadout :: struct {
    shown: bool,
    freq:  f32,
    cents: f32,
}


run_app :: proc(config: ^Config) {
    app := App {
        config        = config,
        readout_track = -1,
        traced_track  = -1,
    }
    note_target := &app.note_target
    note_target^ = core.init_note_target(config.target_freq_hz, config.pitch_standard, prevent_octave_jumps = true)

    // Saved for the next start
    defer config.target_freq_hz = note_target.target_note.frequency

    size, min_size, position := window_placement(config)
    if !gfx.init(size.x, size.y, APP_NAME, min_size, position) do return

    defer gfx.shutdown()

    setup_menu_bar(&app)

    // Loaded each frame for the screen's scale, see update_pixel_fonts
    defer unload_pixel_fonts()

    gfx.load_shapes()
    defer gfx.unload_shapes()

    app.strobe_lock_in = core.init_strobe_lock_in(
        config.target_freq_hz,
        config.strobe_intervals[:],
        config.strobe_mode,
    )
    defer core.destroy_strobe_lock_in(app.strobe_lock_in)

    app.pitch_detector = core.init_pitch_detector(config.pitch_standard)
    defer core.destroy_pitch_detector(&app.pitch_detector)

    app.scope = core.init_scope(SCOPE_COLUMNS, SCOPE_ROWS)
    defer core.destroy_scope(&app.scope)

    // Made as the first glowing display draws, see ensure_glow_targets
    defer unload_glow_targets(&app.glow_targets)

    app.strobe_display = init_strobe_display(strobe_bg_color)

    app.scope_display = init_scope_display(strobe_bg_color)
    defer destroy_scope_display(&app.scope_display)

    app.trace_display = init_trace_display()
    defer destroy_trace_display(&app.trace_display)

    app.spectrum_display = init_spectrum_display()
    defer destroy_spectrum_display(&app.spectrum_display)

    // Opened or not, the strobe area says why there's no input, see draw_strobe_area
    audio_capture := audio.init(config.input_device)
    defer audio.destroy(audio_capture)

    app.input.capture = audio_capture

    audio.register_audio_node(audio_capture, &app.pitch_detector)
    audio.register_audio_node(audio_capture, app.strobe_lock_in)
    audio.register_audio_node(audio_capture, &app.scope)
    audio.register_audio_node(audio_capture, &app.spectrum_display)
    match_input_rate(&app)
    audio.start(audio_capture)

    build_input_list(&app.input, config.input_device)
    defer delete(app.input.devices)
    defer delete(app.input.default_label)

    apply_config(&app)

    // The desktop window keeps drawing while it's dragged or zoomed to another size, the loop below is stuck
    // in the OS's own loop meanwhile
    when !gfx.MOBILE {
        gfx.live_resize_frames(proc(data: rawptr) {
            defer free_all(context.temp_allocator)
            run_frame((^App)(data))
        }, &app)
    }

    for !gfx.should_close() {
        // The labels and readouts are formatted into the temp allocator, nothing in it outlives a frame
        defer free_all(context.temp_allocator)

        if gfx.in_background() {
            wait_in_background(&app)
            continue
        }

        // Nothing to measure for, the input keeps running and the measurements start over on the audio after
        // the gap, see core.audio_capture_skip_stale
        when !gfx.MOBILE {
            if gfx.window_hidden() {
                gfx.wait_while_hidden()
                continue
            }
        }

        run_frame(&app)
    }
}

// A turn of the main loop after its events: the measurements, the layout and the drawing
run_frame :: proc(app: ^App) {
    config, audio_capture := app.config, app.input.capture
    if audio.interruption_ended(audio_capture) do app.input.restart = true

    follow_input(app)

    config_before := config^
    handle_keys(app)

    if app.config_changed do apply_config(app)

    reading := measure(app)
    update_in_tune_tap(app, reading)

    when !DEBUG_STATS {
        // A tablet draws in larger points than its own, see ui_scale
        points := gfx.window_points()
        gfx.set_ui_scale(ui_scale(points / gfx.content_scale(), gfx.ui_scale()))
        when !gfx.MOBILE do follow_window_size(config, points)
    }

    window, safe := gfx.window_size(), gfx.safe_area()

    // The plots take the rest of the window on the right
    when DEBUG_STATS {
        window.x = STROBE_WIDTH
        safe.width = STROBE_WIDTH
    }

    layout := compute_layout(window, safe, selected_preset(config) >= 0)
    update_pixel_fonts()
    update_menu_checks(app)

    gfx.begin_frame(gfx.hex(strobe_bg_color))
    defer gfx.end_frame()
    gui_begin_frame()

    // The sheets slide up over the main screen, which keeps running under them and ignores taps until
    // they're all the way down again. They're drawn at the end of the frame.
    // A sheet all the way up covers the panel, the instrument sheet the strobe too when the panel is under
    // it. A phone's strobe area still shows above that, behind the notch. Not while a sheet is dragged, it
    // may move down later in the frame.
    gui.disabled = false
    panel_covered := false
    for sheet in app_sheets(app) {
        slide_sheet(sheet)
        if sheet.open || sheet.slide > 0 do gui.disabled = true
        if sheet.slide == 1 && !sheet.drag.active do panel_covered = true
    }

    instrument_sheet := app.instrument_sheet
    covered := !layout.beside && instrument_sheet.slide == 1 && !instrument_sheet.drag.active
    strobe_shows := !covered || safe.y > 0

    feed_scope(app, strobe_shows)

    // The arrows are on the strobe, they show above the sheet
    if covered {
        if strobe_shows do draw_strobe_area(app, layout)
    } else if panel_covered {
        draw_strobe_area(app, layout)
        draw_tuning_arrows(app, layout, reading)
    } else {
        draw_main_screen(app, layout, reading)
    }
    draw_sheets(app, layout, reading)

    if config^ != config_before do app.unsaved, app.unsaved_s = true, 0

    save_when_settled(app)
    limit_frame_rate(app)
}

// The strobe on the target note with the current tracks, speed and mode
retune :: proc(app: ^App) {
    config := app.config
    app.traced_track = -1 // the tracks are at another note now
    app.held_readout = {}
    app.strobe_lock_in.readout_fit_s = config.readout_fit_s
    core.set_strobe_lock_in_tracks(
        app.strobe_lock_in,
        config.strobe_intervals[:],
        config.strobe_offsets_cents[:],
        config.strobe_speeds[:],
    )
    core.set_strobe_lock_in_freq(
        app.strobe_lock_in,
        core.target_freq(&app.note_target),
        config.pitch_standard,
        strobe_speed(config),
        VERNIER_SPEED_MULTIPLIER,
        config.strobe_mode,
    )
}

// The pitch detection, the note target and the strobe brought up to the config, at the start and after a
// change. The tracks start over, so only for what they measure: the displays read their colors and options from
// the config as they draw.
apply_config :: proc(app: ^App) {
    note_target, config := &app.note_target, app.config

    // Same notes, retuned to the pitch standard
    app.pitch_detector.pitch_standard = config.pitch_standard
    core.set_target_pitch_standard(note_target, config.pitch_standard)
    note_target.offsets_cents = active_note_offsets(config)
    core.set_target_strings(note_target, tuning_strings(config))

    retune(app)
    app.config_changed = false
}

// A phone suspends the app in the background and may end it there without warning. The config is saved on the
// way out, the input is opened again on the way back.
wait_in_background :: proc(app: ^App) {
    app.config.target_freq_hz = app.note_target.target_note.frequency
    save_config(app.config^)
    audio.stop(app.input.capture)
    gfx.wait_for_foreground()
    app.input.restart = true
}

// Settings… from the menu bar or Ctrl+, closes the settings when they're up, the sheet covers the strobe
toggle_settings_sheet :: proc(app: ^App) {
    if app.settings_sheet.open do close_settings_sheet(app)
    else do open_settings_sheet(app)
}

// Over whichever sheet is up
open_settings_sheet :: proc(app: ^App) {
    for sheet in app_sheets(app) do if sheet != &app.settings_sheet do dismiss_sheet(app, sheet)
    reset_note_offsets_editing()

    app.settings_sheet.open = true
    app.display_options = false
    app.reset_confirm = false
}

handle_keys :: proc(app: ^App) {
    config := app.config

    // A menu item's key reaches the keys here too, the plain ones skip while Command is down
    app.menu = MenuCommand(gfx.menu_command())
    command := gfx.key_down(.LEFT_SUPER) || gfx.key_down(.RIGHT_SUPER)
    plain := !command

    #partial switch app.menu {
    case .SETTINGS:
        toggle_settings_sheet(app)
    case .RETRO_GLOW:
        config.strobe_glow = !config.strobe_glow
    case .DEFAULT_SIZE:
        config.window_size = {}
    }
    for menu_command, type in DISPLAY_COMMANDS {
        if app.menu == menu_command do config.strobe_display_type = type
    }
    for menu_command, colorway in COLORWAY_COMMANDS {
        if app.menu == menu_command do config.strobe_colorway = colorway
    }

    // Opened in the next frame like a pick on the input's sheet, see follow_input
    input := int(app.menu) - int(MenuCommand.INPUTS)
    if input >= 0 && input < len(app.input.devices) do app.input.device_index = input

    if plain && gfx.key_pressed(.G) do config.strobe_glow = !config.strobe_glow

    if plain && gfx.key_pressed(.TAB) do config.strobe_display_type = next_display(config.strobe_display_type)

    // Or straight to one, in the settings' order
    DISPLAY_KEYS :: [StrobeDisplayType]gfx.Key {
        .STROBE   = .NUM_1,
        .SCOPE    = .NUM_2,
        .TRACE    = .NUM_3,
        .LAMP     = .NUM_4,
        .SPECTRUM = .NUM_5,
    }
    for key, type in DISPLAY_KEYS {
        if plain && gfx.key_pressed(key) do config.strobe_display_type = type
    }

    // The next preset of the tracks, it replaces the partials and clears what was set on each track
    if plain && gfx.key_pressed(.I) && config.strobe_mode == .HARMONIC {
        options, defaults := INTERVAL_OPTIONS, config_defaults
        config.strobe_intervals_index = (config.strobe_intervals_index + 1) % len(options)
        config.strobe_intervals = options[config.strobe_intervals_index]
        config.strobe_offsets_cents = defaults.strobe_offsets_cents
        config.strobe_speeds = defaults.strobe_speeds
        retune(app)
    }

    // Hidden, the tracks' band a semitone, a half or a quarter wide: each half has half the noise and twice the lag.
    // The screens' persistence follows, as many periods as the band's window, so the lamp's tracks narrow along
    // with the lock-in's and the two can be compared like for like.
    if plain && gfx.key_pressed(.W) {
        lock_in := app.strobe_lock_in
        lock_in.band_cents = lock_in.band_cents / 2 if lock_in.band_cents > 25 else core.DFT_RESOLUTION_CENTS
        config.persistence_periods = 1 / (math.pow(f32(2), f32(lock_in.band_cents) / 1200) - 1)
        fmt.printfln("Strobe band: %d cents, persistence %.0f periods", lock_in.band_cents, config.persistence_periods)
        retune(app)
    }

    // Without a menu bar Ctrl+, opens the settings and Ctrl+0 puts the window back to the strobe's size, see
    // follow_window_size
    when !gfx.MOBILE && ODIN_OS != .Darwin {
        control := gfx.key_down(.LEFT_CONTROL) || gfx.key_down(.RIGHT_CONTROL)
        if control && gfx.key_pressed(.COMMA) do toggle_settings_sheet(app)

        if control && gfx.key_pressed(.NUM_0) do config.window_size = {}
    }
}

// The In-tune tap: once the strobe's readout holds within IN_TUNE_CENTS for IN_TUNE_HOLD_S the phone taps,
// once. The readout is the strobe's own, in tune there is when its stripes have all but stopped. It taps again
// only after the readout went further than IN_TUNE_REARM_CENTS or away, another note or the note gone dark,
// a readout wavering at the edge doesn't tap over and over.
IN_TUNE_CENTS :: 1
IN_TUNE_HOLD_S :: 0.3
IN_TUNE_REARM_CENTS :: 3

update_in_tune_tap :: proc(app: ^App, reading: Reading) {
    if !app.config.in_tune_tap || !gfx.has_haptics() do return

    // Dark, the readout shown is the held one, see measure
    cents := abs(reading.steady.err_cents)
    if !app.note_target.active || !reading.strobe_readout || cents > IN_TUNE_REARM_CENTS {
        app.in_tune_s, app.in_tune_tapped = 0, false
        return
    }
    if cents > IN_TUNE_CENTS {
        app.in_tune_s = 0
        return
    }

    app.in_tune_s += gfx.frame_time()
    if app.in_tune_s >= IN_TUNE_HOLD_S && !app.in_tune_tapped {
        gfx.haptic_tap()
        app.in_tune_tapped = true
    }
}

// The pitch detection, the strobe and the note target on the new audio
measure :: proc(app: ^App) -> (reading: Reading) {
    note_target := &app.note_target
    reading.pitch = core.run_pitch_detection(&app.pitch_detector, note_target.pitch)
    core.run_phase_detection(app.strobe_lock_in, reading.pitch.is_tonal)

    // The track the readout follows. The strobe keeps the note lit while it shows it. Retuned to another note the
    // tracks start over, their reading was from the note before.
    ready: bool
    app.readout_track, ready = core.strobe_readout_track(app.strobe_lock_in, app.readout_track)
    if core.update_note_target(note_target, reading.pitch, core.strobe_shows_note(app.strobe_lock_in)) {
        retune(app)
        ready = false
    }

    reading.out_of_range = core.out_of_range(note_target)
    reading.steady = core.readout_pitch(note_target)

    // The readout is the strobe's, 0 where the fundamental's track stands still, none until a track has settled
    // after the pluck. The pitch detection only picks the note: it reads the whole wave, a real string's partials
    // are a little sharp and pull it a few cents off the track you see. The Hz move along with the cents. A
    // fading note keeps its track's last reading, also once the note target lets go of it.
    steady := &reading.steady
    reading.strobe_readout = ready && !reading.out_of_range
    reading.strobe_readout &&= abs(app.strobe_lock_in.bands[app.readout_track].err_cents) <= core.READOUT_RANGE_CENTS

    if reading.strobe_readout {
        band := app.strobe_lock_in.bands[app.readout_track]
        steady.detected_freq = core.freq_at_cents(steady.detected_freq, band.err_cents - steady.err_cents)
        steady.err_cents = band.err_cents
    }

    // The readout's cents, the strobe's so an in tune note is on the middle line, none before a track settled.
    // The track the readout followed carries on as the note decays and the readout gives way, the line as lit as
    // its stripes and dark with them, not the noisy weak detections.
    if reading.strobe_readout do app.traced_track = app.readout_track

    // Lit, the readout is the track's as it measures. Dark, it keeps the last one shown: the track goes on
    // measuring whatever passes through its band, the room's noise would read as a wandering pitch. Another
    // note starts over, see retune.
    held := &app.held_readout
    if note_target.active {
        if reading.strobe_readout do held^ = {true, steady.detected_freq, steady.err_cents}
    } else {
        reading.strobe_readout = held.shown
        steady.detected_freq, steady.err_cents = held.freq, held.cents
    }

    light: f32 = 1
    traced_cents := math.nan_f32()

    if app.traced_track >= 0 {
        band := app.strobe_lock_in.bands[app.traced_track]
        fade := core.STROBE_FADE_SNR_DB
        light = math.smoothstep(fade[0], fade[1], band.snr_db)
        if light == 0 || !band.in_range do app.traced_track = -1

        if app.traced_track >= 0 && !reading.out_of_range && abs(band.err_cents) <= core.READOUT_RANGE_CENTS {
            traced_cents = band.err_cents
        }
    }

    record_trace(&app.trace_display, traced_cents, light, reading.pitch.fresh, gfx.frame_time())

    // The spectrum of what came in, only while it's the display
    config := app.config
    if config.strobe_display_type == .SPECTRUM do update_spectrum_display(&app.spectrum_display, config.spectrum_windows)

    return
}

// The new audio onto the scope's screen, while its views or the tracks the lamp turns show it. strobe_shows
// is false while a sheet covers the whole strobe area.
feed_scope :: proc(app: ^App, strobe_shows: bool) {
    scope, config := &app.scope, app.config

    type := config.strobe_display_type
    shown := type == .SCOPE || type == .LAMP || (type == .STROBE && config.strobe_source == .LAMP)

    if !shown || !strobe_shows {
        core.skip_scope(scope)

        // The lamp's tracks start over on a dark screen too, the phases they turned by are stale
        app.strobe_lamp.freq_hz = 0
        return
    }

    // At the strobe's frequency, not the target note's: that one jumps an octave with the detection while
    // the strobe stays, and every change starts with a dark screen
    strobe_hz := f64(app.strobe_lock_in.base_freq_hz)
    if scope.freq_hz != strobe_hz do core.set_scope_freq(scope, strobe_hz)

    // The lamp is the screen from above, it needs the sweep over time, and so do the tracks it turns
    sweep := config.scope_sweep if config.strobe_display_type == .SCOPE else .TIME
    if scope.sweep != sweep do core.set_scope_sweep(scope, sweep)

    // In periods of the strobe's frequency, the smear and the waver per cent look the same on every note
    scope.persistence_seconds = f64(config.persistence_periods) / strobe_hz
    scope.gain = config.scope_gain
    scope.noise_floor = app.pitch_detector.noise_floor.level
    core.update_scope(scope)
}

// The sheets that are up, over the main screen
draw_sheets :: proc(app: ^App, layout: Layout, reading: Reading) {
    // Android's back button is Escape. It closes a sheet, with none up it leaves the app as anywhere else.
    when gfx.ANDROID {
        sheets_down := true
        for sheet in app_sheets(app) do sheets_down &&= sheet.slide == 0
        if gfx.key_pressed(.ESCAPE) && sheets_down do gfx.system_back()
    }

    draw_settings_sheet(app, layout)
    draw_track_sheet(app, layout)
    draw_instrument_sheet(app, layout)
    draw_input_sheet(app, layout, reading)
}

draw_settings_sheet :: proc(app: ^App, layout: Layout) {
    sheet := &app.settings_sheet
    if sheet.slide == 0 do return

    // The display's options page has rows of its own, the strobe's more than the settings
    rows := settings_rows()
    if app.display_options {
        option_rows := DISPLAY_OPTION_ROWS
        rows = max(rows, option_rows[app.config.strobe_display_type])
    }

    sheet_layout, swiped := begin_sheet(sheet, rows, layout)
    close, changed := gui_settings(sheet_layout, app.config, &app.display_options, &app.reset_confirm, &app.open_dropdown)
    if changed do app.config_changed = true

    grab_sheet(sheet, sheet_layout)

    // Escape goes back from the display's options like the ‹
    if app.display_options && gfx.key_pressed(.ESCAPE) {
        app.display_options = false
    } else if close || sheet_dismissed(sheet_layout, swiped) {
        close_settings_sheet(app)
    }
}

close_settings_sheet :: proc(app: ^App) {
    dismiss_sheet(app, &app.settings_sheet)
    app.reset_confirm = false
}

// Every sheet, one is up at a time
app_sheets :: proc(app: ^App) -> [4]^Sheet {
    return {&app.settings_sheet, &app.track_sheet, &app.instrument_sheet, &app.input_sheet}
}

// Closed with the dropdown menu that may be open on it
dismiss_sheet :: proc(app: ^App, sheet: ^Sheet) {
    close_sheet(sheet)
    app.open_dropdown = .NONE
    gui.menu_open = false
}

// The display after this one, the button and Tab go round them in the settings' order
next_display :: proc(type: StrobeDisplayType) -> StrobeDisplayType {
    return StrobeDisplayType((int(type) + 1) % len(StrobeDisplayType))
}

draw_input_sheet :: proc(app: ^App, layout: Layout, reading: Reading) {
    sheet := &app.input_sheet
    if sheet.slide == 0 do return

    // A few times a second, the latest detection's
    input := &app.input
    input.stats_age += gfx.frame_time()
    if input.stats_age >= INPUT_STATS_HOLD_S {
        pitch := reading.pitch

        // The floor is the level's average, quiet wobbles under it, the SNR of the background is 0. None
        // until something was measured, e.g. without an input, a reading that isn't one would be 0 dBFS.
        none := math.nan_f32()
        input.stats = {none, none, none}
        if pitch.measured do input.stats = {pitch.rms_dbfs, core.dbfs(pitch.noise_floor), max(pitch.snr_db, 0)}
        input.stats_age = 0
    }

    capture := input.capture
    device_name := "No input"
    if audio.device_count(capture) > 0 do device_name = audio.device_name(capture, capture.active_device)

    sheet_layout, swiped := begin_sheet(sheet, INPUT_ROWS, layout)
    close := gui_audio_input(
        sheet_layout,
        device_name,
        capture.device_rate,
        capture.sample_rate,
        input.stats,
        input.devices[:],
        &input.device_index,
        &app.open_dropdown,
    )
    grab_sheet(sheet, sheet_layout)

    if close || sheet_dismissed(sheet_layout, swiped) {
        dismiss_sheet(app, sheet)
    }
}

draw_track_sheet :: proc(app: ^App, layout: Layout) {
    sheet := &app.track_sheet
    if sheet.slide == 0 do return

    config := app.config
    bands := app.strobe_lock_in.bands[:]
    sheet_layout, swiped := begin_sheet(sheet, TRACK_SETTINGS_ROWS, layout)
    app.selected_track = min(app.selected_track, len(bands) - 1)
    close, changed := gui_track_settings(sheet_layout, config, app.selected_track, bands[app.selected_track])
    if changed do app.config_changed = true

    grab_sheet(sheet, sheet_layout)

    // Tapping another track outside the sheet switches to it, anywhere else closes the sheet
    if gui_button(sheet_layout.outside) {
        track := strobe_track_at(config.strobe_shape, layout.strobe, layout.strobe_scale, layout.strobe_turned, len(bands), gfx.mouse_position())
        if track >= 0 do app.selected_track = track
        else do close = true
    }

    if close || gfx.key_pressed(.ESCAPE) || swiped do close_sheet(sheet)
}

draw_instrument_sheet :: proc(app: ^App, layout: Layout) {
    sheet := &app.instrument_sheet
    if sheet.slide == 0 do return

    // Over the whole window, room for every note offset of a preset
    sheet_layout, swiped := begin_sheet(sheet, 0, layout, gfx.window_size().y)

    // A new offset starts on the note the strobe is on
    target := -1
    if index, in_range := core.note_index(app.note_target.target_note); in_range {
        target = index
    }
    close, changed := gui_instrument(sheet_layout, app.config, &app.open_dropdown, target)
    if changed {
        app.config_changed = true

        // Other notes on the ruler, it starts again on the target
        note_ruler.initialized = false
    }
    grab_sheet(sheet, sheet_layout)

    if close || sheet_dismissed(sheet_layout, swiped) {
        dismiss_sheet(app, sheet)
        reset_note_offsets_editing()
    }
}

// Written once the sheets are down, a quit that skips the save at the end keeps what was changed: the stop
// button of a debugger, Ctrl+C in the terminal, a crash. And once it stopped changing for SAVE_SETTLE_S, a
// window dragged bigger where the system's loop doesn't hold the frames, e.g. Linux, isn't written every frame.
save_when_settled :: proc(app: ^App) {
    sheets_open := false
    for sheet in app_sheets(app) do sheets_open ||= sheet.open
    if !app.unsaved || sheets_open do return

    app.unsaved_s += gfx.frame_time()
    if app.unsaved_s < SAVE_SETTLE_S do return

    // With the note the strobe is on, a crash or a stop from the debugger starts on it too
    app.config.target_freq_hz = app.note_target.target_note.frequency
    save_config(app.config^)
    app.unsaved, app.unsaved_s = false, 0
}

// The window opens where it was last used and at its size, see follow_window_size. The plots take a window of
// their own size, it stays as it is.
window_placement :: proc(config: ^Config) -> (size, min_size: [2]i32, position: Maybe([2]i32)) {
    min_size = WINDOW_MIN_SIZE
    size = {STROBE_WIDTH, DESKTOP_HEIGHT}
    when DEBUG_STATS {
        min_size = {}
        size.x = 1200
    } else {
        if config.window_size != {} {
            size = {i32(config.window_size.x), i32(config.window_size.y)}
            position = [2]i32{i32(config.window_position.x), i32(config.window_position.y)}
        }
    }

    return
}

// The desktop window opens where it was last used and at its size, kept up to date here once a drag is over
// rather than on every frame of it, where the system's loop draws the drag's frames, macOS. Elsewhere every
// frame, the save waits for it to settle. A size of 0 is a reset's or Cmd+0's, the window goes back to the strobe's
// size where it is. window is the window's own size, in the system's points, the same it's opened with.
follow_window_size :: proc(config: ^Config, window: [2]f32) {
    if config.window_size == {} {
        gfx.set_window_size(STROBE_WIDTH, DESKTOP_HEIGHT)
        config.window_size = {STROBE_WIDTH, DESKTOP_HEIGHT}
    } else if !gfx.resizing() {
        config.window_size = {int(window.x), int(window.y)}
        position := gfx.window_position()
        config.window_position = {int(position.x), int(position.y)}
    }
}

// Fewer frames with nothing to show. The strobe is dark while no band is above the background noise, and the
// pitch detection still runs often enough to wake it up.
limit_frame_rate :: proc(app: ^App) {
    signal := app.note_target.active
    for band in app.strobe_lock_in.bands {
        if band.snr_db > core.STROBE_FADE_SNR_DB[0] do signal = true
    }
    touched := gfx.mouse_down() || gfx.mouse_pressed() || gfx.mouse_wheel() != 0
    sliding := note_ruler.swipe.gesture == .COASTING
    for sheet in app_sheets(app) {
        if sheet.slide != f32(int(sheet.open)) do sliding = true
    }

    if signal || touched || sliding {
        app.quiet_time = 0
    } else {
        app.quiet_time += gfx.frame_time()
    }
    gfx.limit_fps(IDLE_FPS if app.quiet_time > IDLE_AFTER_S else MAX_FPS)
}
