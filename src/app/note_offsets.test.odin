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

import "core:testing"


// A step every few points, the catch at 0¢ from either side, held at the ends
@(test)
test_offset_slide_cents :: proc(t: ^testing.T) {
    STEP :: 4
    HALF_CATCH :: OFFSET_SLIDE_CATCH / 2
    slide :: proc(from, points: f32) -> f32 {
        return offset_slide_cents(from, points, STEP)
    }

    testing.expect_value(t, slide(3, 0), 3)
    testing.expect_value(t, slide(3, 2 * STEP), 4)
    testing.expect_value(t, slide(3, -2 * STEP), 2)

    // Out of the catch a step past it, and back into it from either side
    testing.expect_value(t, slide(0, HALF_CATCH - 1), 0)
    testing.expect_value(t, slide(0, HALF_CATCH + STEP), NOTE_OFFSET_STEP_CENTS)
    testing.expect_value(t, slide(0, -HALF_CATCH - STEP), -NOTE_OFFSET_STEP_CENTS)
    testing.expect_value(t, slide(1, -2 * STEP - 1), 0)
    testing.expect_value(t, slide(-1, 2 * STEP + 1), 0)

    testing.expect_value(t, slide(20, 1000), NOTE_OFFSET_MAX_CENTS)
    testing.expect_value(t, slide(-20, -1000), -NOTE_OFFSET_MAX_CENTS)
}
