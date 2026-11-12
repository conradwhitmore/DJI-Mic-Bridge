// Offline contract test of the built HAL plug-in. Does not install/register it or open audio hardware.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static AudioServerPlugInDriverRef driver;
static void property(AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioObjectPropertyScope scope, void *value, UInt32 bytes) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = bytes;
    assert((*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, bytes, &size, value) == noErr);
    assert(size == bytes);
}
static void string_property(AudioObjectPropertySelector selector, CFStringRef expected) {
    CFStringRef value = NULL;
    property(3, selector, kAudioObjectPropertyScopeGlobal, &value, sizeof(value));
    assert(value && CFEqual(value, expected)); CFRelease(value);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), true);
    CFBundleRef bundle = CFBundleCreate(NULL, url); assert(bundle && CFBundleLoadExecutable(bundle));
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = (void *)CFBundleGetFunctionPointerForName(bundle, CFSTR("BlackHole_Create"));
    assert(factory); driver = factory(NULL, kAudioServerPlugInTypeUUID); assert(driver);
    string_property(kAudioObjectPropertyName, CFSTR("MicBridge Audio"));
    string_property(kAudioDevicePropertyDeviceUID, CFSTR("MicBridgeAudio2ch_UID"));
    string_property(kAudioObjectPropertyManufacturer, CFSTR("MicBridge"));
    UInt32 value;
    property(3, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &value, sizeof(value));
    assert(value == kAudioDeviceTransportTypeUSB);
    property(3, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput, &value, sizeof(value));
    assert(value == 1);
    property(3, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput, &value, sizeof(value));
    assert(value == 0);
    AudioObjectID input, output;
    property(3, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, &input, sizeof(input));
    property(3, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, &output, sizeof(output));
    AudioStreamBasicDescription format;
    property(input, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format));
    assert(format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32);
    assert(format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0);
    assert((*driver)->StartIO(driver, 3, 1) == noErr);
    // Write/read across the ring boundary, using the exported plug-in interface.
    float source[512], captured[512];
    for (int i = 0; i < 512; ++i) source[i] = sinf(i * 0.1f) * 0.25f;
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mOutputTime.mSampleTime = cycle.mInputTime.mSampleTime = 65500;
    assert((*driver)->DoIOOperation(driver, 3, output, 1, kAudioServerPlugInIOOperationWriteMix, 256, &cycle, source, NULL) == noErr);
    memset(captured, 0, sizeof(captured));
    assert((*driver)->DoIOOperation(driver, 3, input, 1, kAudioServerPlugInIOOperationReadInput, 256, &cycle, captured, NULL) == noErr);
    for (int i = 0; i < 512; ++i) assert(fabsf(source[i] - captured[i]) < 0.00001f);
    // After the producer stops, input is silent, not stale data.
    cycle.mInputTime.mSampleTime += 256;
    assert((*driver)->DoIOOperation(driver, 3, input, 1, kAudioServerPlugInIOOperationReadInput, 256, &cycle, captured, NULL) == noErr);
    for (int i = 0; i < 512; ++i) assert(captured[i] == 0);
    assert((*driver)->StopIO(driver, 3, 1) == noErr);
    puts("PASS: identity, USB transport, default input, stereo Float32 loopback, wraparound and silence after producer stops");
    CFRelease(bundle); CFRelease(url);
    return 0;
}
