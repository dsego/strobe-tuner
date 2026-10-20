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
    steady_s:       f32, // of that, held within STEADY_RUN_CENTS of run_freq, -1 for no run
    run_freq:       f32, // the first detection of the steady run

    confirm_s:      f32, // seen this long in a row before switching, the last one strong or the run steady
}

// How long a new note is detected in a row before the strobe switches to it, the last detection strong or
// the run steady. At 0 a note under hum flickers.
NOTE_SWITCH_S :: 0.05

// Detections of the same note this close to the first of them are a steady pitch, see recognize_note
STEADY_RUN_CENTS :: 5

// Whether the optional note is this note, by its cents from A4
holds_note :: proc(optional: Maybe(Note), note: Note) -> bool {
    held, ok := optional.?
    return ok && held.cents == note.cents
}

// Takes the latest detection. strong is whether it counts for the readout and the switch, confirmed whether
// its note was seen for confirm_s in a row.
//
// Medium clarity detections count too, a short pluck may only be strong briefly, but they're only strong
// once they hold steady for as long, e.g. another string ringing along muddies the wave. A stray one in
// between, like the pitch detection's guess at a multiple of the period, breaks the run. Noise doesn't
// hold a note to a few cents.
recognize_note :: proc(self: ^NoteRecognition, pitch: PitchInfo) -> (strong, confirmed: bool) {
    if pitch.fresh do time_detection(self, pitch)

    seen := holds_note(self.candidate_note, pitch.detected_note)
    confirmed = seen && self.candidate_s >= self.confirm_s

    steady := seen && self.steady_s >= 0 && self.steady_s >= self.confirm_s
    strong = pitch.is_strong_pitch || (!pitch.is_weak_pitch && steady)
    return
}

// Times consecutive detections of the same note, and how long they held steady. Only for new measurements.
time_detection :: proc(self: ^NoteRecognition, pitch: PitchInfo) {
    switch {
    case pitch.is_weak_pitch:
        self.candidate_note = nil
    case !holds_note(self.candidate_note, pitch.detected_note):
        self.candidate_note = pitch.detected_note
        self.candidate_s = 0
        self.steady_s = 0
        self.run_freq = pitch.detected_freq
    case:
        self.candidate_s += pitch.elapsed_s

        holds_steady := self.steady_s >= 0 && abs(cents_deviation(pitch.detected_freq, self.run_freq)) <= STEADY_RUN_CENTS
        if holds_steady {
            self.steady_s += pitch.elapsed_s
        } else {
            self.steady_s = 0
            self.run_freq = pitch.detected_freq
        }
    }

    // A guess at a multiple of the period isn't a steady pitch however close it holds, the wave can repeat
    // better over a few periods for a moment
    if !pitch.shortest_period do self.steady_s = -1
}
