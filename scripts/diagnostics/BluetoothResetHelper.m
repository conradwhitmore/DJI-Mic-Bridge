// Local Bluetooth reset helper. Build with Foundation, IOBluetooth and Security.
// No command scans, connects, opens a channel, or reads keychain secret data.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

// These are the same private preference entry points used by blueutil.
extern int IOBluetoothPreferencesAvailable(void);
extern int IOBluetoothPreferenceGetControllerPowerState(void);
extern void IOBluetoothPreferenceSetControllerPowerState(int state);

static NSString *const SystemKeychainPath = @"/Library/Keychains/System.keychain";
static NSArray<NSString *> *deviceKeyServices(void) {
    return @[@"MobileBluetooth", @"BluetoothLE", @"BluetoothLESync"];
}

static void timedOut(int number) {
    (void)number;
    static const char message[] =
        "{\"ok\":false,\"error\":\"timeout\",\"timeout_seconds\":20}\n";
    // Only async-signal-safe operations: a framework call can be stuck on any thread.
    (void)write(STDOUT_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void emit(NSDictionary *result, int status) __attribute__((noreturn));
static void emit(NSDictionary *result, int status) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
    if (!data) {
        static const char fallback[] = "{\"ok\":false,\"error\":\"json_encoding_failed\"}\n";
        (void)write(STDOUT_FILENO, fallback, sizeof(fallback) - 1);
        _exit(1);
    }
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    const unsigned char *bytes = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining) {
        ssize_t written = write(STDOUT_FILENO, bytes, remaining);
        if (written < 0 && errno == EINTR) { continue; }
        if (written <= 0) { _exit(1); }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    alarm(0);
    _exit(status);
}

static NSDictionary *failure(NSString *operation, NSString *error) {
    return @{ @"ok": @NO, @"operation": operation, @"error": error };
}

static NSDictionary *securityFailure(NSString *stage, OSStatus status) {
    NSString *message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
    return @{ @"stage": stage, @"status": @(status), @"message": message ?: @"Security operation failed" };
}

static BOOL isMAC(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 17) { return NO; }
    unichar separator = [value characterAtIndex:2];
    if (separator != ':' && separator != '-') { return NO; }
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (index % 3 == 2) {
            if (character != separator) { return NO; }
        } else if (!((character >= '0' && character <= '9') ||
                     (character >= 'a' && character <= 'f') ||
                     (character >= 'A' && character <= 'F'))) {
            return NO;
        }
    }
    return YES;
}

static NSString *canonicalMAC(NSString *value) {
    return [[value stringByReplacingOccurrencesOfString:@"-" withString:@":"] uppercaseString];
}

// nil means an unknown schema or no usable device identity.
static NSArray<NSString *> *addressesForAccount(NSString *service, NSString *account) {
    NSArray *addresses = nil;
    if ([service isEqual:@"MobileBluetooth"] && isMAC(account)) {
        addresses = @[account];
    } else if (([service isEqual:@"BluetoothLE"] || [service isEqual:@"BluetoothLESync"]) &&
               [account isKindOfClass:NSString.class]) {
        NSArray *parts = [account componentsSeparatedByString:@" "];
        if (parts.count == 4 && [parts[0] isEqual:@"Public"] && [parts[2] isEqual:@"Random"] &&
            isMAC(parts[1]) && isMAC(parts[3]) && [parts[1] characterAtIndex:2] == ':' &&
            [parts[3] characterAtIndex:2] == ':') {
            addresses = @[parts[1], parts[3]];
        }
    }
    if (!addresses) { return nil; }
    NSMutableSet *canonical = [NSMutableSet set];
    for (NSString *address in addresses) {
        NSString *value = canonicalMAC(address);
        if (![value isEqual:@"00:00:00:00:00:00"]) { [canonical addObject:value]; }
    }
    return canonical.count ? [[canonical allObjects] sortedArrayUsingSelector:@selector(compare:)] : nil;
}

// This query requests only attributes and an opaque item reference, never value data.
// An explicit search list prevents fallback to login/iCloud/other keychains.
static NSArray<NSDictionary *> *deviceKeyItems(SecKeychainRef keychain, OSStatus *status) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *service in deviceKeyServices()) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecReturnRef: @YES
        };
        CFTypeRef result = NULL;
        *status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (*status == errSecItemNotFound) { if (result) { CFRelease(result); } continue; }
        if (*status != errSecSuccess) { if (result) { CFRelease(result); } return nil; }
        id objects = CFBridgingRelease(result);
        if (![objects isKindOfClass:NSArray.class]) { *status = errSecDecode; return nil; }
        for (id object in objects) {
            if (![object isKindOfClass:NSDictionary.class]) { *status = errSecDecode; return nil; }
            [items addObject:object];
        }
    }
    *status = errSecSuccess;
    return items;
}

