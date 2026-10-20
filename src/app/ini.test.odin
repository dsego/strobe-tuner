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

import "core:fmt"
import "core:testing"


// What save_config writes reads back the same, and a config from before the names still loads
@(test)
test_read_value :: proc(t: ^testing.T) {
    read :: proc(field: ^$T, text: string) {
        read_value(field, type_info_of(T), text)
    }

    // The values the names stand for, the rows of the offsets each in its own row however long they are
    config := config_defaults
    read(&config.preset_instruments, "[3, 1, 0, 9]")
    testing.expect_value(t, config.preset_instruments, [PRESET_SLOTS]Instrument{.BASS, .GUITAR, .CHROMATIC, .CHROMATIC})
    read(&config.instrument_capos, "[0, 2, 0, 1]")
    testing.expect_value(t, config.instrument_capos[.GUITAR], 2)
    testing.expect_value(t, config.instrument_capos[.BASS], 1)
    read(&config.note_offset_notes, "[[1, 2], [3]]")
    testing.expect_value(t, config.note_offset_notes[0][1], 2)
    testing.expect_value(t, config.note_offset_notes[0][2], 0)
    testing.expect_value(t, config.note_offset_notes[1][0], 3)

    // A preset's number or none, a config from before none reads -1, see selected_preset
    read(&config.preset, "2")
    testing.expect_value(t, config.preset, 2)
    read(&config.preset, "nil")
    testing.expect_value(t, config.preset, nil)
    read(&config.preset, "-1")
    testing.expect_value(t, selected_preset(&config), nil)

    // Written as save_config does and read back
    saved := config_defaults
    saved.preset_instruments = {.UKULELE, .BASS, .SEVEN_STRING, .GUITAR}
    saved.instrument_tunings[.BARITONE_UKULELE] = 3
    saved.note_offset_cents[2] = {-1.5, 2.25, 0, 0, 0, 0, 0, 0, 0, 7}
    saved.strobe_mode = .VERNIER
    saved.preset = 3

    loaded := config_defaults
    read(&loaded.preset_instruments, fmt.tprintf("%v", saved.preset_instruments))
    read(&loaded.instrument_tunings, fmt.tprintf("%v", saved.instrument_tunings))
    read(&loaded.note_offset_cents, fmt.tprintf("%v", saved.note_offset_cents))
    read(&loaded.strobe_mode, fmt.tprintf("%v", saved.strobe_mode))
    read(&loaded.preset, fmt.tprintf("%v", saved.preset))
    testing.expect_value(t, loaded.preset_instruments, saved.preset_instruments)
    testing.expect_value(t, loaded.instrument_tunings, saved.instrument_tunings)
    testing.expect_value(t, loaded.note_offset_cents, saved.note_offset_cents)
    testing.expect_value(t, loaded.strobe_mode, saved.strobe_mode)
    testing.expect_value(t, loaded.preset, saved.preset)
}
