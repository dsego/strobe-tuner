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
import "core:strings"

import "../core"
import "../gfx"

// A stringed instrument: the ruler holds only its strings in the order they're tuned, and the gauge under it
// reaches a few semitones out to bring a string up from far off. It's for beginners, a few named tunings
// each, anything else is tuned on the chromatic ruler. A capo moves the strings up, they keep the names of
// the open strings like the chord shapes do. The transpose only renames notes, it's for chromatic.
//
// A custom instrument's strings are notes picked by hand, a tuning that isn't built in or a handpan's scale.
// They're a preset's note offsets, so only a preset is custom, with no capo or transpose: a note is picked as
// it sounds.
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
    CUSTOM, // the last, only a preset is custom
}

// On top of the sheet's menu, all but CUSTOM
BUILT_IN_INSTRUMENTS :: len(Instrument) - 1
#assert(int(Instrument.CUSTOM) == BUILT_IN_INSTRUMENTS)

INSTRUMENT_NAMES :: [Instrument]string {
    .CHROMATIC        = "Chromatic",
    .GUITAR           = "Guitar",
    .SEVEN_STRING     = "7-string guitar",
    .BASS             = "Bass",
    .UKULELE          = "Ukulele",
    .BARITONE_UKULELE = "Baritone ukulele",
    .CUSTOM           = "Custom",
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
    .CUSTOM           = "CUSTOM",
}

// The standard tuning first, the others' names are in the bottom left corner too
Tuning :: struct {
    name:    string,
    // in the order they're tuned, a guitar's low E first, a ukulele's high G, spelled as cents_to_note spells
    // them (C# and F# sharp, Eb, Ab and Bb flat) so the sheet lists a string as the ruler names it
    strings: []string,
}

TUNINGS := [Instrument][]Tuning {
    .CHROMATIC = {},
    .GUITAR = {
        {"Standard", {"E2", "A2", "D3", "G3", "B3", "E4"}},
        {"Drop D", {"D2", "A2", "D3", "G3", "B3", "E4"}},
        {"Half step down", {"Eb2", "Ab2", "C#3", "F#3", "Bb3", "Eb4"}},
        {"Whole step down", {"D2", "G2", "C3", "F3", "A3", "D4"}},
        {"Drop C", {"C2", "G2", "C3", "F3", "A3", "D4"}},
        {"DADGAD", {"D2", "A2", "D3", "G3", "A3", "D4"}},
        {"Open G", {"D2", "G2", "D3", "G3", "B3", "D4"}},
        {"Open D", {"D2", "A2", "D3", "F#3", "A3", "D4"}},
        {"Open E", {"E2", "B2", "E3", "Ab3", "B3", "E4"}},
    },
    .SEVEN_STRING = {
        {"Standard", {"B1", "E2", "A2", "D3", "G3", "B3", "E4"}},
        {"Drop A", {"A1", "E2", "A2", "D3", "G3", "B3", "E4"}},
    },
    .BASS = {
        {"Standard", {"E1", "A1", "D2", "G2"}},
        {"Drop D", {"D1", "A1", "D2", "G2"}},
        {"Half step down", {"Eb1", "Ab1", "C#2", "F#2"}},
    },
    .UKULELE = {
        {"Standard", {"G4", "C4", "E4", "A4"}},
        {"Low G", {"G3", "C4", "E4", "A4"}},
    },
    .BARITONE_UKULELE = {
        {"Standard", {"D3", "G3", "B3", "E4"}},
    },
    .CUSTOM = {}, // the preset's notes, see custom_strings
}

// An instrument as it's tuned, a built-in one with what it remembers or a preset, see current_setup
Setup :: struct {
    instrument: Instrument,
    tuning:     int, // counted from 0 in the instrument's TUNINGS
    capo:       int,
    transpose:  int,
    preset:     Maybe(int), // counted from 0, none on a built-in instrument
}

