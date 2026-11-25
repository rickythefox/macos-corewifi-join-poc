// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
// Experimental, standalone CoreWiFi join proof of concept.
// Build: ./build.sh

#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <CoreLocation/CoreLocation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Observed on macOS 27.2.1. Resolve the classes dynamically; fail closed if absent.
@interface NSObject (CoreWiFiSPI)
- (NSInteger)serviceType;
- (id)coreWiFiScanResult;
- (id)coreWiFiNetworkProfile;
- (id)scanRecord;
- (NSData *)SSID;
- (BOOL)isSystemMode;
- (BOOL)isPSK;
- (void)setScanResult:(id)result;
- (void)setKnownNetworkProfile:(id)profile;
- (void)setPassword:(NSString *)password;
- (BOOL)associateWithParameters:(id)parameters error:(NSError **)error;
@end

static void requireSelector(id object, SEL selector) {
    if (![object respondsToSelector:selector]) {
        @throw [NSException exceptionWithName:@"UnavailablePrivateAPI"
                                      reason:[NSString stringWithFormat:@"%@ lacks %@",
                                              object ? NSStringFromClass([object class]) : @"nil",
                                              NSStringFromSelector(selector)]
                                    userInfo:nil];
    }
}

static void emit(NSDictionary *report) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                   error:&error];
    if (!json) {
        fprintf(stderr, "JSON output failed: %s\n", error.localizedDescription.UTF8String);
        exit(1);
    }
    fwrite(json.bytes, 1, json.length, stdout);
    putchar('\n');
    fflush(stdout);
}

static NSDictionary *errorReport(NSError *error) {
    // Do not dump userInfo or private objects: they may contain credentials.
    return error ? @{@"domain": error.domain, @"code": @(error.code),
                     @"description": error.localizedDescription}
                 : @{@"description": @"The API failed without an NSError"};
}

static NSString *authorizationName(CLAuthorizationStatus status) {
    switch (status) {
        case kCLAuthorizationStatusNotDetermined: return @"notDetermined";
        case kCLAuthorizationStatusRestricted: return @"restricted";
        case kCLAuthorizationStatusDenied: return @"denied";
        case kCLAuthorizationStatusAuthorizedAlways: return @"authorizedAlways";
    }
    return @"unknown";
}

@interface LocationDelegate : NSObject <CLLocationManagerDelegate>
@property(nonatomic) BOOL receivedAuthorization;
@end

@implementation LocationDelegate
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    self.receivedAuthorization = YES;
}
@end

