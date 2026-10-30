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


// What the main loop keeps from one frame to the next
App :: struct {
    config:         ^Config,
    measurement:    Measurement,
    input:          AudioInput,
    displays:       Displays,
    sheets:         AppSheets,

    in_tune_s:      f32, // how long the readout has held in tune, see update_in_tune_tap
    in_tune_tapped: bool, // and it tapped, not again until the readout moves away
    config_changed: bool, // the note target and the strobe need the new config, see apply_config
    unsaved:        bool, // the config changed since it was saved, see save_when_settled
    unsaved_s:      f32, // since it last changed
    quiet_time:     f32, // seconds with no signal and nobody touching anything, see IDLE_AFTER_S
}

// What the strobe area draws, the display picked in the settings and the arrows over it
Displays :: struct {
    glow_targets: GlowTargets, // shared by the displays that glow
    strobe:       StrobeDisplay,
    scope:        ScopeDisplay, // the scope's and the lamp's views
    trace:        TraceDisplay,
    needle:       NeedleDisplay,
    spectrum:     SpectrumDisplay,

    // The arrows on the strobe, see draw_tuning_arrows
    flat_arrow:   bool,
    sharp_arrow:  bool,

    menu_open:    bool, // the displays' menu over the strobe, see gui_display_button
    toast:        TapToast, // the option a tap on the view changed, see show_tap_toast
}


run_app :: proc(config: ^Config) {
    app := new_app(config)
    if !start_app(&app) do return

    defer stop_app(&app)

    // The desktop window keeps drawing while it's dragged or zoomed to another size, the main loop is stuck
    // in the OS's own loop meanwhile
    when !gfx.MOBILE {
        gfx.live_resize_frames(proc(data: rawptr) {
            defer free_all(context.temp_allocator)
            run_frame((^App)(data))
        }, &app)
    }

    run_main_loop(&app)
}

// Nothing measured yet, no track followed
new_app :: proc(config: ^Config) -> App {
    return {config = config, measurement = {readout_track = -1, traced_track = -1}}
}

// The window, the measurements, the displays and the input, everything a frame needs. False without a
// window, nothing else is made then.
start_app :: proc(app: ^App) -> bool {
    size, min_size, position := window_placement(app.config)
    if !gfx.init(size.x, size.y, APP_NAME, min_size, position) do return false

    setup_menu_bar(app)
    gfx.load_shapes()
    init_measurement(&app.measurement, app.config)
    init_displays(&app.displays)

    // Opened or not, the strobe area says why there's no input, see draw_strobe_area
    open_audio_input(app)

    apply_config(app)
    return true
}

// What start_app made, in reverse, with the note saved for the next start
stop_app :: proc(app: ^App) {
    app.config.target_freq_hz = app.measurement.note_target.target_note.frequency

    close_audio_input(app)
    destroy_displays(&app.displays)
    destroy_measurement(&app.measurement)
    gfx.unload_shapes()

    // Loaded each frame for the screen's scale, see update_pixel_fonts
    unload_pixel_fonts()

    gfx.shutdown()
}

// The glow's targets are made as the first glowing display draws, see ensure_glow_targets
init_displays :: proc(displays: ^Displays) {
    displays.strobe = init_strobe_display(strobe_bg_color)
    displays.scope = init_scope_display(strobe_bg_color)
    displays.trace = init_trace_display()
    displays.spectrum = init_spectrum_display()
}

destroy_displays :: proc(displays: ^Displays) {
    destroy_spectrum_display(&displays.spectrum)
    destroy_trace_display(&displays.trace)
    destroy_scope_display(&displays.scope)
    unload_glow_targets(&displays.glow_targets)
}

// The configured input, or the default, its samples to everything that measures or shows them. The list of
// inputs for the settings.
open_audio_input :: proc(app: ^App) {
    measurement := &app.measurement
    capture := audio.init(app.config.input_device)
    app.input.capture = capture

    audio.register_audio_node(capture, &measurement.pitch_detector)
    audio.register_audio_node(capture, measurement.strobe_lock_in)
    audio.register_audio_node(capture, &measurement.scope)
    audio.register_audio_node(capture, &app.displays.spectrum)
    match_input_rate(app)
    audio.start(capture)

    build_input_list(&app.input, app.config.input_device)
}

