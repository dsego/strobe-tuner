package app

/*
    The Kalman Filter
    https://www.youtube.com/playlist?list=PLX2gX-ftPVXU3oUFNATxGXY90AULiqnWT
*/

kalman_filter :: proc (
    measurement: f32,
    prev_estimate: f32,
    prev_error_estimate: f32,
    error_measurement: f32, // error in measurement does not change between measurements
) -> (f32, f32) {

    // (1) Calculate the Kalman gain
    //      0 <= KG <= 1
    //      small error in measurement means gain is closer to 1
    gain := prev_error_estimate / (prev_error_estimate + error_measurement)

    // (2) Calculate the new estimate
    estimate := prev_estimate + gain * (measurement - prev_estimate)

    // (3) Calculate the error
    error_estimate := (1.0 - gain) * prev_error_estimate

    return estimate, error_estimate
}
