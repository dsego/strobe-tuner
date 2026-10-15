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
import "core:testing"


// The note the strobe is tuned to, picked from the notes recognized in the pitch detections, and the readout
// measured from it.
//
// A locked note stays, another note played is out of range.
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

// Whether a strong detection of the note moves the readout. A locked note's readout only follows that note,
// a stray detection an octave or a fifth off would swing it from one side to the other. An unlocked string's
// only follows that string, another string's note is measured once it's held long enough to be the target,
// not against the string before. A locked string follows every note, it's tuned from wherever it starts.
readout_follows :: proc(self: ^NoteTarget, note: Note) -> bool {
    if locked_note(self) do return note.cents == self.target_note.cents
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

// Another note is played than the target, a locked note's neighbour. The strobe and the readout have
// nothing to measure, the gauge points the way, see out_of_range_side. A string is measured from
// however far off it is.
out_of_range :: proc(self: ^NoteTarget) -> bool {
    detected, has_detected := self.detected_note.?
    if self.string_count > 0 || !has_detected do return false

    return detected.cents != self.target_note.cents
}

// How far the played note is from the target while out of range, in cents, a whole number of semitones
out_of_range_cents :: proc(self: ^NoteTarget) -> f32 {
    detected := self.detected_note.? or_else self.target_note
    return f32(detected.cents - self.target_note.cents)
}

// Which way the played note is from the target while out of range, -1 below and 1 above
out_of_range_side :: proc(self: ^NoteTarget) -> f32 {
    return -1 if out_of_range_cents(self) < 0 else 1
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


// A guitar in standard tuning, E2 A2 D3 G3 B3 E4 in semitones from A4
GUITAR_STRINGS :: [?]int{-29, -24, -19, -14, -10, -5}

// A recognized note retunes the strobe, a weak detection in between starts the count again
@(test)
test_note_target_switches_note :: proc(t: ^testing.T) {
    // 0.1 s is 3 detections 0.05 s apart
    target := init_note_target(E2_HZ, 440, true, 0.1)
    testing.expect(t, !update_note_target(&target, test_detection(A2_HZ)))
    testing.expect(t, !update_note_target(&target, test_detection(A2_HZ)))
    testing.expect(t, update_note_target(&target, test_detection(A2_HZ)))
    testing.expect_value(t, target.target_note.name, 'A')

    target = init_note_target(E2_HZ, 440, true, 0.1)
    update_note_target(&target, test_detection(A2_HZ))
    update_note_target(&target, test_detection(A2_HZ))
    update_note_target(&target, test_detection(A2_HZ, strong = false))
    testing.expect(t, !update_note_target(&target, test_detection(A2_HZ)))
    testing.expect_value(t, target.target_note.name, 'E')
}

// Medium clarity detections follow a note once they've held steady, not before
@(test)
test_note_target_steady_run :: proc(t: ^testing.T) {
    target := init_note_target(E2_HZ, 440, true, 0.1)
    update_note_target(&target, test_medium_detection(A2_HZ))
    update_note_target(&target, test_medium_detection(freq_at_cents(A2_HZ, 1)))
    testing.expect(t, !target.active)
    update_note_target(&target, test_medium_detection(freq_at_cents(A2_HZ, 2)))
    testing.expect(t, target.active)
    testing.expect_value(t, target.target_note.name, 'A')
}

// Concert A raised while a note sounds, the readout reads it against the new A at once
@(test)
test_note_target_pitch_standard :: proc(t: ^testing.T) {
    target := init_note_target(A2_HZ, 440, true, 0)
    update_note_target(&target, test_detection(A2_HZ))
    testing.expect(t, abs(readout_pitch(&target).err_cents) < 0.01)

    set_target_pitch_standard(&target, 442)
    expected := cents_deviation(A2_HZ, A2_HZ * 442 / 440)
    readout := readout_pitch(&target)
    testing.expectf(t, abs(readout.err_cents - expected) < 0.01, "got %v cents, want %v", readout.err_cents, expected)
    testing.expect_value(t, readout.detected_note.name, 'A')
    testing.expect(t, abs(target.target_note.frequency - A2_HZ * 442 / 440) < 0.001)
}

// The strobe follows an octave either way while a note is followed, e.g. a slur down to the note whose
// octave the strobe was on
@(test)
test_note_target_follows_octave :: proc(t: ^testing.T) {
    target := init_note_target(A2_HZ, 440, true, 0)
    update_note_target(&target, test_detection(A2_HZ))
    testing.expect(t, update_note_target(&target, test_detection(A2_HZ / 2)))
    testing.expect_value(t, target.target_note.octave, 1)
    testing.expect(t, update_note_target(&target, test_detection(A2_HZ)))
    testing.expect_value(t, target.target_note.octave, 2)
}

// The strobe keeps a followed note lit when the detections turn weak, but doesn't light one
@(test)
test_note_target_strobe_keeps_note_lit :: proc(t: ^testing.T) {
    target := init_note_target(A2_HZ, 440, true, 0)
    update_note_target(&target, test_detection(A2_HZ, strong = false), strobe_hears = true)
    testing.expect(t, !target.active)
    update_note_target(&target, test_detection(A2_HZ))
    update_note_target(&target, test_detection(A2_HZ, strong = false), strobe_hears = true)
    testing.expect(t, target.active)
    update_note_target(&target, test_detection(A2_HZ, strong = false))
    testing.expect(t, !target.active)
}

// A locked note stays, its octave too. Another note is out of range, the gauge points down to it.
@(test)
test_note_target_note_lock :: proc(t: ^testing.T) {
    target := init_note_target(E2_HZ, 440, false, 0)
    update_note_target(&target, test_detection(E2_HZ))
    toggle_note_lock(&target)
    testing.expect(t, !out_of_range(&target))
    update_note_target(&target, test_detection(E2_HZ / 2))
    testing.expect_value(t, target.target_note.octave, 2)
    testing.expect(t, out_of_range(&target))
    testing.expect_value(t, out_of_range_side(&target), -1)
    testing.expect_value(t, out_of_range_cents(&target), -1200)
    update_note_target(&target, test_detection(A3_HZ))
    testing.expect_value(t, target.target_note.name, 'E')
    testing.expect_value(t, out_of_range_side(&target), 1)

    // Its readout doesn't follow a stray detection of another note
    update_note_target(&target, test_detection(E2_HZ))
    update_note_target(&target, test_detection(2 * E2_HZ))
    steady := readout_pitch(&target)
    testing.expect(t, abs(steady.err_cents) < 0.1) // E2 is 82.407 Hz

    // Unlocking goes back to the detected note
    update_note_target(&target, test_detection(A3_HZ))
    testing.expect(t, toggle_note_lock(&target))
    testing.expect_value(t, target.target_note.name, 'A')

    // Stepping locks and moves by semitones
    testing.expect(t, step_target_note(&target, -2))
    testing.expect(t, target.locked)
    testing.expect_value(t, target.target_note.name, 'G')
}

// The readout averages small wobbles, a bigger change jumps straight there
@(test)
test_note_target_readout_smoothing :: proc(t: ^testing.T) {
    target := init_note_target(A2_HZ, 440, true, 0)
    update_note_target(&target, test_detection(A2_HZ))
    update_note_target(&target, test_detection(freq_at_cents(A2_HZ, 2)))
    steady := readout_pitch(&target)
    testing.expect(t, steady.err_cents > 0.3 && steady.err_cents < 0.5)
    update_note_target(&target, test_detection(freq_at_cents(A2_HZ, 20)))
    steady = readout_pitch(&target)
    testing.expect(t, abs(steady.err_cents - 20) < 0.01)
}

// A note tuned 10 cents flat: the strobe is tuned there and the readout counts from there
@(test)
test_note_target_note_offset :: proc(t: ^testing.T) {
    target := init_note_target(A2_HZ, 440, true, 0)
    a2_index, _ := note_index(target.target_note)
    target.offsets_cents[a2_index] = -10
    testing.expect(t, abs(target_freq(&target) - freq_at_cents(A2_HZ, -10)) < 0.001)
    update_note_target(&target, test_detection(freq_at_cents(A2_HZ, -10)))
    steady := readout_pitch(&target)
    testing.expect(t, abs(steady.err_cents) < 0.01)

    // The octave isn't tuned flat, the strobe moves there untouched
    testing.expect(t, update_note_target(&target, test_detection(A3_HZ)))
    testing.expect(t, target_freq(&target) == target.target_note.frequency)
}

// The target is always one of the instrument's strings, the nearest to the note played
@(test)
test_note_target_strings :: proc(t: ^testing.T) {
    guitar := GUITAR_STRINGS
    target := init_note_target(A3_HZ, 440, true, 0)
    testing.expect(t, set_target_strings(&target, guitar[:]))
    testing.expect_value(t, target.string_index, 3)
    testing.expect_value(t, target.target_note.name, 'G')

    // From every note the nearest string, not the low E an octave below or the nearer one by a semitone
    for start in ([][2]int{{-17, 2}, {-26, 1}}) {
        chromatic := init_note_target(cents_to_note(f32(100 * start.x), 440).frequency, 440, true, 0)
        set_target_strings(&chromatic, guitar[:])
        testing.expect_value(t, chromatic.string_index, start.y)
    }

    // From the low E up past halfway to A it stays on E, until A is more than a semitone closer
    update_note_target(&target, test_detection(E2_HZ))
    testing.expect_value(t, target.string_index, 0)
    update_note_target(&target, test_detection(97.999)) // G2, 3 semitones up and 2 below A
    testing.expect_value(t, target.string_index, 0)
    testing.expect(t, !out_of_range(&target))
    steady := readout_pitch(&target)
    testing.expect(t, abs(steady.err_cents - 300) < 0.1)
    update_note_target(&target, test_detection(103.83)) // G#2
    testing.expect_value(t, target.string_index, 1)

    // The low E ringing an octave high is still the low E, read from that octave
    update_note_target(&target, test_detection(E2_HZ))
    update_note_target(&target, test_detection(2 * E2_HZ))
    testing.expect_value(t, target.string_index, 0)
    steady = readout_pitch(&target)
    testing.expect(t, abs(steady.err_cents) < 0.1)

    // Another string's note isn't measured against the target string while it's held long enough to be the
    // target, then against its own string
    held := init_note_target(A3_HZ, 440, true, 0.1)
    set_target_strings(&held, guitar[:])
    for _ in 0 ..< 3 do update_note_target(&held, test_detection(196.0)) // G3, the target

    update_note_target(&held, test_detection(E2_HZ))
    testing.expect_value(t, held.string_index, 3)
    steady = readout_pitch(&held)
    testing.expect(t, abs(steady.err_cents) < 0.1)
    update_note_target(&held, test_detection(E2_HZ))
    update_note_target(&held, test_detection(E2_HZ))
    testing.expect_value(t, held.string_index, 0)
    steady = readout_pitch(&held)
    testing.expect(t, abs(steady.err_cents) < 0.1)

    // Drop D's low D and the D string an octave up are two strings
    drop_d := []int{-31, -24, -19, -14, -10, -5}
    set_target_strings(&target, drop_d)
    update_note_target(&target, test_detection(73.42))
    testing.expect_value(t, target.string_index, 0)
    update_note_target(&target, test_detection(146.83))
    testing.expect_value(t, target.string_index, 2)
}

// Stepping goes string by string and locks, a locked string stays whatever is played
@(test)
test_note_target_string_steps :: proc(t: ^testing.T) {
    guitar := GUITAR_STRINGS
    drop_d := []int{-31, -24, -19, -14, -10, -5}
    target := init_note_target(A3_HZ, 440, true, 0)
    set_target_strings(&target, drop_d)
    update_note_target(&target, test_detection(146.83)) // D3
    testing.expect_value(t, target.string_index, 2)

    testing.expect(t, step_target_note(&target, 1))
    testing.expect_value(t, target.string_index, 3)
    testing.expect(t, step_target_note(&target, 10))
    testing.expect_value(t, target.string_index, 5)
    update_note_target(&target, test_detection(E2_HZ))
    testing.expect_value(t, target.string_index, 5)

    // Unlocked it goes to the string nearest to the note, without strings to every note again
    toggle_note_lock(&target)
    testing.expect_value(t, target.string_index, 0)
    set_target_strings(&target, nil)
    update_note_target(&target, test_detection(A2_HZ))
    testing.expect_value(t, target.target_note.name, 'A')

    // The same note played on after the strings change picks the target again: a G2 on the low E string,
    // then every note, is the G
    set_target_strings(&target, guitar[:])
    update_note_target(&target, test_detection(E2_HZ))
    update_note_target(&target, test_detection(97.999))
    testing.expect_value(t, target.string_index, 0)
    set_target_strings(&target, nil)
    update_note_target(&target, test_detection(97.999))
    testing.expect_value(t, target.target_note.name, 'G')

    // A seven string's high E is a string too
    seven_string := []int{-34, -29, -24, -19, -14, -10, -5}
    set_target_strings(&target, seven_string)
    testing.expect_value(t, target.string_count, 7)
    step_target_note(&target, 10)
    testing.expect_value(t, target.target_note.cents, -500)
}
