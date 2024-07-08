package bench

import "core:time"
import "core:fmt"
import "core:math"


run_perf :: proc (fn: proc (), iterations: int, name: string) {
    stopwatch := time.Stopwatch{}
    time.stopwatch_start(&stopwatch)

    // do the work here
    for i in 0..<iterations do fn()

    time.stopwatch_stop(&stopwatch)
    duration := time.stopwatch_duration(stopwatch)
    µs := time.duration_microseconds(duration)
    fmt.printf("%s  %.2v µs\n", name, µs / f64(iterations))
}

main :: proc() {

    ITERATIONS :: 1000000


    // res := math.trunc(f64(128.128))
    // fmt.println(res)
    // res := math.floor(f64(128.128))
    // fmt.println(res)
    // num, frac := math.modf(f64(128.128))
    // fmt.println(num, frac)


    floor := proc () {
        res := math.floor(f64(128.128))
    }
    run_perf(floor, ITERATIONS, "math.floor(num)")


    modf := proc () {
        num, frac := math.modf(f64(128.128))
    }
    run_perf(modf, ITERATIONS, "math.modf(num)")

    trun := proc () {
        res := math.trunc(f64(128.128))
    }
    run_perf(trun, ITERATIONS, "math.trunc(num)")



    trunc_plus := proc () {
        res := math.trunc(f64(128.128)) + 1
    }
    run_perf(trunc_plus, ITERATIONS, "math.trunc(num) + 1")

    ceil := proc () {
        res := math.trunc(f64(128.128)) + 1
    }
    run_perf(ceil, ITERATIONS, "math.ceil(num)")

}
