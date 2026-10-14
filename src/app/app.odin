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

// A picked input that's gone is looked for this often, the system says nothing when one is plugged in that
// isn't its default
MISSING_INPUT_POLL_S :: 2

// The config is written once it stopped changing this long, see save_when_settled
SAVE_SETTLE_S :: 0.5

// Vernier mode, each track turns this much faster than the one under it
VERNIER_SPEED_MULTIPLIER :: 2


// What the main loop keeps from one frame to the next
App :: struct {
    config:             ^Config,
    tuner:              core.Tuner,
    pitch_detector:     core.PitchDetector, // follows the pitch standard, see apply_config
    phase_comparator:   ^core.PhaseComparator,
    scope:              core.Scope, // of the scope and the lamp display types, and the tracks the lamp turns
    audio_capture:      ^audio.Capture,
    audio_devices:      [dynamic]GuiOption,
    audio_device_index: int, // in audio_devices, picked on the input's sheet
    input_listed:       int, // audio_device_index as list_inputs picked it, another one is a pick
    refresh_inputs:     bool, // the list is made again, see follow_input
    default_label:      string, // the list's first input, see list_inputs
    input_menu:         int, // the Input menu, see setup_menu_bar
    strobe_display:     StrobeDisplay,
    cents_trace:        Trace,
    spectrum_view:      SpectrumView,

    settings_menu:      SettingsMenu, // the dropdown whose menu is open
    settings_sheet:     Sheet,
    display_options:    bool, // the settings sheet shows the display's options, see gui_settings
    reset_confirm:      bool, // RESET on the settings sheet was tapped once and asks
    menu:               MenuCommand, // the menu bar's item chosen this frame, see handle_keys
    track_sheet:        Sheet, // a track's own, opened by tapping the track
    selected_track:     int,
    instrument_sheet:   Sheet, // the instruments and the presets, opened from the bottom left corner
    input_sheet:        Sheet, // the picker, the rate and the levels, opened by tapping the input's level
    input_stats:        InputStats, // on its sheet, held INPUT_STATS_HOLD_S
    input_stats_age:    f32,

    // The arrows on the strobe, see draw_tuning_arrows
    flat_arrow:         bool,
    sharp_arrow:        bool,

    readout_track:      int, // the strobe track the readout follows, see core.strobe_readout_track
    in_tune_s:          f32, // how long the readout has held in tune, see update_in_tune_tap
    in_tune_tapped:     bool, // and it tapped, not again until the readout moves away
    held_readout:       HeldReadout, // the last one shown while the note was lit, see measure
    traced_track:      int, // the track the readout followed, the trace stays on it while its stripes show
    config_changed:     bool, // the tuner and the strobe need the new config, see apply_config
    unsaved:            bool, // the config changed since it was saved, see save_when_settled
    unsaved_s:          f32, // since it last changed
    restart_audio:      bool, // opens the input again, after the background or an interruption
    missing_input_s:    f32, // since the picked input was last looked for, see MISSING_INPUT_POLL_S
    quiet_time:         f32, // seconds with no signal and nobody touching anything, see IDLE_AFTER_S
}

