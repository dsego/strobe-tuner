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

import "core:math"
import "core:testing"


@(test)
test_noise_floor :: proc(t: ^testing.T) {
    DT :: 0.05
    floor := init_noise_floor()

    // Learns the background
    for _ in 0 ..< 100 do update_noise_floor(&floor, 0.001, DT)

    testing.expectf(t, abs(floor.level - 0.001) < 1e-5, "background, got %v", floor.level)

    // A loud note stands out and barely moves it, only the slow creep
    snr: f32
    for _ in 0 ..< 20 do snr = update_noise_floor(&floor, 0.1, DT)

    testing.expectf(t, snr > 35, "note SNR, got %v dB", snr)
    rise_db := 20 * math.log10(floor.level / 0.001)
    testing.expectf(t, abs(rise_db - NOISE_FLOOR_RISE_DB_PER_S * 20 * DT) < 0.01, "rise, got %v dB", rise_db)

    // Back down after the note
    for _ in 0 ..< 200 do update_noise_floor(&floor, 0.001, DT)

    testing.expectf(t, abs(floor.level - 0.001) < 1e-5, "after the note, got %v", floor.level)

    // A clear pitch held for minutes doesn't move it at all
    for _ in 0 ..< 6000 do snr = update_noise_floor(&floor, 0.1, DT, is_tonal = true)

    testing.expectf(t, abs(floor.level - 0.001) < 1e-5, "held note, got %v", floor.level)
    testing.expectf(t, snr > 39, "held note SNR, got %v dB", snr)

    // Nor one barely over it, a weak partial's band, it would rise to the partial and stay
    for _ in 0 ..< 6000 do snr = update_noise_floor(&floor, 0.002, DT, is_tonal = true)

    testing.expectf(t, abs(floor.level - 0.001) < 1e-5, "weak partial, got %v", floor.level)

    // A held note unclear for a moment now and then, like a voice, stays a note
    for step in 0 ..< 6000 do update_noise_floor(&floor, 0.002, DT, is_tonal = step % 8 != 0)

    testing.expectf(t, abs(floor.level - 0.001) < 1e-5, "unclear moments, got %v", floor.level)

    // Once it stops, the floor learns the room again
    for _ in 0 ..< 200 do update_noise_floor(&floor, 0.003, DT)

    testing.expectf(t, abs(floor.level - 0.003) < 1e-4, "after the note, got %v", floor.level)
}

@(test)
test_noise_floor_warmup_on_a_note :: proc(t: ^testing.T) {
    DT :: 0.05

    // Started while a note rings, it stands out and the floor waits for the background. The attack isn't a
    // clear pitch yet.
    floor := init_noise_floor()
    snr: f32
    update_noise_floor(&floor, 0.2, DT)
    for _ in 0 ..< 40 do snr = update_noise_floor(&floor, 0.1, DT, is_tonal = true)

    testing.expectf(t, snr >= NOISE_FLOOR_UNKNOWN_SNR_DB, "note SNR, got %v dB", snr)
    for _ in 0 ..< 100 do update_noise_floor(&floor, 0.001, DT)

    testing.expectf(t, abs(floor.level - 0.001) < 1e-5, "background, got %v", floor.level)

    // A tone that never stops still isn't the background
    floor = init_noise_floor()
    for _ in 0 ..< 300 do snr = update_noise_floor(&floor, 0.01, DT, is_tonal = true)

    testing.expectf(t, floor.level == 0, "steady tone, got %v", floor.level)
    testing.expectf(t, snr >= NOISE_FLOOR_UNKNOWN_SNR_DB, "steady tone SNR, got %v dB", snr)
}
