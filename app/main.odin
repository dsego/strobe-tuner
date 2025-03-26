package app

import "core:fmt"
import "core:mem"


main :: proc() {
    // Tracking allocator that warns you if your program is leaking memory
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer mem.tracking_allocator_destroy(&track)
        context.allocator = mem.tracking_allocator(&track)
        defer {
            for _, leak in track.allocation_map {
                fmt.printf("%v leaked %m\n", leak.location, leak.size)
            }
            for bad_free in track.bad_free_array {
                fmt.printf(
                    "%v allocation %p was freed badly\n",
                    bad_free.location,
                    bad_free.memory,
                )
            }
        }
    }

    run_raylib_app()
}
