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

import "core:testing"


// Picks the note the strobe is tuned to from the pitch detections.
//
// A new note has to be detected several times in a row before the strobe switches to it, otherwise a single
// noisy detection of a decaying note resets the strobe. A locked note keeps its name and the octave follows
// the detected note. A note ringing out an octave off, like a harmonic on some guitar and bass strings, can
// keep the strobe where it is.
Tuner :: struct {
    target_note:          Note, // what the strobe is tuned to
    detected_note:        Note, // the last confirmed detection, cents -1 before the first
    locked:               bool,
    active:               bool, // a pitch is being followed, until the detections turn weak
    pitch:                PitchInfo, // the latest detection
    last_good_pitch:      PitchInfo, // the latest strong detection
    steady_freq:          f32, // the strong detections averaged for the readout, 0 before the first

    // the note seen in a row so far and how many times
    candidate_note:       Note,
    candidate_count:      int,

    confirmations:        int, // detections in a row before switching, the last one must be strong
    prevent_octave_jumps: bool,

    // Cents each note from A0 up is tuned off equal temperament, e.g. a ukulele's E a little flat so its
    // fretted chords sound right. The strobe and the readout follow, see note_offset_cents.
    offsets_cents:        [NOTE_COUNT]f32,
}

init_tuner :: proc(target_freq_hz, pitch_standard: f32, confirmations: int, prevent_octave_jumps: bool) -> Tuner {
    return {
        target_note = find_note(target_freq_hz, pitch_standard),
        detected_note = {cents = -1},
        candidate_note = {cents = -1},
        confirmations = confirmations,
        prevent_octave_jumps = prevent_octave_jumps,
    }
}

// Takes the latest detection, returns whether the strobe has to be retuned to target_note
update_tuner :: proc(self: ^Tuner, pitch: PitchInfo) -> (retune: bool) {
    self.pitch = pitch

    // Count consecutive detections of the same note, only for new measurements. Medium clarity detections
    // count too, a short pluck may only be strong briefly, but the switch itself needs a strong detection.
    if pitch.fresh {
        if pitch.is_weak_pitch {
            self.candidate_count = 0
        } else if self.candidate_note.cents == pitch.detected_note.cents {
            self.candidate_count += 1
        } else {
            self.candidate_note = pitch.detected_note
            self.candidate_count = 1
        }
    }
    confirmed := self.candidate_count >= self.confirmations

    // Keep the previous measurement while there is no detected note
    if pitch.is_strong_pitch {
        if pitch.fresh do steady_readout(self, pitch.detected_freq)
        self.last_good_pitch = pitch
        if confirmed && self.detected_note.cents != pitch.detected_note.cents {
            self.detected_note = pitch.detected_note

            new_target := self.detected_note
            if self.locked do new_target = nearest_note_named(self.detected_note, self.target_note.semitone_index)

            if new_target.cents != self.target_note.cents {
                is_octave := octave_apart(self.target_note, new_target)
                same_offset := note_offset_cents(self, self.target_note) == note_offset_cents(self, new_target)
                self.target_note = new_target

                // The strobe stays on the note it's following, the note is still shown. Not when the octave
                // is tuned off by another amount, the strobe would stand still in the wrong place.
                retune = !(self.prevent_octave_jumps && is_octave && same_offset && self.active)
            }
        }
        self.active = true
    }

    if pitch.is_weak_pitch do self.active = false

    return
}

// A detection moves the readout a fraction of the way, about a quarter second to settle at 20 detections a second
READOUT_SMOOTHING :: 0.2

// Further than this from the readout is a new note or a turned peg, the readout jumps there instead of gliding
READOUT_JUMP_CENTS :: 6

// Averages the strong detections so the readout doesn't flicker with every one, a new pluck starts afresh
steady_readout :: proc(self: ^Tuner, freq: f32) {
    jump := self.steady_freq == 0 || !self.active || abs(cents_deviation(freq, self.steady_freq)) > READOUT_JUMP_CENTS
    if jump {
        self.steady_freq = freq
    } else {
        // In cents rather than Hz, the same smoothing for every note
        self.steady_freq = cents_to_freq(READOUT_SMOOTHING * cents_deviation(freq, self.steady_freq), self.steady_freq)
    }
}

// Unlocked, the target follows the detected note again
toggle_note_lock :: proc(self: ^Tuner) -> (retune: bool) {
    self.locked = !self.locked
    if self.locked || self.detected_note.cents == -1 do return false

    prev := self.target_note
    self.target_note = self.detected_note
    return self.target_note.cents != prev.cents
}

// Locks the target and moves it by steps semitones
step_target_note :: proc(self: ^Tuner, steps: int) -> (retune: bool) {
    if steps == 0 do return false

    self.locked = true
    prev := self.target_note
    for _ in 0 ..< abs(steps) {
        self.target_note = prev_chromatic_note(self.target_note) if steps < 0 else next_chromatic_note(self.target_note)
    }
    // Nothing to do at the end of the range
    return self.target_note.cents != prev.cents
}

// The same notes, tuned to another pitch standard
set_tuner_pitch_standard :: proc(self: ^Tuner, pitch_standard: f32) {
    self.target_note = cents_to_note(f32(self.target_note.cents), pitch_standard)
    if self.detected_note.cents != -1 {
        self.detected_note = cents_to_note(f32(self.detected_note.cents), pitch_standard)
    }
}

