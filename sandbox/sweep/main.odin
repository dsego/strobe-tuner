package sweep

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

main :: proc () {

    sample_buffer: [100]f64
    win_sample_buffer: [100]f64
    reference_buffer: [100]f64

    samplerate := 44100.0
    freq_hz := 4186.009
    interval := samplerate / freq_hz

    sample_count := int(math.ceil(2 * interval))

    win_samples := win_sample_buffer[:sample_count]
    samples := sample_buffer[:sample_count]
    reference_signal := reference_buffer[:sample_count]


    rl.InitWindow(800, 600, "Sweep")
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})

    orig_phase := 0.0


    for !rl.WindowShouldClose() {

        if rl.IsKeyPressed(rl.KeyboardKey.RIGHT) {
            orig_phase += 0.1
            if 1.0 - orig_phase < 0.000001 do orig_phase -= 1.0
        }
        else if rl.IsKeyPressed(rl.KeyboardKey.LEFT) {
            orig_phase -= 0.1
            if orig_phase < 0.0 do orig_phase += 1.0
        }

        // Reference
        // generate_sine(freq=freq_hz/samplerate, amp=1.0, phase=orig_phase, data=reference_signal)

        // Target
        generate_sine(freq=freq_hz/samplerate, amp=1.0, phase=orig_phase, data=samples)

        // Apply windowing
        for i in 0..<len(samples) {
            // win_samples[i] = blackmann_window(f64(i), f64(len(samples)))
            // win_samples[i] = samples[i] * gaussian_window(f64(i), f64(len(samples)), 4.0)
            // win_samples[i] = samples[i] * flattop_window(f64(i), f64(len(samples)))
            win_samples[i] = samples[i] * blackmann_window(f64(i), f64(len(samples)))
        }

        // ref_dft := run_dft(freq_hz=freq_hz, samples=reference_signal, samplerate=samplerate, interval=interval)
        // ref_phase := dft_phase(ref_dft)


        dft := run_dft(freq_hz=freq_hz, samples=samples, samplerate=samplerate, interval=interval)
        phase := dft_phase(dft)


        win_dft := run_dft(freq_hz=freq_hz, samples=win_samples, samplerate=samplerate, interval=interval)
        win_phase := dft_phase(win_dft)


        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)



        rect := rl.Rectangle{100, 50, 600, 200}

        rl.DrawLineEx({rect.x, rect.y+rect.height/2}, {rect.x + rect.width, rect.y+rect.height/2}, 1.0, rl.GRAY)

        dx := rect.width / f32(len(samples) - 1)

        for i in 0..<sample_count {
            x := rect.x + f32(i) * dx
            rl.DrawLineEx({f32(x), rect.y}, {f32(x), rect.y+rect.height}, 1.0, rl.GRAY)
            rl.DrawText(fmt.ctprintf("%v", i), i32(x), 320, 14, rl.GRAY)
        }
        {
            fraction := interval - math.trunc(interval)
            l := len(samples)
            sample := samples[l-2] + fraction * (samples[l-1] - samples[l-2])
            x := rect.x + f32(interval) * f32(dx)
            y := rect.y - f32(sample) * rect.height

            // rl.DrawRectangleV({f32(x) - 3.5, f32(y) - 3.5}, {7, 7}, rl.GOLD)
        }

        draw_samples(rect, samples, rl.PINK)
        draw_samples(rect, win_samples, rl.GOLD)

        rl.DrawText(
            fmt.ctprintf("Phase: %.6f    %.6f    %.6f", orig_phase, phase, win_phase),
            100,
            400,
            16,
            rl.PINK,
        )

        // rl.DrawText(fmt.ctprintf("Corrected phase: %.4f", phase - ref_phase), 100, 430, 16, rl.PINK)
    }
}


draw_samples :: proc (rect: rl.Rectangle, data: []f64,  color: rl.Color) {
    points: [100]rl.Vector2
    l := len(data)
    dx := rect.width / f32(l - 1)
    x := rect.x
    for d, i in data {
        y := rect.y + 0.5 * rect.height - f32(d) * 0.5 * rect.height
        points[i] = rl.Vector2{x, y}
        x += dx
    }
    rl.DrawLineStrip(raw_data(points[:l]), i32(l), color)
}



generate_sine :: proc(freq: f64, amp: f64, phase: f64, data: []f64) {
    for d, i in data {
        time := f64(i)
        data[i] = amp * math.sin(time * freq * 2.0 * math.PI + phase * 2.0 * math.PI)
    }
}


// A brute force implementation that executes the Fourier formula directly
run_dft :: proc(freq_hz: f64, samples: []f64, samplerate: f64, interval: f64) -> (dft: complex128) {
    freq_bin := freq_hz / samplerate
    l := len(samples)

    for i in 0..< l - 2 {
        time := f64(i)

        // Fourier formula: cos(2πft) - i×sin(2πft)
        re := samples[i] * math.cos(2.0 * math.PI * freq_bin * time)
        im := samples[i] * math.sin(2.0 * math.PI * freq_bin * time)

        dft += complex(re, im)
    }

    // take care of the fractional part
    {
        // fraction := interval - math.floor(interval)
        // sample := samples[l-2] + fraction * (samples[l-1] - samples[l-2])
        // re := sample * math.cos(2.0 * math.PI * freq_bin * interval)
        // im := sample * math.sin(2.0 * math.PI * freq_bin * interval)
        // dft += complex(re, im)
    }

    return
}

dft_phase :: proc (dft: complex128) -> f64 {
    sin := real(dft)
    cos := imag(dft)
    phase := 0.5 * math.atan2(sin, cos) / math.PI

    if phase < 0.0 do phase += 1.0
    if phase >= 1.0 do phase -= 1.0

    return phase
}

// Complex number magnitude
magnitude :: proc (cpx: complex128) -> f64 {
    return math.sqrt(real(cpx) * real(cpx) + imag(cpx) * imag(cpx))
}

blackmann_window :: proc (k: f64, size: f64) -> f64 {
    a0 := 0.42
    a1 := 0.5
    a2 := 0.08

    l:f64 = 2.0 * math.PI * k / (2.0 * size/2 - 1.0)
    return a0 - a1 * math.cos(l) + a2 * math.cos(2.0 * l)
}


// https://ccrma.stanford.edu/~jos/Windows/Windows_2up.pdf
gaussian_window :: proc (k: f64, size: f64, sigma: f64) -> f64 {
    n := k - (size -1) / 2.0
    return math.exp(-n * n / (2.0 * sigma * sigma))
}

// https://www.recordingblogs.com/wiki/flat-top-window
flattop_window :: proc (k: f64, size: f64) -> f64 {
    return (
        0.21557895
        - 0.41663158  * math.cos(2 * math.PI * k / (size - 1))
        + 0.277263158 * math.cos(4 * math.PI * k / (size - 1))
        - 0.083578947 * math.cos(6 * math.PI * k / (size - 1))
        + 0.006947368 * math.cos(8 * math.PI * k / (size - 1))
    )
}

