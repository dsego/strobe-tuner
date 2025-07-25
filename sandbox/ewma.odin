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



// Exponentially Weighted Moving Average (https://github.com/jonnieZG/EWMA)
package core

EwmaState :: struct {
    alpha:       f32,
    output:      f32,
    has_initial: bool,
}

init_ewma :: proc(alpha: f32) -> EwmaState {
    self := EwmaState{}
    self.alpha = alpha
    self.has_initial = false
    return self
}

reset_ewma :: proc(self: ^EwmaState) {
    self.has_initial = false
}

ewma_filter :: proc(self: ^EwmaState, reading: f32) -> f32 {
    if self.has_initial {
        self.output += self.alpha * (reading - self.output)
    } else {
        self.output = reading
        self.has_initial = true
    }
    return self.output
}
