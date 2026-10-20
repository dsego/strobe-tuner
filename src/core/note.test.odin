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


#+build !js
package core


import "core:testing"


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

@(test)
test_cents_and_freq :: proc(t: ^testing.T) {
    testing.expect_value(t, cents_deviation(880.0, 440.0), 1200.0)
    testing.expect_value(t, freq_at_cents(440.0, 1200.0), 880.0)
    testing.expect_value(t, freq_at_cents(110, 1200), 220)
    testing.expect_value(t, freq_at_cents(110, -1200), 55)
    testing.expect(t, abs(cents_deviation(freq_at_cents(61.74, 7.5), 61.74) - 7.5) < 0.001)
}

@(test)
test_cents_to_note :: proc(t: ^testing.T) {
    // A5 880Hz
    note := cents_to_note(1200.0)
    testing.expect_value(t, note.frequency, 880.0)
    testing.expect_value(t, note.semitone_index, 9)
    testing.expect_value(t, note.octave, 5)
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
