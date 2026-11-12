#include "BridgeAudio.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
static MBBuffer *buffer;
static _Atomic int done;
static void *produce(void *unused) {
    float input[480];
    for (int i = 0; i < 480; ++i) input[i] = sinf(i * 0.1f);
    for (int i = 0; i < 20000; ++i) {
        mb_buffer_write(buffer, input, 480, mb_buffer_now(buffer));
        if (i % 211 == 0) mb_buffer_reset(buffer);
    }
    atomic_store(&done, 1); return NULL;
}
static void *consume(void *unused) {
    float l[512], r[512];
    do {
        mb_buffer_render(buffer, l, r, 512, 44100, mb_buffer_now(buffer));
        for (int i = 0; i < 512; ++i) assert(isfinite(l[i]) && l[i] == r[i] && fabsf(l[i]) <= 1);
    } while (!atomic_load(&done));
    return NULL;
}
int main(void) {
    buffer = mb_buffer_create(24000, 1920); assert(buffer);
    pthread_t producer, consumer;
    pthread_create(&producer, NULL, produce, NULL); pthread_create(&consumer, NULL, consume, NULL);
    pthread_join(producer, NULL); pthread_join(consumer, NULL);
    MBBufferStats stats = mb_buffer_stats(buffer); assert(stats.queued_frames <= 24000);
    mb_buffer_destroy(buffer); puts("Concurrent producer / renderer / reset: passed");
}
