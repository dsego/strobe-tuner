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
import "core:strings"

import "../core"

// A stringed instrument: the ruler holds only its strings in the order they're tuned, and the gauge under it
// reaches a few semitones out to bring a string up from far off. It's for beginners, a few named tunings
// each, anything else is tuned on the chromatic ruler. A capo moves the strings up, they keep the names of
// the open strings like the chord shapes do. The transpose only renames notes, it's for chromatic.

Instrument :: enum {
    CHROMATIC,
    GUITAR,
    BASS,
    UKULELE,
}

INSTRUMENT_NAMES :: [Instrument]string {
    .CHROMATIC = "Chromatic",
    .GUITAR    = "Guitar",
    .BASS      = "Bass",
    .UKULELE   = "Ukulele",
}

Tuning :: struct {
    name:    string,
    short:   string, // in the bottom left corner, none for the standard tuning, the instrument's name shows
    strings: []string, // in the order they're tuned, a guitar's low E first, a ukulele's high G
}

TUNINGS := [Instrument][]Tuning {
    .CHROMATIC = {},
    .GUITAR = {
        {"Standard", "", {"E2", "A2", "D3", "G3", "B3", "E4"}},
        {"Drop D", "Drop D", {"D2", "A2", "D3", "G3", "B3", "E4"}},
        {"Half step down", "Half down", {"D#2", "G#2", "C#3", "F#3", "A#3", "D#4"}},
        {"Whole step down", "Whole down", {"D2", "G2", "C3", "F3", "A3", "D4"}},
        {"Drop C", "Drop C", {"C2", "G2", "C3", "F3", "A3", "D4"}},
        {"DADGAD", "DADGAD", {"D2", "A2", "D3", "G3", "A3", "D4"}},
        {"Open G", "Open G", {"D2", "G2", "D3", "G3", "B3", "D4"}},
        {"Open D", "Open D", {"D2", "A2", "D3", "F#3", "A3", "D4"}},
        {"Open E", "Open E", {"E2", "B2", "E3", "G#3", "B3", "E4"}},
    },
    .BASS = {
        {"Standard", "", {"E1", "A1", "D2", "G2"}},
        {"Drop D", "Drop D", {"D1", "A1", "D2", "G2"}},
        {"Half step down", "Half down", {"D#1", "G#1", "C#2", "F#2"}},
    },
    .UKULELE = {
        {"Standard", "", {"G4", "C4", "E4", "A4"}},
        {"Low G", "Low G", {"G3", "C4", "E4", "A4"}},
        {"Baritone", "Baritone", {"D3", "G3", "B3", "E4"}},
    },
}

// The strings of the instrument's tuning as they sound with the capo, in semitones from A4, none for the
// chromatic ruler. Lives until the end of the frame.
tuning_strings :: proc(config: ^Config) -> []int {
    tunings := TUNINGS[config.instrument]
    if len(tunings) == 0 do return nil
    names := tunings[clamp(config.tuning, 0, len(tunings) - 1)].strings
    semitones := make([]int, len(names), context.temp_allocator)
    for name, i in names {
        note, _ := core.new_note(name)
        semitones[i] = note.cents / 100 + capo_fret(config)
    }
    return semitones
}

CAPO_MAX_FRET :: 7

// None on the chromatic ruler
capo_fret :: proc(config: ^Config) -> int {
    if config.instrument == .CHROMATIC do return 0
    return clamp(config.capo, 0, CAPO_MAX_FRET)
}

// The key of a transposing instrument, a Bb instrument sounds a tone below the written note and the note
// shows 2 semitones up. Down a key is up a semitone.
TRANSPOSE_KEYS :: [12]string{"C", "B", "Bb", "A", "Ab", "G", "Gb", "F", "E", "Eb", "D", "Db"}

transpose_key :: proc(config: ^Config) -> int {
    return ((config.transpose % 12) + 12) % 12
}

