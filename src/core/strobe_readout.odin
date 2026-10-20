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

// The readout follows a track this loud, where its stripes are fully there
READOUT_MIN_SNR_DB :: STROBE_FADE_SNR_DB[1]
READOUT_WEAK_FUNDAMENTAL_DB :: 20 // this far under the loudest partial the fundamental gives way to it
// The track's own reading this far off its partial, as far as the tracks were measured to read, see
// sandbox/accuracy and sandbox/recordings. Further out the readout has none.
READOUT_RANGE_CENTS :: 50
READOUT_SETTLE_S :: 0.05 // the track's fit since the pluck before the readout follows it

// The track the readout follows, the fundamental. A weak or missing fundamental gives way to the loudest
// partial. The partials read a few cents apart, so once its track is ready the readout stays on it and
// keeps its last reading as it fades, until a pluck or another note starts the tracks over. Only a partial
// still ringing this far over it takes the readout on, e.g. a low string's fundamental dies down first.
// Only an octave track reads out, its cents from its partial are the note's. -1 for none.
//
// ready once its track has fitted a little since the pluck, until then the readout is the pitch detection's.
strobe_readout_track :: proc(self: ^StrobeLockIn, current: int) -> (track: int, ready: bool) {
    settled :: proc(band: PhaseBand) -> bool {
        return band.rate_time_s >= READOUT_SETTLE_S
    }

    // A pluck lifts the loudest partial, a faint one's level wobbling isn't one
    loudest, fundamental := readout_candidates(self)
    plucked := loudest >= 0 && self.bands[loudest].onset

    // Held, unless a pluck brings another track to pick or the held one fades under a ringing partial
    held := current >= 0 && current < len(self.bands) && measures_band(self, current) && settled(self.bands[current])
    if held && !plucked {
        faded := loudest >= 0 && self.bands[loudest].snr_db - self.bands[current].snr_db >= READOUT_WEAK_FUNDAMENTAL_DB
        if !faded do return current, true

        return loudest, settled(self.bands[loudest])
    }

    if loudest < 0 do return -1, false

    track = loudest
    if fundamental >= 0 && self.bands[loudest].snr_db - self.bands[fundamental].snr_db < READOUT_WEAK_FUNDAMENTAL_DB {
        track = fundamental
    }
    return track, settled(self.bands[track])
}

// The loudest track the readout can follow and the fundamental's, -1 for none
readout_candidates :: proc(self: ^StrobeLockIn) -> (loudest, fundamental: int) {
    loudest, fundamental = -1, -1
    for band, index in self.bands {
        if !measures_band(self, index) || !is_octave_track(band) do continue
        if !hears_note(band, self.band_cents) || band.snr_db < READOUT_MIN_SNR_DB do continue

        if loudest < 0 || band.snr_db > self.bands[loudest].snr_db do loudest = index
        if band.interval == 1 do fundamental = index
    }
    return
}

// The fundamental's or an octave's track, the others' partials are another note, e.g. a fifth
is_octave_track :: proc(band: PhaseBand) -> bool {
    octaves := math.log2(band.interval)
    return band.interval > 0 && abs(octaves - math.round(octaves)) < 0.01
}

// A track hears its note while it drifts less than its window is wide, band_cents, a semitone unless the W
// key narrowed it. Further out it's another note leaking in.
hears_note :: proc(band: PhaseBand, band_cents: int) -> bool {
    return band.in_range && band.drift_cents <= f32(band_cents)
}

// Whether any track's stripes are at least half faded in, the note is still ringing. The background noise
// stays under it.
strobe_shows_note :: proc(self: ^StrobeLockIn) -> bool {
    fade := STROBE_FADE_SNR_DB
    for band in self.bands {
        if hears_note(band, self.band_cents) && band.snr_db >= 0.5 * (fade[0] + fade[1]) do return true
    }
    return false
}
