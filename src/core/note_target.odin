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


package core

import "core:math"


// The note the strobe is tuned to, picked from the notes recognized in the pitch detections, and the readout
// measured from it.
//
// A locked note stays, another note played is measured from it like a string, see out_of_range.
NoteTarget :: struct {
    target_note:          Note, // what the strobe is tuned to
    detected_note:        Maybe(Note), // the last confirmed detection, none before the first
    locked:               bool,
    active:               bool, // a pitch is being followed, until the detections turn weak
    pitch:                PitchInfo, // the latest detection
    last_good_pitch:      PitchInfo, // the latest strong detection
    steady_freq:          f32, // the strong detections averaged for the readout, 0 before the first

    recognition:          NoteRecognition,
    prevent_octave_jumps: bool,

    // Cents each note from A0 up is tuned off equal temperament, e.g. a ukulele's E a little flat so its
    // fretted chords sound right. The strobe and the readout follow, see note_offset_cents.
    offsets_cents:        [NOTE_COUNT]f32,

    // An instrument's strings in the order they're tuned, in semitones from A4, none for every note. The
    // target is always one of them, the nearest to the detected note or the one stepped to, and the
    // readout measures from it however far off the string is. See set_target_strings.
    strings:              [MAX_STRINGS]int,
    string_count:         int,
    string_index:         int, // the target's
}

MAX_STRINGS :: 8 // an 8-string guitar, the built-in tunings go up to 7

// The note confirmed holds this far, 10 cents past halfway to the next, and the next one held holds as far
// back, see update_note_target
NOTE_HOLD_CENTS :: 60

init_note_target :: proc(
    target_freq_hz, pitch_standard: f32,
    prevent_octave_jumps: bool,
    confirm_s: f32 = NOTE_SWITCH_S,
) -> NoteTarget {
    return {
        target_note = freq_to_note(target_freq_hz, pitch_standard),
        recognition = {confirm_s = confirm_s},
        prevent_octave_jumps = prevent_octave_jumps,
    }
}

// Takes the latest detection, returns whether the strobe has to be retuned to target_note.
//
// strobe_hears is whether the strobe shows the note, see strobe_shows_note. It keeps a followed note lit
// when the pitch detection loses it, but only the pitch detection lights one. A fading string sinks into
// the room's noise for the pitch detection while the strobe's narrow tracks still hear it and its
// overtones, settled or still swinging from the attack. The note and the stripes go dark together.
update_note_target :: proc(self: ^NoteTarget, pitch: PitchInfo, strobe_hears := false) -> (retune: bool) {
    // Between two notes, the one confirmed holds until the pitch is NOTE_HOLD_CENTS from it, like a Schmitt
    // trigger. Rounded to the nearest, a pitch wavering round halfway, a hum or a string tuned up from
    // a semitone flat, flipped from one to the other and the strobe's tracks and the scope started over.
    pitch := pitch
    if held, has_held := self.detected_note.?; has_held && !pitch.is_weak_pitch && !holds_note(held, pitch.detected_note) {
        held_freq := freq_at_cents(held.frequency, note_offset_cents(self, held))
        if abs(cents_deviation(pitch.detected_freq, held_freq)) <= NOTE_HOLD_CENTS {
            pitch.detected_note = held
            pitch.err_cents = cents_deviation(pitch.detected_freq, held.frequency)
        }
    }
    self.pitch = pitch

    strong, confirmed := recognize_note(&self.recognition, pitch)
    if strong {
        if confirmed do retune = follow_detected_note(self, pitch.detected_note)

        // Keep the previous measurement while there is no detected note
        if readout_follows(self, pitch.detected_note) {
            if pitch.fresh do steady_readout(self, pitch.detected_freq, pitch.elapsed_s)

            self.last_good_pitch = pitch
        }
        self.active = true
    }

    if pitch.is_weak_pitch && !strobe_hears do self.active = false

    return
}

// A newly confirmed note, the target moves to it or to its string. A locked note stays. A locked string too,
// and a string tuned an octave off is still that string. Returns whether the target moved.
follow_detected_note :: proc(self: ^NoteTarget, detected: Note) -> (retune: bool) {
    if holds_note(self.detected_note, detected) do return false

    self.detected_note = detected

    new_target := self.target_note
    if self.string_count > 0 {
        if !self.locked do self.string_index = nearest_string(self, detected)

        new_target = string_note(self, self.string_index)
    } else if !self.locked {
        new_target = detected
    }

    if new_target.cents == self.target_note.cents do return false

    self.target_note = new_target
    return true
}

