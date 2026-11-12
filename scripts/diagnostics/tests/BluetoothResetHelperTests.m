// Pure account classification tests: no Bluetooth or Security API is invoked.
#define main BluetoothResetHelperEntryPoint
#include "../BluetoothResetHelper.m"
#undef main
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSArray *classic = addressesForAccount(@"MobileBluetooth", @"aa-bb-cc-dd-ee-ff");
        assert([classic isEqual:@[@"AA:BB:CC:DD:EE:FF"]]);
        NSArray *le = addressesForAccount(@"BluetoothLE", @"Public AA:BB:CC:DD:EE:FF Random 11:22:33:44:55:66");
        assert(le.count == 2);
        assert([le containsObject:@"AA:BB:CC:DD:EE:FF"]);
        NSArray *sync = addressesForAccount(@"BluetoothLESync", @"Public 00:00:00:00:00:00 Random 11:22:33:44:55:66");
        assert([sync isEqual:@[@"11:22:33:44:55:66"]]);
        NSArray *same = addressesForAccount(@"BluetoothLE", @"Public AA:BB:CC:DD:EE:FF Random AA:BB:CC:DD:EE:FF");
        assert(same.count == 1);
        NSArray *bad = @[
            @[@"BluetoothGlobal", @"AA:BB:CC:DD:EE:FF"],
            @[@"BluetoothGlobal", @"Identity Root"],
            @[@"MobileBluetooth", @"Identity Root"],
            @[@"MobileBluetooth", @"prefix AA:BB:CC:DD:EE:FF"],
            @[@"MobileBluetooth", @"00:00:00:00:00:00"],
            @[@"BluetoothLE", @"AA:BB:CC:DD:EE:FF"],
            @[@"BluetoothLE", @"Public AA-BB-CC-DD-EE-FF Random 11:22:33:44:55:66"],
            @[@"BluetoothLE", @"Public AA:BB:CC:DD:EE:FF Random 11:22:33:44:55:66 trailing"],
            @[@"BluetoothLE", @"Public 00:00:00:00:00:00 Random 00:00:00:00:00:00"],
            @[@"BluetoothLE", @"Public AA:BB:CC:DD:EE:FF  Random 11:22:33:44:55:66"],
            @[@"BluetoothLESync", @"Identity Root"],
            @[@"Other", @"Public AA:BB:CC:DD:EE:FF Random 11:22:33:44:55:66"]
        ];
        for (NSArray *example in bad) { assert(addressesForAccount(example[0], example[1]) == nil); }
        assert(([deviceKeyServices() isEqual:@[@"MobileBluetooth", @"BluetoothLE", @"BluetoothLESync"]]));
        puts("Account classification tests passed; no Bluetooth or Keychain operation executed.");
    }
    return 0;
}