// This frame's measurements, for the main screen
Reading :: struct {
    pitch:          core.PitchInfo, // the latest detection
    steady:         core.PitchInfo, // the readout, the strong detections averaged
    out_of_range:   bool, // another note than a locked one is played, see core.tuner_out_of_range
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
    tuner := &app.tuner
    tuner^ = core.init_tuner(config.target_freq_hz, config.pitch_standard, prevent_octave_jumps = true)
    configure_tuner(&app)

    // Saved for the next start
    defer config.target_freq_hz = tuner.target_note.frequency

    // The window opens where it was last used and at its size, see follow_window_size. The plots take a window
    // of their own size, it stays as it is.
    min_size := WINDOW_MIN_SIZE
    size := [2]i32{STROBE_WIDTH, DESKTOP_HEIGHT}
    position: Maybe([2]i32)
    when DEBUG_STATS {
        min_size = {}
        size.x = 1200
    } else {
        if config.window_size != {} {
            size = {i32(config.window_size.x), i32(config.window_size.y)}
            position = [2]i32{i32(config.window_position.x), i32(config.window_position.y)}
        }
    }

    if !gfx.init(size.x, size.y, APP_NAME, min_size, position) do return

    defer gfx.shutdown()

    setup_menu_bar(&app)

    // Loaded each frame for the screen's scale, see update_pixel_fonts
    defer unload_pixel_fonts()

    gfx.load_shapes()
    defer gfx.unload_shapes()

    app.phase_comparator = core.init_phase_comparator(
        config.target_freq_hz,
        config.strobe_intervals[:],
        config.strobe_mode,
    )
    defer core.destroy_phase_comparator(app.phase_comparator)

    app.pitch_detector = core.init_pitch_detector(config.pitch_standard)
    defer core.destroy_pitch_detector(&app.pitch_detector)

    app.scope = core.init_scope(SCOPE_COLUMNS, SCOPE_ROWS)
    defer core.destroy_scope(&app.scope)

    app.strobe_display = init_strobe_display(strobe_bg_color)
    defer destroy_strobe_display(&app.strobe_display)

    app.cents_trace = create_trace()
    defer destroy_trace(&app.cents_trace)

    app.spectrum_view = init_spectrum_view()
    defer destroy_spectrum_view(&app.spectrum_view)

    // Opened or not, the strobe area says why there's no input, see draw_strobe_area
    audio_capture := audio.init(config.input_device)
    defer audio.destroy(audio_capture)

    app.audio_capture = audio_capture

    audio.register_node(audio_capture, &app.pitch_detector)
    audio.register_node(audio_capture, app.phase_comparator)
    audio.register_node(audio_capture, &app.scope)
    audio.register_node(audio_capture, &app.spectrum_view)
    match_input_rate(&app)
    audio.start(audio_capture)

    list_inputs(&app)
    defer delete(app.audio_devices)
    defer delete(app.default_label)

    retune(&app)

    // The desktop window keeps drawing while it's dragged or zoomed to another size, the loop below is stuck
    // in the OS's own loop meanwhile
    when !gfx.MOBILE {
        gfx.live_resize_frames(proc(data: rawptr) {
            defer free_all(context.temp_allocator)
            frame((^App)(data))
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

        frame(&app)
    }
}

// A turn of the main loop after its events: the measurements, the layout and the drawing
frame :: proc(app: ^App) {
    config, audio_capture := app.config, app.audio_capture
    if audio.interruption_ended(audio_capture) do app.restart_audio = true

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
    gui_press_taken = false

    // The sheets slide up over the main screen, which keeps running under them and ignores taps until
    // they're all the way down again. They're drawn at the end of the frame.
    // A sheet all the way up covers the panel, the instrument sheet the strobe too when the panel is under
    // it. A phone's strobe area still shows above that, behind the notch. Not while a sheet is dragged, it
    // may move down later in the frame.
    gui_disabled = false
    panel_covered := false
    for sheet in app_sheets(app) {
        slide_sheet(sheet)
        if sheet.open || sheet.slide > 0 do gui_disabled = true
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
    app.phase_comparator.readout_fit_s = config.readout_fit_s
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
        strobe_speed(config),
        VERNIER_SPEED_MULTIPLIER,
        config.strobe_mode,
    )
}

// The tuner's settings from the config, all but the pitch standard, see apply_config
configure_tuner :: proc(app: ^App) {
    tuner, config := &app.tuner, app.config
    tuner.offsets_cents = active_note_offsets(config)
    core.set_tuner_strings(tuner, tuning_strings(config))
}

// The pitch detection, the tuner and the strobe brought up to the config. The tracks start over, so only
// for what they measure: the displays read their colors and options from the config as they draw.
apply_config :: proc(app: ^App) {
    config := app.config

    // Same notes, retuned to the pitch standard
    app.pitch_detector.pitch_standard = config.pitch_standard
    core.set_tuner_pitch_standard(&app.tuner, config.pitch_standard)
    configure_tuner(app)

    retune(app)
    app.config_changed = false
}

// A phone suspends the app in the background and may end it there without warning. The config is saved on the
// way out, the input is opened again on the way back.
wait_in_background :: proc(app: ^App) {
    app.config.target_freq_hz = app.tuner.target_note.frequency
    save_config(app.config^)
    audio.stop(app.audio_capture)
    gfx.wait_for_foreground()
    app.restart_audio = true
}

// The input as it's picked and as the system has it. A pick on the input's sheet or in the Input menu is kept
// by its name, for the next start too. The list is made again when the system changed it, or the sheet or the
// menu opens, and every MISSING_INPUT_POLL_S while a picked input is gone, it waits on the system default
// until it's back. Before the frame copies the config, the name the config had is freed here.
follow_input :: proc(app: ^App) {
    capture := app.audio_capture

    // Picked since the last frame, the list's own pick is input_listed
    if app.audio_device_index != app.input_listed {
        picked := picked_device(app)
        set_input_device(app.config, "" if picked == audio.SYSTEM_DEFAULT else audio.device_name(capture, picked))
        app.input_listed = app.audio_device_index
        app.unsaved = true
    }

    if audio.devices_changed(capture) {
        app.refresh_inputs = true
        app.restart_audio = true
    }

    missing := app.config.input_device != "" && audio.find_device(capture, app.config.input_device) == audio.SYSTEM_DEFAULT
    app.missing_input_s = app.missing_input_s + gfx.frame_time() if missing else 0
    if app.missing_input_s >= MISSING_INPUT_POLL_S {
        app.missing_input_s = 0
        app.refresh_inputs = true
    }
    if app.refresh_inputs {
        app.refresh_inputs = false
        audio.refresh_devices(capture)
        list_inputs(app)

        // One may be there now
        if audio.input_failed(capture) do app.restart_audio = true
    }

    if app.restart_audio || picked_device(app) != capture.active_device do switch_input(app)
}

// The list on the input's sheet and in the Input menu: the system default with the device it is now, then
// the devices, none without any. The config's input is picked, the default while it isn't connected. The
// one opened follows in follow_input.
list_inputs :: proc(app: ^App) {
    capture := app.audio_capture
    clear(&app.audio_devices)
    app.audio_device_index, app.input_listed = 0, 0

    if audio.device_count(capture) > 0 {
        delete(app.default_label)
        default_name := audio.device_name(capture, audio.SYSTEM_DEFAULT)
        if default_name == "" do app.default_label = fmt.aprint("Default")
        else do app.default_label = fmt.aprintf("Default (%s)", default_name)

        append(&app.audio_devices, GuiOption{audio.SYSTEM_DEFAULT, app.default_label})
        wanted := audio.find_device(capture, app.config.input_device)
        for index in 0 ..< audio.device_count(capture) {
            append(&app.audio_devices, GuiOption{index, audio.device_name(capture, index)})
            if index == wanted do app.audio_device_index = len(app.audio_devices) - 1
        }
        app.input_listed = app.audio_device_index
    }

    // The default, a line, the devices. As many as there are commands for, the sheet has them all.
    items: [dynamic]gfx.MenuItem
    items.allocator = context.temp_allocator
    for option, index in app.audio_devices[:min(len(app.audio_devices), MAX_INPUT_COMMANDS)] {
        if index == 1 do append(&items, gfx.MenuItem{})
        append(&items, gfx.MenuItem{title = fmt.ctprintf("%s", option.label), command = int(MenuCommand.INPUTS) + index})
    }
    if len(items) == 0 do append(&items, gfx.MenuItem{title = "No Input Found"})

    gfx.set_menu_items(app.input_menu, items[:])

    // Checked already, the menu may be opening now and show before the next frame's update_menu_checks
    if len(app.audio_devices) > 0 && app.audio_device_index < MAX_INPUT_COMMANDS {
        gfx.set_menu_checked(int(MenuCommand.INPUTS) + app.audio_device_index, true)
    }
}

// The input picked, or the same one again, the measurements start afresh on it. Without any there's nothing
// to open.
switch_input :: proc(app: ^App) {
    app.restart_audio = false
    if len(app.audio_devices) == 0 do return

    // Nothing of the previous input's carries over, the readout it held included
    audio.switch_device(app.audio_capture, picked_device(app))
    core.reset_pitch_detector(&app.pitch_detector)
    core.reset_phase_comparator(app.phase_comparator)
    core.reset_scope(&app.scope)
    reset_spectrum_view(&app.spectrum_view)
    app.readout_track, app.traced_track = -1, -1
    app.held_readout = {}
    match_input_rate(app)
}

// The measurements at the rate the input opened at, their windows and filters sized for it. Only a new rate
// changes anything, the strobe's windows are retuned to it. Nothing without an input.
match_input_rate :: proc(app: ^App) {
    sample_rate := app.audio_capture.sample_rate
    if sample_rate == 0 || sample_rate == app.phase_comparator.sample_rate do return

    core.set_pitch_detector_sample_rate(&app.pitch_detector, sample_rate)
    core.set_phase_comparator_sample_rate(app.phase_comparator, sample_rate)
    core.set_scope_sample_rate(&app.scope, sample_rate)
    set_spectrum_view_sample_rate(&app.spectrum_view, sample_rate)
    retune(app)
}

// The input's index picked in the settings, the open one without a list
picked_device :: proc(app: ^App) -> i32 {
    if len(app.audio_devices) == 0 do return app.audio_capture.active_device

    return app.audio_devices[app.audio_device_index].id
}

// The macOS menu bar's commands, see setup_menu_bar. Each key has Command in it, see handle_keys.
MenuCommand :: enum {
    NONE,
    SETTINGS,
    SHOW_STROBE,
    SHOW_SCOPE,
    SHOW_TRACE,
    SHOW_LAMP,
    SHOW_SPECTRUM,
    COLORS_RED,
    COLORS_MINT,
    COLORS_AMBER,
    COLORS_MONO,
    RETRO_GLOW,
    LOCK_NOTE,
    DEFAULT_SIZE,
    INPUTS, // and the ones after it, the Input menu's by their place in audio_devices, see list_inputs
}

MAX_INPUT_COMMANDS :: gfx.MAX_MENU_COMMANDS - int(MenuCommand.INPUTS)

// The display each of the View menu's first items shows, in the settings' order
DISPLAY_COMMANDS :: [StrobeDisplayType]MenuCommand {
    .STROBE   = .SHOW_STROBE,
    .SCOPE    = .SHOW_SCOPE,
    .TRACE    = .SHOW_TRACE,
    .LAMP     = .SHOW_LAMP,
    .SPECTRUM = .SHOW_SPECTRUM,
}

// The colors the View menu's second group picks, named like the settings' Colors
COLORWAY_COMMANDS :: [StrobeColorway]MenuCommand {
    .VIBRANT_RED = .COLORS_RED,
    .MINTY       = .COLORS_MINT,
    .AMBER       = .COLORS_AMBER,
    .MONO        = .COLORS_MONO,
}

// SDL's app menu gets Settings…, the View menu the displays, the colors, the glow and the lock, the Input
// menu the inputs, the Window menu the strobe's size back. Resetting stays on the settings sheet, where
// RESET asks first.
setup_menu_bar :: proc(app: ^App) {
    gfx.add_app_menu_items(int(MenuCommand.SETTINGS), {})

    // The displays by their number keys, named like on the settings, and the colors
    view := make([dynamic]gfx.MenuItem, context.temp_allocator)
    display_names, display_commands := DISPLAY_NAMES, DISPLAY_COMMANDS
    for type in StrobeDisplayType {
        key := fmt.ctprintf("%d", int(type) + 1)
        append(&view, gfx.MenuItem{title = display_names[type], key = key, command = int(display_commands[type])})
    }
    append(&view, gfx.MenuItem{})

    colorway_names, colorway_commands := COLORWAY_NAMES, COLORWAY_COMMANDS
    for colorway in StrobeColorway {
        append(&view, gfx.MenuItem{title = colorway_names[colorway], command = int(colorway_commands[colorway])})
    }
    append(
        &view,
        gfx.MenuItem{},
        gfx.MenuItem{title = "Retro Glow", key = "g", command = int(MenuCommand.RETRO_GLOW)},
        gfx.MenuItem{title = "Lock Note", key = "l", command = int(MenuCommand.LOCK_NOTE)},
    )
    gfx.add_menu("View", view[:])

    // Filled by list_inputs, and the list made again as it opens for what's connected now. The one opened
    // follows in the next frame, see follow_input.
    looking :: proc(data: rawptr) {
        app := (^App)(data)
        if app.audio_capture == nil do return

        audio.refresh_devices(app.audio_capture)
        list_inputs(app)
    }
    app.input_menu = gfx.add_menu("Input", {}, looking, app)

    gfx.add_window_menu_items({{title = "Strobe Size", key = "0", command = int(MenuCommand.DEFAULT_SIZE)}})
}

// The check marks in the View menu follow the app however it was changed
update_menu_checks :: proc(app: ^App) {
    for command, type in DISPLAY_COMMANDS {
        gfx.set_menu_checked(int(command), app.config.strobe_display_type == type)
    }
    for command, colorway in COLORWAY_COMMANDS {
        gfx.set_menu_checked(int(command), app.config.strobe_colorway == colorway)
    }
    gfx.set_menu_checked(int(MenuCommand.RETRO_GLOW), app.config.strobe_glow)
    gfx.set_menu_checked(int(MenuCommand.LOCK_NOTE), app.tuner.locked)

    for index in 0 ..< min(len(app.audio_devices), MAX_INPUT_COMMANDS) {
        gfx.set_menu_checked(int(MenuCommand.INPUTS) + index, index == app.audio_device_index)
    }
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
    if input >= 0 && input < len(app.audio_devices) do app.audio_device_index = input

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
        comparator := app.phase_comparator
        comparator.band_cents = comparator.band_cents / 2 if comparator.band_cents > 25 else core.DFT_RESOLUTION_CENTS
        config.persistence_periods = 1 / (math.pow(f32(2), f32(comparator.band_cents) / 1200) - 1)
        fmt.printfln("Strobe band: %d cents, persistence %.0f periods", comparator.band_cents, config.persistence_periods)
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
    if !app.tuner.active || !reading.strobe_readout || cents > IN_TUNE_REARM_CENTS {
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

// The pitch detection, the strobe and the tuner on the new audio
measure :: proc(app: ^App) -> (reading: Reading) {
    tuner := &app.tuner
    reading.pitch = core.run_pitch_detection(&app.pitch_detector, tuner.pitch)
    core.run_phase_detection(app.phase_comparator, reading.pitch.is_tonal)

    // The track the readout follows. The strobe keeps the note lit while it shows it. Retuned to another note the
    // tracks start over, their reading was from the note before.
    ready: bool
    app.readout_track, ready = core.strobe_readout_track(app.phase_comparator, app.readout_track)
    if core.update_tuner(tuner, reading.pitch, core.strobe_shows_note(app.phase_comparator)) {
        retune(app)
        ready = false
    }

    reading.out_of_range = core.tuner_out_of_range(tuner)
    reading.steady = core.tuner_readout(tuner)

    // The readout is the strobe's, 0 where the fundamental's track stands still, none until a track has settled
    // after the pluck. The pitch detection only picks the note: it reads the whole wave, a real string's partials
    // are a little sharp and pull it a few cents off the track you see. The Hz move along with the cents. A
    // fading note keeps its track's last reading, also once the tuner lets go of it.
    steady := &reading.steady
    reading.strobe_readout = ready && !reading.out_of_range
    reading.strobe_readout &&= abs(app.phase_comparator.bands[app.readout_track].err_cents) <= core.READOUT_RANGE_CENTS

    if reading.strobe_readout {
        band := app.phase_comparator.bands[app.readout_track]
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
    if tuner.active {
        if reading.strobe_readout do held^ = {true, steady.detected_freq, steady.err_cents}
    } else {
        reading.strobe_readout = held.shown
        steady.detected_freq, steady.err_cents = held.freq, held.cents
    }

    light: f32 = 1
    traced_cents := math.nan_f32()

    if app.traced_track >= 0 {
        band := app.phase_comparator.bands[app.traced_track]
        fade := core.STROBE_FADE_SNR_DB
        light = math.smoothstep(fade[0], fade[1], band.snr_db)
        if light == 0 || !band.in_range do app.traced_track = -1

        if app.traced_track >= 0 && !reading.out_of_range && abs(band.err_cents) <= core.READOUT_RANGE_CENTS {
            traced_cents = band.err_cents
        }
    }

    record_trace(&app.cents_trace, traced_cents, light, reading.pitch.fresh, gfx.frame_time())

    // The spectrum of what came in, only while it's the display
    config := app.config
    if config.strobe_display_type == .SPECTRUM do update_spectrum_view(&app.spectrum_view, config.spectrum_windows)

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

    // In periods of the strobe's frequency, the smear and the waver per cent look the same on every note
    scope.persistence_seconds = f64(config.persistence_periods) / strobe_hz
    scope.gain = config.scope_gain
    scope.noise_floor = app.pitch_detector.noise_floor.level
    core.update_scope(scope)
}

draw_main_screen :: proc(app: ^App, layout: Layout, reading: Reading) {
    config := app.config

    draw_strobe_area(app, layout)
    draw_tuning_arrows(app, layout, reading)
    draw_note_controls(app, layout, reading)

    // The strobe's reading, none before a track settled, and nothing to measure on another note than a locked
    // one. The gauge points the way without one.
    draw_measurements(
        layout.measurements,
        reading.steady.detected_freq,
        reading.steady.err_cents,
        reading.strobe_readout,
        app.tuner.active,
    )

    // The displays in a cycle, the number keys go straight to one
    if gui_display_button(layout.display, config.strobe_display_type) {
        config.strobe_display_type = next_display(config.strobe_display_type)
    }

    // Opens on the settings, not the display's options it was closed on
    if gui_settings_button(layout.settings) do open_settings_sheet(app)

    if gui_instrument_button(layout.instrument, config) do app.instrument_sheet.open = true

    // The input level, the microphone icon marks it as the input. The level is the rounded track cut off flat
    // where it ends.
    icon_y := f32(LEVEL_METER_HEIGHT - ICON_SIZE) / 2
    draw_icon(ICON_MICROPHONE, layout.level_meter + {0, icon_y}, icon_color)

    // A slow input, a Bluetooth headset's microphone at 16 or 24 kHz, gets a warning before the icon. The high
    // notes and the partials over its Nyquist are out of reach, their tracks show empty.
    WARNING_GAP :: 4
    if sample_rate := app.audio_capture.sample_rate; sample_rate > 0 && sample_rate < core.LOW_SAMPLE_RATE {
        draw_icon(ICON_WARNING, layout.level_meter + {-ICON_SIZE - WARNING_GAP, icon_y}, warning_color)
    }

    meter := layout.level_meter + {LEVEL_BAR_OFFSET, 0}
    track := gfx.Rect{meter.x, meter.y, LEVEL_BAR_WIDTH, LEVEL_METER_HEIGHT}
    gfx.draw_rounded_rect(track, LEVEL_METER_HEIGHT / 2, pill_dark)

    // Empty until something was measured, e.g. without an input, a reading that isn't one would be 0 dBFS
    if reading.pitch.measured {
        level := LEVEL_BAR_WIDTH + clamp(reading.pitch.rms_dbfs, -LEVEL_BAR_WIDTH, 0)
        gfx.begin_scissor({meter.x, meter.y, level, LEVEL_METER_HEIGHT})
        gfx.draw_rounded_rect(track, LEVEL_METER_HEIGHT / 2, accent_color)
        gfx.end_scissor()
    }

    // The warning, the icon and the level open the input's sheet, a finger tall around the thin meter. Its
    // levels show right away, not after the first hold, and its list has what's connected now.
    left := layout.level_meter.x - ICON_SIZE - WARNING_GAP
    if gui_button({left, meter.y + LEVEL_METER_HEIGHT / 2 - 22, LEVEL_METER_WIDTH + ICON_SIZE + WARNING_GAP, 44}) {
        app.input_sheet.open = true
        app.input_stats_age = INPUT_STATS_HOLD_S
        app.refresh_inputs = true
    }

    when DEBUG_STATS do draw_debug_stats(app, layout, reading.pitch, meter)
}

// The strobe, or the trace or the scope's view in its place. Tapping a track opens its sheet, tapping the scope
// flips its sweep.
draw_strobe_area :: proc(app: ^App, layout: Layout) {
    config, display := app.config, &app.strobe_display
    strobe, view := layout.strobe, layout.strobe_view

    // The selected track stands out as its sheet comes up
    display.selected_track = app.selected_track
    display.selection = app.track_sheet.slide

    // The background behind the notch. The strobe's tracks reach up behind it too, the trace and the scope's
    // views start under it.
    gfx.draw_rect({strobe.x, strobe.y}, {strobe.width, view.y - strobe.y}, gfx.hex(strobe_bg_color))

    switch config.strobe_display_type {
    case .STROBE:
        // Turned by the lock-in or by the lamp's screen
        comparator := app.phase_comparator
        bands := comparator.bands[:]
        if config.strobe_source == .LAMP {
            bands = lamp_bands(display, &app.scope, bands, app.pitch_detector.snr_db)
        }
        draw_strobe_display(display, strobe, layout.strobe_scale, layout.strobe_turned, bands, comparator, config)

        // Vernier mode shows the same pitch on every track, there's nothing to set on one
        if config.strobe_mode == .HARMONIC && !input_missing(app) && gui_button(strobe) {
            track := strobe_track_at(config.strobe_shape, strobe, layout.strobe_scale, layout.strobe_turned, len(bands), gfx.mouse_position())
            if track >= 0 {
                app.selected_track = track
                app.track_sheet.open = true
            }
        }

    case .TRACE:
        colors := strobe_colors(config)
        seconds, range := config.trace_seconds, config.trace_range_cents
        draw_cents_trace(&app.cents_trace, view, seconds, range, gfx.hex(colors.x), gfx.hex(colors.y), gfx.hex(strobe_bg_color))

    case .SPECTRUM:
        comparator := app.phase_comparator
        track_hz := make([]f32, len(comparator.bands), context.temp_allocator)
        for band, index in comparator.bands do track_hz[index] = band.freq_hz

        colors := strobe_colors(config)
        draw_spectrum_view(
            &app.spectrum_view,
            display,
            view,
            track_hz,
            app.tuner.active,
            config,
            gfx.hex(colors.x),
            gfx.hex(colors.y),
            gfx.hex(strobe_bg_color),
        )

    case .SCOPE, .LAMP:
        draw_scope_display(display, &app.scope, view, config, app.pitch_detector.snr_db)

        // Between the wave over time and the Lissajous figure
        if config.strobe_display_type == .SCOPE && !input_missing(app) && gui_button(strobe) {
            config.scope_sweep = .XY if config.scope_sweep == .TIME else .TIME
        }

        // Between the one lamp and the split one, its two halves
        if config.strobe_display_type == .LAMP && !input_missing(app) && gui_button(strobe) {
            config.lamp_shape = .HALF_RECTIFIED if config.lamp_shape == .SPLIT else .SPLIT
        }
    }

    // Over the whole strobe area, the part behind the notch included
    draw_strobe_shadow(display, strobe)

    // A denied microphone only gives silence, an input that didn't open gives nothing. The strobe would just
    // stand still, say why instead.
    title, hint: cstring
    if audio.microphone_denied() {
        title, hint = "Microphone access is off", "Tap to allow it in Settings"
    } else if len(app.audio_devices) == 0 {
        title, hint = "No input found", "Connect one and tap to look again"
    } else if audio.input_failed(app.audio_capture) {
        title, hint = "The input didn't open", "Tap to try again"
    }

    if title != nil {
        gfx.draw_rect({strobe.x, strobe.y}, {strobe.width, strobe.height}, gfx.hex(strobe_bg_color))
        center := [2]f32{strobe.x + strobe.width / 2, strobe.y + strobe.height / 2}
        title_size := measure_label(pixel_fonts.title, title)
        hint_size := measure_label(pixel_fonts.label, hint)
        draw_label(pixel_fonts.title, title, center - {title_size.x / 2, title_size.y + 4}, text_color_white)
        draw_label(pixel_fonts.label, hint, center - {hint_size.x / 2, -4}, text_color_muted)

        // Tried again on what's connected now
        if gui_button(strobe) {
            if audio.microphone_denied() do audio.allow_microphone()
            else do app.restart_audio, app.refresh_inputs = true, true
        }
    }
}

// The strobe area says why there's no input instead, see draw_strobe_area
input_missing :: proc(app: ^App) -> bool {
    return audio.microphone_denied() || audio.input_failed(app.audio_capture)
}

// An arrow on the side the pitch is off to, pointing inwards the way to tune: flat on the left pointing right
// to tune up, like higher notes are to the right on the ruler
draw_tuning_arrows :: proc(app: ^App, layout: Layout, reading: Reading) {
    tuner := &app.tuner

    // Only the strong readings, a fading note drifts and would flash the arrows. The strobe's close to the
    // note, like the readout. On another note than the locked one, as far as the notes are apart.
    cents := core.tuner_cents_off(tuner, tuner.last_good_pitch.detected_freq)
    if reading.strobe_readout do cents = reading.steady.err_cents
    if reading.out_of_range do cents = core.tuner_out_of_range_cents(tuner)

    distance := abs(cents)
    measures_target := core.measures_target(tuner)

    // Without a lock or a string, further than half a semitone is a neighbouring note that isn't confirmed yet
    if !tuner.active || (!measures_target && distance > 50) do return

    app.flat_arrow = core.schmitt_trigger_neg(app.flat_arrow, cents, -8, -10)
    app.sharp_arrow = core.schmitt_trigger(app.sharp_arrow, cents, 8, 10)

    arrow := pixel_fonts.strobe_arrow

    // A turned strobe's stripes climb when sharp, see strobe_upright: flat at the bottom pointing up, sharp
    // at the top pointing down, in the middle
    if layout.strobe_turned {
        strobe, view := layout.strobe, layout.strobe_view
        glyph: cstring = "▲" if app.flat_arrow else "▼"
        x := strobe.x + (strobe.width - gfx.measure_text(arrow.font, glyph, arrow.size, 0).x) / 2
        if app.flat_arrow {
            gfx.draw_text(arrow.font, glyph, snap_to_pixels({x, view.y + view.height - 10 - arrow.size}), arrow.size, 0, accent_color)
        } else if app.sharp_arrow {
            gfx.draw_text(arrow.font, glyph, snap_to_pixels({x, view.y + 10}), arrow.size, 0, accent_color)
        }
        return
    }

    arrow_y := layout.strobe_view.y + 10

    if app.flat_arrow {
        gfx.draw_text(arrow.font, "▶", snap_to_pixels({layout.strobe.x + 10, arrow_y}), arrow.size, 0, accent_color)
    } else if app.sharp_arrow {
        width := gfx.measure_text(arrow.font, "◀", arrow.size, 0).x
        position := snap_to_pixels({layout.strobe.x + layout.strobe.width - 10 - width, arrow_y})
        gfx.draw_text(arrow.font, "◀", position, arrow.size, 0, accent_color)
    }
}

// The target note on the ruler with the gauge under it, the lock, and the note's offset. The lock button (or
// space, or tapping the note) locks the note, tapping another note on the ruler locks that one instead.
draw_note_controls :: proc(app: ^App, layout: Layout, reading: Reading) {
    config, tuner := app.config, &app.tuner
    setup := current_setup(config)
    string_mode := setup.instrument != .CHROMATIC

    // A transposing instrument reads the written note, only what's shown moves, the steps are relative and
    // work the same either way. With a capo the strings sound higher and keep the names of the open strings,
    // like the chord shapes played over it.
    transpose := -capo_fret(setup) if string_mode else transpose_key(setup)
    shown_cents := tuner.target_note.cents
    shown_note := core.cents_to_note(f32(shown_cents + 100 * transpose), tuner.target_note.pitch_standard)

    // The strings, or every note of a piano with the target among them. There's always a target, load_config
    // holds the start note in A0 to C8.
    ruler_notes: []core.Note
    target: int
    if string_mode {
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
        target = clamp(shown_cents / 100 - core.LOWEST_NOTE, 0, core.NOTE_COUNT - 1)
    }
    step, note_tapped, swiping := gui_note_ruler(layout.ruler, ruler_notes, target, tuner.active)

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
        draw_cents_gauge(layout.gauge, cents, lit, string_mode, gfx.hex(strobe_colors(config).x))
    }

    lock_toggled := gui_lock_toggle(layout.lock, tuner.locked) || note_tapped
    if !gui_disabled {
        if gfx.key_pressed(.SPACE) || app.menu == .LOCK_NOTE do lock_toggled = true
        if gfx.key_pressed(.LEFT) do step = -1
        if gfx.key_pressed(.RIGHT) do step = 1
    }

    // A swipe locks the note in the middle as it goes, the one it started on right away, rather than the
    // target following the detected note under the finger
    if swiping do lock_toggled = !tuner.locked
    if lock_toggled || step != 0 do app.quiet_time = 0

    retune_target := lock_toggled && core.toggle_note_lock(tuner)

    if core.step_target_note(tuner, step) do retune_target = true
    if retune_target do retune(app)

    // A note that's tuned off pitch says so between the letter and the lock, the strobe and the readout are on
    // the offset note, see gui_note_offsets.
    if offset := core.note_offset_cents(tuner, tuner.target_note); offset != 0 {
        text := offset_cents_text(offset)
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
        gfx.draw_text(font.font, text, position, 16 if large else 12, 0, color)
    }

    floor_level := core.dbfs(pitch.noise_floor)
    gfx.draw_rect(meter + {0, LEVEL_METER_HEIGHT}, {LEVEL_BAR_WIDTH, 3}, gfx.hex(strobe_bg_color))
    gfx.draw_rect(meter + {0, LEVEL_METER_HEIGHT}, {LEVEL_BAR_WIDTH + floor_level, 3}, gfx.PURPLE)

    base_band := app.phase_comparator.bands[0]
    stat(fmt.ctprintf("Band SNR %.1f", base_band.snr_db), layout.stats)
    stat(fmt.ctprintf("Band NF %.1f", core.dbfs(base_band.noise_floor.level)), layout.stats + {0, 15})
    stat(fmt.ctprintf("Band drift %.1f", base_band.drift_cents), layout.stats + {0, 30})
    stat(fmt.ctprintf("RMS %.1f", pitch.rms_dbfs), layout.stats + {130, 0})
    stat(fmt.ctprintf("NF %.1f", floor_level), layout.stats + {130, 15})
    stat(fmt.ctprintf("SNR %.1f", pitch.snr_db), layout.stats + {130, 30})

    stat(fmt.ctprintf("Clarity %.3f", pitch.clarity), {500, 10}, large = true)
    if pitch.is_strong_pitch do stat("strong", {600, 10}, gfx.ORANGE, large = true)
    if pitch.is_weak_pitch do stat("weak", {600, 10}, gfx.PURPLE, large = true)

    font := pixel_fonts.label_small.font
    draw_nsdf(gfx.Rect{520, 40, 660, 200}, &app.pitch_detector.nsdf, font)
    draw_freq_plot(gfx.Rect{520, 300, 660, 200}, &app.pitch_detector.nsdf, font)
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

    sheet_layout, swiped := begin_sheet(sheet, rows, &app.strobe_display, layout)
    close, changed := gui_settings(sheet_layout, app.config, &app.display_options, &app.reset_confirm, &app.settings_menu)
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
    app.settings_menu = .NONE
    exclusive_control_mode = false
}

// The display after this one, the button and Tab go round them in the settings' order
next_display :: proc(type: StrobeDisplayType) -> StrobeDisplayType {
    return StrobeDisplayType((int(type) + 1) % len(StrobeDisplayType))
}

draw_input_sheet :: proc(app: ^App, layout: Layout, reading: Reading) {
    sheet := &app.input_sheet
    if sheet.slide == 0 do return

    // A few times a second, the latest detection's
    app.input_stats_age += gfx.frame_time()
    if app.input_stats_age >= INPUT_STATS_HOLD_S {
        pitch := reading.pitch

        // The floor is the level's average, quiet wobbles under it, the SNR of the background is 0. None
        // until something was measured, e.g. without an input, a reading that isn't one would be 0 dBFS.
        none := math.nan_f32()
        app.input_stats = {none, none, none}
        if pitch.measured do app.input_stats = {pitch.rms_dbfs, core.dbfs(pitch.noise_floor), max(pitch.snr_db, 0)}
        app.input_stats_age = 0
    }

    capture := app.audio_capture
    device_name := "No input"
    if audio.device_count(capture) > 0 do device_name = audio.device_name(capture, capture.active_device)

    sheet_layout, swiped := begin_sheet(sheet, INPUT_ROWS, &app.strobe_display, layout)
    close := gui_input(
        sheet_layout,
        device_name,
        capture.device_rate,
        capture.sample_rate,
        app.input_stats,
        app.audio_devices[:],
        &app.audio_device_index,
        &app.settings_menu,
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
    bands := app.phase_comparator.bands[:]
    sheet_layout, swiped := begin_sheet(sheet, TRACK_SETTINGS_ROWS, &app.strobe_display, layout)
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
    sheet_layout, swiped := begin_sheet(sheet, 0, &app.strobe_display, layout, gfx.window_size().y)

    // A new offset starts on the note the tuner is on
    target := -1
    if index, in_range := core.note_index(app.tuner.target_note); in_range {
        target = index
    }
    close, changed := gui_instrument(sheet_layout, app.config, &app.settings_menu, target)
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
    app.config.target_freq_hz = app.tuner.target_note.frequency
    save_config(app.config^)
    app.unsaved, app.unsaved_s = false, 0
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
    signal := app.tuner.active
    for band in app.phase_comparator.bands {
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
