#ifndef MICBRIDGE_AUDIO_H
#define MICBRIDGE_AUDIO_H
#include <stdint.h>
#include <stddef.h>
typedef struct MBBuffer MBBuffer;
typedef struct {
    uint64_t queued_frames, written_frames, output_frames;
    uint64_t overflow_frames, latency_dropped_frames, underrun_frames;
} MBBufferStats;
MBBuffer *mb_buffer_create(uint32_t capacity, uint32_t target_frames);
void mb_buffer_destroy(MBBuffer *buffer);
double mb_buffer_now(MBBuffer *buffer);
// Exactly one producer (the main thread) and one consumer (the output callback).
void mb_buffer_write(MBBuffer *buffer, const float *mono, uint32_t count, double now);
void mb_buffer_reset(MBBuffer *buffer);
void mb_buffer_render(MBBuffer *buffer, float *left, float *right,
                      uint32_t count, double output_rate, double now);
MBBufferStats mb_buffer_stats(MBBuffer *buffer);
#endif
