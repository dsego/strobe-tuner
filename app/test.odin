package main

import "core:fmt"
import "core:math"
import "core:testing"


is_close :: proc(a: f64, b: f64) -> bool {
    return math.trunc(a * 100) == math.trunc(b * 100)
}


/*

Example run:
   total       rounded  interval
---------------------------------
    109,09       110     110
    218,18       219     109
    327,27       328     109
    436,36       437     109
    545,45       546     109
    654,54       655     109
    763,63       764     109
    872,72       873     109
    981,81       982     109
  1.090,90      1091     109
  1.199,99      1200     109
  1.309,08      1310     110
  1.418,17      1419     109
  1.527,26      1528     109
  1.636,35      1637     109
  1.745,44      1746     109
  1.854,53      1855     109
  1.963,62      1964     109
  2.072,71      2073     109
  2.181,80      2182     109
  2.290,89      2291     109
  2.399,98      2400     109
  2.509,07      2510     110
*/


@test
test_calculate_framerate :: proc(t: ^testing.T) {
    interval := f64(109.09)

    start_frames_real := f64(327.27)
    frames := u32(328)

    frames_real, skip, read := calculate_framerate(400, start_frames_real, interval)
    frames += skip + read

    frames_real, skip, read = calculate_framerate(400, frames_real, interval)
    frames += skip + read

    frames_real, skip, read = calculate_framerate(400, frames_real, interval)
    frames += skip + read

    expected_frames_real := 1_309.08
    testing.expect(t, frames_real == expected_frames_real, fmt.tprintf("Expected frames_real = %v, but got %v instead", expected_frames_real, frames_real))

    expected_frames := u32(1310)
    testing.expect(t, frames == expected_frames, fmt.tprintf("Expected frames = %v, but got %v instead", expected_frames, frames))
}
