package core

import "core:fmt"
import "core:testing"

import pq "core:container/priority_queue"

// Two-heaps pattern
// Thanks to https://emre.me/coding-patterns/two-heaps/

SlidingMedian :: struct {
    min_heap: pq.Priority_Queue(f32), // store the smaller part of the list in a max_heap
    max_heap: pq.Priority_Queue(f32), // store the larger part of the list in a min_heap
}

min_heap_cmp :: proc(a: f32, b: f32) -> bool {
    return a < b
}

max_heap_cmp :: proc(a: f32, b: f32) -> bool {
    return a > b
}


init_median :: proc(capacity: int) -> SlidingMedian {
    self := SlidingMedian{}
    pq.init(&self.min_heap, min_heap_cmp, pq.default_swap_proc(f32), capacity=capacity)
    pq.init(&self.max_heap, max_heap_cmp, pq.default_swap_proc(f32), capacity=capacity)
    return self
}

destroy_median :: proc(self: ^SlidingMedian) {
    pq.destroy(&self.min_heap)
    pq.destroy(&self.max_heap)
}


median_add :: proc(self: ^SlidingMedian, value: f32) {
    if pq.len(self.max_heap) == 0 || pq.peek(self.max_heap) >= value {
        pq.push(&self.max_heap, value)
    } else {
        pq.push(&self.min_heap, value)
    }

    // balance the heaps
    if pq.len(self.max_heap) > pq.len(self.min_heap) + 1 {
        popped := pq.pop(&self.max_heap)
        pq.push(&self.min_heap, popped)

    } else if pq.len(self.max_heap) < pq.len(self.min_heap) {
        popped := pq.pop(&self.min_heap)
        pq.push(&self.max_heap, popped)
    }
}

find_median :: proc(self: ^SlidingMedian) -> (f32, bool) {
    if pq.len(self.max_heap) < 0 {
        return 0.0, false
    }

    // even number of elements
    if pq.len(self.max_heap) == pq.len(self.min_heap) {
        return (pq.peek(self.max_heap) + pq.peek(self.min_heap)) / 2.0, true
    }

    // the first element in max-heap is the median element
    return pq.peek(self.max_heap), true
}

clear_median :: proc(self: ^SlidingMedian) {
    pq.clear(&self.max_heap)
    pq.clear(&self.min_heap)
}


@(test)
test_sliding_median :: proc(t: ^testing.T) {
    med := init_median(16)
    defer destroy_median(&med)

    median_add(&med, 1)
    median_add(&med, 3)

    m, ok := find_median(&med)

    // [1, 3]
    testing.expect_value(t, m, 2.0)

    median_add(&med, 5)

    m, ok = find_median(&med)

    // [1, 3, 5]
    testing.expect_value(t, m, 3)

    median_add(&med, 4)

    m, ok = find_median(&med)

    // [1, 2, 3, 4]
    testing.expect_value(t, m, 3.5)
}
