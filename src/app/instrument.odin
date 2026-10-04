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
import "../gfx"

// A stringed instrument: the ruler holds only its strings in the order they're tuned, and the gauge under it
// reaches a few semitones out to bring a string up from far off. It's for beginners, a few named tunings
// each, anything else is tuned on the chromatic ruler. A capo moves the strings up, they keep the names of
// the open strings like the chord shapes do. The transpose only renames notes, it's for chromatic.
//
// The built-in instruments are picked and tuned to straight away, each remembers its tuning and capo,
// chromatic its transpose. A preset is one of yours as it's tuned: an instrument with its options like the
// built-ins and its own note offsets, two guitars in the same tuning have one each. The slots are fixed,
// a preset keeps its number, and only they have offsets.

PRESET_SLOTS :: 4

Instrument :: enum {
    CHROMATIC,
    GUITAR,
    SEVEN_STRING,
    BASS,
    UKULELE,
    BARITONE_UKULELE,
}

INSTRUMENT_NAMES :: [Instrument]string {
    .CHROMATIC        = "Chromatic",
    .GUITAR           = "Guitar",
    .SEVEN_STRING     = "7-string guitar",
    .BASS             = "Bass",
    .UKULELE          = "Ukulele",
    .BARITONE_UKULELE = "Baritone ukulele",
}

// In the bottom left corner before a tuning other than the standard one or a transpose, letters would read
// like notes
INSTRUMENT_ABBREVIATIONS :: [Instrument]string {
    .CHROMATIC        = "CHROM",
    .GUITAR           = "GTR",
    .SEVEN_STRING     = "7-STR",
    .BASS             = "BASS",
    .UKULELE          = "UKE",
    .BARITONE_UKULELE = "BARI",
}

// The standard tuning first, the others' names are in the bottom left corner too
Tuning :: struct {
    name:    string,
    strings: []string, // in the order they're tuned, a guitar's low E first, a ukulele's high G
}

TUNINGS := [Instrument][]Tuning {
    .CHROMATIC = {},
    .GUITAR = {
        {"Standard", {"E2", "A2", "D3", "G3", "B3", "E4"}},
        {"Drop D", {"D2", "A2", "D3", "G3", "B3", "E4"}},
        {"Half step down", {"D#2", "G#2", "C#3", "F#3", "A#3", "D#4"}},
        {"Whole step down", {"D2", "G2", "C3", "F3", "A3", "D4"}},
        {"Drop C", {"C2", "G2", "C3", "F3", "A3", "D4"}},
        {"DADGAD", {"D2", "A2", "D3", "G3", "A3", "D4"}},
        {"Open G", {"D2", "G2", "D3", "G3", "B3", "D4"}},
        {"Open D", {"D2", "A2", "D3", "F#3", "A3", "D4"}},
        {"Open E", {"E2", "B2", "E3", "G#3", "B3", "E4"}},
    },
    .SEVEN_STRING = {
        {"Standard", {"B1", "E2", "A2", "D3", "G3", "B3", "E4"}},
        {"Drop A", {"A1", "E2", "A2", "D3", "G3", "B3", "E4"}},
    },
    .BASS = {
        {"Standard", {"E1", "A1", "D2", "G2"}},
        {"Drop D", {"D1", "A1", "D2", "G2"}},
        {"Half step down", {"D#1", "G#1", "C#2", "F#2"}},
    },
    .UKULELE = {
        {"Standard", {"G4", "C4", "E4", "A4"}},
        {"Low G", {"G3", "C4", "E4", "A4"}},
    },
    .BARITONE_UKULELE = {
        {"Standard", {"D3", "G3", "B3", "E4"}},
    },
}

// An instrument as it's tuned, a built-in one with what it remembers or a preset, see current_setup
Setup :: struct {
    instrument: Instrument,
    tuning:     int, // counted from 0 in the instrument's TUNINGS
    capo:       int,
    transpose:  int,
    preset:     int, // counted from 0, -1 for a built-in instrument
}

// The preset that's tuned to, -1 on a built-in instrument
selected_preset :: proc(config: ^Config) -> int {
    return config.preset if config.preset >= 0 && config.preset < PRESET_SLOTS else -1
}

preset_setup :: proc(config: ^Config, preset: int) -> Setup {
    value := config.preset_instruments[preset]
    instrument := Instrument(value) if value >= 0 && value < len(Instrument) else .CHROMATIC
    return {instrument, config.preset_tunings[preset], config.preset_capos[preset], config.preset_transposes[preset], preset}
}

// What's tuned to, the selected preset or the built-in instrument
current_setup :: proc(config: ^Config) -> Setup {
    if preset := selected_preset(config); preset >= 0 do return preset_setup(config, preset)

    index := int(config.instrument)
    return {config.instrument, config.instrument_tunings[index], config.instrument_capos[index], config.transpose, -1}
}

