package app

Trace :: struct {
    data_points_head: int,
    data_points:      []f32,
}

create_trace :: proc (size: int) -> (self: Trace) {
    self.data_points = make([]f32, size)
    return self 
}

destroy_trace :: proc (self: ^Trace) {
    delete(self.data_points)
}

trace_point:: proc (self: ^Trace, value: f32) {
    self.data_points[self.data_points_head] = value
    self.data_points_head = (self.data_points_head + 1) % len(self.data_points)
}