// The preset that's tuned to, none on a built-in instrument or one hand edited out of range
selected_preset :: proc(config: ^Config) -> Maybe(int) {
    preset, ok := config.preset.?
    if ok && preset >= 0 && preset < PRESET_SLOTS do return preset

    return nil
}

preset_setup :: proc(config: ^Config, preset: int) -> Setup {
    instrument := config.preset_instruments[preset]
    return {instrument, config.preset_tunings[preset], config.preset_capos[preset], config.preset_transposes[preset], preset}
}

// What's tuned to, the selected preset or the built-in instrument
current_setup :: proc(config: ^Config) -> Setup {
    preset, has_preset := selected_preset(config).?
    if has_preset do return preset_setup(config, preset)

    instrument := config.instrument
    return {instrument, config.instrument_tunings[instrument], config.instrument_capos[instrument], config.transpose, nil}
}

// With its index in the instrument's TUNINGS, none on chromatic
setup_tuning :: proc(setup: Setup) -> (tuning: Tuning, index: int) {
    tunings := TUNINGS[setup.instrument]
    if len(tunings) == 0 do return

    index = clamp(setup.tuning, 0, len(tunings) - 1)
    return tunings[index], index
}

CAPO_MAX_FRET :: 7

// None on the chromatic ruler or a custom instrument
capo_fret :: proc(setup: Setup) -> int {
    if setup.instrument == .CHROMATIC || setup.instrument == .CUSTOM do return 0

    return clamp(setup.capo, 0, CAPO_MAX_FRET)
}

// The key of a transposing instrument, a Bb instrument sounds a tone below the written note and the note
// shows 2 semitones up. Down a key is up a semitone.
TRANSPOSE_KEYS :: [12]string{"C", "B", "Bb", "A", "Ab", "G", "Gb", "F", "E", "Eb", "D", "Db"}

// Only chromatic is transposed, 0 on a stringed instrument
transpose_key :: proc(setup: Setup) -> int {
    return setup.transpose %% 12 if setup.instrument == .CHROMATIC else 0
}

// The strings of the tuning that's tuned to as they sound with the capo, or a custom preset's notes, in
// semitones from A4, none for the chromatic ruler. Lives until the end of the frame.
tuning_strings :: proc(config: ^Config) -> []int {
    setup := current_setup(config)
    preset, has_preset := setup.preset.?
    if has_preset && setup.instrument == .CUSTOM do return custom_strings(config, preset)

    tuning, _ := setup_tuning(setup)
    if len(tuning.strings) == 0 do return nil

    semitones := make([]int, len(tuning.strings), context.temp_allocator)
    for name, index in tuning.strings {
        note, _ := core.parse_note(name)
        semitones[index] = note.cents / 100 + capo_fret(setup)
    }
    return semitones
}

// A custom preset's note offsets in their rows' order, a note in two rows is two strings. None before the
// first row is added, every note like chromatic. Lives until the end of the frame.
custom_strings :: proc(config: ^Config, preset: int) -> []int {
    count := clamp(config.note_offset_counts[preset], 0, MAX_NOTE_OFFSETS)
    semitones := make([]int, count, context.temp_allocator)
    for &semitone, row in semitones {
        note := clamp(config.note_offset_notes[preset][row], 0, core.NOTE_COUNT - 1) // counted from A0
        semitone = note + core.LOWEST_NOTE
    }
    return semitones
}

