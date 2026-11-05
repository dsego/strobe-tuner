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

// Whether the pitch detections hold a note long enough to switch to it.
//
// A new note has to be detected for a moment in a row, otherwise a single noisy detection of a decaying note
// resets the strobe. See NoteTarget for what is switched.
NoteRecognition :: struct {
    // the note seen in a row so far, none after a weak detection, and for how long
    candidate_note: Maybe(Note),
    candidate_s:    f32,
    run_s:          f32, // of that, since a guess at a multiple of the period, see recognize_note
    last_freq:      f32, // the candidate's latest detection
    settled:        bool, // the latest within SETTLED_CENTS of the one before, or the first

    confirm_s:      f32, // seen this long in a row before switching, the last one strong or the run long
}

// How long a new note is detected in a row before the strobe switches to it, the last detection strong or
// the run as long, and settled. At 0 a note under hum flickers.
//
// Settled, the pitch has stopped moving. A window across a jump in the wave's phase, a tone generator
// starting its new note from zero, reads past the new pitch for as long as the window: from C#2 in tune
// to 55 cents sharp read 60 to 83 cents for 50 ms, past NOTE_HOLD_CENTS, and switched to D. The
// detections were 9 to 17 cents apart, a string being tuned moves a few cents a detection.
NOTE_SWITCH_S :: 0.05

// The latest detection this close to the one before is settled
SETTLED_CENTS :: 5

// A new note that's a harmonic or an undertone of the confirmed note is seen this long in a row before the
// strobe switches to it, a steady octave beats one that flips. For about 4 detections after a low note stepped
// 55 cents the harmonic stack's bass window spans both and the note's own stack comes apart, its 5th harmonic
// won, held still and was taken for the note: a B0 read D3 and then Bb0. A real octave or a twelfth shows about
// 50 ms later, a fifth isn't a harmonic and doesn't wait. E.g. -define:NOTE_HARMONIC_SWITCH_S=n
NOTE_HARMONIC_SWITCH_S :: #config(NOTE_HARMONIC_SWITCH_S, 0.1)

// Whether the optional note is this note, by its cents from A4
holds_note :: proc(optional: Maybe(Note), note: Note) -> bool {
    held, ok := optional.?
    return ok && held.cents == note.cents
}

// Takes the latest detection. strong is whether it counts for the readout and the switch, confirmed whether
// its note was seen for confirm_s in a row.
//
// Medium clarity detections count too, a short pluck may only be strong briefly, but they're only strong
// once the same note has been seen for as long, e.g. another string ringing along muddies the wave. A stray
// one in between, like the pitch detection's guess at a multiple of the period, starts the run again. They
// had to hold within 5 cents of the run's first as well, but a hum glides about 17 cents in 50 ms at any pitch
// and its low notes lit only when strong. Without it a 3rd octave hum lit 73% of the time instead of 54 with
// the stack, and the recordings, the generated tones and noise alone read the same.
//
// confirmed_hz is the confirmed note's while it's lit, 0 for none, a harmonic of it is confirmed after
// NOTE_HARMONIC_SWITCH_S instead.
recognize_note :: proc(self: ^NoteRecognition, pitch: PitchInfo, confirmed_hz: f32 = 0) -> (strong, confirmed: bool) {
    if pitch.fresh do time_detection(self, pitch)

    confirm_s := self.confirm_s
    if harmonic, _ := harmonic_of_followed(pitch.detected_freq, confirmed_hz); harmonic > 1 {
        confirm_s = max(confirm_s, NOTE_HARMONIC_SWITCH_S)
    }

    seen := holds_note(self.candidate_note, pitch.detected_note)
    confirmed = seen && self.candidate_s >= confirm_s && self.settled

    held := seen && self.run_s >= self.confirm_s
    strong = pitch.is_strong_pitch || (!pitch.is_weak_pitch && held)
    return
}

// Times consecutive detections of the same note. Only for new measurements.
time_detection :: proc(self: ^NoteRecognition, pitch: PitchInfo) {
    switch {
    case pitch.is_weak_pitch:
        self.candidate_note = nil
    case !holds_note(self.candidate_note, pitch.detected_note):
        self.candidate_note = pitch.detected_note
        self.candidate_s = 0
        self.run_s = 0
        self.settled = true
    case:
        self.candidate_s += pitch.elapsed_s
        self.run_s += pitch.elapsed_s
        self.settled = abs(cents_deviation(pitch.detected_freq, self.last_freq)) <= SETTLED_CENTS
    }
    self.last_freq = pitch.detected_freq

    // A guess at a multiple of the period isn't the note however long it holds, the wave can repeat better over
    // a few periods for a moment
    if !pitch.shortest_period do self.run_s = 0
}