// In the bottom left corner, the piano for every note or the guitar for an instrument's strings, and the
// name after it, the icons alone don't say which. A tuning other than the standard one shows its name
// instead, a capo its fret, a transpose its key. pos is the left edge and the middle. Tapping either opens the sheet.
gui_instrument_button :: proc(pos: [2]f32, config: ^Config) -> bool {
    LABEL_GAP :: 10
    TOUCH_HEIGHT :: 48

    icon := ICON_PIANO_KEYS if config.instrument == .CHROMATIC else ICON_GUITAR
    draw_icon(icon, {pos.x, pos.y - ICON_LARGE_SIZE / 2}, icon_color, large = true)

    // In capitals like the FAST and the OFFSETS labels, the key keeps its flat
    names := INSTRUMENT_NAMES
    keys := TRANSPOSE_KEYS
    tunings := TUNINGS[config.instrument]
    name := names[config.instrument]
    if len(tunings) > 0 {
        // The instrument's initial tells a guitar's Drop D from a bass's
        short := tunings[clamp(config.tuning, 0, len(tunings) - 1)].short
        if short != "" do name = fmt.tprintf("%c %s", name[0], short)
    }
    label := fmt.ctprintf("%s", strings.to_upper(name, context.temp_allocator))
    // The capo's fret alone, a C2 would read like a note
    if capo_fret(config) > 0 do label = fmt.ctprintf("%s · %d", label, capo_fret(config))
    if config.instrument == .CHROMATIC && transpose_key(config) != 0 {
        label = fmt.ctprintf("TRANS. %s", keys[transpose_key(config)])
    }
    label_x := pos.x + ICON_LARGE_SIZE + LABEL_GAP
    label_width := measure_label(pixel_fonts.label, label, 1).x
    draw_label(pixel_fonts.label, label, {label_x, pos.y - LABEL_SIZE / 2}, text_color_light, 1)

    // The icon and the label, a little past them on each side
    return gui_button({pos.x - 12, pos.y - TOUCH_HEIGHT / 2, label_x + label_width + 12 - (pos.x - 12), TOUCH_HEIGHT})
}

INSTRUMENT_ROWS :: 3

// Under the rows, room for the tuning's menu to open down over the capo
instrument_sheet_extra :: proc() -> f32 {
    most := 0
    for tunings in TUNINGS do most = max(most, len(tunings))
    return max(f32(most * 24 + 8) - SHEET_ROW_HEIGHT, 0)
}

// The instrument, then a stringed instrument's tuning and capo, the strings next to the title, or the
// transpose for chromatic. Returns close when ✕ is tapped, changed when the tuner needs the new strings or
// the ruler the new names.
gui_instrument :: proc(sheet_layout: SheetLayout, config: ^Config, menu: ^SettingsMenu) -> (close: bool, changed: bool) {
    sheet, close_area, title_position := sheet_layout.sheet, sheet_layout.close, sheet_layout.title
    draw_rect({sheet.x, sheet.y}, {sheet.width, sheet.height}, hex(sheet_bg_color))

    title: cstring = "Instrument"
    draw_label(pixel_fonts.title, title, title_position, text_color_white, 1)
    tunings := TUNINGS[config.instrument]
    config.tuning = clamp(config.tuning, 0, max(len(tunings) - 1, 0))
    if len(tunings) > 0 {
        details := strings.join(tunings[config.tuning].strings, " ", context.temp_allocator)
        title_size := measure_label(pixel_fonts.title, title, 1)
        details_y := title_position.y + (title_size.y - LABEL_SIZE) / 2
        draw_label(pixel_fonts.label, fmt.ctprintf("%s", details), {title_position.x + title_size.x + 12, details_y}, text_color_light, 1)
    }

    draw_icon(ICON_X, {close_area.x + (close_area.width - 16) / 2, close_area.y + (close_area.height - 16) / 2}, icon_color)
    if gui_button(close_area) do close = true

    if len(tunings) > 0 {
        rect := settings_row(sheet_layout, 2, "Capo", 176)
        capo := capo_fret(config)
        steps, reset := gui_stepper_buttons(rect, fmt.ctprintf("Fret %d", capo) if capo > 0 else "None")
        capo = 0 if reset else clamp(capo + int(steps), 0, CAPO_MAX_FRET)
        if capo != config.capo {
            config.capo = capo
            changed = true
        }
    } else {
        keys := TRANSPOSE_KEYS
        rect := settings_row(sheet_layout, 1, "Transpose", 176)
        transpose := transpose_key(config)
        steps, reset := gui_stepper_buttons(rect, fmt.ctprintf("%s", keys[transpose]))
        if reset do transpose = 0
        transpose = (transpose - int(steps)) %% 12
        if transpose != config.transpose {
            config.transpose = transpose
            changed = true
        }
    }

    // The tuning after the capo and the instrument last, their menus open down over the rows under them
    if len(tunings) > 0 {
        options := make([]GuiOption, len(tunings), context.temp_allocator)
        for tuning, i in tunings do options[i] = {i32(i), tuning.name}
        rect := settings_row(sheet_layout, 1, "Tuning", 176)
        selected := config.tuning
        gui_settings_dropdown(menu, .TUNING, rect, options, &selected, down = true)
        if selected != config.tuning {
            config.tuning = selected
            changed = true
        }
    }

    {
        names := INSTRUMENT_NAMES
        options := make([]GuiOption, len(Instrument), context.temp_allocator)
        for instrument in Instrument do options[int(instrument)] = {i32(instrument), names[instrument]}
        rect := settings_row(sheet_layout, 0, "Instrument", 176)
        selected := int(config.instrument)
        gui_settings_dropdown(menu, .INSTRUMENT, rect, options, &selected, down = true)
        if selected != int(config.instrument) {
            config.instrument = Instrument(selected)
            // A capo is on one instrument, not the next
            config.tuning = 0
            config.capo = 0
            changed = true
        }
    }

    return
}
