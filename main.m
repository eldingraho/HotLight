#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <math.h>
#import "SMC-Internal.h"

typedef void *(*HIDCreate)(CFAllocatorRef);
typedef int32_t (*HIDMatch)(void *, CFDictionaryRef);
typedef CFArrayRef (*HIDServices)(void *);
typedef CFTypeRef (*HIDProperty)(void *, CFStringRef);
typedef void *(*HIDEvent)(void *, int64_t, int32_t, int64_t);
typedef double (*HIDValue)(void *, int32_t);

static double hidTemperature(BOOL dumpSensors) {
    static void *library = NULL;
    if (!library) library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!library) return NAN;
    HIDCreate create = (HIDCreate)dlsym(library, "IOHIDEventSystemClientCreate");
    HIDMatch match = (HIDMatch)dlsym(library, "IOHIDEventSystemClientSetMatching");
    HIDServices servicesFor = (HIDServices)dlsym(library, "IOHIDEventSystemClientCopyServices");
    HIDProperty property = (HIDProperty)dlsym(library, "IOHIDServiceClientCopyProperty");
    HIDEvent eventFor = (HIDEvent)dlsym(library, "IOHIDServiceClientCopyEvent");
    HIDValue valueFor = (HIDValue)dlsym(library, "IOHIDEventGetFloatValue");
    if (!create || !match || !servicesFor || !property || !eventFor || !valueFor) return NAN;

    int32_t page = 0xff00, usage = 5;
    CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &page);
    CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { pageNumber, usageNumber };
    CFDictionaryRef filter = CFDictionaryCreate(NULL, keys, values, 2,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    CFRelease(pageNumber);
    CFRelease(usageNumber);

    void *system = create(kCFAllocatorDefault);
    if (!system) { CFRelease(filter); return NAN; }
    match(system, filter);
    CFRelease(filter);
    CFArrayRef services = servicesFor(system);
    double hottest = NAN;
    if (services) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            void *service = (void *)CFArrayGetValueAtIndex(services, i);
            CFTypeRef rawName = property(service, CFSTR("Product"));
            if (!rawName) continue;
            NSString *name = CFGetTypeID(rawName) == CFStringGetTypeID() ? (__bridge NSString *)rawName : @"";
            BOOL cpu = [name hasPrefix:@"PMU tdie"] || [name hasPrefix:@"PMU tdev"] ||
                       [name hasPrefix:@"pACC MTR Temp"] || [name hasPrefix:@"eACC MTR Temp"] ||
                       [name rangeOfString:@"CPU" options:NSCaseInsensitiveSearch].location != NSNotFound;
            void *event = eventFor(service, 15, 0, 0);
            if (!event) { CFRelease(rawName); continue; }
            double value = valueFor(event, 15 << 16);
            CFRelease(event);
            if (dumpSensors) printf("%7.2f C  %s  %s\n", value, cpu ? "CPU" : "other", name.UTF8String);
            CFRelease(rawName);
            if (!cpu) continue;
            if (isfinite(value) && value >= 0 && value < 110 && (isnan(hottest) || value > hottest))
                hottest = value;
        }
        CFRelease(services);
    }
    CFRelease(system);
    return hottest;
}

