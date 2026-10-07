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


// A black key is spelled the way most musicians name it, C# and F# sharp, Eb, Ab and Bb flat
Accidental :: enum {
    NATURAL,
    SHARP,
    FLAT,
}

// A note of equal temperament
Note :: struct {
    name:           rune, // the letter, without the sharp or the flat
    semitone_index: int, // C = 0, C# = 1, ... B = 11
    accidental:     Accidental,
    octave:         int,
    cents:          int, // from A4, a whole number of semitones
    frequency:      f32,
    pitch_standard: f32,
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
    index, ok := note_index(freq_to_note(27.5))
    testing.expect(t, ok)
    testing.expect_value(t, index, 0)

    index, ok = note_index(freq_to_note(4186.01))
    testing.expect(t, ok)
    testing.expect_value(t, index, NOTE_COUNT - 1)

    // Below A0
    _, ok = note_index(freq_to_note(20))
    testing.expect(t, !ok)
}


// The letter, the sharp or the flat and the octave, e.g. "C#2" or "Bb2"
note_name :: proc(note: Note, allocator := context.temp_allocator) -> string {
    ACCIDENTALS :: [Accidental]string{.NATURAL = "", .SHARP = "#", .FLAT = "b"}
    accidentals := ACCIDENTALS
    return fmt.aprintf("%v%v%v", note.name, accidentals[note.accidental], note.octave, allocator = allocator)
}


// The note named by a letter, an optional sharp or flat and a single digit octave, e.g. "A#2" or "Bb2"
parse_note :: proc(name: string, pitch_standard: f32 = 440.0) -> (note: Note, ok: bool) {
    if len(name) < 2 || len(name) > 3 do return

    is_accidental := len(name) == 3
    if is_accidental && name[1] != '#' && name[1] != 'b' do return

    digit := name[len(name) - 1]
    if digit < '0' || digit > '9' do return

    // Semitones from A of the same octave
    semitone: int
    switch name[0] {
    case 'C': semitone = -9
    case 'D': semitone = -7
    case 'E': semitone = -5
    case 'F': semitone = -4
    case 'G': semitone = -2
    case 'A': semitone = 0
    case 'B': semitone = 2
    case: return
    }
    if is_accidental do semitone += 1 if name[1] == '#' else -1

    octave := int(digit - '0')
    return cents_to_note(f32(100 * (semitone + 12 * (octave - 4))), pitch_standard), true
}

@(test)
test_parse_note :: proc(t: ^testing.T) {
    note, ok := parse_note("C2")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, note.name, 'C')
    testing.expect_value(t, note.octave, 2)
    testing.expect(t, abs(note.frequency - 65.41) < 0.01)

    note, ok = parse_note("A#5")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, note.name, 'B') // spelled Bb
    testing.expect_value(t, note.octave, 5)
    testing.expect(t, abs(note.frequency - 932.33) < 0.01)
    testing.expect_value(t, note_name(note), "Bb5")

    // A flat is the same key, C# and F# keep their sharps
    flat, _ := parse_note("Bb5")
    testing.expect_value(t, flat.cents, note.cents)
    for name in ([]string{"C#3", "Eb3", "F#3", "Ab3", "Bb3"}) {
        note, ok = parse_note(name)
        testing.expectf(t, ok, "%q didn't parse", name)
        testing.expect_value(t, note_name(note), name)
    }
    note, _ = parse_note("Cb4")
    testing.expect_value(t, note_name(note), "B3")

    // A negative octave, no octave and other junk
    for bad in ([]string{"", "K", "A#2#", "Ax2", "C-1", "AX", "H2"}) {
        _, ok = parse_note(bad)
        testing.expectf(t, !ok, "%q parsed", bad)
    }
}


// Cents from the pitch standard, A4
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


// The note nearest to the cents from the pitch standard, A4
cents_to_note :: proc(cents: f32, pitch_standard: f32 = 440.0) -> (note: Note) {
    NAMES :: [12]rune{'C', 'C', 'D', 'E', 'E', 'F', 'F', 'G', 'A', 'A', 'B', 'B'}
    ACCIDENTALS :: [12]Accidental{1 = .SHARP, 3 = .FLAT, 6 = .SHARP, 8 = .FLAT, 10 = .FLAT}

    // From A4, the octave numbers change at C, 9 semitones below A
    semitones := int(math.round(cents / 100))
    from_c4 := semitones + 9

    note.pitch_standard = pitch_standard
    note.cents = semitones * 100
    note.frequency = cents_to_freq(f32(note.cents), pitch_standard)
    note.semitone_index = from_c4 %% 12
    note.octave = 4 + math.floor_div(from_c4, 12)
    names, accidentals := NAMES, ACCIDENTALS
    note.name = names[note.semitone_index]
    note.accidental = accidentals[note.semitone_index]
    return
}

