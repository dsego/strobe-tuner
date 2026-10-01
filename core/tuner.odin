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
    strobe_anchor:        Maybe(f32), // the strobe's cents at the latest strong detection, see update_tuner

    // the note seen in a row so far and how many times
    candidate_note:       Note,
    candidate_count:      int,
    candidate_freq:       f32, // its latest detection
    steady_count:         int, // of those, in a row each within STEADY_RUN_CENTS of the one before

    // The level of the previous detection and how many detections ago a pluck raised it, see update_tuner
    prev_rms_dbfs:        f32,
    since_pluck:          int,

    confirmations:        int, // detections in a row before switching, the last one strong or the run steady
    prevent_octave_jumps: bool,
    // The strobe shows the octave on a track of its own, it can stay where it is when the note jumps an
    // octave. Fine mode has every track on the one note, it goes dark on the octave and follows it instead.
    octave_track:         bool,

    // Cents each note from A0 up is tuned off equal temperament, e.g. a ukulele's E a little flat so its
    // fretted chords sound right. The strobe and the readout follow, see note_offset_cents.
    offsets_cents:        [NOTE_COUNT]f32,

    // An instrument's strings in the order they're tuned, in semitones from A4, none for every note. The
    // target is always one of them, the nearest to the detected note or the one stepped to, and the
    // readout measures from it however far off the string is. See set_tuner_strings.
    strings:              [MAX_STRINGS]int,
    string_count:         int,
    string_index:         int, // the target's
}

MAX_STRINGS :: 6

init_tuner :: proc(target_freq_hz, pitch_standard: f32, confirmations: int, prevent_octave_jumps: bool) -> Tuner {
    return {
        target_note = find_note(target_freq_hz, pitch_standard),
        detected_note = {cents = -1},
        candidate_note = {cents = -1},
        confirmations = confirmations,
        prevent_octave_jumps = prevent_octave_jumps,
        octave_track = true,
    }
}

// Detections of the same note this close one after the other are a steady pitch, see update_tuner
STEADY_RUN_CENTS :: 5

// The strobe keeps a note lit while it reads within this of where it was at the latest strong detection
STROBE_HOLD_CENTS :: 15

// A pluck raises the level at least this much from one detection to the next, a ringing string only fades
PLUCK_RISE_DB :: 3

// Detections after a pluck, about half a second, while a note an octave or two above the followed one is a
// new note, see update_tuner
PLUCK_DETECTIONS :: 10