static NSArray<NSDictionary *> *eligibleItems(NSArray<NSDictionary *> *items, NSUInteger *skipped) {
    NSMutableArray *eligible = [NSMutableArray array];
    *skipped = 0;
    for (NSDictionary *item in items) {
        id service = item[(__bridge id)kSecAttrService];
        id account = item[(__bridge id)kSecAttrAccount];
        id reference = item[(__bridge id)kSecValueRef];
        if (!addressesForAccount(service, account) || !reference ||
            CFGetTypeID((__bridge CFTypeRef)reference) != SecKeychainItemGetTypeID()) {
            (*skipped)++;
            continue;
        }
        [eligible addObject:item];
    }
    return eligible;
}

static NSArray<NSString *> *accountsForItems(NSArray<NSDictionary *> *items) {
    NSMutableSet *accounts = [NSMutableSet set];
    for (NSDictionary *item in items) {
        [accounts addObjectsFromArray:addressesForAccount(item[(__bridge id)kSecAttrService], item[(__bridge id)kSecAttrAccount])];
    }
    return [[accounts allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

static NSArray<NSDictionary *> *detailsForItems(NSArray<NSDictionary *> *items) {
    NSMutableArray *details = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSString *service = item[(__bridge id)kSecAttrService], *account = item[(__bridge id)kSecAttrAccount];
        [details addObject:@{ @"service": service, @"account": account,
                             @"addresses": addressesForAccount(service, account) }];
    }
    [details sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult result = [left[@"service"] compare:right[@"service"]];
        return result == NSOrderedSame ? [left[@"account"] compare:right[@"account"]] : result;
    }];
    return details;
}

static NSDictionary *countsForItems(NSArray<NSDictionary *> *items) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSString *service in deviceKeyServices()) { counts[service] = @0; }
    for (NSDictionary *item in items) {
        NSString *service = item[(__bridge id)kSecAttrService];
        counts[service] = @([counts[service] unsignedIntegerValue] + 1);
    }
    return counts;
}

// Recheck the exact item's keychain, class, service and original account just
// before deleting its reference. There is no broad service-only delete fallback.
static OSStatus validateItem(SecKeychainItemRef item, NSString *expectedService, NSString *expectedAccount) {
    SecKeychainRef owner = NULL;
    OSStatus status = SecKeychainItemCopyKeychain(item, &owner);
    if (status != errSecSuccess) { return status; }
    char path[4096];
    UInt32 pathLength = sizeof(path);
    status = SecKeychainGetPath(owner, &pathLength, path);
    CFRelease(owner);
    if (status != errSecSuccess) { return status; }
    if (pathLength >= sizeof(path)) { return errSecDecode; }
    path[pathLength] = '\0';
    if (strcmp(path, SystemKeychainPath.fileSystemRepresentation) != 0) { return errSecParam; }

    UInt32 tags[] = { kSecServiceItemAttr, kSecAccountItemAttr };
    UInt32 formats[] = { CSSM_DB_ATTRIBUTE_FORMAT_STRING, CSSM_DB_ATTRIBUTE_FORMAT_STRING };
    SecKeychainAttributeInfo info = { 2, tags, formats };
    SecItemClass itemClass = 0;
    SecKeychainAttributeList *attributes = NULL;
    // Both data outputs are NULL: no password or pairing-key bytes are requested.
    status = SecKeychainItemCopyAttributesAndData(item, &info, &itemClass, &attributes, NULL, NULL);
    if (status != errSecSuccess) { return status; }
    NSString *service = nil, *account = nil;
    for (UInt32 index = 0; index < attributes->count; index++) {
        SecKeychainAttribute attribute = attributes->attr[index];
        NSString *value = [[NSString alloc] initWithBytes:attribute.data length:attribute.length encoding:NSUTF8StringEncoding];
        if (attribute.tag == kSecServiceItemAttr) { service = value; }
        if (attribute.tag == kSecAccountItemAttr) { account = value; }
    }
    SecKeychainItemFreeAttributesAndData(attributes, NULL);
    return itemClass == kSecGenericPasswordItemClass && [service isEqual:expectedService] &&
           addressesForAccount(service, account) != nil && [account isEqual:expectedAccount] ? errSecSuccess : errSecParam;
}