close_audio_input :: proc(app: ^App) {
    delete(app.input.default_label)
    delete(app.input.devices)
    audio.destroy(app.input.capture)
}

// Until the window closes, a frame at a time, waiting while the app is in the background or hidden
run_main_loop :: proc(app: ^App) {
    for !gfx.should_close() {
        // The labels and readouts are formatted into the temp allocator, nothing in it outlives a frame
        defer free_all(context.temp_allocator)

        if gfx.in_background() {
            wait_in_background(app)
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

        run_frame(app)
    }
}

// A turn of the main loop after its events: the measurements, the layout and the drawing
run_frame :: proc(app: ^App) {
    config, audio_capture := app.config, app.input.capture
    if audio.interruption_ended(audio_capture) do app.input.restart = true

    follow_input(app)

    config_before := config^
    menu := handle_keys(app)

    if app.config_changed do apply_config(app)

    reading := measure(app)
    update_in_tune_tap(app, reading)
    follow_note_colors(app)

    when !DEBUG_STATS {
        // A tablet draws in larger points than its own, see ui_scale
        points := gfx.window_points()
        gfx.set_ui_scale(ui_scale(points / gfx.content_scale(), gfx.ui_scale()))
        when !gfx.MOBILE && !gfx.WEB do follow_window_size(config, points)
    }

    window, safe := gfx.window_size(), gfx.safe_area()

    // The plots take the rest of the window on the right
    when DEBUG_STATS {
        window.x = STROBE_WIDTH
        safe.width = STROBE_WIDTH
    }

    layout := compute_layout(window, safe, selected_preset(config) != nil)
    update_pixel_fonts()
    update_menu_checks(app)

    gfx.begin_frame(gfx.hex(panel_bg_color))
    defer gfx.end_frame()
    gui_begin_frame()

    // The sheets slide up over the main screen, which keeps running under them and ignores taps until
    // they're all the way down again. They're drawn at the end of the frame.
    // A sheet all the way up covers the panel, the instrument sheet the strobe too when the panel is under
    // it. A phone's strobe area still shows above that, behind the notch. Not while a sheet is dragged, it
    // may move down later in the frame.
    gui.disabled = false
    panel_covered := false
    for sheet in all_sheets(&app.sheets) {
        slide_sheet(sheet)
        if sheet.open || sheet.slide > SHEET_DOWN do gui.disabled = true
        if sheet.slide == SHEET_UP && !sheet.drag.active do panel_covered = true
    }

    instrument_sheet := app.sheets.instrument
    covered := !layout.beside && instrument_sheet.slide == SHEET_UP && !instrument_sheet.drag.active
    strobe_shows := !covered || safe.y > 0

    feed_scope(app, strobe_shows)

    // The arrows are on the strobe, they show above the sheet
    if covered {
        if strobe_shows do draw_strobe_area(app, layout)
    } else if panel_covered {
        draw_strobe_area(app, layout)
        draw_tuning_arrows(&app.displays, &app.measurement.note_target, layout, reading)
    } else {
        draw_main_screen(app, layout, reading, menu)
    }
    draw_sheets(app, layout, reading)

    if config^ != config_before do app.unsaved, app.unsaved_s = true, 0

    save_when_settled(app)
    limit_frame_rate(app)
}

// The pitch detection, the note target and the strobe brought up to the config, at the start and after a
// change. The tracks start over, so only for what they measure: the displays read their colors and options from
// the config as they draw.
apply_config :: proc(app: ^App) {
    measurement, config := &app.measurement, app.config
    note_target := &measurement.note_target

    // Same notes, retuned to the pitch standard
    measurement.pitch_detector.pitch_standard = config.pitch_standard
    core.set_target_pitch_standard(note_target, config.pitch_standard)
    note_target.offsets_cents = active_note_offsets(config)
    core.set_target_strings(note_target, tuning_strings(config))

    retune(measurement, config)
    app.config_changed = false
}

// A phone suspends the app in the background and may end it there without warning. The config is saved on the
// way out, the input is opened again on the way back.
wait_in_background :: proc(app: ^App) {
    app.config.target_freq_hz = app.measurement.note_target.target_note.frequency
    save_config(app.config^)
    audio.stop(app.input.capture)
    gfx.wait_for_foreground()
    app.input.restart = true
}

// The menu bar's item chosen this frame is returned for the main screen's, see draw_note_controls
handle_keys :: proc(app: ^App) -> (menu: MenuCommand) {
    config := app.config

    // A menu item's key reaches the keys here too, the plain ones skip while Command is down
    menu = MenuCommand(gfx.menu_command())
    command := gfx.key_down(.LEFT_SUPER) || gfx.key_down(.RIGHT_SUPER)
    plain := !command

    #partial switch menu {
    case .SETTINGS:
        toggle_settings_sheet(&app.sheets)
    case .RETRO_GLOW:
        config.strobe_glow = !config.strobe_glow
    case .DEFAULT_SIZE:
        config.window_size = {}
    }
    for menu_command, type in DISPLAY_COMMANDS {
        if menu == menu_command do config.strobe_display_type = type
    }
    for menu_command, colorway in COLORWAY_COMMANDS {
        if menu == menu_command do config.strobe_colorway = colorway
    }

    // Opened in the next frame like a pick on the input's sheet, see follow_input
    input := int(menu) - int(MenuCommand.INPUTS)
    if input >= 0 && input < len(app.input.devices) do app.input.device_index = input

    if plain && gfx.key_pressed(.G) do config.strobe_glow = !config.strobe_glow

    if plain && gfx.key_pressed(.TAB) do config.strobe_display_type = next_display(config.strobe_display_type)

    // Or straight to one, in the settings' order
    DISPLAY_KEYS :: [StrobeDisplayType]gfx.Key {
        .STROBE   = .NUM_1,
        .SCOPE    = .NUM_2,
        .TRACE    = .NUM_3,
        .NEEDLE   = .NUM_4,
        .LAMP     = .NUM_5,
        .SPECTRUM = .NUM_6,
    }
    for key, type in DISPLAY_KEYS {
        if plain && gfx.key_pressed(key) do config.strobe_display_type = type
    }

    // Without a menu bar Ctrl+, opens the settings and Ctrl+0 puts the window back to the strobe's size, see
    // follow_window_size
    when !gfx.MOBILE && ODIN_OS != .Darwin {
        control := gfx.key_down(.LEFT_CONTROL) || gfx.key_down(.RIGHT_CONTROL)
        if control && gfx.key_pressed(.COMMA) do toggle_settings_sheet(&app.sheets)

        if control && gfx.key_pressed(.NUM_0) do config.window_size = {}
    }
    return
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
    if !app.measurement.note_target.active || !reading.strobe_readout || cents > IN_TUNE_REARM_CENTS {
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

// The display after this one, the button and Tab go round them in the settings' order
next_display :: proc(type: StrobeDisplayType) -> StrobeDisplayType {
    return StrobeDisplayType((int(type) + 1) % len(StrobeDisplayType))
}

// Written once the sheets are down, a quit that skips the save at the end keeps what was changed: the stop
// button of a debugger, Ctrl+C in the terminal, a crash. And once it stopped changing for SAVE_SETTLE_S, a
// window dragged bigger where the system's loop doesn't hold the frames, e.g. Linux, isn't written every frame.
save_when_settled :: proc(app: ^App) {
    sheets_open := false
    for sheet in all_sheets(&app.sheets) do sheets_open ||= sheet.open
    if !app.unsaved || sheets_open do return

    app.unsaved_s += gfx.frame_time()
    if app.unsaved_s < SAVE_SETTLE_S do return

    // With the note the strobe is on, a crash or a stop from the debugger starts on it too
    app.config.target_freq_hz = app.measurement.note_target.target_note.frequency
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
    signal := app.measurement.note_target.active
    for band in app.measurement.strobe_lock_in.bands {
        if band.snr_db > core.STROBE_FADE_SNR_DB[0] do signal = true
    }
    touched := gfx.mouse_down() || gfx.mouse_pressed() || gfx.mouse_wheel() != 0
    sliding := note_ruler.swipe.gesture == .COASTING || note_ruler.roll != 0
    for sheet in all_sheets(&app.sheets) {
        if sheet.slide != slide_target(sheet^) do sliding = true
    }

    if signal || touched || sliding {
        app.quiet_time = 0
    } else {
        app.quiet_time += gfx.frame_time()
    }
    gfx.limit_fps(IDLE_FPS if app.quiet_time > IDLE_AFTER_S else MAX_FPS)
}