// Whether a strong detection of the note moves the readout. A locked note's readout only follows the
// confirmed note, a stray detection an octave or a fifth off would swing it from one side to the other.
// Another note held long enough is measured against the locked one, like a string. An unlocked string's
// only follows that string, another string's note is measured once it's held long enough to be the target,
// not against the string before. A locked string follows every note, it's tuned from wherever it starts.
readout_follows :: proc(self: ^NoteTarget, note: Note) -> bool {
    if locked_note(self) do return holds_note(self.detected_note, note)
    if self.string_count > 0 && !self.locked do return nearest_string(self, note) == self.string_index

    return true
}

// The readout follows the detections with this time constant, about a quarter second to settle
READOUT_SMOOTHING_S :: 0.224

// Further than this from the readout is a new note or a turned peg, the readout jumps there instead of gliding
READOUT_JUMP_CENTS :: 6

// Averages the strong detections so the readout doesn't flicker with every one, a new pluck starts afresh
steady_readout :: proc(self: ^NoteTarget, freq: f32, elapsed_s: f32) {
    jump := self.steady_freq == 0 || !self.active || abs(cents_deviation(freq, self.steady_freq)) > READOUT_JUMP_CENTS
    if jump {
        self.steady_freq = freq
    } else {
        // In cents rather than Hz, the same smoothing for every note
        smoothing := 1 - math.exp(-elapsed_s / READOUT_SMOOTHING_S)
        self.steady_freq = freq_at_cents(self.steady_freq, smoothing * cents_deviation(freq, self.steady_freq))
    }
}

// Unlocked, the target follows the detected note again, or the string nearest to it
toggle_note_lock :: proc(self: ^NoteTarget) -> (retune: bool) {
    self.locked = !self.locked
    detected, has_detected := self.detected_note.?
    if self.locked || !has_detected do return false

    prev := self.target_note
    if self.string_count > 0 {
        self.string_index = nearest_string(self, detected)
        self.target_note = string_note(self, self.string_index)
    } else {
        self.target_note = detected
    }
    return self.target_note.cents != prev.cents
}

// Locks the target and moves it by steps semitones, or strings
step_target_note :: proc(self: ^NoteTarget, steps: int) -> (retune: bool) {
    if steps == 0 do return false

    self.locked = true
    prev := self.target_note
    if self.string_count > 0 {
        self.string_index = clamp(self.string_index + steps, 0, self.string_count - 1)
        self.target_note = string_note(self, self.string_index)
    } else {
        for _ in 0 ..< abs(steps) {
            self.target_note = prev_chromatic_note(self.target_note) if steps < 0 else next_chromatic_note(self.target_note)
        }
    }

    // Nothing to do at the end of the range
    return self.target_note.cents != prev.cents
}

// An instrument's strings, in semitones from A4, or none to go back to every note. The target moves to the
// string nearest to it. Returns whether the strobe has to be retuned.
set_target_strings :: proc(self: ^NoteTarget, strings: []int) -> (retune: bool) {
    assert(len(strings) <= MAX_STRINGS, "more strings than MAX_STRINGS")
    count := len(strings)
    changed := count != self.string_count
    for semitone, index in strings {
        changed ||= self.strings[index] != semitone
        self.strings[index] = semitone
    }
    self.string_count = count
    if !changed do return false

    // The note being played picks the target again, it's only picked when the note changes
    self.detected_note = nil
    if count == 0 do return false

    // The string nearest to the target, plainly: nearest_string's hysteresis and octave rule hold on to a
    // string being tuned, there's none yet
    prev := self.target_note
    semitone := self.target_note.cents / 100
    self.string_index = 0
    for string_semitone, index in self.strings[:count] {
        if abs(semitone - string_semitone) < abs(semitone - self.strings[self.string_index]) do self.string_index = index
    }
    self.target_note = string_note(self, self.string_index)
    return self.target_note.cents != prev.cents
}

string_note :: proc(self: ^NoteTarget, index: int) -> Note {
    return cents_to_note(f32(100 * self.strings[index]), self.target_note.pitch_standard)
}