static int locationCommand(BOOL request) {
    if (request) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
    CLLocationManager *manager = [[CLLocationManager alloc] init];
    __attribute__((objc_precise_lifetime)) LocationDelegate *delegate = [[LocationDelegate alloc] init];
    manager.delegate = delegate;
    NSDate *initialDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!delegate.receivedAuthorization && initialDeadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (request && manager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        fprintf(stderr, "Waiting up to 60 seconds for your Location permission decision...\n");
        [manager requestWhenInUseAuthorization];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
        while (manager.authorizationStatus == kCLAuthorizationStatusNotDetermined &&
               deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
    CLAuthorizationStatus status = manager.authorizationStatus;
    emit(@{@"stage": @"location", @"authorization": authorizationName(status),
           @"authorizationCallbackReceived": @(delegate.receivedAuthorization),
           @"locationServicesEnabled": @([CLLocationManager locationServicesEnabled]),
           @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: (id)[NSNull null]});
    if (!request) return 0;
    if (status == kCLAuthorizationStatusAuthorizedAlways) return 0;
    fprintf(stderr, "Location access is not granted. Check System Settings > Privacy & Security > Location Services.\n");
    return 1;
}

static void usage(void) {
    puts("Experimental private CoreWiFi CLI (no passwords read by this process).\n"
         "Usage:\n"
         "  corewifi-join status               Show Location authorization; read-only.\n"
         "  corewifi-join authorize            Request Location permission (you must approve).\n"
         "  corewifi-join list                 Scan and list nearby networks; read-only.\n"
         "  corewifi-join inspect 'Exact SSID' Check a saved network; read-only.\n"
         "  corewifi-join join 'Exact SSID'    Attempt a REAL join using airportd's keychain path.\n"
         "\n"
         "No arguments means list. No sudo or special entitlements are added.\n"
         "Join supports saved, system-mode personal (PSK) networks only.\n"
         "Scans and joins are synchronous and may take seconds.\n"
         "Location restrictions can hide network names; empty results do not prove absence.\n"
         "Join can disrupt connectivity or cause a macOS authorization prompt.\n"
         "A successful API return is not proof of internet access or prompt-free behavior.");
}

static int run(int argc, const char **argv) {
    NSString *command = argc > 1 ? @(argv[1]) : @"list";
    if ([command isEqualToString:@"--help"] || [command isEqualToString:@"help"]) {
        usage();
        return 0;
    }
    if ([command isEqualToString:@"authorize"] || [command isEqualToString:@"status"]) {
        if (argc != 2) { usage(); return 2; }
        return locationCommand([command isEqualToString:@"authorize"]);
    }
    BOOL list = [command isEqualToString:@"list"];
    BOOL join = [command isEqualToString:@"join"];
    if ((!list && !join && ![command isEqualToString:@"inspect"]) ||
        (list && argc > 2) || (!list && argc != 3)) {
        usage();
        return 2;
    }
    NSString *target = list ? nil : [NSString stringWithUTF8String:argv[2]];
    if (!list && (!target || target.length == 0)) {
        fprintf(stderr, "An exact, nonempty UTF-8 SSID is required.\n");
        return 2;
    }
    if (!dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_NOW)) {
        fprintf(stderr, "CoreWiFi unavailable: %s\n", dlerror());
        return 1;
    }
    CWWiFiClient *client = [CWWiFiClient sharedWiFiClient];
    CWInterface *interface = client.interface;
    if (!interface) {
        fprintf(stderr, "No Wi-Fi interface.\n");
        return 1;
    }
    // Reuse CoreWLAN's already-configured service connection; do not activate or invalidate it.
    id corewifi = [interface valueForKey:@"corewifi"];
    requireSelector(corewifi, @selector(serviceType));
    requireSelector(corewifi, @selector(associateWithParameters:error:));
    if ([corewifi serviceType] != 5) {
        fprintf(stderr, "Refusing unexpected CoreWiFi service type (expected 5).\n");
        return 1;
    }
    CWConfiguration *configuration = interface.configuration;
    if (!configuration) {
        fprintf(stderr, "Cannot read saved Wi-Fi configuration.\n");
        return 1;
    }
    fprintf(stderr, "Scanning %s (no association requested yet)...\n", interface.interfaceName.UTF8String);
    NSError *error = nil;
    NSSet<CWNetwork *> *scanned = [interface scanForNetworksWithName:target error:&error];
    if (!scanned) {
        emit(@{@"stage": @"scan", @"error": errorReport(error)});
        return 1;
    }
    NSArray<CWNetwork *> *networks = [scanned.allObjects sortedArrayUsingComparator:
        ^NSComparisonResult(CWNetwork *a, CWNetwork *b) {
            if (a.rssiValue > b.rssiValue) return NSOrderedAscending;
            if (a.rssiValue < b.rssiValue) return NSOrderedDescending;
            return [(a.ssid ?: @"") compare:(b.ssid ?: @"")];
        }];
    NSMutableArray *rows = [NSMutableArray array];
    CWNetwork *selectedNetwork = nil;
    id selectedScan = nil;
    id selectedProfile = nil;
    NSUInteger redacted = 0;
    NSMutableSet<NSNumber *> *targetSecurityTypes = [NSMutableSet set];
    NSData *targetData = [target dataUsingEncoding:NSUTF8StringEncoding];
    for (CWNetwork *network in networks) {
        if (!network.ssid || !network.ssidData) redacted++;
        if (target && ![network.ssidData isEqual:targetData]) continue;
        requireSelector(network, @selector(coreWiFiScanResult));
        id scan = [network coreWiFiScanResult];
        requireSelector(scan, @selector(scanRecord));
        requireSelector(scan, @selector(isPSK));
        requireSelector(scan, @selector(SSID));
        // Match raw SSID bytes AND the saved security type. Never manufacture a saved profile.
        NSMutableArray<CWNetworkProfile *> *matches = [NSMutableArray array];
        for (CWNetworkProfile *profile in configuration.networkProfiles) {
            if (network.ssidData && [profile.ssidData isEqual:network.ssidData] &&
                [network supportsSecurity:profile.security]) {
                [matches addObject:profile];
                if (target) [targetSecurityTypes addObject:@(profile.security)];
            }
        }
        id saved = nil;
        if (matches.count == 1) {
            requireSelector(matches.firstObject, @selector(coreWiFiNetworkProfile));
            saved = [matches.firstObject coreWiFiNetworkProfile];
            requireSelector(saved, @selector(isSystemMode));
            requireSelector(saved, @selector(isPSK));
            requireSelector(saved, @selector(SSID));
        }
        BOOL eligible = saved && [saved isSystemMode] && [saved isPSK] && [scan isPSK] &&
                        [scan scanRecord] != nil && [saved SSID] != nil &&
                        [[saved SSID] isEqual:network.ssidData] &&
                        [[scan SSID] isEqual:network.ssidData];
        [rows addObject:@{@"ssid": network.ssid ?: (id)[NSNull null],
                         @"rssi": @(network.rssiValue),
                         @"matchingSavedProfiles": @(matches.count),
                         @"systemMode": @([saved isSystemMode]),
                         @"personalSecurity": @([scan isPSK]),
                         @"hasScanRecord": @([scan scanRecord] != nil),
                         @"eligibleForPrivateJoin": @(eligible)}];
        if (target && eligible && !selectedNetwork) {
            selectedNetwork = network;
            selectedScan = scan;
            selectedProfile = saved;
        }
    }
    emit(@{@"stage": @"inspection", @"interface": interface.interfaceName,
           @"serviceType": @([corewifi serviceType]), @"power": @(interface.powerOn),
           @"currentSSID": interface.ssid ?: (id)[NSNull null],
           @"requiresAdministratorForAssociation": @(configuration.requireAdministratorForAssociation),
           @"savedProfileCount": @(configuration.networkProfiles.count),
           @"redactedScanCount": @(redacted), @"networks": rows});
    if (list) return 0;
    if (!selectedNetwork || targetSecurityTypes.count != 1) {
        fprintf(stderr, "No unambiguous, visible, system-mode PSK profile/scan pair. Nothing joined.\n");
        return 1;
    }
    Class paramsClass = NSClassFromString(@"CWFAssocParameters");
    id parameters = [[paramsClass alloc] init];
    requireSelector(parameters, @selector(setScanResult:));
    requireSelector(parameters, @selector(setKnownNetworkProfile:));
    requireSelector(parameters, @selector(setPassword:));
    [parameters setScanResult:selectedScan];
    [parameters setKnownNetworkProfile:selectedProfile];
    [parameters setPassword:nil];
    if (!join) {
        emit(@{@"stage": @"ready", @"associationAttempted": @NO,
               @"ssid": target, @"passwordSupplied": @NO});
        return 0;
    }
    fprintf(stderr, "Joining %s using airportd's stored-credential path; macOS may prompt...\n", target.UTF8String);
    error = nil;
    BOOL accepted = [corewifi associateWithParameters:parameters error:&error];
    // Association return and observed interface state are separate evidence.
    NSMutableDictionary *result = [@{@"stage": @"association", @"apiSucceeded": @(accepted),
                                    @"requestedSSID": target, @"passwordSupplied": @NO,
                                    @"observedSSID": interface.ssid ?: (id)[NSNull null],
                                    @"observedSSIDMatches": @([interface.ssidData isEqual:targetData])} mutableCopy];
    if (!accepted || error) result[@"error"] = errorReport(error);
    emit(result);
    return accepted ? 0 : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *resultFile = nil;
        if (argc >= 3 && strcmp(argv[1], "--result-file") == 0) {
            resultFile = [NSString stringWithUTF8String:argv[2]];
            argc -= 2;
            argv += 2;
        }
        int result;
        @try {
            result = run(argc, argv);
        } @catch (NSException *exception) {
            fprintf(stderr, "%s: %s\n", exception.name.UTF8String, exception.reason.UTF8String);
            result = 1;
        }
        if (resultFile) {
            NSError *error = nil;
            if (![[NSString stringWithFormat:@"%d\n", result] writeToFile:resultFile atomically:YES
                                                              encoding:NSUTF8StringEncoding error:&error]) {
                fprintf(stderr, "Cannot write exit status: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
        }
        return result;
    }
}
