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


hamming_window :: proc(k: f32, size: f32) -> f32 {
    n := size - 1.0
    return 0.54 - 0.46 * math.cos((math.TAU * k) / n)
}

hann_window :: proc(k: f32, size: f32) -> f32 {
    n := size - 1.0
    return 0.5 - 0.5 * math.cos((math.TAU * k) / n)
}


blackmann_window :: proc(k: f32, size: f32) -> f32 {
    a0: f32 = 0.42
    a1: f32 = 0.5
    a2: f32 = 0.08

    l: f32 = math.TAU * k / (size - 1.0)
    return a0 - a1 * math.cos(l) + a2 * math.cos(2.0 * l)
}


// https://www.recordingblogs.com/wiki/flat-top-window
flattop_window :: proc(k: f32, size: f32) -> f32 {
    x := k / (size - 1)
    a0 :: 0.21557895
    a1 :: 0.41663158
    a2 :: 0.277263158
    a3 :: 0.083578947
    a4 :: 0.006947368

    w :=
        a0 -
        a1 * math.cos(2 * math.PI * x) +
        a2 * math.cos(4 * math.PI * x) -
        a3 * math.cos(6 * math.PI * x) +
        a4 * math.cos(8 * math.PI * x)

    return w
}


// Symmetric Blackmann-Harris
// https://en.wikipedia.org/wiki/Window_function
// https://github.com/JvanKatwijk/filter-demo/blob/master/blackman-harris.cpp#L18-L24
// https://www.mathworks.com/matlabcentral/mlc-downloads/downloads/submissions/46092/versions/3/previews/coswin.m/index.html?access_key=
blackman_harris :: proc(i: f32, size: f32) -> f32 {
    a0 :: 0.358750287312166
    a1 :: 0.488290107472600
    a2 :: 0.141279712970519
    a3 :: 0.0116798922447150

    x := i / (size - 1.0)
    res :=
        a0 -
        a1 * math.cos(2.0 * math.PI * x) +
        a2 * math.cos(4.0 * math.PI * x) -
        a3 * math.cos(6.0 * math.PI * x)


    return res
}
