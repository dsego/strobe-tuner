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

@(require) import "core:fmt"

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
    strobe_area:    StrobeArea,
    sheets:         AppSheets,

    config_changes: ConfigChanges, // the note target and the strobe need the new config, see apply_config
    unsaved:        bool, // the config changed since it was saved, see save_when_settled
    unsaved_s:      f32, // since it last changed
    quiet_time:     f32, // seconds with no signal and nobody touching anything, see IDLE_AFTER_S
}

// What a change to the settings needs, see apply_config
ConfigChange :: enum {
    RETUNE, // what the tracks measure, they start over
    SPEED, // how fast the stripes turn, the tracks keep measuring
    READOUT, // what the readout reads and how long it averages, the tracks keep measuring
}
ConfigChanges :: bit_set[ConfigChange]

// What the strobe area draws, the display picked in the settings and the arrows over it
StrobeArea :: struct {
    glow_targets: GlowTargets, // shared by the displays that glow
    strobe:       StrobeDisplay,
    scope:        ScopeDisplay, // the scope's and the lamp's views
    trace:        TraceDisplay,
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
    // in the OS's own loop meanwhile. The app outlives it, the main loop returns here.
    when !gfx.MOBILE {
        gfx.live_resize_frames(proc(data: rawptr) {
            defer free_all(context.temp_allocator)
            run_frame((^App)(data))
        }, rawptr(&app))
    }

    run_main_loop(&app)
}

// Nothing measured yet, no track followed. Opened to tune, the unlock's reminder waits its time first.
new_app :: proc(config: ^Config) -> App {
    return {
        config = config,
        measurement = {readout_track = -1, traced_track = -1},
        sheets = {unlock = {until_next_s = UNLOCK_REMINDER_S}},
    }
}

// The window, the measurements, the displays and the input, everything a frame needs. False without a
// window, nothing else is made then.
start_app :: proc(app: ^App) -> bool {
    size, min_size, position := window_placement(app.config)
    if !gfx.init(size.x, size.y, APP_NAME, min_size, position) do return false

    setup_menu_bar(app)
    gfx.load_shapes()
    init_measurement(&app.measurement, app.config)
    init_strobe_area(&app.strobe_area)

    // Opened or not, the strobe area says why there's no input, see draw_strobe_area
    open_audio_input(app)

    apply_config(app, {.RETUNE})

    // Asks the App Store for the product and an earlier purchase, nothing without UNLOCK
    ask_app_store()
    return true
}

// What start_app made, in reverse, with the note saved for the next start
stop_app :: proc(app: ^App) {
    app.config.target_freq_hz = app.measurement.note_target.target_note.frequency

    close_audio_input(app)
    destroy_strobe_area(&app.strobe_area)
    unload_glow_targets(&app.sheets.unlock.backdrop)
    destroy_measurement(&app.measurement)
    gfx.unload_shapes()

    // Loaded each frame for the screen's scale, see update_pixel_fonts
    unload_pixel_fonts()

    // Filled as the stats draw, see draw_debug_stats
    when DEBUG_STATS do destroy_debug_spectrogram(&debug_spectrogram)

    gfx.shutdown()
}

// The displays, but not the glow's targets: those take the size of the first glowing display as it
// draws, see ensure_glow_targets
init_strobe_area :: proc(strobe_area: ^StrobeArea) {
    strobe_area.strobe = init_strobe_display(strobe_bg_color)
    strobe_area.scope = init_scope_display(strobe_bg_color)
    strobe_area.trace = init_trace_display()
    strobe_area.spectrum = init_spectrum_display()
}