// How far the note is tuned off equal temperament, one offset per exact note: E2 and E4 are tuned apart
note_offset_cents :: proc(self: ^Tuner, note: Note) -> f32 {
    index, ok := note_index(note)
    return self.offsets_cents[index] if ok else 0
}

// What the strobe is tuned to, the target note with its offset
tuner_target_freq :: proc(self: ^Tuner) -> f32 {
    return cents_to_freq(note_offset_cents(self, self.target_note), self.target_note.frequency)
}

// The detected note isn't the target, there's nothing for the readout to measure against. A locked note is
// expected to differ, it's measured against anyway.
tuner_out_of_range :: proc(self: ^Tuner) -> bool {
    return !self.locked && self.detected_note.cents != self.target_note.cents
}

// The latest detection as it is, and the strong detections averaged for the readout. A locked note is
// measured against the target instead of the nearest note. Either way from where the note is tuned to, the
// readout is 0 where the strobe stands still.
tuner_readout :: proc(self: ^Tuner) -> (pitch, steady_pitch: PitchInfo) {
    pitch = self.pitch
    steady_pitch = self.last_good_pitch
    if self.steady_freq != 0 do steady_pitch.detected_freq = self.steady_freq

    reference := self.target_note if self.locked else steady_pitch.detected_note
    steady_pitch.err_cents = cents_deviation(steady_pitch.detected_freq, reference.frequency)
    steady_pitch.err_cents -= note_offset_cents(self, reference)

    if self.locked do pitch.err_cents = cents_deviation(pitch.detected_freq, self.target_note.frequency)
    pitch.err_cents -= note_offset_cents(self, self.target_note if self.locked else pitch.detected_note)
    return
}


@(test)
test_tuner :: proc(t: ^testing.T) {
    detection :: proc(freq: f32, strong := true) -> PitchInfo {
        return {
            fresh = true,
            detected_freq = freq,
            detected_note = find_note(freq),
            is_strong_pitch = strong,
            is_weak_pitch = !strong,
        }
    }

    E2 :: 82.41
    A2 :: 110.0
    A3 :: 220.0

    // A new note needs 3 detections in a row
    tuner := init_tuner(E2, 440, 3, true)
    testing.expect(t, !update_tuner(&tuner, detection(A2)))
    testing.expect(t, !update_tuner(&tuner, detection(A2)))
    testing.expect(t, update_tuner(&tuner, detection(A2)))
    testing.expect_value(t, tuner.target_note.name, 'A')

    // A weak detection starts the count again
    tuner = init_tuner(E2, 440, 3, true)
    update_tuner(&tuner, detection(A2))
    update_tuner(&tuner, detection(A2))
    update_tuner(&tuner, detection(A2, strong = false))
    testing.expect(t, !update_tuner(&tuner, detection(A2)))
    testing.expect_value(t, tuner.target_note.name, 'E')

    // An octave jump while a note is followed keeps the strobe, the target note still changes
    tuner = init_tuner(A2, 440, 1, true)
    update_tuner(&tuner, detection(A2))
    testing.expect(t, !update_tuner(&tuner, detection(A3)))
    testing.expect_value(t, tuner.target_note.octave, 3)

    // A locked note keeps its name, the octave follows
    tuner = init_tuner(E2, 440, 1, false)
    toggle_note_lock(&tuner)
    update_tuner(&tuner, detection(A3))
    testing.expect_value(t, tuner.target_note.name, 'E')
    testing.expect_value(t, tuner.target_note.octave, 3)
    testing.expect(t, !tuner_out_of_range(&tuner))

    // Unlocking goes back to the detected note
    testing.expect(t, toggle_note_lock(&tuner))
    testing.expect_value(t, tuner.target_note.name, 'A')

    // Stepping locks and moves by semitones
    testing.expect(t, step_target_note(&tuner, -2))
    testing.expect(t, tuner.locked)
    testing.expect_value(t, tuner.target_note.name, 'G')

    // The readout averages small wobbles, a bigger change jumps straight there
    tuner = init_tuner(A2, 440, 1, true)
    update_tuner(&tuner, detection(A2))
    update_tuner(&tuner, detection(cents_to_freq(2, A2)))
    _, steady := tuner_readout(&tuner)
    testing.expect(t, steady.err_cents > 0.3 && steady.err_cents < 0.5)
    update_tuner(&tuner, detection(cents_to_freq(20, A2)))
    _, steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents - 20) < 0.01)

    // A note tuned 10 cents flat: the strobe is tuned there and the readout counts from there
    tuner = init_tuner(A2, 440, 1, true)
    a2_index, _ := note_index(tuner.target_note)
    tuner.offsets_cents[a2_index] = -10
    testing.expect(t, abs(tuner_target_freq(&tuner) - cents_to_freq(-10, A2)) < 0.001)
    update_tuner(&tuner, detection(cents_to_freq(-10, A2)))
    _, steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents) < 0.01)

    // The octave isn't tuned flat, the strobe moves there instead of staying
    testing.expect(t, update_tuner(&tuner, detection(A3)))
    testing.expect(t, tuner_target_freq(&tuner) == tuner.target_note.frequency)
}