static NSDictionary *keychainCommand(BOOL deleteItems) {
    NSString *operation = deleteItems ? @"delete-device-pairing-keys" : @"keychain-summary";
    if (deleteItems && geteuid() != 0) { return failure(operation, @"root_required"); }
    OSStatus status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) {
        return @{ @"ok": @NO, @"operation": operation, @"error": securityFailure(@"disable_interaction", status) };
    }
    SecKeychainRef keychain = NULL;
    status = SecKeychainOpen(SystemKeychainPath.fileSystemRepresentation, &keychain);
    if (status != errSecSuccess) {
        return @{ @"ok": @NO, @"operation": operation, @"error": securityFailure(@"open_system_keychain", status) };
    }
    NSArray *items = deviceKeyItems(keychain, &status);
    if (!items) {
        CFRelease(keychain);
        return @{ @"ok": @NO, @"operation": operation, @"error": securityFailure(@"enumerate_attributes", status) };
    }
    NSUInteger skipped = 0;
    NSArray *eligible = eligibleItems(items, &skipped);
    if (!deleteItems) {
        CFRelease(keychain);
        return @{ @"ok": skipped == 0 ? @YES : @NO, @"operation": operation, @"keychain": SystemKeychainPath,
                  @"services": deviceKeyServices(), @"accounts": accountsForItems(eligible),
                  @"count": @(eligible.count), @"items": detailsForItems(eligible),
                  @"counts_by_service": countsForItems(eligible), @"skipped_count": @(skipped) };
    }

    NSUInteger deleted = 0, alreadyAbsent = 0;
    NSMutableArray *errors = [NSMutableArray array];
    // Unknown schemas abort the entire deletion phase before any item is changed.
    if (skipped) { [errors addObject:@{ @"stage": @"validate_schema", @"message": @"Unknown device-account schema or item reference; no items deleted" }]; }
    for (NSDictionary *item in skipped ? @[] : eligible) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSString *account = item[(__bridge id)kSecAttrAccount];
        SecKeychainItemRef reference = (__bridge SecKeychainItemRef)item[(__bridge id)kSecValueRef];
        status = validateItem(reference, service, account);
        NSString *stage = @"validate_exact_item";
        if (status == errSecSuccess) {
            stage = @"delete_exact_item";
            status = SecKeychainItemDelete(reference);
        }
        if (status == errSecSuccess) { deleted++; }
        else if (status == errSecItemNotFound) { alreadyAbsent++; }
        else {
            NSMutableDictionary *error = [securityFailure(stage, status) mutableCopy];
            error[@"account"] = account;
            error[@"service"] = service;
            [errors addObject:error];
        }
    }

    NSArray *remaining = deviceKeyItems(keychain, &status);
    CFRelease(keychain);
    NSUInteger remainingSkipped = 0;
    NSArray *remainingEligible = remaining ? eligibleItems(remaining, &remainingSkipped) : nil;
    if (!remaining) { [errors addObject:securityFailure(@"verify_attributes", status)]; }
    BOOL verified = remaining != nil && remainingEligible.count == 0 && remainingSkipped == 0 && skipped == 0;
    return @{ @"ok": verified && errors.count == 0 ? @YES : @NO, @"operation": operation,
              @"keychain": SystemKeychainPath, @"services": deviceKeyServices(),
              @"before_count": @(eligible.count), @"attempted": @(skipped ? 0 : eligible.count),
              @"items": detailsForItems(eligible), @"counts_by_service": countsForItems(eligible),
              @"deleted": @(deleted), @"already_absent": @(alreadyAbsent), @"errors": errors,
              @"remaining_accounts": remainingEligible ? accountsForItems(remainingEligible) : (id)NSNull.null,
              @"remaining_count": remainingEligible ? @(remainingEligible.count) : (id)NSNull.null,
              @"remaining_items": remainingEligible ? detailsForItems(remainingEligible) : (id)NSNull.null,
              @"remaining_counts_by_service": remainingEligible ? countsForItems(remainingEligible) : (id)NSNull.null,
              @"skipped_count": @(skipped), @"remaining_skipped_count": @(remainingSkipped), @"verified": @(verified) };
}

