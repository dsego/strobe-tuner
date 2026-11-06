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
package app

import "core:slice"
import "core:testing"


// A custom preset's rows are its strings in their order with no capo, its offsets by note like chromatic's
@(test)
test_custom_strings :: proc(t: ^testing.T) {
    config := config_defaults
    config.preset = 1
    config.preset_instruments[1] = .CUSTOM
    config.preset_capos[1] = 2
    testing.expect_value(t, len(tuning_strings(&config)), 0)

    // D3, A3 and B♭3 counted from A0, the B♭ a little sharp, then B♭3 again
    rows := [?]int{29, 36, 37, 37}
    for note, row in rows do config.note_offset_notes[1][row] = note
    config.note_offset_counts[1] = len(rows)
    config.note_offset_cents[1][2] = 3
    config.note_offset_cents[1][3] = -2
    testing.expect(t, slice.equal(tuning_strings(&config), []int{-19, -12, -11, -11}))

    // A note in two rows is tuned by the first
    offsets := active_note_offsets(&config)
    testing.expect_value(t, offsets[37], 3)

    // There's no built-in custom instrument, it has no notes
    config.preset = nil
    config.instrument = .CUSTOM
    testing.expect_value(t, len(tuning_strings(&config)), 0)
}

// The menu on top lists the built-in instruments without custom, then the presets
@(test)
test_instrument_and_preset_options :: proc(t: ^testing.T) {
    config := config_defaults
    config.preset_instruments[1] = .CUSTOM
    options := instrument_and_preset_options(&config)
    testing.expect_value(t, len(options), BUILT_IN_INSTRUMENTS + PRESET_SLOTS)
    testing.expect_value(t, options[BUILT_IN_INSTRUMENTS - 1].label, "Baritone ukulele")
    testing.expect_value(t, options[BUILT_IN_INSTRUMENTS].label, "Preset 1 - Empty")
    testing.expect_value(t, options[BUILT_IN_INSTRUMENTS + 1].label, "Preset 2 - CUSTOM")
}