// The string to tune to the note, the target string until another is more than a semitone closer so it
// doesn't flip back and forth halfway between two. A note an octave off the target string and not near
// another one is the string ringing an octave high, like a low string's harmonic.
nearest_string :: proc(self: ^NoteTarget, note: Note) -> int {
    semitone := note.cents / 100
    best := self.string_index
    for string_semitone, index in self.strings[:self.string_count] {
        if abs(semitone - string_semitone) < abs(semitone - self.strings[best]) do best = index
    }

    // In semitones, from the target string and from the nearest one
    from_target := abs(semitone - self.strings[self.string_index])
    from_nearest := abs(semitone - self.strings[best])
    if self.prevent_octave_jumps && abs(from_target - 12) <= 1 && from_nearest > 1 do return self.string_index

    return best if from_target - from_nearest > 1 else self.string_index
}

// Cents from what the strobe is tuned to. A string that rings an octave off reads from that octave, see
// nearest_string. 0 before anything was detected, active is set before the first detection is followed.
target_cents_off :: proc(self: ^NoteTarget, freq: f32) -> f32 {
    if freq <= 0 do return 0

    cents := cents_deviation(freq, target_freq(self))
    if self.string_count > 0 && self.prevent_octave_jumps && abs(abs(cents) - 1200) < 100 {
        cents -= 1200 if cents > 0 else -1200
    }
    return cents
}

// The same notes, tuned to another pitch standard
set_target_pitch_standard :: proc(self: ^NoteTarget, pitch_standard: f32) {
    self.target_note = cents_to_note(f32(self.target_note.cents), pitch_standard)
    if detected, has_detected := self.detected_note.?; has_detected {
        self.detected_note = cents_to_note(f32(detected.cents), pitch_standard)
    }

    // The readout falls back on the latest strong detection until the strobe settles, its note as the pitch
    // detection names it at the new standard
    last := &self.last_good_pitch
    if last.detected_freq > 0 {
        last.detected_note = freq_to_note(last.detected_freq, pitch_standard)
        last.err_cents = cents_deviation(last.detected_freq, last.detected_note.frequency)
    }
}

// How far the note is tuned off equal temperament, one offset per exact note: E2 and E4 are tuned apart
note_offset_cents :: proc(self: ^NoteTarget, note: Note) -> f32 {
    index, ok := note_index(note)
    return self.offsets_cents[index] if ok else 0
}

// What the strobe is tuned to, the target note with its offset
target_freq :: proc(self: ^NoteTarget) -> f32 {
    return freq_at_cents(self.target_note.frequency, note_offset_cents(self, self.target_note))
}

// Another note is played than a locked one. The gauge measures it from the locked note like a string, the
// strobe's tracks have nothing to measure: one still fitted on the locked note would read it as it was. A
// string's readout carries on however far off it is.
out_of_range :: proc(self: ^NoteTarget) -> bool {
    detected, has_detected := self.detected_note.?
    if self.string_count > 0 || !has_detected do return false

    return detected.cents != self.target_note.cents
}

// A locked note or a string, measured from the target instead of the nearest note
measures_target :: proc(self: ^NoteTarget) -> bool {
    return self.locked || self.string_count > 0
}

// A note locked on the chromatic ruler, not a string
locked_note :: proc(self: ^NoteTarget) -> bool {
    return self.locked && self.string_count == 0
}

// The strong detections averaged for the readout, see readout_cents
readout_pitch :: proc(self: ^NoteTarget) -> (steady_pitch: PitchInfo) {
    steady_pitch = self.last_good_pitch
    if self.steady_freq != 0 do steady_pitch.detected_freq = self.steady_freq

    steady_pitch.err_cents = readout_cents(self, steady_pitch.detected_freq, steady_pitch.detected_note)
    return
}

// Cents of a detected note like the readout's. A locked note or a string is measured against the target
// instead of the nearest note. Either way from where the note is tuned to, 0 where the strobe stands still.
readout_cents :: proc(self: ^NoteTarget, freq: f32, note: Note) -> f32 {
    if measures_target(self) do return target_cents_off(self, freq)

    if freq <= 0 || note.frequency <= 0 do return 0

    return cents_deviation(freq, note.frequency) - note_offset_cents(self, note)
}
