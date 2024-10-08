/*


44100/4186,009


interval

10,5350944062


sine wave with freq 4186,009, sum should be zero,

generate sine with different phases, take dft and compare phase



I need the "overlap" sample to calculate the DFT correctly!!!!!

*/

package sweep

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

main :: proc () {

    buffer: [100]f64
    points: [100]rl.Vector2
    samplerate := 44100.0
    freq_hz := 4186.009
    interval := samplerate / freq_hz

    sample_count := int(math.ceil(interval))

    samples := buffer[:sample_count]

    target_phase := 0.5

    generate_sine(freq=freq_hz/samplerate, amp=1.0, phase=target_phase, data=samples)

    dft := run_dft(freq_hz=freq_hz, samples=samples, samplerate=samplerate)

    sin := real(dft)
    cos := imag(dft)
    dft_phase := 0.5 * math.atan2(sin, cos) / math.PI
    mag := magnitude(dft)

    dx := 600.0 / f64(sample_count - 1)
    x := 100.0
    for s, i in samples {
        y := 200.0 - s * 100.0
        points[i] = rl.Vector2{f32(x), f32(y)}
        x += dx
    }

    rl.InitWindow(800, 600, "Sweep")
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rl.DrawLineEx({100, 200}, {700, 200}, 1.0, rl.GRAY)

        for i in 0..<sample_count {
            x := 100.0 + f64(i) * dx
            rl.DrawLineEx({f32(x), 100}, {f32(x), 300}, 1.0, rl.GRAY)
            rl.DrawText(fmt.ctprintf("%v", i), i32(x), 320, 14, rl.GRAY)
        }

        rl.DrawLineStrip(raw_data(points[:]), i32(sample_count), rl.GOLD)

        rl.DrawText(fmt.ctprintf("Target: %.4f, DFT: %.4f", target_phase, dft_phase), 100, 400, 20, rl.PINK)
    }
}


generate_sine :: proc(freq: f64, amp: f64, phase: f64, data: []f64) {
    for d, i in data {
        time := f64(i)
        data[i] = amp * math.sin(time * freq * 2.0 * math.PI + phase * 2.0 * math.PI)
    }
}


// A brute force implementation that executes the Fourier formula directly
run_dft :: proc(freq_hz: f64, samples: []f64, samplerate: f64) -> (dft: complex128) {
    freq_bin := freq_hz / samplerate
    phase_angle:f64 = 2.0 * math.PI

    for sample, i in samples {
        time := phase_angle * f64(i)

        // Fourier formula: cos(2πft) - i×sin(2πft)
        ft := freq_bin * time
        re := sample * math.cos(ft)
        im := sample * math.sin(ft)

        dft += complex(re, im)
    }
    return
}

// Complex number magnitude
magnitude :: proc (cpx: complex128) -> f64 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}
