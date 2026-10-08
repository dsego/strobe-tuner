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

import "core:math"
import "core:testing"


// Picks the note the strobe is tuned to from the pitch detections.
//
// A new note has to be detected for a moment in a row before the strobe switches to it, otherwise a single
// noisy detection of a decaying note resets the strobe. A locked note stays, another note played is out of
// range.
Tuner :: struct {
    target_note:          Note, // what the strobe is tuned to
    detected_note:        Note, // the last confirmed detection, cents -1 before the first
    locked:               bool,
    active:               bool, // a pitch is being followed, until the detections turn weak
    pitch:                PitchInfo, // the latest detection
    last_good_pitch:      PitchInfo, // the latest strong detection
    steady_freq:          f32, // the strong detections averaged for the readout, 0 before the first

    // the note seen in a row so far, cents -1 for none, and for how long
    candidate_note:       Note,
    candidate_s:          f32,
    steady_s:             f32, // of that, held within STEADY_RUN_CENTS of run_freq, -1 for no run
    run_freq:             f32, // the first detection of the steady run

    confirm_s:            f32, // seen this long in a row before switching, the last one strong or the run steady
    prevent_octave_jumps: bool,

    // The target moved up to the partial the readout measures, octaves over the note played, see
    // follow_readout_partial
    on_partial:           bool,

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

MAX_STRINGS :: 8 // an 8-string guitar, the built-in tunings go up to 7

// How long a new note is detected in a row before the strobe switches to it, the last detection strong or
// the run steady. At 0 a note under hum flickers.
NOTE_SWITCH_S :: 0.05

init_tuner :: proc(
    target_freq_hz, pitch_standard: f32,
    prevent_octave_jumps: bool,
    confirm_s: f32 = NOTE_SWITCH_S,
) -> Tuner {
    return {
        target_note = freq_to_note(target_freq_hz, pitch_standard),
        detected_note = {cents = -1},
        candidate_note = {cents = -1},
        confirm_s = confirm_s,
        prevent_octave_jumps = prevent_octave_jumps,
    }
}

// Detections of the same note this close to the first of them are a steady pitch, see update_tuner
STEADY_RUN_CENTS :: 5

// Takes the latest detection, returns whether the strobe has to be retuned to target_note.
//
// strobe_hears is whether the strobe shows the note, see strobe_shows_note. It keeps a followed note lit
// when the pitch detection loses it, but only the pitch detection lights one. A fading string sinks into
// the room's noise for the pitch detection while the strobe's narrow tracks still hear it and its
// overtones, settled or still swinging from the attack. The note and the stripes go dark together.
update_tuner :: proc(self: ^Tuner, pitch: PitchInfo, strobe_hears := false) -> (retune: bool) {
    self.pitch = pitch

    // Time consecutive detections of the same note, only for new measurements. Medium clarity detections
    // count too, a short pluck may only be strong briefly, but the switch itself needs a strong detection or
    // a steady run.
    if pitch.fresh {
        if pitch.is_weak_pitch {
            self.candidate_note = {cents = -1}
        } else if self.candidate_note.cents == pitch.detected_note.cents {
            self.candidate_s += pitch.elapsed_s
            if self.steady_s >= 0 && abs(cents_deviation(pitch.detected_freq, self.run_freq)) <= STEADY_RUN_CENTS {
                self.steady_s += pitch.elapsed_s
            } else {
                self.steady_s = 0
                self.run_freq = pitch.detected_freq
            }
        } else {
            self.candidate_note = pitch.detected_note
            self.candidate_s = 0
            self.steady_s = 0
            self.run_freq = pitch.detected_freq
        }

        // A guess at a multiple of the period isn't a steady pitch however close it holds, the wave can
        // repeat better over a few periods for a moment
        if !pitch.shortest_period do self.steady_s = -1
    }
    seen := self.candidate_note.cents == pitch.detected_note.cents
    confirmed := seen && self.candidate_s >= self.confirm_s

    // Or medium clarity detections that hold steady for as long, e.g. another string ringing along muddies
    // the wave. A stray one in between, like the pitch detection's guess at a multiple of the period,
    // breaks the run. Noise doesn't hold a note to a few cents.
    steady := seen && self.steady_s >= 0 && self.steady_s >= self.confirm_s
    strong := pitch.is_strong_pitch || (!pitch.is_weak_pitch && steady)

    if strong {
        if confirmed && self.detected_note.cents != pitch.detected_note.cents {
            self.detected_note = pitch.detected_note

            // A locked note stays. A locked string too, and a string tuned an octave off is still that string.
            new_target := self.target_note
            if self.string_count > 0 {
                if !self.locked do self.string_index = nearest_string(self, self.detected_note)

                new_target = string_note(self, self.string_index)
            } else if !self.locked {
                // On a partial the note played is still under it, e.g. the pitch detection going between the
                // fundamental and the 2nd harmonic. Another note starts over from that one.
                if plays_under_partial(self, self.detected_note) {
                    new_target = self.target_note
                } else {
                    new_target = self.detected_note
                    self.on_partial = false
                }
            }

            if new_target.cents != self.target_note.cents {
                retune = true
                self.target_note = new_target
            }
        }

        // Keep the previous measurement while there is no detected note. A locked note's readout only follows
        // that note, a stray detection an octave or a fifth off would swing it from one side to the other. An
        // unlocked string's only follows that string, another string's note is measured once it's held long
        // enough to be the target, not against the string before. A locked string follows every note, it's
        // tuned from wherever it starts.
        follows := true
        if locked_note(self) {
            follows = pitch.detected_note.cents == self.target_note.cents
        } else if self.string_count > 0 && !self.locked {
            follows = nearest_string(self, pitch.detected_note) == self.string_index
        }
        if follows {
            if pitch.fresh do steady_readout(self, pitch.detected_freq, pitch.elapsed_s)

            self.last_good_pitch = pitch
        }
        self.active = true
    }

    if pitch.is_weak_pitch && !strobe_hears do self.active = false

    return
}

// The readout follows the detections with this time constant, about a quarter second to settle
READOUT_SMOOTHING_S :: 0.224

// Further than this from the readout is a new note or a turned peg, the readout jumps there instead of gliding
READOUT_JUMP_CENTS :: 6

// Averages the strong detections so the readout doesn't flicker with every one, a new pluck starts afresh
steady_readout :: proc(self: ^Tuner, freq: f32, elapsed_s: f32) {
    jump := self.steady_freq == 0 || !self.active || abs(cents_deviation(freq, self.steady_freq)) > READOUT_JUMP_CENTS
    if jump {
        self.steady_freq = freq
    } else {
        // In cents rather than Hz, the same smoothing for every note
        smoothing := 1 - math.exp(-elapsed_s / READOUT_SMOOTHING_S)
        self.steady_freq = freq_at_cents(self.steady_freq, smoothing * cents_deviation(freq, self.steady_freq))
    }
}

// The readout gave way to a partial over the target, the strobe moves up to it so its tracks count from the
// note shown, 1× is the partial. A pluck goes back to the note played, its fundamental may ring again. A
// locked note and a string keep their own. track and ready are strobe_readout_track's, was_ready its
// ready of the frame before: the tracks start over on a retune and a fresh one's first level is a pluck.
// Only while the note is lit, a string still ringing: dark, a click or a bump in the tracks would move it
// up and up. Not past the highest note. Called after update_tuner, returns whether the strobe has to be
// retuned.
follow_readout_partial :: proc(self: ^Tuner, strobe: ^PhaseComparator, track: int, ready, was_ready: bool) -> (retune: bool) {
    if !self.active do return false

    if self.on_partial && was_ready && strobe_plucked(strobe) {
        self.on_partial = false
        if self.detected_note.cents == -1 || self.detected_note.cents == self.target_note.cents do return false

        self.target_note = self.detected_note
        return true
    }
    if !ready || measures_target(self) do return false

    octaves := readout_octaves(strobe.bands[track], tuner_target_freq(self))
    if octaves <= 0 do return false

    // Only with the fundamental under the partial. Its track can lose the note for a moment while it catches
    // the attack, the readout's loudest is then a partial the note may not have.
    for band in strobe.bands {
        if band.interval == 1 && band.snr_db >= strobe.bands[track].snr_db do return false
    }

    partial_cents := self.target_note.cents + 1200 * octaves
    if partial_cents > HIGHEST_NOTE * 100 do return false

    self.target_note = cents_to_note(f32(partial_cents), self.target_note.pitch_standard)
    self.on_partial = true
    return true
}

// The note played under the partial the target moved up to, the target's note at or below it
plays_under_partial :: proc(self: ^Tuner, note: Note) -> bool {
    below := self.target_note.cents - note.cents
    return self.on_partial && !measures_target(self) && below >= 0 && below % 1200 == 0
}

// Unlocked, the target follows the detected note again, or the string nearest to it
toggle_note_lock :: proc(self: ^Tuner) -> (retune: bool) {
    self.locked = !self.locked
    self.on_partial = false
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
    self.on_partial = false
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
    self.detected_note = {cents = -1}
    if count == 0 do return false

    // The string nearest to the target from the first one, the previous string may be past the new count
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
    return freq_at_cents(self.target_note.frequency, note_offset_cents(self, self.target_note))
}

// Another note is played than the target, a locked note's neighbour. The strobe and the readout have
// nothing to measure, the gauge points the way, see tuner_out_of_range_side. A string is measured from
// however far off it is.
tuner_out_of_range :: proc(self: ^Tuner) -> bool {
    if self.string_count > 0 || self.detected_note.cents == -1 do return false

    return self.detected_note.cents != self.target_note.cents && !plays_under_partial(self, self.detected_note)
}

// Which way the played note is from the target while out of range, -1 below and 1 above
tuner_out_of_range_side :: proc(self: ^Tuner) -> f32 {
    return -1 if self.detected_note.cents < self.target_note.cents else 1
}

// A locked note or a string, measured from the target instead of the nearest note
measures_target :: proc(self: ^Tuner) -> bool {
    return self.locked || self.string_count > 0
}

// A note locked on the chromatic ruler, not a string
locked_note :: proc(self: ^Tuner) -> bool {
    return self.locked && self.string_count == 0
}

// The strong detections averaged for the readout, see tuner_cents
tuner_readout :: proc(self: ^Tuner) -> (steady_pitch: PitchInfo) {
    steady_pitch = self.last_good_pitch
    if self.steady_freq != 0 do steady_pitch.detected_freq = self.steady_freq

    steady_pitch.err_cents = tuner_cents(self, steady_pitch.detected_freq, steady_pitch.detected_note)
    return
}

// Cents of a detected note like the readout's. A locked note or a string is measured against the target
// instead of the nearest note. Either way from where the note is tuned to, 0 where the strobe stands still.
tuner_cents :: proc(self: ^Tuner, freq: f32, note: Note) -> f32 {
    if measures_target(self) do return tuner_cents_off(self, freq)

    return cents_deviation(freq, note.frequency) - note_offset_cents(self, note)
}


@(test)
test_tuner :: proc(t: ^testing.T) {
    detection :: proc(freq: f32, strong := true) -> PitchInfo {
        return {
            fresh = true,
            elapsed_s = 0.05, // 20 detections a second
            detected_freq = freq,
            detected_note = freq_to_note(freq),
            is_strong_pitch = strong,
            is_weak_pitch = !strong,
            shortest_period = true,
        }
    }

    E2 :: 82.41
    A2 :: 110.0
    A3 :: 220.0

    // A new note needs to be seen for confirm_s, 0.1 s is 3 detections 0.05 s apart
    tuner := init_tuner(E2, 440, true, 0.1)
    testing.expect(t, !update_tuner(&tuner, detection(A2)))
    testing.expect(t, !update_tuner(&tuner, detection(A2)))
    testing.expect(t, update_tuner(&tuner, detection(A2)))
    testing.expect_value(t, tuner.target_note.name, 'A')

    // At 60 detections a second it takes as long, 7 of them
    tuner = init_tuner(E2, 440, true, 0.1)
    fast := detection(A2)
    fast.elapsed_s = 1.0 / 60
    for _ in 0 ..< 6 do testing.expect(t, !update_tuner(&tuner, fast))

    testing.expect(t, update_tuner(&tuner, fast))

    // A weak detection starts the count again
    tuner = init_tuner(E2, 440, true, 0.1)
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
    tuner = init_tuner(E2, 440, true, 0.1)
    update_tuner(&tuner, medium(A2))
    update_tuner(&tuner, medium(A2 * 2.0 / 3.0))
    update_tuner(&tuner, medium(A2))
    testing.expect(t, !update_tuner(&tuner, medium(freq_at_cents(A2, 1))))
    testing.expect(t, !tuner.active)
    testing.expect(t, !update_tuner(&tuner, medium(freq_at_cents(A2, 10))))
    update_tuner(&tuner, medium(freq_at_cents(A2, 12)))
    testing.expect(t, update_tuner(&tuner, medium(freq_at_cents(A2, 9))))
    testing.expect(t, tuner.active)
    testing.expect_value(t, tuner.target_note.name, 'A')

    // Not a steady run of guesses at three periods, a third of the note
    tuner = init_tuner(E2, 440, true, 0.1)
    for _ in 0 ..< 5 {
        guess := medium(A3 / 3)
        guess.shortest_period = false
        testing.expect(t, !update_tuner(&tuner, guess))
    }
    testing.expect(t, !tuner.active)

    // The strobe follows an octave either way while a note is followed, e.g. a slur down to the note whose
    // octave the strobe was on
    tuner = init_tuner(A2, 440, true, 0)
    update_tuner(&tuner, detection(A2))
    testing.expect(t, update_tuner(&tuner, detection(A2 / 2)))
    testing.expect_value(t, tuner.target_note.octave, 1)
    testing.expect(t, update_tuner(&tuner, detection(A2)))
    testing.expect_value(t, tuner.target_note.octave, 2)

    // The strobe keeps a followed note lit when the detections turn weak, but doesn't light one
    tuner = init_tuner(A2, 440, true, 0)
    update_tuner(&tuner, detection(A2, strong = false), strobe_hears = true)
    testing.expect(t, !tuner.active)
    update_tuner(&tuner, detection(A2))
    update_tuner(&tuner, detection(A2, strong = false), strobe_hears = true)
    testing.expect(t, tuner.active)
    update_tuner(&tuner, detection(A2, strong = false))
    testing.expect(t, !tuner.active)

    // A locked note stays, its octave too. Another note is out of range, the gauge points down to it.
    tuner = init_tuner(E2, 440, false, 0)
    update_tuner(&tuner, detection(E2))
    toggle_note_lock(&tuner)
    testing.expect(t, !tuner_out_of_range(&tuner))
    update_tuner(&tuner, detection(E2 / 2))
    testing.expect_value(t, tuner.target_note.octave, 2)
    testing.expect(t, tuner_out_of_range(&tuner))
    testing.expect_value(t, tuner_out_of_range_side(&tuner), -1)
    update_tuner(&tuner, detection(A3))
    testing.expect_value(t, tuner.target_note.name, 'E')
    testing.expect_value(t, tuner_out_of_range_side(&tuner), 1)

    // Its readout doesn't follow a stray detection of another note
    update_tuner(&tuner, detection(E2))
    update_tuner(&tuner, detection(2 * E2))
    steady := tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents) < 0.1) // E2 is 82.407 Hz

    // Unlocking goes back to the detected note
    update_tuner(&tuner, detection(A3))
    testing.expect(t, toggle_note_lock(&tuner))
    testing.expect_value(t, tuner.target_note.name, 'A')

    // Stepping locks and moves by semitones
    testing.expect(t, step_target_note(&tuner, -2))
    testing.expect(t, tuner.locked)
    testing.expect_value(t, tuner.target_note.name, 'G')

    // The readout averages small wobbles, a bigger change jumps straight there
    tuner = init_tuner(A2, 440, true, 0)
    update_tuner(&tuner, detection(A2))
    update_tuner(&tuner, detection(freq_at_cents(A2, 2)))
    steady = tuner_readout(&tuner)
    testing.expect(t, steady.err_cents > 0.3 && steady.err_cents < 0.5)
    update_tuner(&tuner, detection(freq_at_cents(A2, 20)))
    steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents - 20) < 0.01)

    // A note tuned 10 cents flat: the strobe is tuned there and the readout counts from there
    tuner = init_tuner(A2, 440, true, 0)
    a2_index, _ := note_index(tuner.target_note)
    tuner.offsets_cents[a2_index] = -10
    testing.expect(t, abs(tuner_target_freq(&tuner) - freq_at_cents(A2, -10)) < 0.001)
    update_tuner(&tuner, detection(freq_at_cents(A2, -10)))
    steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents) < 0.01)

    // The octave isn't tuned flat, the strobe moves there untouched
    testing.expect(t, update_tuner(&tuner, detection(A3)))
    testing.expect(t, tuner_target_freq(&tuner) == tuner.target_note.frequency)

    // A guitar in standard tuning, E2 A2 D3 G3 B3 E4 in semitones from A4
    guitar := []int{-29, -24, -19, -14, -10, -5}
    tuner = init_tuner(A3, 440, true, 0)
    testing.expect(t, set_tuner_strings(&tuner, guitar))
    testing.expect_value(t, tuner.string_index, 3)
    testing.expect_value(t, tuner.target_note.name, 'G')

    // From the low E up past halfway to A it stays on E, until A is more than a semitone closer
    update_tuner(&tuner, detection(E2))
    testing.expect_value(t, tuner.string_index, 0)
    update_tuner(&tuner, detection(97.999)) // G2, 3 semitones up and 2 below A
    testing.expect_value(t, tuner.string_index, 0)
    testing.expect(t, !tuner_out_of_range(&tuner))
    steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents - 300) < 0.1)
    update_tuner(&tuner, detection(103.83)) // G#2
    testing.expect_value(t, tuner.string_index, 1)

    // The low E ringing an octave high is still the low E, read from that octave
    update_tuner(&tuner, detection(E2))
    update_tuner(&tuner, detection(2 * E2))
    testing.expect_value(t, tuner.string_index, 0)
    steady = tuner_readout(&tuner)
    testing.expect(t, abs(steady.err_cents) < 0.1)

    // Another string's note isn't measured against the target string while it's held long enough to be the
    // target, then against its own string
    held := init_tuner(A3, 440, true, 0.1)
    set_tuner_strings(&held, guitar)
    for _ in 0 ..< 3 do update_tuner(&held, detection(196.0)) // G3, the target

    update_tuner(&held, detection(E2))
    testing.expect_value(t, held.string_index, 3)
    steady = tuner_readout(&held)
    testing.expect(t, abs(steady.err_cents) < 0.1)
    update_tuner(&held, detection(E2))
    update_tuner(&held, detection(E2))
    testing.expect_value(t, held.string_index, 0)
    steady = tuner_readout(&held)
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

    // A bass's fundamental dies down under its 2nd harmonic, the strobe moves up to it. The pitch detection
    // still reads the fundamental, it stays, and it's not another note out of range. A pluck goes back down.
    {
        E1 :: 41.2
        bass := init_tuner(E1, 440, true, 0)
        update_tuner(&bass, detection(E1))

        strobe := init_phase_comparator(E1, {1, 2, 4}, .HARMONIC)
        defer destroy_phase_comparator(strobe)

        set_phase_comparator_freq(strobe, E1, 440, 0.01, 2, .HARMONIC)
        snrs := [?]f32{40, 90, 60}
        for &band, index in strobe.bands {
            band.in_range = true
            band.rate_time_s = 1
            band.snr_db = snrs[index]
        }
        track, ready := strobe_readout_track(strobe, -1)
        testing.expect(t, follow_readout_partial(&bass, strobe, track, ready, false))
        testing.expect_value(t, bass.target_note.octave, 2)

        update_tuner(&bass, detection(E1))
        testing.expect_value(t, bass.target_note.octave, 2)
        testing.expect(t, !tuner_out_of_range(&bass))

        // Retuned, the partial is the 1× track and the loudest. The tracks start over there, their first level
        // is no pluck.
        set_phase_comparator_freq(strobe, 2 * E1, 440, 0.01, 2, .HARMONIC)
        for &band in strobe.bands {
            band.in_range = true
            band.snr_db = 90 if band.interval == 1 else 50
        }
        strobe.bands[0].onset = true
        testing.expect(t, !follow_readout_partial(&bass, strobe, 0, false, false))
        testing.expect(t, follow_readout_partial(&bass, strobe, 0, false, true))
        testing.expect_value(t, bass.target_note.octave, 1)

        // Dark, a click or a bump loudest in a partial's track doesn't move it
        bass.active = false
        testing.expect(t, !follow_readout_partial(&bass, strobe, 0, true, true))
        testing.expect_value(t, bass.target_note.octave, 1)
    }

    // Not past the highest note, C7's 4th harmonic is C9
    {
        C7 :: 2093.0
        high := init_tuner(C7, 440, true, 0)
        update_tuner(&high, detection(C7))

        strobe := init_phase_comparator(C7, {1, 2, 4}, .HARMONIC)
        defer destroy_phase_comparator(strobe)

        set_phase_comparator_freq(strobe, C7, 440, 0.01, 2, .HARMONIC)
        snrs := [?]f32{40, 50, 90}
        for &band, index in strobe.bands {
            band.in_range = true
            band.rate_time_s = 1
            band.snr_db = snrs[index]
        }
        track, ready := strobe_readout_track(strobe, -1)
        testing.expect_value(t, track, 2)
        testing.expect(t, !follow_readout_partial(&high, strobe, track, ready, false))
        testing.expect_value(t, high.target_note.octave, 7)
    }

    // A seven string's high E is a string too
    seven_string := []int{-34, -29, -24, -19, -14, -10, -5}
    set_tuner_strings(&tuner, seven_string)
    testing.expect_value(t, tuner.string_count, 7)
    step_target_note(&tuner, 10)
    testing.expect_value(t, tuner.target_note.cents, -500)
}
