package core


import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:testing"
import "core:unicode/utf8"


// GUITAR_STD_NOTES :: []


// Assumes equal temperament

Note :: struct {
    name:           rune, // note name does not include the accidental
    semitone_index: int, // C = 0, C# = 1, ... B = 11
    is_accidental:  bool,
    octave:         int,
    cents:          int,
    frequency:      f32,
    pitch_standard: f32,
    cents_offset:   f32,
}


note_str :: proc(note: Note) -> string {
    return fmt.aprintf("{}{}{}", note.name, "#" if note.is_accidental else "", note.octave)
}


// new note from string, eg new_note("A#2")
new_note :: proc(label: string, pitch_standard: f32 = 440.0) -> (Note, bool) {
    if len(label) < 2 || len(label) > 3 do return Note{}, false

    octave := 0
    name := rune(label[0])
    is_accidental := false

    if len(label) == 2 {
        octave = strconv.parse_int(label[1:]) or_else 0
    }

    if len(label) == 3 && label[1] == '#' {
        is_accidental = true
        octave = strconv.parse_int(label[2:]) or_else 0
    }

    cents := 0

    // octave 4
    if (name == 'C') do cents = -900
    else // C#
    if (name == 'D') do cents = -700
    else // D#
    if (name == 'E') do cents = -500
    else if (name == 'F') do cents = -400
    else // F#
    if (name == 'G') do cents = -200
    else if (name == 'A') do cents = 0
    else // A#
    if (name == 'B') do cents = 200
    else do return Note{}, false

    if is_accidental do cents += 100

    // move to the correct octave
    if octave > 4 do cents += 1200 * (octave - 4)
    if octave < 4 do cents -= 1200 * (4 - octave)

    new_note := cents_to_note(f32(cents), pitch_standard)

    return new_note, true
}

@(test)
test_new_note :: proc(t: ^testing.T) {
    note, ok := new_note("C2")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, note.name, 'C')
    testing.expect_value(t, note.octave, 2)
    testing.expect(t, note.frequency - 65.41 <= 0.00001)

    note, ok = new_note("A#5")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, note.name, 'A')
    testing.expect_value(t, note.octave, 5)
    testing.expect(t, note.frequency - 932.33 <= 0.00001)

    // bad notes
    note, ok = new_note("")
    testing.expect_value(t, ok, false)

    note, ok = new_note("K")
    testing.expect_value(t, ok, false)

    note, ok = new_note("A#2#")
    testing.expect_value(t, ok, false)

}


// Cents difference from the pitch standard A440
freq_to_cents :: proc(freq: f32, pitch_standard: f32 = 440.0) -> f32 {
    return 1200.0 * math.log2(freq / pitch_standard)
}

@(test)
test_freq_to_cents :: proc(t: ^testing.T) {
    cents := freq_to_cents(880.0)
    testing.expect_value(t, cents, 1200.0)
}


cents_to_freq :: proc(cents: f32, pitch_standard: f32 = 440.0) -> f32 {
    return pitch_standard * libc.exp2(cents / 1200.0)
}


@(test)
test_cents_to_freq :: proc(t: ^testing.T) {
    freq := cents_to_freq(1200.0)
    testing.expect_value(t, freq, 880.0)
}


cents_to_octave :: proc(cents: f32) -> (f32, f32) {
    nearest: f32 = math.round(cents / 100.0)
    octave := math.trunc((nearest / 12.0) + 4.75)
    return octave, nearest
}


freq_to_octave :: proc(freq: f32) -> f32 {
    cents := freq_to_cents(freq)
    nearest: f32 = math.round(cents / 100.0)
    octave := math.trunc((nearest / 12.0) + 4.75)
    return octave
}

@(test)
test_freq_to_octave :: proc(t: ^testing.T) {
    // A0
    octave := freq_to_octave(27.5)
    testing.expect_value(t, octave, 0)

    // C1
    octave = freq_to_octave(32.7)
    testing.expect_value(t, octave, 1)

    // C2
    octave = freq_to_octave(65.4)
    testing.expect_value(t, octave, 2)

    // B2
    octave = freq_to_octave(123.5)
    testing.expect_value(t, octave, 2)

    // C3
    octave = freq_to_octave(130.8)
    testing.expect_value(t, octave, 3)

    // C4
    octave = freq_to_octave(261.6)
    testing.expect_value(t, octave, 4)

    // A4
    octave = freq_to_octave(440.0)
    testing.expect_value(t, octave, 4)

    // B5
    octave = freq_to_octave(987.7)
    testing.expect_value(t, octave, 5)

    // C6
    octave = freq_to_octave(1046.5)
    testing.expect_value(t, octave, 6)

    // A6
    octave = freq_to_octave(1760.0)
    testing.expect_value(t, octave, 6)

    // C7
    octave = freq_to_octave(2093.0)
    testing.expect_value(t, octave, 7)

    // C8
    octave = freq_to_octave(4186.0)
    testing.expect_value(t, octave, 8)
}