// For the bottom left corner, in capitals: the instrument's name, or its abbreviation
// before a tuning other than the standard one or a transpose's key, the key keeps its flat, and a capo's
// fret after it. After a preset's number. Lives until the end of the frame.
setup_label :: proc(setup: Setup) -> string {
    names := INSTRUMENT_NAMES
    abbreviations := INSTRUMENT_ABBREVIATIONS
    keys := TRANSPOSE_KEYS
    prefix := ""
    preset, has_preset := setup.preset.?
    if has_preset {
        prefix = fmt.tprintf("P%d - ", preset + 1)
    }

    // A Bb instrument, the way it's said
    transpose := transpose_key(setup)
    if transpose != 0 {
        return fmt.tprintf("%s%s IN %s", prefix, abbreviations[setup.instrument], keys[transpose])
    }

    // A tuning other than the instrument's standard one
    name := strings.to_upper(names[setup.instrument], context.temp_allocator)
    tuning, tuning_index := setup_tuning(setup)
    if tuning_index > 0 {
        name = fmt.tprintf("%s %s", abbreviations[setup.instrument], strings.to_upper(tuning.name, context.temp_allocator))
    }

    // The capo's fret alone, a C2 would read like a note
    capo := capo_fret(setup)
    if capo > 0 {
        name = fmt.tprintf("%s · %d", name, capo)
    }

    return strings.concatenate({prefix, name}, context.temp_allocator)
}

// In the bottom left corner, the piano for every note, the guitar for an instrument's strings or the pinwheel
// for a custom one's notes, and the label of what's tuned to after it, the icons alone don't say which. pos is
// the left edge and the middle. Tapping either opens the sheet.
gui_instrument_button :: proc(pos: [2]f32, config: ^Config) -> bool {
    LABEL_GAP :: 10
    TOUCH_HEIGHT :: 48

    setup := current_setup(config)
    icon := ICON_GUITAR
    if setup.instrument == .CHROMATIC {
        icon = ICON_PIANO_KEYS
    }
    if setup.instrument == .CUSTOM {
        icon = ICON_PINWHEEL
    }

    draw_icon(icon, {pos.x, pos.y - ICON_LARGE_SIZE / 2}, icon_color, .LARGE)

    label := fmt.ctprintf("%s", setup_label(setup))
    label_x := pos.x + ICON_LARGE_SIZE + LABEL_GAP
    label_width := measure_label(pixel_fonts.label, label, 1).x
    draw_label(pixel_fonts.label, label, {label_x, pos.y - LABEL_SIZE / 2}, text_color_light, 1)

    // The icon and the label, a little past them on each side
    return gui_button({pos.x - 12, pos.y - TOUCH_HEIGHT / 2, label_x + label_width + 12 - (pos.x - 12), TOUCH_HEIGHT})
}

INSTRUMENT_WIDTH :: 240 // the dropdown of what's tuned to

// The sheet, it covers the window. On top with no label what's tuned to: the built-in instruments and the
// presets. Under it a preset's instrument, then a stringed instrument's tuning and capo, the
// strings next to the title, or the transpose for chromatic, and a preset's note offsets under them, a custom
// instrument's notes. target is the note a new row starts on, see gui_note_offsets. Returns close when ✕ is
// tapped, changed when the tuner needs the new strings or offsets or the ruler the new names.
gui_instrument :: proc(
    sheet_layout: SheetLayout,
    config: ^Config,
    open: ^Dropdown,
    target: int,
) -> (
    close: bool,
    changed: bool,
) {
    setup := current_setup(config)
    preset, is_preset := setup.preset.?
    tuning, tuning_index := setup_tuning(setup)
    stringed := len(tuning.strings) > 0

    // What the rows change, the built-in instrument's options or the preset's
    tuning_value := &config.instrument_tunings[setup.instrument]
    capo_value := &config.instrument_capos[setup.instrument]
    transpose_value := &config.transpose
    if is_preset {
        tuning_value = &config.preset_tunings[preset]
        capo_value = &config.preset_capos[preset]
        transpose_value = &config.preset_transposes[preset]
    }

    // On top with no label what's tuned to. Under a preset its instrument. Then a stringed instrument's
    // tuning, no row with only the standard one like a baritone ukulele's, and its capo, or the transpose.
    // A custom instrument has neither, its notes come next.
    top_row := settings_row(sheet_layout, 0, "", 0)
    instrument_rect := gfx.Rect{sheet_layout.rows.x, top_row.y, INSTRUMENT_WIDTH, top_row.height}
    tunable := len(TUNINGS[setup.instrument]) > 1
    tuning_row := 2 if is_preset else 1
    options_row := tuning_row + 1 if tunable else tuning_row
    offsets_row := options_row if setup.instrument == .CUSTOM else options_row + 1

    // The strings next to the title
    details: cstring
    if stringed {
        details = fmt.ctprintf("%s", strings.join(tuning.strings, " ", context.temp_allocator))
    }

    close = draw_sheet_header(sheet_layout, "Instrument", details)

    if stringed {
        if gui_capo_row(sheet_layout, options_row, setup, capo_value) {
            changed = true
        }
    } else if setup.instrument == .CHROMATIC {
        if gui_transpose_row(sheet_layout, options_row, setup, transpose_value) {
            changed = true
        }
    }

    if is_preset && gui_note_offsets(sheet_layout, offsets_row, config, preset, target) {
        changed = true
    }

    // The dropdowns from the bottom up, their menus open down over the rows under them
    if tunable && gui_tuning_dropdown(open, sheet_layout, tuning_row, setup.instrument, tuning_index, tuning_value) {
        changed = true
    }

    if is_preset && gui_preset_instrument_dropdown(open, sheet_layout, config, preset) {
        changed = true
    }

    if gui_instrument_dropdown(open, instrument_rect, config, setup.preset) {
        changed = true
    }

    return
}

