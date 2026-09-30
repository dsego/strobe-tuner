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


blackman_window :: proc(index: f32, size: f32) -> f32 {
    a0: f32 = 0.42
    a1: f32 = 0.5
    a2: f32 = 0.08

    angle: f32 = math.TAU * index / (size - 1.0)
    return a0 - a1 * math.cos(angle) + a2 * math.cos(2.0 * angle)
}
