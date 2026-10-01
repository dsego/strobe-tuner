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


package core


import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:testing"


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


// A0 to C8, the notes of a piano, in semitones from A4
LOWEST_NOTE :: -48
HIGHEST_NOTE :: 39
NOTE_COUNT :: HIGHEST_NOTE - LOWEST_NOTE + 1

// Counted from A0, ok is false for a note outside of A0 to C8
note_index :: proc(note: Note) -> (index: int, ok: bool) {
    index = note.cents / 100 - LOWEST_NOTE
    return index, index >= 0 && index < NOTE_COUNT
}

@(test)
test_note_index :: proc(t: ^testing.T) {
    index, ok := note_index(find_note(27.5))
    testing.expect(t, ok)
    testing.expect_value(t, index, 0)

    index, ok = note_index(find_note(4186.01))
    testing.expect(t, ok)
    testing.expect_value(t, index, NOTE_COUNT - 1)

    // Below A0
    _, ok = note_index(find_note(20))
    testing.expect(t, !ok)
}


note_str :: proc(note: Note) -> string {
    return fmt.aprintf("{}{}{}", note.name, "#" if note.is_accidental else "", note.octave)
}


// new note from string, eg new_note("A#2")
new_note :: proc(label: string, pitch_standard: f32 = 440.0) -> (Note, bool) {
    // The name, an optional sharp and a single digit octave
    if len(label) < 2 || len(label) > 3 do return Note{}, false

    name := rune(label[0])
    is_accidental := len(label) == 3
    if is_accidental && label[1] != '#' do return Note{}, false

    digit := label[len(label) - 1]
    if digit < '0' || digit > '9' do return Note{}, false
    octave := int(digit - '0')

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
    testing.expect(t, abs(note.frequency - 65.41) < 0.01)

    note, ok = new_note("A#5")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, note.name, 'A')
    testing.expect_value(t, note.octave, 5)
    testing.expect(t, abs(note.frequency - 932.33) < 0.01)

    // bad notes
    note, ok = new_note("")
    testing.expect_value(t, ok, false)

    note, ok = new_note("K")
    testing.expect_value(t, ok, false)

    note, ok = new_note("A#2#")
    testing.expect_value(t, ok, false)

    // a flat, a negative octave, no octave
    note, ok = new_note("Ab2")
    testing.expect_value(t, ok, false)

    note, ok = new_note("C-1")
    testing.expect_value(t, ok, false)

    note, ok = new_note("AX")
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
    // nearest counts semitones from A4, the pitch standard, but octave numbers change at C. The 4 is A4's
    // octave, the 9 is how far C4 is below A4 (C up to A is 9 semitones), so 4 + 9/12 = 4.75 moves the
    // octave boundary from A down to C: octave = 4 + floor((nearest + 9) / 12)
    octave := math.floor((nearest / 12.0) + 4.75)
    return octave, nearest
}


freq_to_octave :: proc(freq: f32) -> f32 {
    octave, _ := cents_to_octave(freq_to_cents(freq))
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

    // C0 and B-1, below the piano
    octave = freq_to_octave(16.35)
    testing.expect_value(t, octave, 0)

    octave = freq_to_octave(15.43)
    testing.expect_value(t, octave, -1)
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
    cents := note.cents
    switch note.name {
    case 'B', 'E':
        cents += 100
    case:
        cents += 100 if note.is_accidental else 200
    }
    // C8 is the highest note
    cents = min(cents, HIGHEST_NOTE * 100)
    return cents_to_note(f32(cents), note.pitch_standard)
}

prev_note_in_scale :: proc(note: Note) -> Note {
    cents := note.cents
    switch note.name {
    case 'C', 'F':
        cents -= 200 if note.is_accidental else 100
    case:
        cents -= 300 if note.is_accidental else 200
    }
    // A0 is the lowest note
    cents = max(cents, LOWEST_NOTE * 100)
    return cents_to_note(f32(cents), note.pitch_standard)
}

// The range is in cents, in Hz it moves with the pitch standard
next_chromatic_note :: proc(note: Note) -> Note {
    // C8 is the highest note
    if note.cents >= HIGHEST_NOTE * 100 do return note

    return cents_to_note(f32(note.cents + 100), note.pitch_standard)
}

prev_chromatic_note :: proc(note: Note) -> Note {
    // A0 is the lowest note
    if note.cents <= LOWEST_NOTE * 100 do return note

    return cents_to_note(f32(note.cents - 100), note.pitch_standard)
}

octave_down :: proc(note: Note) -> Note {
    // lowest we can go is A0
    if note.cents - 1200 < LOWEST_NOTE * 100 do return note

    return cents_to_note(f32(note.cents - 1200), note.pitch_standard)
}

octave_up :: proc(note: Note) -> Note {
    // highest we can go is C8
    if note.cents + 1200 > HIGHEST_NOTE * 100 do return note

    return cents_to_note(f32(note.cents + 1200), note.pitch_standard)
}

@(test)
test_chromatic_range :: proc(t: ^testing.T) {
    // C8 and A0 stay the ends of the range away from A440
    for pitch_standard in ([]f32{400, 440, 480}) {
        c8 := cents_to_note(HIGHEST_NOTE * 100, pitch_standard)
        testing.expect_value(t, next_chromatic_note(c8).cents, c8.cents)
        testing.expect_value(t, octave_up(prev_chromatic_note(c8)).cents, prev_chromatic_note(c8).cents)

        a0 := cents_to_note(LOWEST_NOTE * 100, pitch_standard)
        testing.expect_value(t, prev_chromatic_note(a0).cents, a0.cents)
        testing.expect_value(t, prev_note_in_scale(next_chromatic_note(a0)).cents, a0.cents)
        testing.expect_value(t, octave_down(next_chromatic_note(a0)).cents, next_chromatic_note(a0).cents)
    }
}


cents_deviation :: proc(freq_1_hz: f32, freq_2_hz: f32) -> f32 {
    return freq_to_cents(freq_1_hz, freq_2_hz)
}

octave_apart :: proc(first: Note, second: Note) -> bool {
    return math.abs(first.cents - second.cents) == 1200
}

// The note with the given name (C = 0 ... B = 11) closest to `note`, within half an octave, or the other
// way when that's past A0 or C8
nearest_note_named :: proc(note: Note, semitone_index: int) -> Note {
    diff := (semitone_index - note.semitone_index) %% 12
    if diff > 6 do diff -= 12
    cents := note.cents + diff * 100
    if cents < LOWEST_NOTE * 100 do cents += 1200
    if cents > HIGHEST_NOTE * 100 do cents -= 1200
    return cents_to_note(f32(cents), note.pitch_standard)
}

@(test)
test_nearest_note_named :: proc(t: ^testing.T) {
    // E locked, A2 detected: E2 is 5 semitones down, E3 is 7 up
    note := nearest_note_named(find_note(110), 4)
    testing.expect_value(t, note.name, 'E')
    testing.expect_value(t, note.octave, 2)

    // E locked, B2 detected: E3 is 5 semitones up
    note = nearest_note_named(find_note(123.47), 4)
    testing.expect_value(t, note.octave, 3)

    // E locked, A0 detected: E0 is below the piano, E1 is up
    note = nearest_note_named(find_note(27.5), 4)
    testing.expect_value(t, note.name, 'E')
    testing.expect_value(t, note.octave, 1)
}
