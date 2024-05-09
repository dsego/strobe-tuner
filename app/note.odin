package app

import "core:testing"
import "core:fmt"
import "core:math"
import "core:c/libc"
import "core:unicode/utf8"

// Assumes equal temperament


Note :: struct {
    name: u8, // note name does not include the accidental
    semitone_index: int,  // C = 0, C# = 1, ... B = 11
    is_accidental: bool,
    octave: int,
    cents: int,
    frequency: f32,
    pitch_standard: f32,
    // cents_offset: f32,
}

freq_to_cents :: proc (freq: f32, pitch_standard: f32 = 440.0) -> f32 {
    return 1200.0 * math.log2(freq / pitch_standard)
}

@(test)
test_freq_to_cents :: proc(t: ^testing.T) {
    cents := freq_to_cents(880.0)
    testing.expect_value(t, cents, 1200.0)
}


cents_to_freq :: proc (cents: f32, pitch_standard: f32 = 440.0) -> f32 {
    return pitch_standard * libc.exp2(cents / 1200.0)
}

@(test)
test_cents_to_freq :: proc(t: ^testing.T) {
    freq := cents_to_freq(1200.0)
    testing.expect_value(t, freq, 880.0)
}



cents_to_octave :: proc(cents: f32) -> (f32, f32) {
    nearest: f32 = math.round(cents / 100.0)
    octave := math.floor((nearest/12.0) + 4.75)
    return octave, nearest
}

freq_to_octave :: proc(freq: f32) -> f32 {
    cents := freq_to_cents(freq)
    nearest: f32 = math.round(cents / 100.0)
    octave := math.floor((nearest/12.0) + 4.75)
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

note_names: []u8 = {'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B'}

cents_to_note :: proc (cents: f32, pitch_standard: f32 = 440.0) -> (note: Note) {
    octave, nearest := cents_to_octave(cents)

    note.pitch_standard = pitch_standard
    note.cents = cast(int) nearest * 100
    note.octave = cast(int) octave
    note.frequency = cents_to_freq(f32(note.cents), note.pitch_standard)

    index := (cast(int) nearest % 12) + 9;  // C = 0
    if index < 0 do index += 12
    else if index > 11 do index -= 12
    note.semitone_index = index

    // C#, D#, F#, G#, A#
    note.is_accidental = (
        index == 1 ||
        index == 3 ||
        index == 6 ||
        index == 8 ||
        index == 10
    )

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


find_note :: proc (freq: f32, pitch_standard: f32 = 440.0) -> Note {
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
