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


package core

import "core:math"

// The tracks turned by the lamp, see strobe_lamp_bands: each one's phase on the screen at the previous
// frame, at this reference and this sample, and the phase it turned to. A freq_hz of 0 starts them over.
StrobeLamp :: struct {
    phases:        [MAX_BANDS]f64,
    freq_hz:       f64,
    clock:         i64,
    scaled_phases: [MAX_BANDS]f32,
}

// The lock-in's tracks turned by the lamp instead, the strobe the other way: a DFT bin of the scope's
// screen from above (scope_partials) for each track's partial, instead of its DFT on the samples. They turn
// like the tracks: by the bin's phase advance, rescaled so all notes spin at the same rate per cent, times
// the track's speed, and stand still at its partial's target, offset included. The screen's quirks show, a
// pluck or a weak partial can make the stripes jump. A copy for drawing until the next frame, its DFTs are
// the lock-in's own. The phases between frames are kept in self.
strobe_lamp_bands :: proc(
    self: ^StrobeLamp,
    scope: ^Scope,
    lock_in_bands: []PhaseBand,
    signal_snr_db: f32,
) -> (
    bands: []PhaseBand,
) {
    bands = make([]PhaseBand, len(lock_in_bands), context.temp_allocator)
    copy(bands, lock_in_bands)
    if scope.freq_hz <= 0 do return

    // The bin nearest each track's partial, its target a little off for an offset in cents
    periods := make([]int, len(bands), context.temp_allocator)
    for band, index in bands {
        periods[index] = max(int(math.round(SCOPE_PERIODS * f64(band.freq_hz) / scope.freq_hz)), 1)
    }
    partials := make([]ScopePartial, len(bands), context.temp_allocator)
    noise := max(scope_partials(scope, periods, partials), 1e-9)

    // A new reference starts with a dark screen, the phases before it are arbitrary. So are they after a while
    // without the lamp's tracks, another display showed and the screen went dark, see skip_scope.
    elapsed := f64(scope.sample_clock - self.clock) / f64(scope.sample_rate)
    has_phase := self.freq_hz == scope.freq_hz && elapsed <= STROBE_STALE_S
    self.freq_hz = scope.freq_hz
    self.clock = scope.sample_clock

    for &band, index in bands {
        partial := partials[index]
        phase_before := self.phases[index]
        self.phases[index] = partial.phase
        if !band.in_range do continue

        // The screen remembers a note after it fades into the room's noise, the signal's SNR fades it out
        level := max(partial.level, 1e-9)
        band.snr_db = min(f32(20 * math.log10(level / noise)), signal_snr_db)

        // As run_phase_detection does it, the shortest way from the previous frame's phase. On the target
        // the partial drifts on the screen by how far it is from the bin.
        bin_hz := f64(periods[index]) / SCOPE_PERIODS * scope.freq_hz
        target_advance := math.TAU * (f64(band.freq_hz) - bin_hz) * elapsed
        advance := wrap_phase(partial.phase - phase_before - target_advance) if has_phase else 0

        rescale := strobe_rescale(band.freq_hz)
        band.phase_diff = f32(advance * rescale)
        turn_strobe(&self.scaled_phases[index], band.phase_diff, band.speed)
        band.scaled_phase = self.scaled_phases[index]
    }
    return
}
