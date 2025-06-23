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


package app

Trace :: struct {
    data_points_head: int,
    data_points:      []f32,
}

create_trace :: proc (size: int) -> (self: Trace) {
    self.data_points = make([]f32, size)
    return self 
}

destroy_trace :: proc (self: ^Trace) {
    delete(self.data_points)
}

trace_point:: proc (self: ^Trace, value: f32) {
    self.data_points[self.data_points_head] = value
    self.data_points_head = (self.data_points_head + 1) % len(self.data_points)
}


