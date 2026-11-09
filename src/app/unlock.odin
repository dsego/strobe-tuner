// Copyright (C) 2026  Davorin Šego

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

import "../gfx"

// Free with a reminder, built with UNLOCK only, see app_store.odin. The whole app works. Once per install it
// gives UNLOCK_FREE_S from the first lit note, then a reminder over the whole window asks to unlock every
// UNLOCK_REMINDER_S on screen, closed after a countdown of UNLOCK_CLOSE_AFTER_S. It comes over any other sheet,
// they leave the strobe to tune with. Unlocked, it doesn't come back.
UNLOCK_FREE_S :: f32(#config(UNLOCK_FREE_S, 120))
UNLOCK_REMINDER_S :: f32(#config(UNLOCK_REMINDER_S, 30))
UNLOCK_CLOSE_AFTER_S :: f32(#config(UNLOCK_CLOSE_AFTER_S, 5))

// The reminder's column in the middle of the window, larger than a sheet's to stand out over the blur. Its
// gaps under the title, the words, the two buttons and over the restore.
UNLOCK_WIDTH :: 400 // at most
UNLOCK_SIDE_MARGIN :: 24
UNLOCK_LINE_HEIGHT :: LABEL_LARGE_SIZE + 9
UNLOCK_BUTTON_HEIGHT :: 48
UNLOCK_RESTORE_HEIGHT :: 32
UNLOCK_GAPS :: [4]f32{18, 24, 12, 20}

// Everything under the reminder is blurred, the strobe can't be read through it while it counts down: drawn
// offscreen, shrunk by UNLOCK_BLUR_DOWNSCALE, blurred UNLOCK_BLUR_ITERATIONS times with the glow's taps spaced
// UNLOCK_BLUR_SPACING apart, and the sheet's color over it as much as UNLOCK_TINT, 0.2 is 80% see-through.
// Taps 2 apart fall on texel centres and only ever mix every other texel, odd with odd and even with even,
// and the ruler's ticks and the note's strokes left a checker of 4 point squares on the iPhone. 1.5 falls
// between texels like the glow's, 5 times about as wide as 3 at 2.
UNLOCK_BLUR_DOWNSCALE :: f32(#config(UNLOCK_BLUR_DOWNSCALE, 4))
UNLOCK_BLUR_ITERATIONS :: #config(UNLOCK_BLUR_ITERATIONS, 5)
UNLOCK_BLUR_SPACING :: f32(#config(UNLOCK_BLUR_SPACING, 1.5))
UNLOCK_TINT :: f32(#config(UNLOCK_TINT, 0.2))

UNLOCK_TEXT :: [?]cstring {
    "Strobie is free to try, all of it.",
    "Unlock it once to tune without this",
    "reminder, on iPhone, iPad and Mac.",
}

// The reminder's sheet and its times, see UNLOCK_FREE_S
UnlockReminder :: struct {
    sheet:         Sheet,
    until_next_s:  f32, // on screen until the next one, a whole UNLOCK_REMINDER_S after a start, see new_app
    close_after_s: f32, // left of the countdown, it can be closed at 0
    asked:         bool, // opened from the settings, it has the restore too
    backdrop:      GlowTargets, // the screen under it and its blur, made while it's up, see UNLOCK_BLUR_DOWNSCALE
}

// Once a frame until it's bought: the free minutes counted from the first lit note, and once they're
// used up the reminder every UNLOCK_REMINDER_S
remind_to_unlock :: proc(app: ^App) {
    frame_time := gfx.frame_time()
    reminder := &app.sheets.unlock
    if reminder.sheet.open do reminder.close_after_s = max(reminder.close_after_s - frame_time, 0)
    if purchase_state() == .UNLOCKED do return

    // From the first lit note on, saved, a new start doesn't give it again. The reminder comes as it ends.
    config := app.config
    if config.unlock_free_s < UNLOCK_FREE_S {
        if config.unlock_free_s > 0 || app.measurement.note_target.active do config.unlock_free_s += frame_time
        reminder.until_next_s = 0
        return
    }

    if reminder.sheet.open do return

    reminder.until_next_s -= frame_time
    if reminder.until_next_s <= 0 do open_unlock_sheet(&app.sheets, countdown = true)
}

// Over the main screen, the other sheets go. Opened from the settings it closes at once and has the restore.
// Already up it stays as it is, its countdown too.
open_unlock_sheet :: proc(sheets: ^AppSheets, countdown: bool) {
    reminder := &sheets.unlock
    if reminder.sheet.open do return

    for sheet in all_sheets(sheets) {
        if sheet == &reminder.sheet do continue

        dismiss_sheet(sheets, sheet)
    }
    reset_note_offsets_editing()

    // The App Store asked again when it couldn't be reached, e.g. offline at the start
    ask_app_store_again()

    reminder.sheet.open = true
    reminder.close_after_s = UNLOCK_CLOSE_AFTER_S if countdown else 0
    reminder.until_next_s = UNLOCK_REMINDER_S
    reminder.asked = !countdown
}

// Over the whole window and its blurred backdrop. While the countdown runs it stays up, then Close or Escape
// takes it down.
draw_unlock_sheet :: proc(app: ^App) {
    sheets := &app.sheets
    reminder := &sheets.unlock
    sheet := &reminder.sheet
    if sheet.slide == SHEET_DOWN do return

    // Bought, it can go at once
    if purchase_state() == .UNLOCKED do reminder.close_after_s = 0

    // Not the tap that opened it, not while it slides away
    gui.disabled = !(sheet.was_open && sheet.open)

    close := gui_unlock(reminder.close_after_s, sheet.slide, reminder.asked)
    if reminder.close_after_s > 0 do return

    if close || gfx.key_pressed(.ESCAPE) do dismiss_sheet(sheets, sheet)
}

// A column in the middle of the window that comes up from under it with slide: the title, the words, the button
// that buys it, under it the one that closes it after the countdown, and with restore the restore. Returns close
// when that one is tapped.
gui_unlock :: proc(close_after_s, slide: f32, restore: bool) -> (close: bool) {
    state := purchase_state()
    text, gaps := UNLOCK_TEXT, UNLOCK_GAPS
    font := pixel_fonts.label_large

    left, width, y := unlock_column(slide, restore)
    middle := left + width / 2

    draw_centered_text(pixel_fonts.title_large, "Unlock Strobie", middle, y)
    y += TITLE_LARGE_SIZE + gaps[0]

    for line in text {
        draw_centered_text(font, line, middle, y)
        y += UNLOCK_LINE_HEIGHT
    }
    y += gaps[1]

    // The purchase, its price is on the App Store's own sheet in the buyer's currency
    buy_button := gfx.Rect{left, y, width, UNLOCK_BUTTON_HEIGHT}
    if gui_unlock_button(buy_button, font, buy_label(state), can_buy(state), highlight = true) do buy_unlock()

    y += UNLOCK_BUTTON_HEIGHT + gaps[2]

    // Under it the button that closes it, dead until the countdown runs out
    close_button := gfx.Rect{left, y, width, UNLOCK_BUTTON_HEIGHT}
    close = gui_unlock_button(close_button, font, close_label(close_after_s), close_after_s <= 0)
    y += UNLOCK_BUTTON_HEIGHT + gaps[3]

    if !restore do return

    // Restore, Apple asks for a way to it, as wide as its words. Not on the reminder that interrupts, StoreKit
    // finds an earlier purchase at every start, and buying again what's bought costs nothing.
    label := restore_label(state)
    restore_width := measure_label(pixel_fonts.label, label, 1).x + 2 * UNLOCK_SIDE_MARGIN
    restore_button := gfx.Rect{middle - restore_width / 2, y, restore_width, UNLOCK_RESTORE_HEIGHT}
    if gui_unlock_button(restore_button, pixel_fonts.label, label, can_restore(state)) do restore_purchase()

    return
}

// The column's left edge, its width and its top as it slides up from under the window, in the middle of the
// safe area once it's up
unlock_column :: proc(slide: f32, restore: bool) -> (left, width, top: f32) {
    text, gaps := UNLOCK_TEXT, UNLOCK_GAPS
    window, safe := gfx.window_size(), gfx.safe_area()
    width = min(safe.width - 2 * UNLOCK_SIDE_MARGIN, UNLOCK_WIDTH)
    left = safe.x + (safe.width - width) / 2

    height := TITLE_LARGE_SIZE + gaps[0] + f32(len(text)) * UNLOCK_LINE_HEIGHT + gaps[1]
    height += 2 * UNLOCK_BUTTON_HEIGHT + gaps[2]
    if restore do height += gaps[3] + UNLOCK_RESTORE_HEIGHT

    centered := safe.y + (safe.height - height) / 2
    top = window.y + (centered - window.y) * slide
    return
}

// What the purchase's button says for where the purchase stands
buy_label :: proc(state: PurchaseState) -> (label: cstring) {
    switch state {
    case .READY, .NOTHING_TO_RESTORE:
        label = "Buy once"
    case .LOADING:
        label = "Asking the App Store…"
    case .BUSY:
        label = "Waiting for the App Store…"
    case .UNAVAILABLE:
        label = "The App Store can't be reached"
    case .UNLOCKED:
        label = "Unlocked, thank you!"
    }
    return
}

// Once the App Store has the product, and after a restore that found nothing
can_buy :: proc(state: PurchaseState) -> bool {
    return state == .READY || state == .NOTHING_TO_RESTORE
}

// "Close", or the seconds left until it can be closed
close_label :: proc(close_after_s: f32) -> cstring {
    seconds := int(math.ceil(close_after_s))
    if seconds <= 0 do return "Close"
    if seconds == 1 do return "Close in 1 second"

    return fmt.ctprintf("Close in %v seconds", seconds)
}

restore_label :: proc(state: PurchaseState) -> cstring {
    return "No earlier purchase found" if state == .NOTHING_TO_RESTORE else "Restore purchase"
}

// Not while the App Store is asked or busy, nor once it's bought
can_restore :: proc(state: PurchaseState) -> bool {
    return state != .LOADING && state != .BUSY && state != .UNLOCKED
}

// A pill with its label in the middle, a shade lighter while it's held. The purchase's in yellow with dark
// words while it can be bought. Dead when not enabled, the words stay white.
gui_unlock_button :: proc(rect: gfx.Rect, font: PixelFont, label: cstring, enabled: bool, highlight := false) -> bool {
    fill, words := pill_dark, text_color_white
    if highlight && enabled do fill, words = pill_yellow, text_color_dark
    if enabled && gui_button_held(rect) do fill = pill_gray

    gfx.draw_pill(rect, fill)
    width := measure_label(font, label, 1).x
    draw_label(font, label, {rect.x + (rect.width - width) / 2, rect.y + (rect.height - font.size) / 2}, words, 1)
    return enabled && gui_button(rect)
}

// In white, centred on middle, top is the top of its line
draw_centered_text :: proc(font: PixelFont, text: cstring, middle, top: f32) {
    width := measure_label(font, text, 1).x
    draw_label(font, text, {middle - width / 2, top}, text_color_white, 1)
}

// While the reminder is up or sliding, what's under it is drawn into the backdrop until end_unlock_backdrop,
// which blurs it
begin_unlock_backdrop :: proc(reminder: ^UnlockReminder) {
    backdrop := &reminder.backdrop

    // The scene sharp at the display's scale, the blur in the window's own points like the glow's
    ensure_glow_targets(backdrop, gfx.window_size(), UNLOCK_BLUR_DOWNSCALE)
    gfx.begin_render_target(backdrop.scene_rt, gfx.hex(panel_bg_color), {}, backdrop.scale)
}

// The screen as it was drawn, its blur over it as the sheet comes up, and the sheet's color over that
end_unlock_backdrop :: proc(reminder: ^UnlockReminder) {
    backdrop := &reminder.backdrop
    gfx.end_render_target()

    gfx.set_blend_mode(.REPLACE)
    gfx.begin_shader(.BLOOM)

    // Shrunk first, a wide blur for the taps of a narrow one. Each texel is the average of the scene's under
    // it, a thin stripe moving across texels that took one sample each would flicker.
    blur_size := gfx.render_target_size(backdrop.bloom_rt[0])
    uniforms := gfx.BloomUniforms {
        mode       = .SHRINK,
        texel_step = 1.0 / blur_size,
    }
    gfx.set_shader_uniforms(.BLOOM, &uniforms)
    gfx.begin_render_target(backdrop.bloom_rt[0], nil)
    gfx.draw_render_target(backdrop.scene_rt, {0, 0, blur_size.x, blur_size.y})
    gfx.end_render_target()

    blur_render_targets(backdrop.bloom_rt, UNLOCK_BLUR_ITERATIONS, UNLOCK_BLUR_SPACING)
    gfx.end_shader()

    // The sharp screen under the blur while it slides, once it's up the blur covers all of it
    slide := reminder.sheet.slide
    window := gfx.Rect{0, 0, backdrop.size.x, backdrop.size.y}
    if slide < SHEET_UP do gfx.draw_render_target(backdrop.scene_rt, window)
    gfx.set_blend_mode(.ALPHA)

    gfx.draw_render_target(backdrop.bloom_rt[0], window, fade_color(gfx.WHITE, slide))
    gfx.draw_rect({0, 0}, backdrop.size, fade_color(gfx.hex(sheet_bg_color), UNLOCK_TINT * slide))
}

// The version after the settings' title, and Free until it's unlocked
settings_details :: proc() -> cstring {
    if purchase_state() == .UNLOCKED do return VERSION
    return fmt.ctprintf("%v · Free", VERSION)
}

// UNLOCK in the settings' header after Free until it's unlocked, built with UNLOCK only. It opens the reminder,
// with the restore. Returns true when it's tapped.
gui_settings_unlock :: proc(sheet_layout: SheetLayout) -> bool {
    if purchase_state() == .UNLOCKED do return false

    // After the title and its details as draw_sheet_header lays them out, on the title's middle, a row's height
    // to tap
    DETAILS_GAP :: 12
    BUTTON_GAP :: 10
    LABEL :: "UNLOCK"
    title_size := measure_label(pixel_fonts.title, "Settings", 1)
    details_width := measure_label(pixel_fonts.label, settings_details(), 1).x
    left := sheet_layout.title.x + title_size.x + DETAILS_GAP + details_width + BUTTON_GAP
    middle := sheet_layout.title.y + title_size.y / 2
    control := gfx.Rect{0, middle - SHEET_ROW_HEIGHT / 2, 0, SHEET_ROW_HEIGHT}
    return gui_small_button(left + small_button_width(LABEL), control, LABEL)
}