// Writes the fret to capo_value, true when it changed
gui_capo_row :: proc(sheet_layout: SheetLayout, row: int, setup: Setup, capo_value: ^int) -> bool {
    capo_text :: proc(fret: int) -> cstring {
        return fmt.ctprintf("Fret %d", fret) if fret > 0 else "None"
    }

    widest: f32
    for fret in 0 ..= CAPO_MAX_FRET {
        widest = max(widest, measure_label(pixel_fonts.label, capo_text(fret), 1).x)
    }

    rect := settings_row(sheet_layout, row, "Capo", stepper_width(widest))
    capo := capo_fret(setup)
    steps, reset := gui_stepper_buttons(rect, capo_text(capo))
    capo = 0 if reset else clamp(capo + int(steps), 0, CAPO_MAX_FRET)
    if capo == capo_value^ do return false

    capo_value^ = capo
    return true
}

// Writes the key to transpose_value, true when it changed. Down a key is up a semitone, see TRANSPOSE_KEYS.
gui_transpose_row :: proc(sheet_layout: SheetLayout, row: int, setup: Setup, transpose_value: ^int) -> bool {
    keys := TRANSPOSE_KEYS
    widest: f32
    for key in keys {
        widest = max(widest, measure_label(pixel_fonts.label, fmt.ctprintf("%s", key), 1).x)
    }

    rect := settings_row(sheet_layout, row, "Transpose", stepper_width(widest))
    transpose := transpose_key(setup)
    steps, reset := gui_stepper_buttons(rect, fmt.ctprintf("%s", keys[transpose]))
    if reset {
        transpose = 0
    }

    transpose = (transpose - int(steps)) %% len(keys)
    if transpose == transpose_value^ do return false

    transpose_value^ = transpose
    return true
}

// Writes the tuning to tuning_value, true when it changed. A preset's string offsets stay with the strings.
gui_tuning_dropdown :: proc(
    open: ^Dropdown,
    sheet_layout: SheetLayout,
    row: int,
    instrument: Instrument,
    tuning_index: int,
    tuning_value: ^int,
) -> bool {
    tunings := TUNINGS[instrument]
    options := make([]GuiOption, len(tunings), context.temp_allocator)
    for listed, index in tunings {
        options[index] = {i32(index), listed.name}
    }

    rect := settings_row(sheet_layout, row, "Tuning", dropdown_width(options))
    selected := tuning_index
    gui_settings_dropdown(open, .TUNING, rect, options, &selected, down = true)
    if selected == tuning_index do return false

    tuning_value^ = selected
    return true
}

