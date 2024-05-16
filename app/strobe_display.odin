package app

import rl "vendor:raylib"

strobe_samples: [STROBE_COUNT*SAMPLE_SIZE]f32


draw_strobes :: proc(
    target_interval: f64,
) {

    frame_count, drift := read_samples(
        rb_ptr=&strobe_ringbuffer,
        samples=strobe_samples[:],
        target_interval=target_interval,
    )

    width :f32 = 800

    dx := width / f32(target_interval-1)
    drift_adj := f32(drift) * dx


    for i in 0..<STROBE_COUNT {

        points: [SAMPLE_SIZE]rl.Vector2
        x := width + 50 + drift_adj
        // x := 50.0 - drift_adj
        y := 200 + 110 * i32(i)

        for j in 0..<frame_count {
            // note that y is flipped (negative)
            dy := 100.0 / 2.0 - strobe_samples[i+int(j)] * 400.0
            points[j] = { x, f32(y) + dy }
            x -= dx
        }

        rl.DrawRectangleLines(50, y, 800, 100, rl.GRAY)
        rl.DrawLineStrip(raw_data(points[:]), i32(frame_count), rl.PINK)
    }
}
