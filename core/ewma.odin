// Exponentially Weighted Moving Average (https://github.com/jonnieZG/EWMA)
package core

EwmaState :: struct {
    alpha:       f32,
    output:      f32,
    has_initial: bool,
}

init_ewma :: proc(alpha: f32) -> EwmaState {
    self := EwmaState{}
    self.alpha = alpha
    self.has_initial = false
    return self
}

reset_ewma :: proc(self: ^EwmaState) {
    self.has_initial = false
}

ewma_filter :: proc(self: ^EwmaState, reading: f32) -> f32 {
    if self.has_initial {
        self.output += self.alpha * (reading - self.output)
    } else {
        self.output = reading
        self.has_initial = true
    }
    return self.output
}