destroy_strobe_area :: proc(strobe_area: ^StrobeArea) {
    destroy_spectrum_display(&strobe_area.spectrum)
    destroy_trace_display(&strobe_area.trace)
    destroy_scope_display(&strobe_area.scope)
    unload_glow_targets(&strobe_area.glow_targets)
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
    audio.register_audio_node(capture, &app.strobe_area.spectrum)
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

// A turn of the main loop after its events, in steps that each hand the next what it needs: the input, the
// keys, the measurements, the layout, the drawing and the save
run_frame :: proc(app: ^App) {
    config_before := follow_input_and_unlock(app)

    // Before the measurements and the sheets, what a key changed shows this frame. The menu bar's command can
    // only be read once a frame, it's passed on to the note's lock, see draw_note_controls.
    menu := handle_keys(app)

    reading := measure_frame(app)
    layout := lay_out_frame(app)

    // After the keys and the measurements, the menu's check marks show this frame's
    update_menu_checks(app)

    // Ends after the frame's rate is set, the rest of the frame is waited out at it, see limit_frame_rate
    gfx.begin_frame(gfx.hex(panel_bg_color))
    defer gfx.end_frame()

    draw_frame(app, layout, reading, menu)
    save_frame_changes(app, config_before)
    limit_frame_rate(app)
}

// What came in since the last frame: the input, the purchase and the free minutes. Returns the config as it is
// after them, what the rest of the frame changes in it is saved, see save_frame_changes.
follow_input_and_unlock :: proc(app: ^App) -> (config_before: Config) {
    // An interruption that ended, e.g. a call, opens the input again in follow_input
    if audio.interruption_ended(app.input.capture) do app.input.restart = true

    // Before the copy, the input's old name is freed in the config here
    follow_input(app)

    // Before the reminder, a purchase that went through this frame stops it
    when UNLOCK == "fake" do update_fake_app_store(gfx.frame_time())

    // Before the copy. The free minutes used grow in the config every frame, and compared the config would
    // never settle, a changed setting wouldn't save until they ran out. They're written with the next save
    // instead, in the background or at the quit.
    remind_to_unlock(app)

    return app.config^
}

// The config brought up to what the sheets changed last frame, then measured with it
measure_frame :: proc(app: ^App) -> (reading: Reading) {
    if app.config_changes != {} do apply_config(app, app.config_changes)

    reading = measure(app)

    // After the measurements, By note's colors flip with this frame's note
    follow_note_colors(app)
    return
}

// The UI scale, the window's size kept in the config, then the layout and the fonts at that scale. Before the
// frame begins, the fonts load then, see update_pixel_fonts.
lay_out_frame :: proc(app: ^App) -> (layout: Layout) {
    config := app.config

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

    layout = compute_layout(window, safe, selected_preset(config) != nil)
    update_pixel_fonts()
    return
}

// The sheets slid, then the layers from the bottom: the main screen or what a sheet leaves of it, the
// sheets, and the unlock's reminder over all of them blurred
draw_frame :: proc(app: ^App, layout: Layout, reading: Reading, menu: MenuCommand) {
    gui_begin_frame()
    cover := slide_sheets(app, layout)

    // The scope's views get the new audio only while they can be seen
    feed_scope(app, cover.strobe_shows)

    // While the unlock's reminder is up or sliding, what's drawn from here to end_unlock_backdrop is blurred
    // under it
    reminder := &app.sheets.unlock
    reminder_shows := reminder.sheet.slide > SHEET_DOWN
    if reminder_shows do begin_unlock_backdrop(reminder)

    // The arrows are on the strobe, they show above the sheet
    if cover.strobe {
        if cover.strobe_shows do draw_strobe_area(app, layout)
    } else if cover.panel {
        draw_strobe_area(app, layout)
        draw_tuning_arrows(&app.strobe_area, &app.measurement.note_target, layout, reading, app.config)
    } else {
        draw_main_screen(app, layout, reading, menu)
    }
    draw_sheets(app, layout, reading)

    if reminder_shows {
        end_unlock_backdrop(reminder)
    } else {
        // Its render targets go while it's down
        unload_glow_targets(&reminder.backdrop)
    }

    // Last, sharp over the blur
    draw_unlock_sheet(app)
}

// What the sheets cover of the main screen this frame, see slide_sheets
SheetCover :: struct {
    panel:        bool, // a sheet other than the reminder is all the way up
    strobe:       bool, // the instrument sheet is all the way up, with the panel under the strobe
    strobe_shows: bool, // not covered, or above the sheet behind a phone's notch
}

// Before anything draws. The sheets slide up over the main screen, which keeps running under them and ignores
// taps until they're all the way down again. They're drawn at the end of the frame. A sheet all the way up
// covers the panel, the instrument sheet the strobe too when the panel is under it. A phone's strobe area still
// shows above that, behind the notch. Not while a sheet is dragged, it may move down later in the frame. The
// unlock's reminder covers nothing, the screen shows blurred under it.
slide_sheets :: proc(app: ^App, layout: Layout) -> (cover: SheetCover) {
    gui.disabled = false
    reminder := &app.sheets.unlock.sheet
    for sheet in all_sheets(&app.sheets) {
        slide_sheet(sheet)
        if sheet.open || sheet.slide > SHEET_DOWN do gui.disabled = true
        if sheet.slide == SHEET_UP && !sheet.drag.active && sheet != reminder do cover.panel = true
    }

    instrument_sheet := app.sheets.instrument
    cover.strobe = !layout.beside && instrument_sheet.slide == SHEET_UP && !instrument_sheet.drag.active
    cover.strobe_shows = !cover.strobe || gfx.safe_area().y > 0
    return
}

// After everything that changes the config this frame, it's written once it settled, see save_when_settled
save_frame_changes :: proc(app: ^App, config_before: Config) {
    if app.config^ != config_before do app.unsaved, app.unsaved_s = true, 0

    save_when_settled(app)
}

// The pitch detection, the note target and the strobe brought up to the config, at the start and after a
// change. The tracks start over only for what they measure, a turn of the spin rate or the readout's settings
// comes while a string is being tuned. The displays read their colors and options from the config as they draw.
apply_config :: proc(app: ^App, changes: ConfigChanges) {
    measurement, config := &app.measurement, app.config
    note_target := &measurement.note_target
    app.config_changes = {}

    if .RETUNE in changes {
        // Same notes, retuned to the pitch standard
        measurement.pitch_detector.pitch_standard = config.pitch_standard
        core.set_target_pitch_standard(note_target, config.pitch_standard)
        note_target.offsets_cents = active_note_offsets(config)
        core.set_target_strings(note_target, tuning_strings(config))

        retune(measurement, config)
        return
    }

    if .SPEED in changes do set_strobe_speed(measurement, config)

    // Another readout picks its track again, the reading held was the other one's
    if .READOUT in changes {
        set_readout_speed(measurement, config)
        measurement.readout_track, measurement.traced_track = -1, -1
        measurement.held_readout = {}
    }
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
    case .UNLOCK:
        open_unlock_sheet(&app.sheets, countdown = false)
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

    // H flips the pitch detection between its two ways to try them side by side, not a setting yet, see
    // core.PitchMethod. Debug builds only, nothing on the screen shows which one reads.
    when ODIN_DEBUG {
        if plain && gfx.key_pressed(.H) {
            detector := &app.measurement.pitch_detector
            detector.method = .WAVE if detector.method == .HARMONICS else .HARMONICS
            fmt.println("Pitch detection:", detector.method)
        }
    }

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

    // Without a menu bar Ctrl+, opens the settings and Ctrl+0 puts the window back to the strobe's size, see
    // follow_window_size
    when !gfx.MOBILE && ODIN_OS != .Darwin {
        control := gfx.key_down(.LEFT_CONTROL) || gfx.key_down(.RIGHT_CONTROL)
        if control && gfx.key_pressed(.COMMA) do toggle_settings_sheet(&app.sheets)

        if control && gfx.key_pressed(.NUM_0) do config.window_size = {}
    }
    return
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
        if band.visibility > 0 do signal = true
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