// Takes the latest detection, returns whether the strobe has to be retuned to target_note.
//
// strobe_cents is the readout's strobe track while it's loud and settled, see strobe_readout_track. It keeps
// a followed note lit when the pitch detection loses it, but only the pitch detection lights one. A fading
// string barely moves, another sound at the track's frequency beating with it pulls the track further and
// the note goes dark.
update_tuner :: proc(self: ^Tuner, pitch: PitchInfo, strobe_cents: Maybe(f32) = nil) -> (retune: bool) {
    self.pitch = pitch

    // A string's decay can repeat at half or a quarter of its period once its odd partials fade, and the
    // pitch detection reads it an octave or two up. While the wave still repeats better at the followed
    // note's period and nothing was plucked since, it's the same string ringing out, the detection is
    // left out, and so is every repeat of it. A string plucked an octave up repeats better at its own
    // period, or comes with a pluck while the old one still rings.
    if pitch.fresh {
        plucked := pitch.rms_dbfs > self.prev_rms_dbfs + PLUCK_RISE_DB
        self.since_pluck = 0 if plucked else self.since_pluck + 1
        self.prev_rms_dbfs = pitch.rms_dbfs
    }
    octaves_up := pitch.detected_note.cents - self.detected_note.cents
    if self.active && !pitch.is_weak_pitch && (octaves_up == 1200 || octaves_up == 2400) && self.since_pluck >= PLUCK_DETECTIONS {
        for index in 0 ..< pitch.period_peak_count {
            peak := pitch.period_peaks[index]
            followed := find_note(peak.x, self.detected_note.pitch_standard).cents == self.detected_note.cents
            if followed && peak.y > pitch.clarity do return
        }
    }

    // Count consecutive detections of the same note, only for new measurements. Medium clarity detections
    // count too, a short pluck may only be strong briefly, but the switch itself needs a strong detection or
    // a steady run.
    if pitch.fresh {
        if pitch.is_weak_pitch {
            self.candidate_count = 0
            self.steady_count = 0
        } else if self.candidate_note.cents == pitch.detected_note.cents {
            self.candidate_count += 1
            steady := abs(cents_deviation(pitch.detected_freq, self.candidate_freq)) <= STEADY_RUN_CENTS
            self.steady_count = self.steady_count + 1 if steady else 1
        } else {
            self.candidate_note = pitch.detected_note
            self.candidate_count = 1
            self.steady_count = 1
        }
        // A guess at a multiple of the period isn't a steady pitch however close it holds, the wave can
        // repeat better over a few periods for a moment
        if !pitch.shortest_period do self.steady_count = 0
        self.candidate_freq = pitch.detected_freq
    }
    confirmed := self.candidate_count >= self.confirmations

    // Or medium clarity detections that hold steady for as long, e.g. another string ringing along muddies
    // the wave. A stray one in between, like the pitch detection's guess at a multiple of the period,
    // breaks the run. Noise doesn't hold a note to a few cents.
    strong := pitch.is_strong_pitch || (!pitch.is_weak_pitch && self.steady_count >= self.confirmations)

    // Keep the previous measurement while there is no detected note
    if strong {
        if pitch.fresh do steady_readout(self, pitch.detected_freq)
        self.last_good_pitch = pitch
        self.strobe_anchor = strobe_cents
        if confirmed && self.detected_note.cents != pitch.detected_note.cents {
            self.detected_note = pitch.detected_note

            new_target := self.detected_note
            if self.string_count > 0 {
                // A locked string stays, a string tuned an octave off is still that string
                if !self.locked do self.string_index = nearest_string(self, self.detected_note)
                new_target = string_note(self, self.string_index)
            } else if self.locked {
                new_target = nearest_note_named(self.detected_note, self.target_note.semitone_index)
            }

            if new_target.cents != self.target_note.cents {
                is_octave := octave_apart(self.target_note, new_target)
                same_offset := note_offset_cents(self, self.target_note) == note_offset_cents(self, new_target)
                self.target_note = new_target

                // The strobe stays on the note it's following, the note is still shown. Not when the octave
                // is tuned off by another amount, the strobe would stand still in the wrong place. Another
                // string an octave away is another string.
                retune = !(self.prevent_octave_jumps && self.octave_track && is_octave && same_offset && self.active && self.string_count == 0)
            }
        }
        self.active = true
    }

    held := false
    cents, measured := strobe_cents.?
    anchor, anchored := self.strobe_anchor.?
    if measured && anchored do held = abs(cents - anchor) <= STROBE_HOLD_CENTS
    if pitch.is_weak_pitch && !held do self.active = false

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

// Unlocked, the target follows the detected note again, or the string nearest to it
toggle_note_lock :: proc(self: ^Tuner) -> (retune: bool) {
    self.locked = !self.locked
    if self.locked || self.detected_note.cents == -1 do return false

    prev := self.target_note
    if self.string_count > 0 {
        self.string_index = nearest_string(self, self.detected_note)
        self.target_note = string_note(self, self.string_index)
    } else {
        self.target_note = self.detected_note
    }
    return self.target_note.cents != prev.cents
}

// Locks the target and moves it by steps semitones, or strings
step_target_note :: proc(self: ^Tuner, steps: int) -> (retune: bool) {
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
set_tuner_strings :: proc(self: ^Tuner, strings: []int) -> (retune: bool) {
    count := min(len(strings), MAX_STRINGS)
    changed := count != self.string_count
    for i in 0 ..< count {
        changed ||= self.strings[i] != strings[i]
        self.strings[i] = strings[i]
    }
    self.string_count = count
    if !changed do return false

    // The note being played picks the target again, it's only picked when the note changes
    self.detected_note = {cents = -1}
    if count == 0 do return false

    prev := self.target_note
    self.string_index = 0
    self.string_index = nearest_string(self, self.target_note)
    self.target_note = string_note(self, self.string_index)
    return self.target_note.cents != prev.cents
}

string_note :: proc(self: ^Tuner, index: int) -> Note {
    return cents_to_note(f32(100 * self.strings[index]), self.target_note.pitch_standard)
}

// The string to tune to the note, the target string until another is more than a semitone closer so it
// doesn't flip back and forth halfway between two. A note an octave off the target string and not near
// another one is the string ringing an octave high, like a low string's harmonic.
nearest_string :: proc(self: ^Tuner, note: Note) -> int {
    semitone := note.cents / 100
    current := abs(semitone - self.strings[self.string_index])
    best := self.string_index
    for i in 0 ..< self.string_count {
        if abs(semitone - self.strings[i]) < abs(semitone - self.strings[best]) do best = i
    }
    nearest := abs(semitone - self.strings[best])
    if self.prevent_octave_jumps && abs(current - 12) <= 1 && nearest > 1 do return self.string_index
    return best if current - nearest > 1 else self.string_index
}

// Cents from what the strobe is tuned to. A string that rings an octave off reads from that octave, see
// nearest_string.
tuner_cents_off :: proc(self: ^Tuner, freq: f32) -> f32 {
    cents := cents_deviation(freq, tuner_target_freq(self))
    if self.string_count > 0 && self.prevent_octave_jumps && abs(abs(cents) - 1200) < 100 {
        cents -= 1200 if cents > 0 else -1200
    }
    return cents
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

// The detected note isn't the target, there's nothing for the readout to measure against. A locked note or
// a string is expected to differ, it's measured against anyway.
tuner_out_of_range :: proc(self: ^Tuner) -> bool {
    return !measures_target(self) && self.detected_note.cents != self.target_note.cents
}

// A locked note or a string, measured from however far off it is
measures_target :: proc(self: ^Tuner) -> bool {
    return self.locked || self.string_count > 0
}

// The latest detection as it is, and the strong detections averaged for the readout. A locked note or a
// string is measured against the target instead of the nearest note. Either way from where the note is tuned
// to, the readout is 0 where the strobe stands still.
tuner_readout :: proc(self: ^Tuner) -> (pitch, steady_pitch: PitchInfo) {
    pitch = self.pitch
    steady_pitch = self.last_good_pitch
    if self.steady_freq != 0 do steady_pitch.detected_freq = self.steady_freq

    if measures_target(self) {
        steady_pitch.err_cents = tuner_cents_off(self, steady_pitch.detected_freq)
        pitch.err_cents = tuner_cents_off(self, pitch.detected_freq)
        return
    }
    steady_pitch.err_cents = cents_deviation(steady_pitch.detected_freq, steady_pitch.detected_note.frequency)
    steady_pitch.err_cents -= note_offset_cents(self, steady_pitch.detected_note)
    pitch.err_cents -= note_offset_cents(self, pitch.detected_note)
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
            shortest_period = true,
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

    // Medium clarity detections switch once they've held steady as long, a stray guess in between or
    // wandering by more than a few cents starts the run again
    medium :: proc(freq: f32) -> PitchInfo {
        pitch := detection(freq, strong = false)
        pitch.is_weak_pitch = false
        return pitch
    }
    tuner = init_tuner(E2, 440, 3, true)
    update_tuner(&tuner, medium(A2))
    update_tuner(&tuner, medium(A2 * 2.0 / 3.0))
    update_tuner(&tuner, medium(A2))
    testing.expect(t, !update_tuner(&tuner, medium(cents_to_freq(1, A2))))
    testing.expect(t, !tuner.active)
    testing.expect(t, !update_tuner(&tuner, medium(cents_to_freq(10, A2))))
    update_tuner(&tuner, medium(cents_to_freq(12, A2)))
    testing.expect(t, update_tuner(&tuner, medium(cents_to_freq(9, A2))))
    testing.expect(t, tuner.active)
    testing.expect_value(t, tuner.target_note.name, 'A')

    // Not a steady run of guesses at three periods, a third of the note
    tuner = init_tuner(E2, 440, 3, true)
    for _ in 0 ..< 5 {
        guess := medium(A3 / 3)
        guess.shortest_period = false
        testing.expect(t, !update_tuner(&tuner, guess))
    }
    testing.expect(t, !tuner.active)

    // An octave jump while a note is followed keeps the strobe, the target note still changes
    tuner = init_tuner(A2, 440, 1, true)
    update_tuner(&tuner, detection(A2))
    testing.expect(t, !update_tuner(&tuner, detection(A3)))
    testing.expect_value(t, tuner.target_note.octave, 3)

    // A string ringing out an octave up, the wave still repeats better at its own period, is still that note.
    // Not once the octave repeats better, nor right after a pluck.
    E1 :: 41.2
    decay :: proc(octave_clarity, followed_clarity: f32, rms_dbfs: f32 = -30) -> PitchInfo {
        pitch := detection(2 * E1)
        pitch.clarity = octave_clarity
        pitch.rms_dbfs = rms_dbfs
        pitch.period_peaks[0] = {2 * E1, octave_clarity}
        pitch.period_peaks[1] = {E1, followed_clarity}
        pitch.period_peak_count = 2
        return pitch
    }
    ringing :: proc() -> PitchInfo {
        pitch := detection(E1)
        pitch.rms_dbfs = -30
        return pitch
    }
    tuner = init_tuner(E1, 440, 3, true)
    for _ in 0 ..< PLUCK_DETECTIONS do update_tuner(&tuner, ringing())
    // Repeated between detections like the app does every frame
    repeat := decay(0.97, 1)
    repeat.fresh = false
    for _ in 0 ..< 5 {
        update_tuner(&tuner, decay(0.97, 1))
        update_tuner(&tuner, repeat)
    }
    testing.expect_value(t, tuner.detected_note.octave, 1)
    for _ in 0 ..< 3 do update_tuner(&tuner, decay(0.99, 0.98))
    testing.expect_value(t, tuner.detected_note.octave, 2)

    tuner = init_tuner(E1, 440, 3, true)
    for _ in 0 ..< PLUCK_DETECTIONS do update_tuner(&tuner, ringing())
    for _ in 0 ..< 3 do update_tuner(&tuner, decay(0.97, 1, rms_dbfs = -20))
    testing.expect_value(t, tuner.detected_note.octave, 2)

    // The strobe keeps a followed note lit when the detections turn weak, but doesn't light one
    tuner = init_tuner(A2, 440, 1, true)
    update_tuner(&tuner, detection(A2, strong = false), strobe_cents = 0)
    testing.expect(t, !tuner.active)
    update_tuner(&tuner, detection(A2), strobe_cents = 2)
    update_tuner(&tuner, detection(A2, strong = false), strobe_cents = -6)
    testing.expect(t, tuner.active)
    update_tuner(&tuner, detection(A2, strong = false))
    testing.expect(t, !tuner.active)

    // Not when it's pulled further from where it was at the latest strong detection
    update_tuner(&tuner, detection(A2), strobe_cents = 2)
    update_tuner(&tuner, detection(A2, strong = false), strobe_cents = 19)
    testing.expect(t, !tuner.active)

    // Nor without a strobe reading at the strong detection, right after the pluck the track isn't settled
    update_tuner(&tuner, detection(A2))
    update_tuner(&tuner, detection(A2, strong = false), strobe_cents = 0)
    testing.expect(t, !tuner.active)

    // Not without a track for the octave, the strobe follows it
    tuner = init_tuner(A2, 440, 1, true)
    tuner.octave_track = false
    update_tuner(&tuner, detection(A2))
    testing.expect(t, update_tuner(&tuner, detection(A3)))

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

    // A guitar in standard tuning, E2 A2 D3 G3 B3 E4 in semitones from A4
    guitar := []int{-29, -24, -19, -14, -10, -5}
    tuner = init_tuner(A3, 440, 1, true)
    testing.expect(t, set_tuner_strings(&tuner, guitar))
    testing.expect_value(t, tuner.string_index, 3)
    testing.expect_value(t, tuner.target_note.name, 'G')

    // From the low E up past halfway to A it stays on E, until A is more than a semitone closer
    update_tuner(&tuner, detection(E2))
    testing.expect_value(t, tuner.string_index, 0)
    update_tuner(&tuner, detection(97.999)) // G2, 3 semitones up and 2 below A
    testing.expect_value(t, tuner.string_index, 0)
    testing.expect(t, !tuner_out_of_range(&tuner))
    _, steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents - 300) < 0.1)
    update_tuner(&tuner, detection(103.83)) // G#2
    testing.expect_value(t, tuner.string_index, 1)

    // The low E ringing an octave high is still the low E, read from that octave
    update_tuner(&tuner, detection(E2))
    update_tuner(&tuner, detection(2 * E2))
    testing.expect_value(t, tuner.string_index, 0)
    _, steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents) < 0.1)

    // Drop D's low D and the D string an octave up are two strings
    drop_d := []int{-31, -24, -19, -14, -10, -5}
    set_tuner_strings(&tuner, drop_d)
    update_tuner(&tuner, detection(73.42))
    testing.expect_value(t, tuner.string_index, 0)
    update_tuner(&tuner, detection(146.83))
    testing.expect_value(t, tuner.string_index, 2)

    // Stepping goes string by string and locks, a locked string stays whatever is played
    testing.expect(t, step_target_note(&tuner, 1))
    testing.expect_value(t, tuner.string_index, 3)
    testing.expect(t, step_target_note(&tuner, 10))
    testing.expect_value(t, tuner.string_index, 5)
    update_tuner(&tuner, detection(E2))
    testing.expect_value(t, tuner.string_index, 5)

    // Unlocked it goes to the string nearest to the note, without strings to every note again
    toggle_note_lock(&tuner)
    testing.expect_value(t, tuner.string_index, 0)
    set_tuner_strings(&tuner, nil)
    update_tuner(&tuner, detection(A2))
    testing.expect_value(t, tuner.target_note.name, 'A')

    // The same note played on after the strings change picks the target again: a G2 on the low E string,
    // then every note, is the G
    set_tuner_strings(&tuner, guitar)
    update_tuner(&tuner, detection(E2))
    update_tuner(&tuner, detection(97.999))
    testing.expect_value(t, tuner.string_index, 0)
    set_tuner_strings(&tuner, nil)
    update_tuner(&tuner, detection(97.999))
    testing.expect_value(t, tuner.target_note.name, 'G')
}
