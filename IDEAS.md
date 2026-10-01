# Ideas

Features and code changes that aren't planned yet. Nothing here is decided.

## Steady rotation far from a locked note

Behind a flag, in locked mode only. Tuning up a new string with the note locked to low E, the string
starts far below the note and wobbles on the way up. The strobe has nothing steady to show there, and
it's hard to tell how far there is to go.

Far out, show a simulated rotation at a steady rate in the right direction, and blend it into the
real strobe as the string comes within about 50 to 100 cents.

- The band's window is 25 cents a bin, so the lock-in hears the string about 20 dB down at 50 cents
  and not at all past 75. The direction and distance out there have to come from the pitch detection,
  like the arrows next to the note.
- The blend could follow the band's SNR, which rises as the string comes into the window.
- A constant rate reads as "keep going", a rate that follows the distance would jump around with the
  wobble it is meant to hide.
- The handover is the hard part, the simulated stripes and the real ones have to meet without a
  jump in phase or speed. May not be worth it if it can't be made seamless.

## In-tune cues

One setting, all optional.

- Green note name within the tolerance, the strobe itself stays unchanged.
- A short beep once the note holds in the window for about 300 ms. The detection ignores the input
  briefly so the mic doesn't read the beep.
- A haptic tap as a quieter alternative to the beep.

## Audible beating mode

A tone or click through headphones whose rate follows the pitch error and stops when in tune. Also the
path to real VoiceOver support later.

## Piano stretch tuning

## Temperaments and offset presets

The note offsets are set by hand per exact note. A temperament is 12 offsets and a root key, repeated in
every octave, and would be picked in the settings.

## A dot on the offset notes in the ruler

The target note shows its offset under the letter. The neighbours in the ruler don't show which of them
are tuned off pitch in the slot that's on.

## Recent instruments

The instrument sheet remembers the last 3 or 4 setups tuned, each an instrument, its tuning and capo, or
chromatic with its transpose. They show as chips at the top of the sheet with the same labels as the
corner, e.g. UKULELE, G DROP D, G OPEN G · 2. Tapping one switches to it and closes the sheet, nothing to
save, name or delete. Saved presets cover what it can't, two guitars in the same tuning.