@(test)
test_cents_to_note :: proc(t: ^testing.T) {
    // A5 880Hz
    note := cents_to_note(1200.0)
    testing.expect_value(t, note.frequency, 880.0)
    testing.expect_value(t, note.semitone_index, 9)
    testing.expect_value(t, note.octave, 5)
}


freq_to_note :: proc(freq: f32, pitch_standard: f32 = 440.0) -> Note {
    return cents_to_note(freq_to_cents(freq, pitch_standard), pitch_standard)
}

@(test)
test_freq_to_note :: proc(t: ^testing.T) {
    // C# 277.18 Hz (above middle C)
    note := freq_to_note(280.0)
    testing.expect_value(t, note.octave, 4)
    testing.expect_value(t, note.semitone_index, 1)
    testing.expect_value(t, note.accidental, Accidental.SHARP)
    testing.expect_value(t, note.name, 'C')

    // Eb 311.13 Hz
    note = freq_to_note(311)
    testing.expect_value(t, note.semitone_index, 3)
    testing.expect_value(t, note.accidental, Accidental.FLAT)
    testing.expect_value(t, note.name, 'E')

    // G4 391.995 Hz
    note = freq_to_note(391)
    testing.expect_value(t, note.octave, 4)
    testing.expect_value(t, note.semitone_index, 7)
    testing.expect_value(t, note.accidental, Accidental.NATURAL)
    testing.expect_value(t, note.name, 'G')

    // The octave changes at C, below the piano too
    octaves := [?]struct {
        freq:   f32,
        octave: int,
    } {
        {27.5, 0}, // A0
        {32.7, 1}, // C1
        {65.4, 2}, // C2
        {123.5, 2}, // B2
        {130.8, 3}, // C3
        {261.6, 4}, // C4
        {440, 4}, // A4
        {987.7, 5}, // B5
        {1046.5, 6}, // C6
        {1760, 6}, // A6
        {2093, 7}, // C7
        {4186, 8}, // C8
        {16.35, 0}, // C0
        {15.43, -1}, // B-1
    }
    for expected in octaves {
        got := freq_to_note(expected.freq).octave
        testing.expectf(t, got == expected.octave, "%v Hz: octave %v, expected %v", expected.freq, got, expected.octave)
    }
}

// A semitone up or down, it stays at C8 and A0. The range is in cents, in Hz it moves with the pitch standard.
next_chromatic_note :: proc(note: Note) -> Note {
    if note.cents >= HIGHEST_NOTE * 100 do return note

    return cents_to_note(f32(note.cents + 100), note.pitch_standard)
}

prev_chromatic_note :: proc(note: Note) -> Note {
    if note.cents <= LOWEST_NOTE * 100 do return note

    return cents_to_note(f32(note.cents - 100), note.pitch_standard)
}

@(test)
test_chromatic_range :: proc(t: ^testing.T) {
    // C8 and A0 stay the ends of the range away from A440
    for pitch_standard in ([]f32{400, 440, 480}) {
        c8 := cents_to_note(HIGHEST_NOTE * 100, pitch_standard)
        testing.expect_value(t, next_chromatic_note(c8).cents, c8.cents)
        testing.expect_value(t, next_chromatic_note(prev_chromatic_note(c8)).cents, c8.cents)

        a0 := cents_to_note(LOWEST_NOTE * 100, pitch_standard)
        testing.expect_value(t, prev_chromatic_note(a0).cents, a0.cents)
        testing.expect_value(t, prev_chromatic_note(next_chromatic_note(a0)).cents, a0.cents)
    }
}


// How many cents freq_hz is above reference_hz
cents_deviation :: proc(freq_hz: f32, reference_hz: f32) -> f32 {
    return freq_to_cents(freq_hz, reference_hz)
}

// The frequency this many cents above reference_hz, below for negative cents
freq_at_cents :: proc(reference_hz: f32, cents: f32) -> f32 {
    return reference_hz * libc.exp2(cents / 1200.0)
}

@(test)
test_freq_at_cents :: proc(t: ^testing.T) {
    testing.expect_value(t, freq_at_cents(110, 1200), 220)
    testing.expect_value(t, freq_at_cents(110, -1200), 55)
    testing.expect(t, abs(cents_deviation(freq_at_cents(61.74, 7.5), 61.74) - 7.5) < 0.001)
}