// Read a single, named SMC temperature key. Unlike a sweep of every SMC sensor,
// this keeps the displayed value tied to an identified CPU die hotspot.
static double smcValue(const char *name, BOOL dump) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NAN;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess) return NAN;

    double temperature = NAN;
    if (IOConnectCallMethod(connection, kSMCUserClientOpen, NULL, 0, NULL, 0,
                            NULL, NULL, NULL, NULL) == kIOReturnSuccess) {
        uint32_t key = ((uint32_t)(uint8_t)name[0] << 24) |
                       ((uint32_t)(uint8_t)name[1] << 16) |
                       ((uint32_t)(uint8_t)name[2] << 8) |
                       (uint32_t)(uint8_t)name[3];
        SMCParamStruct input = {0}, output = {0};
        size_t outputSize = sizeof(output);
        input.key = key;
        input.data8 = kSMCGetKeyInfo;
        if (IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                      &input, sizeof(input), &output, &outputSize) == kIOReturnSuccess &&
            output.result == kSMCSuccess) {
            SMCKeyInfoData info = output.keyInfo;
            memset(&input, 0, sizeof(input));
            memset(&output, 0, sizeof(output));
            outputSize = sizeof(output);
            input.key = key;
            input.data8 = kSMCReadKey;
            input.keyInfo.dataSize = info.dataSize;
            if (IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                          &input, sizeof(input), &output, &outputSize) == kIOReturnSuccess &&
                output.result == kSMCSuccess) {
                if (info.dataType == 0x666c7420 && info.dataSize == 4) { // flt 
                    float value;
                    memcpy(&value, output.bytes, sizeof(value));
                    temperature = value;
                } else if (info.dataType == 0x73703738 && info.dataSize == 2) { // sp78
                    temperature = (int16_t)((output.bytes[0] << 8) | output.bytes[1]) / 256.0;
                } else if (info.dataType == 0x66706532 && info.dataSize == 2) { // fpe2 RPM
                    temperature = ((output.bytes[0] << 8) | output.bytes[1]) / 4.0;
                } else if (info.dataType == 0x75693820 && info.dataSize == 1) { // ui8
                    temperature = output.bytes[0];
                }
                if (dump) printf("SMC %s: type=%08x size=%u value=%.2f\n",
                                 name, info.dataType, info.dataSize, temperature);
            }
        }
        IOConnectCallMethod(connection, kSMCUserClientClose, NULL, 0, NULL, 0,
                            NULL, NULL, NULL, NULL);
    }
    IOServiceClose(connection);
    return temperature;
}

static double smcTemperature(const char *name, BOOL dump) {
    double value = smcValue(name, dump);
    return isfinite(value) && value >= 0 && value < 120 ? value : NAN;
}

static double cpuTemperature(BOOL dumpSensors, BOOL *usesHotspot) {
    double hotspot = smcTemperature("TCMz", dumpSensors);
    if (usesHotspot) *usesHotspot = isfinite(hotspot);
    return isfinite(hotspot) ? hotspot : hidTemperature(dumpSensors);
}

static NSString *pressureName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"Nominal";
        case NSProcessInfoThermalStateFair: return @"Fair";
        case NSProcessInfoThermalStateSerious: return @"Serious";
        case NSProcessInfoThermalStateCritical: return @"Critical";
    }
    return @"Unknown";
}

@interface LightHot : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSMenuItem *pressureItem;
@property (strong) NSTimer *timer;
@property (copy) NSString *selectedKey;
@property (strong) NSArray<NSDictionary *> *sensors;
@property (strong) NSMutableArray<NSMenuItem *> *sensorItems;
@property (strong) NSMutableArray<NSMenuItem *> *fanItems;
@end

