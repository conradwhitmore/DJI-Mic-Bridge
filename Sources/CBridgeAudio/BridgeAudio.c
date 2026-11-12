#include "BridgeAudio.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>

struct MBBuffer {
    float *samples;
    uint32_t capacity, target;
    _Atomic uint64_t read, write, discard_before, reset_serial;
    _Atomic uint64_t written, output, overflow, latency_dropped, underrun;
    _Atomic double last_write;
    // Consumer-only state; reset requests never mutate the consumer's cursor.
    uint64_t seen_reset;
    double fraction, ticks_to_seconds;
    bool primed, monitoring;
};
MBBuffer *mb_buffer_create(uint32_t capacity, uint32_t target) {
    if (capacity < 16 || target < 2 || target > capacity / 2) return NULL;
    MBBuffer *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->samples = calloc(capacity, sizeof(float));
    if (!b->samples) { free(b); return NULL; }
    b->capacity = capacity; b->target = target;
    atomic_init(&b->read, 0); atomic_init(&b->write, 0);
    atomic_init(&b->discard_before, 0); atomic_init(&b->reset_serial, 0);
    atomic_init(&b->written, 0); atomic_init(&b->output, 0);
    atomic_init(&b->overflow, 0); atomic_init(&b->latency_dropped, 0);
    atomic_init(&b->underrun, 0); atomic_init(&b->last_write, 0);
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    b->ticks_to_seconds = (double)timebase.numer / timebase.denom / 1e9;
    // arm64/x86_64 lock-free atomics only: no hidden locks in the audio callback.
    if (!atomic_is_lock_free(&b->read) || !atomic_is_lock_free(&b->last_write)) {
        mb_buffer_destroy(b); return NULL;
    }
    return b;
}
void mb_buffer_destroy(MBBuffer *b) { if (b) { free(b->samples); free(b); } }
double mb_buffer_now(MBBuffer *b) { return mach_absolute_time() * b->ticks_to_seconds; }
void mb_buffer_write(MBBuffer *b, const float *mono, uint32_t count, double now) {
    if (!b || !mono || !count || !isfinite(now)) return;
    uint64_t w = atomic_load_explicit(&b->write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&b->read, memory_order_acquire);
    uint64_t free_frames = b->capacity - (w - r);
    uint32_t accepted = count < free_frames ? count : (uint32_t)free_frames;
    for (uint32_t i = 0; i < accepted; ++i) {
        float v = mono[i];
        b->samples[(w + i) % b->capacity] = isfinite(v) ? fmaxf(-1, fminf(1, v)) : 0;
    }
    atomic_store_explicit(&b->last_write, now, memory_order_relaxed);
    atomic_store_explicit(&b->write, w + accepted, memory_order_release);
    atomic_fetch_add_explicit(&b->written, accepted, memory_order_relaxed);
    atomic_fetch_add_explicit(&b->overflow, count - accepted, memory_order_relaxed);
}
void mb_buffer_reset(MBBuffer *b) {
    atomic_store_explicit(&b->discard_before, atomic_load_explicit(&b->write, memory_order_acquire), memory_order_relaxed);
    atomic_fetch_add_explicit(&b->reset_serial, 1, memory_order_release);
}
void mb_buffer_render(MBBuffer *b, float *left, float *right, uint32_t count, double rate, double now) {
    if (left) memset(left, 0, count * sizeof(float));
    if (right) memset(right, 0, count * sizeof(float));
    if (!b || !left || !right || !isfinite(rate) || rate < 8000 || rate > 192000) return;
    uint64_t r = atomic_load_explicit(&b->read, memory_order_relaxed);
    uint64_t serial = atomic_load_explicit(&b->reset_serial, memory_order_acquire);
    if (serial != b->seen_reset) {
        uint64_t boundary = atomic_load_explicit(&b->discard_before, memory_order_relaxed);
        if (r < boundary) r = boundary;
        b->seen_reset = serial; b->fraction = 0; b->primed = false; b->monitoring = false;
    }
    uint64_t w = atomic_load_explicit(&b->write, memory_order_acquire);
    double age = now - atomic_load_explicit(&b->last_write, memory_order_relaxed);
    if (!isfinite(now) || age < 0 || age > 0.25) {
        r = w; b->primed = false; b->fraction = 0;
    }
    uint64_t available = w - r;
    if (available > b->capacity / 2) {
        uint64_t drop = available - b->target;
        r += drop; available -= drop; b->fraction = 0;
        atomic_fetch_add_explicit(&b->latency_dropped, drop, memory_order_relaxed);
    }
    if (!b->primed && available >= b->target) {
        b->primed = true;
        b->monitoring = true;
    }
    uint32_t produced = 0;
    if (b->primed) {
        // Small bounded clock correction around 40 ms occupancy (at the standard
        // target). Large backlogs are explicitly dropped, never replayed forever.
        double correction = fmax(-0.001, fmin(0.001, ((double)available - b->target) / 480000.0));
        double step = 48000.0 / rate * (1 + correction);
        for (; produced < count; ++produced) {
            if (w - r < 2) { b->primed = false; b->fraction = 0; r = w; break; }
            float a = b->samples[r % b->capacity], c = b->samples[(r + 1) % b->capacity];
            float sample = a + (c - a) * b->fraction;
            left[produced] = sample; right[produced] = sample;
            b->fraction += step;
            uint64_t advance = (uint64_t)b->fraction;
            if (advance > w - r) advance = w - r;
            r += advance; b->fraction -= advance;
        }
    }
    atomic_store_explicit(&b->read, r, memory_order_release);
    atomic_fetch_add_explicit(&b->output, produced, memory_order_relaxed);
    // Initial buffering and disconnected silence are intentional. Once audio
    // starts, count real starvation until the controller resets on link loss.
    if (b->monitoring)
        atomic_fetch_add_explicit(&b->underrun, count - produced, memory_order_relaxed);
}
MBBufferStats mb_buffer_stats(MBBuffer *b) {
    uint64_t r = atomic_load_explicit(&b->read, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&b->write, memory_order_acquire);
    MBBufferStats s = {w >= r ? w-r : 0,
        atomic_load(&b->written), atomic_load(&b->output), atomic_load(&b->overflow),
        atomic_load(&b->latency_dropped), atomic_load(&b->underrun)};
    return s;
}