// With its index in the instrument's TUNINGS, none on chromatic
setup_tuning :: proc(setup: Setup) -> (tuning: Tuning, index: int) {
    tunings := TUNINGS[setup.instrument]
    if len(tunings) == 0 do return

    index = clamp(setup.tuning, 0, len(tunings) - 1)
    return tunings[index], index
}

CAPO_MAX_FRET :: 7

// None on the chromatic ruler
capo_fret :: proc(setup: Setup) -> int {
    return 0 if setup.instrument == .CHROMATIC else clamp(setup.capo, 0, CAPO_MAX_FRET)
}

// The key of a transposing instrument, a Bb instrument sounds a tone below the written note and the note
// shows 2 semitones up. Down a key is up a semitone.
TRANSPOSE_KEYS :: [12]string{"C", "B", "Bb", "A", "Ab", "G", "Gb", "F", "E", "Eb", "D", "Db"}

// Only chromatic is transposed, 0 on a stringed instrument
transpose_key :: proc(setup: Setup) -> int {
    return setup.transpose %% 12 if setup.instrument == .CHROMATIC else 0
}

// The strings of the tuning that's tuned to as they sound with the capo, in semitones from A4, none for the
// chromatic ruler. Lives until the end of the frame.
tuning_strings :: proc(config: ^Config) -> []int {
    setup := current_setup(config)
    tuning, _ := setup_tuning(setup)
    if len(tuning.strings) == 0 do return nil

    semitones := make([]int, len(tuning.strings), context.temp_allocator)
    for name, i in tuning.strings {
        note, _ := core.parse_note(name)
        semitones[i] = note.cents / 100 + capo_fret(setup)
    }
    return semitones
}

// For the bottom left corner, in capitals like the FAST label: the instrument's name, or its abbreviation
// before a tuning other than the standard one or a transpose's key, the key keeps its flat, and a capo's
// fret after it. After a preset's number. Lives until the end of the frame.
setup_label :: proc(setup: Setup) -> string {
    names := INSTRUMENT_NAMES
    abbreviations := INSTRUMENT_ABBREVIATIONS
    keys := TRANSPOSE_KEYS
    prefix := fmt.tprintf("P%d - ", setup.preset + 1) if setup.preset >= 0 else ""

    // A Bb instrument, the way it's said
    if transpose := transpose_key(setup); transpose != 0 {
        return fmt.tprintf("%s%s IN %s", prefix, abbreviations[setup.instrument], keys[transpose])
    }

    name := strings.to_upper(names[setup.instrument], context.temp_allocator)
    if tuning, index := setup_tuning(setup); index > 0 {
        name = fmt.tprintf("%s %s", abbreviations[setup.instrument], strings.to_upper(tuning.name, context.temp_allocator))
    }

    // The capo's fret alone, a C2 would read like a note
    if capo := capo_fret(setup); capo > 0 do name = fmt.tprintf("%s · %d", name, capo)

    return strings.concatenate({prefix, name}, context.temp_allocator)
}

// In the bottom left corner, the piano for every note or the guitar for an instrument's strings, and the
// label of what's tuned to after it, the icons alone don't say which. pos is the left edge and the middle.
// Tapping either opens the sheet.
gui_instrument_button :: proc(pos: [2]f32, config: ^Config) -> bool {
    LABEL_GAP :: 10
    TOUCH_HEIGHT :: 48

    setup := current_setup(config)
    icon := ICON_PIANO_KEYS if setup.instrument == .CHROMATIC else ICON_GUITAR
    draw_icon(icon, {pos.x, pos.y - ICON_LARGE_SIZE / 2}, icon_color, .LARGE)

    label := fmt.ctprintf("%s", setup_label(setup))
    label_x := pos.x + ICON_LARGE_SIZE + LABEL_GAP
    label_width := measure_label(pixel_fonts.label, label, 1).x
    draw_label(pixel_fonts.label, label, {label_x, pos.y - LABEL_SIZE / 2}, text_color_light, 1)

    // The icon and the label, a little past them on each side
    return gui_button({pos.x - 12, pos.y - TOUCH_HEIGHT / 2, label_x + label_width + 12 - (pos.x - 12), TOUCH_HEIGHT})
}