@implementation LightHot
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.sensors = @[
        @{@"key": @"TCMz", @"name": @"CPU Die Hotspot"},
        @{@"key": @"Tp01", @"name": @"CPU Performance Core 1"},
        @{@"key": @"Tg05", @"name": @"GPU Sensor 1"},
        @{@"key": @"Tm02", @"name": @"Memory Sensor 1"},
        @{@"key": @"TB0T", @"name": @"Battery"}
    ];
    self.selectedKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"SelectedSensor"] ?: @"TCMz";
    if (![[self.sensors valueForKey:@"key"] containsObject:self.selectedKey]) self.selectedKey = @"TCMz";
    self.sensorItems = [NSMutableArray array];
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *symbol = [NSImage imageWithSize:NSMakeSize(14, 16) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        (void)bounds;
        [[NSColor blackColor] setFill];
        NSBezierPath *stem = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5.5, 5, 3, 10)
                                                           xRadius:1.5 yRadius:1.5];
        [stem fill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(3.5, 1.5, 7, 7)] fill];
        return YES;
    }];
    symbol.accessibilityDescription = @"Temperature";
    symbol.template = YES;
    self.item.button.image = symbol;
    self.item.button.imagePosition = NSImageLeft;
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    self.pressureItem = [[NSMenuItem alloc] initWithTitle:@"Thermal Pressure" action:nil keyEquivalent:@""];
    [menu addItem:self.pressureItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:@"Menu Bar Temperature" action:nil keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:heading];
    for (NSDictionary *sensor in self.sensors) {
        NSMenuItem *choice = [[NSMenuItem alloc] initWithTitle:sensor[@"name"] action:@selector(selectSensor:) keyEquivalent:@""];
        choice.target = self;
        choice.representedObject = sensor;
        [self.sensorItems addObject:choice];
        [menu addItem:choice];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    self.fanItems = [NSMutableArray array];
    double count = smcValue("FNum", NO);
    if (isfinite(count) && count >= 1 && count <= 8 && floor(count) == count) {
        for (int i = 0; i < (int)count; i++) {
            NSMenuItem *fan = [[NSMenuItem alloc] initWithTitle:@"Fan speed" action:nil keyEquivalent:@""];
            fan.tag = i;
            [self.fanItems addObject:fan];
            [menu addItem:fan];
        }
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit LightHot" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
    self.item.menu = menu;
    [self refresh:nil];
    self.timer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)selectSensor:(NSMenuItem *)sender {
    self.selectedKey = sender.representedObject[@"key"];
    [[NSUserDefaults standardUserDefaults] setObject:self.selectedKey forKey:@"SelectedSensor"];
    [self refresh:nil];
}

- (void)menuWillOpen:(NSMenu *)menu { (void)menu; [self refresh:nil]; }

- (void)refresh:(NSTimer *)timer {
    (void)timer;
    @autoreleasepool {
        for (NSMenuItem *fan in self.fanItems) {
            NSString *key = [NSString stringWithFormat:@"F%ldAc", (long)fan.tag];
            double rpm = smcValue(key.UTF8String, NO);
            NSString *reading = isfinite(rpm) && rpm >= 0 && rpm <= 20000
                ? [NSString stringWithFormat:@"%.0f RPM", rpm] : @"Unavailable";
            fan.title = [NSString stringWithFormat:@"Fan %ld: %@", (long)fan.tag + 1, reading];
        }
        double temperature = smcTemperature(self.selectedKey.UTF8String, NO);
        BOOL fallback = [self.selectedKey isEqualToString:@"TCMz"] && !isfinite(temperature);
        if (fallback) temperature = hidTemperature(NO);
        NSString *sensorName = @"Temperature";
        for (NSMenuItem *choice in self.sensorItems) {
            NSDictionary *sensor = choice.representedObject;
            BOOL selected = [sensor[@"key"] isEqualToString:self.selectedKey];
            double value = selected ? temperature : smcTemperature([sensor[@"key"] UTF8String], NO);
            choice.title = [NSString stringWithFormat:@"%@: %@", sensor[@"name"],
                isfinite(value) ? [NSString stringWithFormat:@"%.0f°C", value] : @"Unavailable"];
            choice.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
            if (selected) sensorName = fallback ? @"CPU sensor (fallback)" : sensor[@"name"];
        }
        NSString *degrees = isnan(temperature) ? @"—" : [NSString stringWithFormat:@"%.0f°C", temperature];
        NSProcessInfoThermalState state = [NSProcessInfo processInfo].thermalState;
        NSString *pressure = pressureName(state);
        self.item.button.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightRegular];
        self.item.button.title = degrees;
        self.pressureItem.title = [NSString stringWithFormat:@"Thermal Pressure: %@", pressure];
        self.item.button.accessibilityLabel = [NSString stringWithFormat:@"LightHot, %@, %@, thermal pressure %@", sensorName, degrees, pressure];
        self.item.button.toolTip = [NSString stringWithFormat:@"%@: %@ · Thermal pressure: %@",
                                     sensorName,
                                     degrees, pressure];
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--once") == 0) {
            BOOL usesHotspot = NO;
            double value = cpuTemperature(NO, &usesHotspot);
            printf("temperature=%s source=%s pressure=%s\n",
                   isnan(value) ? "unavailable" : [[NSString stringWithFormat:@"%.1fC", value] UTF8String],
                   usesHotspot ? "SMC TCMz" : "HID fallback",
                   [pressureName([NSProcessInfo processInfo].thermalState) UTF8String]);
            return isnan(value) ? 2 : 0;
        }
        if (argc > 1 && strcmp(argv[1], "--fans") == 0) {
            double count = smcValue("FNum", YES);
            if (!isfinite(count) || count < 1 || count > 8 || floor(count) != count) return 2;
            for (int i = 0; i < (int)count; i++) {
                NSString *key = [NSString stringWithFormat:@"F%dAc", i];
                smcValue(key.UTF8String, YES);
            }
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "--dump-sensors") == 0) {
            for (NSString *key in @[@"TCMz", @"Tp01", @"Tg05", @"Tm02", @"TB0T"])
                smcTemperature(key.UTF8String, YES);
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        LightHot *delegate = [[LightHot alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
