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


import "core:fmt"
import "core:math"


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


// How many cents freq_hz is above reference_hz, e.g. the pitch standard A4
cents_deviation :: proc(freq_hz: f32, reference_hz: f32) -> f32 {
    return 1200.0 * math.log2(freq_hz / reference_hz)
}

// The frequency this many cents above reference_hz, below for negative cents
freq_at_cents :: proc(reference_hz: f32, cents: f32) -> f32 {
    return reference_hz * math.pow(f32(2), cents / 1200.0)
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
    note.frequency = freq_at_cents(pitch_standard, f32(note.cents))
    note.semitone_index = from_c4 %% 12
    note.octave = 4 + math.floor_div(from_c4, 12)
    names, accidentals := NAMES, ACCIDENTALS
    note.name = names[note.semitone_index]
    note.accidental = accidentals[note.semitone_index]
    return
}


freq_to_note :: proc(freq: f32, pitch_standard: f32 = 440.0) -> Note {
    return cents_to_note(cents_deviation(freq, pitch_standard), pitch_standard)
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
