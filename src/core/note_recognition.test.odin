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


// The tests' detections, like the pitch detection's 20 a second, strong or weak
test_detection :: proc(freq: f32, strong := true) -> PitchInfo {
    return {
        fresh = true,
        elapsed_s = 0.05,
        detected_freq = freq,
        detected_note = freq_to_note(freq),
        is_strong_pitch = strong,
        is_weak_pitch = !strong,
        shortest_period = true,
    }
}

// A medium clarity detection, neither strong nor weak
test_medium_detection :: proc(freq: f32) -> PitchInfo {
    pitch := test_detection(freq, strong = false)
    pitch.is_weak_pitch = false
    return pitch
}

E2_HZ :: 82.41
A2_HZ :: 110.0
A3_HZ :: 220.0

// A new note needs to be seen for confirm_s in a row, however often it's detected
@(test)
test_recognition_confirms_note :: proc(t: ^testing.T) {
    // 0.1 s is 3 detections 0.05 s apart
    recognition := NoteRecognition {
        confirm_s = 0.1,
    }
    _, confirmed := recognize_note(&recognition, test_detection(A2_HZ))
    testing.expect(t, !confirmed)
    _, confirmed = recognize_note(&recognition, test_detection(A2_HZ))
    testing.expect(t, !confirmed)
    _, confirmed = recognize_note(&recognition, test_detection(A2_HZ))
    testing.expect(t, confirmed)

    // At 60 detections a second it takes as long, 7 of them
    recognition = {
        confirm_s = 0.1,
    }
    fast := test_detection(A2_HZ)
    fast.elapsed_s = 1.0 / 60
    for _ in 0 ..< 6 {
        _, confirmed = recognize_note(&recognition, fast)
        testing.expect(t, !confirmed)
    }
    _, confirmed = recognize_note(&recognition, fast)
    testing.expect(t, confirmed)

    // A weak detection starts the count again
    recognition = {
        confirm_s = 0.1,
    }
    recognize_note(&recognition, test_detection(A2_HZ))
    recognize_note(&recognition, test_detection(A2_HZ))
    recognize_note(&recognition, test_detection(A2_HZ, strong = false))
    _, confirmed = recognize_note(&recognition, test_detection(A2_HZ))
    testing.expect(t, !confirmed)
}

// Medium clarity detections are strong once they've held steady as long, a stray guess in between or
// wandering by more than a few cents starts the run again
@(test)
test_recognition_steady_run :: proc(t: ^testing.T) {
    recognition := NoteRecognition {
        confirm_s = 0.1,
    }
    recognize_note(&recognition, test_medium_detection(A2_HZ))
    recognize_note(&recognition, test_medium_detection(A2_HZ * 2.0 / 3.0))
    recognize_note(&recognition, test_medium_detection(A2_HZ))
    strong, _ := recognize_note(&recognition, test_medium_detection(freq_at_cents(A2_HZ, 1)))
    testing.expect(t, !strong)

    // Seen long enough but wandered off the run
    confirmed: bool
    strong, confirmed = recognize_note(&recognition, test_medium_detection(freq_at_cents(A2_HZ, 10)))
    testing.expect(t, confirmed && !strong)
    recognize_note(&recognition, test_medium_detection(freq_at_cents(A2_HZ, 12)))
    strong, confirmed = recognize_note(&recognition, test_medium_detection(freq_at_cents(A2_HZ, 9)))
    testing.expect(t, strong && confirmed)

    // Not a steady run of guesses at three periods, a third of the note
    recognition = {
        confirm_s = 0.1,
    }
    for _ in 0 ..< 5 {
        guess := test_medium_detection(A3_HZ / 3)
        guess.shortest_period = false
        strong, _ = recognize_note(&recognition, guess)
        testing.expect(t, !strong)
    }
}
