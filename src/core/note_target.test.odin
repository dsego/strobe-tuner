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