// A preset's instrument, another one starts the preset over, offsets and a capo are on one instrument and
// not the next. Chromatic's rows and a custom instrument's are both notes, they stay. True when it changed.
gui_preset_instrument_dropdown :: proc(
    open: ^Dropdown,
    sheet_layout: SheetLayout,
    config: ^Config,
    preset: int,
) -> bool {
    options := instrument_options(len(Instrument), 0)
    rect := settings_row(sheet_layout, 1, "Instrument", dropdown_width(options))
    current := int(config.preset_instruments[preset])
    selected := current
    gui_settings_dropdown(open, .PRESET_INSTRUMENT, rect, options, &selected, down = true)
    if selected == current do return false

    previous, instrument := config.preset_instruments[preset], Instrument(selected)
    if (previous == .CHROMATIC || previous == .CUSTOM) && (instrument == .CHROMATIC || instrument == .CUSTOM) {
        config.preset_instruments[preset] = instrument
        config.preset_transposes[preset] = 0
    } else {
        clear_preset(config, preset, instrument)
    }
    reset_note_offsets_editing()
    return true
}

// The preset as it starts on the instrument, the standard tuning, no capo, transpose or note offsets
clear_preset :: proc(config: ^Config, preset: int, instrument: Instrument) {
    config.preset_instruments[preset] = instrument
    config.preset_tunings[preset] = 0
    config.preset_capos[preset] = 0
    config.preset_transposes[preset] = 0
    config.note_offset_counts[preset] = 0
    config.note_offset_notes[preset] = {}
    config.note_offset_cents[preset] = {}
}

// What's tuned to, a built-in instrument or a preset, the one that is is preset. True when it changed.
gui_instrument_dropdown :: proc(open: ^Dropdown, rect: gfx.Rect, config: ^Config, preset: Maybe(int)) -> bool {
    current := int(config.instrument)
    slot, is_preset := preset.?
    if is_preset {
        current = BUILT_IN_INSTRUMENTS + slot
    }

    // A line between the built-in instruments and the presets
    dividers := []int{BUILT_IN_INSTRUMENTS}

    options := instrument_and_preset_options(config)
    selected := current
    gui_settings_dropdown(open, .INSTRUMENT, rect, options, &selected, down = true, dividers = dividers)
    if selected == current do return false

    if selected >= BUILT_IN_INSTRUMENTS {
        config.preset = selected - BUILT_IN_INSTRUMENTS
    } else {
        config.instrument = Instrument(selected)
        config.preset = nil
    }
    reset_note_offsets_editing()
    return true
}

// The built-in instruments, then the preset slots by number with what's in them like the corner. An unused
// slot is chromatic as it starts, its instrument is picked under it.
instrument_and_preset_options :: proc(config: ^Config) -> []GuiOption {
    options := instrument_options(BUILT_IN_INSTRUMENTS, PRESET_SLOTS)
    for slot in 0 ..< PRESET_SLOTS {
        option := BUILT_IN_INSTRUMENTS + slot
        held := preset_setup(config, slot)
        empty := held.instrument == .CHROMATIC && transpose_key(held) == 0 && config.note_offset_counts[slot] == 0
        held.preset = nil // without the P1 in front
        summary := "Empty" if empty else setup_label(held)
        options[option] = {i32(option), fmt.tprintf("Preset %d - %s", slot + 1, summary)}
    }
    return options
}

// The first count instruments by name, and room after them for extra options. Lives until the end of the frame.
instrument_options :: proc(count, extra: int) -> []GuiOption {
    names := INSTRUMENT_NAMES
    options := make([]GuiOption, count + extra, context.temp_allocator)
    for index in 0 ..< count {
        options[index] = {i32(index), names[Instrument(index)]}
    }

    return options
}