// Cents difference from the pitch standard A440
cents_to_note :: proc(cents: f32, pitch_standard: f32 = 440.0) -> (note: Note) {
    note_names: []rune = {'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B'}

    octave, nearest := cents_to_octave(cents)

    note.pitch_standard = pitch_standard
    note.cents = cast(int)nearest * 100
    note.octave = cast(int)octave
    note.frequency = cents_to_freq(f32(note.cents), note.pitch_standard)

    index := (cast(int)nearest % 12) + 9 // C = 0
    if index < 0 do index += 12
    else if index > 11 do index -= 12
    note.semitone_index = index

    // C#, D#, F#, G#, A#
    note.is_accidental = (index == 1 || index == 3 || index == 6 || index == 8 || index == 10)

    note.name = note_names[index]

    return note
}

@(test)
test_cents_to_note :: proc(t: ^testing.T) {
    // A5 880Hz
    note := cents_to_note(1200.0)
    testing.expect_value(t, note.frequency, 880.0)
    testing.expect_value(t, note.semitone_index, 9)
    testing.expect_value(t, note.octave, 5)
}


find_note :: proc(freq: f32, pitch_standard: f32 = 440.0) -> Note {
    cents := freq_to_cents(freq, pitch_standard)
    note := cents_to_note(cents, pitch_standard)
    return note
}


@(test)
test_find_note :: proc(t: ^testing.T) {
    // C# 277.18 Hz (above middle C)
    note := find_note(280.0)
    testing.expect_value(t, note.octave, 4)
    testing.expect_value(t, note.semitone_index, 1)
    testing.expect_value(t, note.is_accidental, true)
    testing.expect_value(t, note.name, 'C')
}


@(test)
test_find_note_g4 :: proc(t: ^testing.T) {
    // G4 391.995 Hz
    note := find_note(391)
    testing.expect_value(t, note.octave, 4)
    testing.expect_value(t, note.semitone_index, 7)
    testing.expect_value(t, note.is_accidental, false)
    testing.expect_value(t, note.name, 'G')
}

// TODO: test next_in_scale
next_note_in_scale :: proc(note: Note) -> Note {
    // C8 is the highest note
    if note.name == 'C' && note.octave >= 8 do return note

    cents := note.cents
    switch note.name {
    case 'B', 'E':
        cents += 100
    case:
        cents += 100 if note.is_accidental else 200
    }
    return cents_to_note(f32(cents), note.pitch_standard)
}

prev_note_in_scale :: proc(note: Note) -> Note {
    // A0 is the lowest note
    if note.name == 'A' && note.octave <= 0 do return note

    cents := note.cents
    switch note.name {
    case 'C', 'F':
        cents -= 200 if note.is_accidental else 100
    case:
        cents -= 300 if note.is_accidental else 200
    }
    return cents_to_note(f32(cents), note.pitch_standard)
}

next_chromatic_note :: proc(note: Note) -> Note {
    // C8 is the highest note
    if note.name == 'C' && note.octave >= 8 do return note
    return cents_to_note(f32(note.cents + 100), note.pitch_standard)
}

prev_chromatic_note :: proc(note: Note) -> Note {
    // A0 is the lowest note
    if note.name == 'A' && note.octave <= 0 do return note
    return cents_to_note(f32(note.cents - 100), note.pitch_standard)
}

octave_down :: proc(note: Note) -> Note {
    cents := note.cents - 1200
    new_note := cents_to_note(f32(cents), note.pitch_standard)

    // lowest we can go is A0
    if new_note.name != 'A' && new_note.name != 'B' && new_note.octave == 0 do return note
    if new_note.octave < 0 do return note

    return new_note
}

octave_up :: proc(note: Note) -> Note {
    cents := note.cents + 1200
    new_note := cents_to_note(f32(cents), note.pitch_standard)

    // highest we can go is C8
    if new_note.name != 'C' && new_note.octave >= 8 do return note

    return new_note
}


cents_deviation :: proc(freq_1_hz: f32, freq_2_hz: f32) -> f32 {
    return freq_to_cents(freq_1_hz, freq_2_hz)
}