static NSDictionary *bluetoothCommand(NSString *operation, NSString *address) {
    if (!IOBluetoothPreferencesAvailable()) { return failure(operation, @"bluetooth_preferences_unavailable"); }
    if ([operation isEqual:@"snapshot"]) {
        NSMutableArray *devices = [NSMutableArray array];
        NSUInteger pairedCount = 0;
        // IOBluetooth documents nil as the valid result for no paired devices.
        for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
            NSString *value = device.addressString;
            if (!isMAC(value)) { return failure(operation, @"invalid_device_address"); }
            BOOL paired = device.isPaired;
            if (paired) { pairedCount++; }
            [devices addObject:@{ @"address": canonicalMAC(value), @"paired": @(paired) }];
        }
        [devices sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"address"] compare:right[@"address"]];
        }];
        return @{ @"ok": @YES, @"operation": operation, @"devices": devices,
                  @"count": @(devices.count), @"paired_count": @(pairedCount),
                  @"power": @(IOBluetoothPreferenceGetControllerPowerState()) };
    }
    if ([operation isEqual:@"power-off"]) {
        IOBluetoothPreferenceSetControllerPowerState(0);
        for (NSUInteger attempt = 0; attempt < 150; attempt++) {
            if (IOBluetoothPreferenceGetControllerPowerState() == 0) {
                return @{ @"ok": @YES, @"operation": operation, @"power": @0 };
            }
            [NSThread sleepForTimeInterval:0.1];
        }
        return failure(operation, @"power_off_not_confirmed");
    }
    IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
    if (!device) { return failure(operation, @"device_lookup_failed"); }
    SEL selector = NSSelectorFromString(@"remove");
    NSMethodSignature *signature = [device methodSignatureForSelector:selector];
    if (![device respondsToSelector:selector] || !signature || signature.numberOfArguments != 2) {
        return failure(operation, @"unpair_selector_unavailable");
    }
    // NSInvocation avoids assuming the private selector's return type or ownership.
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = device;
    invocation.selector = selector;
    [invocation invoke];
    return @{ @"ok": @YES, @"operation": operation, @"address": canonicalMAC(address),
              @"requested": @YES, @"confirmed": @NO };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
            puts("Usage: BluetoothResetHelper --snapshot | --power-off | --unpair ADDRESS | --keychain-summary | --delete-device-pairing-keys --apply\n"
                 "Operational commands emit JSON and have a 20-second hard timeout.\n"
                 "Unpair reports only a request. Keychain commands inspect only System.keychain / genp / MobileBluetooth, BluetoothLE, BluetoothLESync attributes; deletion requires root and --apply.\n"
                 "--delete-mobilebluetooth-keys remains an alias for --delete-device-pairing-keys.\n"
                 "No scanning, connections, audio, or keychain secret-data reads. Help performs no Bluetooth or Security calls.");
            return 0;
        }
        NSString *operation = nil, *address = nil;
        if (argc == 2 && strcmp(argv[1], "--snapshot") == 0) { operation = @"snapshot"; }
        else if (argc == 2 && strcmp(argv[1], "--power-off") == 0) { operation = @"power-off"; }
        else if (argc == 2 && strcmp(argv[1], "--keychain-summary") == 0) { operation = @"keychain-summary"; }
        else if (argc == 3 && strcmp(argv[1], "--unpair") == 0) {
            operation = @"unpair";
            address = [NSString stringWithUTF8String:argv[2]];
            if (!isMAC(address)) { emit(failure(operation, @"invalid_mac_address"), 64); }
        } else if (argc == 3 && (strcmp(argv[1], "--delete-device-pairing-keys") == 0 ||
                                strcmp(argv[1], "--delete-mobilebluetooth-keys") == 0) && strcmp(argv[2], "--apply") == 0) {
            operation = @"delete-device-pairing-keys";
            if (geteuid() != 0) { emit(failure(operation, @"root_required"), 77); }
        } else { emit(failure(@"arguments", @"invalid_arguments_use_help"), 64); }

        struct sigaction action = {0};
        action.sa_handler = timedOut;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGALRM, &action, NULL) != 0) { emit(failure(operation, @"watchdog_setup_failed"), 1); }
        alarm(20);
        // macOS IOBluetooth initialization can synchronously wait on the main queue.
        // The first framework API runs here while the main thread services its run loop.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                @try {
                    NSDictionary *result;
                    if ([operation isEqual:@"keychain-summary"] || [operation isEqual:@"delete-device-pairing-keys"]) {
                        result = keychainCommand([operation isEqual:@"delete-device-pairing-keys"]);
                    } else { result = bluetoothCommand(operation, address); }
                    emit(result, [result[@"ok"] boolValue] ? 0 : 1);
                } @catch (NSException *exception) {
                    emit(@{ @"ok": @NO, @"operation": operation, @"error": @"objective_c_exception",
                            @"exception": exception.name ?: @"unknown" }, 1);
                }
            }
        });
        while (true) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false); }
    }
}