// The sheet, it covers the window. On top with no label what's tuned to: the built-in instruments and the
// presets. Under it a preset's instrument, then a stringed instrument's tuning and capo, the
// strings next to the title, or the transpose for chromatic, and a preset's note offsets under them. target
// is the note the tuner is on, see gui_note_offsets. Returns close when ✕ is tapped, changed when the tuner
// needs the new strings or offsets or the ruler the new names.
gui_instrument :: proc(
    sheet_layout: SheetLayout,
    config: ^Config,
    menu: ^SettingsMenu,
    target: int,
) -> (
    close: bool,
    changed: bool,
) {
    setup := current_setup(config)
    preset := setup.preset
    tuning, tuning_index := setup_tuning(setup)
    stringed := len(tuning.strings) > 0

    // What the rows change, the built-in instrument's options or the preset's
    tuning_value := &config.instrument_tunings[int(setup.instrument)]
    capo_value := &config.instrument_capos[int(setup.instrument)]
    transpose_value := &config.transpose
    if preset >= 0 {
        tuning_value = &config.preset_tunings[preset]
        capo_value = &config.preset_capos[preset]
        transpose_value = &config.preset_transposes[preset]
    }

    // On top with no label what's tuned to. Under a preset its instrument. Then a stringed instrument's
    // tuning and capo, or the transpose.
    PICK_WIDTH :: 240
    top_row := settings_row(sheet_layout, 0, "", 0)
    pick_rect := gfx.Rect{sheet_layout.rows.x, top_row.y, PICK_WIDTH, top_row.height}

    // No tuning row with only the standard one, a baritone ukulele's
    tunable := len(TUNINGS[setup.instrument]) > 1
    tuning_row := 2 if preset >= 0 else 1
    options_row := tuning_row + 1 if tunable else tuning_row

    // The strings next to the title
    details: cstring
    if stringed do details = fmt.ctprintf("%s", strings.join(tuning.strings, " ", context.temp_allocator))

    close = draw_sheet_header(sheet_layout, "Instrument", details)

    if stringed {
        rect := settings_row(sheet_layout, options_row, "Capo", 176)
        capo := capo_fret(setup)
        steps, reset := gui_stepper_buttons(rect, fmt.ctprintf("Fret %d", capo) if capo > 0 else "None")
        capo = 0 if reset else clamp(capo + int(steps), 0, CAPO_MAX_FRET)
        if capo != capo_value^ {
            capo_value^ = capo
            changed = true
        }
    } else {
        keys := TRANSPOSE_KEYS
        rect := settings_row(sheet_layout, options_row, "Transpose", 176)
        transpose := transpose_key(setup)
        steps, reset := gui_stepper_buttons(rect, fmt.ctprintf("%s", keys[transpose]))
        if reset do transpose = 0

        transpose = (transpose - int(steps)) %% 12
        if transpose != transpose_value^ {
            transpose_value^ = transpose
            changed = true
        }
    }

    if preset >= 0 && gui_note_offsets(sheet_layout, options_row + 1, config, target) {
        changed = true
    }

    // The dropdowns from the bottom up, their menus open down over the rows under them
    if tunable {
        tunings := TUNINGS[setup.instrument]
        options := make([]GuiOption, len(tunings), context.temp_allocator)
        for listed, i in tunings do options[i] = {i32(i), listed.name}

        rect := settings_row(sheet_layout, tuning_row, "Tuning", 176)
        selected := tuning_index
        gui_settings_dropdown(menu, .TUNING, rect, options, &selected, down = true)
        if selected != tuning_index {
            // A preset's string offsets stay with the strings
            tuning_value^ = selected
            changed = true
        }
    }

    if preset >= 0 {
        names := INSTRUMENT_NAMES
        options := make([]GuiOption, len(Instrument), context.temp_allocator)
        for instrument in Instrument do options[int(instrument)] = {i32(instrument), names[instrument]}

        rect := settings_row(sheet_layout, 1, "Instrument", 176)
        selected := int(setup.instrument)
        gui_settings_dropdown(menu, .INSTRUMENT, rect, options, &selected, down = true)
        if selected != int(setup.instrument) {
            // Offsets and a capo are on one instrument, not the next
            config.preset_instruments[preset] = selected
            config.preset_tunings[preset] = 0
            config.preset_capos[preset] = 0
            config.preset_transposes[preset] = 0
            config.note_offset_counts[preset] = 0
            config.note_offset_notes[preset] = {}
            config.note_offset_cents[preset] = {}
            reset_note_offsets_editing()
            changed = true
        }
    }

    {
        // The built-in instruments, then the preset slots by number with what's in them like the corner, a
        // line between them. An unused slot is chromatic as it starts, its instrument is picked under it.
        names := INSTRUMENT_NAMES
        options := make([]GuiOption, len(Instrument) + PRESET_SLOTS, context.temp_allocator)
        for instrument in Instrument do options[int(instrument)] = {i32(instrument), names[instrument]}

        for slot in 0 ..< PRESET_SLOTS {
            option := len(Instrument) + slot
            held := preset_setup(config, slot)
            empty := held.instrument == .CHROMATIC && transpose_key(held) == 0 && config.note_offset_counts[slot] == 0
            held.preset = -1 // without the P1 in front
            summary := "Empty" if empty else setup_label(held)
            options[option] = {i32(option), fmt.tprintf("Preset %d - %s", slot + 1, summary)}
        }
        dividers := []int{len(Instrument)}

        current := len(Instrument) + preset if preset >= 0 else int(config.instrument)
        selected := current
        gui_settings_dropdown(menu, .PICK, pick_rect, options, &selected, down = true, dividers = dividers)
        if selected != current {
            if selected >= len(Instrument) {
                config.preset = selected - len(Instrument)
            } else {
                config.instrument = Instrument(selected)
                config.preset = -1
            }
            reset_note_offsets_editing()
            changed = true
        }
    }

    return
}
