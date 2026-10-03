// trackpad-probe: a virtual HID touch screen made with IOHIDUserDevice, to see
// whether macOS's multitouch stack turns its contacts into gestures. It names
// itself Manufacturer "Apple" so AppleMultitouchDriver's (0x0D,0x04) personality
// can match it. Creating it needs com.apple.developer.hid.virtual.device in a
// provisioning profile; without one the kernel refuses (docs/design/trackpad.md).
//   trackpad-probe hold [seconds]         create the device and keep it
//   trackpad-probe swipe up|down|left|right [fingers]
// Build: clang -framework IOKit -framework CoreFoundation -o trackpad-probe trackpad-probe.c
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FINGERS 5

// One finger: tip switch + 7 bits pad, contact id (8), X (16), Y (16) = 6 bytes.
#define FINGER_DESC                                                            \
    0x09, 0x22, 0xA1, 0x02,                         /* Finger, Logical      */ \
    0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,     \
    0x95, 0x07, 0x81, 0x03,                         /* pad                  */ \
    0x09, 0x51, 0x25, 0x0F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, /* id       */ \
    0x05, 0x01, 0x26, 0xFF, 0x0F, 0x75, 0x10, 0x55, 0x0F, 0x65, 0x11,          \
    0x09, 0x30, 0x35, 0x00, 0x46, 0xA0, 0x00, 0x81, 0x02, /* X, 160 mm    */   \
    0x09, 0x31, 0x46, 0x73, 0x00, 0x81, 0x02,       /* Y, 115 mm            */ \
    0x05, 0x0D, 0xC0

static const uint8_t descriptor[] = {
    0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, // Digitizer, Touch Screen, Application
    0x85, 0x01,
    FINGER_DESC, FINGER_DESC, FINGER_DESC, FINGER_DESC, FINGER_DESC,
    0x09, 0x54, 0x15, 0x00, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, // Contact Count
    0x85, 0x02,
    0x09, 0x55, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, // Contact Count Maximum
    0xC0,
};

struct __attribute__((packed)) finger { uint8_t tip; uint8_t id; uint16_t x, y; };
struct __attribute__((packed)) report { uint8_t rid; struct finger f[FINGERS]; uint8_t count; };

static IOHIDUserDeviceRef dev;

static void cfset(CFMutableDictionaryRef d, CFStringRef k, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
}

static void send(int n, int x0, int y0, int down) {
    struct report r = { .rid = 1 };
    for (int i = 0; i < n; i++) {
        r.f[i].tip = down;
        r.f[i].id = i + 1;
        r.f[i].x = x0 + i * 500; // fingers ~20 mm apart
        r.f[i].y = y0;
    }
    r.count = n;
    IOReturn rc = IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(), (uint8_t *)&r, sizeof r);
    if (rc) fprintf(stderr, "report: 0x%x\n", rc);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s hold [s] | swipe dir [fingers]\n", argv[0]); return 2; }
    CFMutableDictionaryRef p = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef d = CFDataCreate(NULL, descriptor, sizeof descriptor);
    CFDictionarySetValue(p, CFSTR(kIOHIDReportDescriptorKey), d);
    cfset(p, CFSTR(kIOHIDVendorIDKey), 0x16C0);
    cfset(p, CFSTR(kIOHIDProductIDKey), 0x7D7);
    CFDictionarySetValue(p, CFSTR(kIOHIDProductKey), CFSTR("vhid trackpad probe"));
    CFDictionarySetValue(p, CFSTR(kIOHIDManufacturerKey), CFSTR("Apple"));
    CFDictionarySetValue(p, CFSTR(kIOHIDTransportKey), CFSTR("Virtual"));
    dev = IOHIDUserDeviceCreateWithProperties(NULL, p, 0);
    if (!dev) { fprintf(stderr, "IOHIDUserDeviceCreateWithProperties failed\n"); return 1; }
    IOHIDUserDeviceRegisterGetReportBlock(dev, ^IOReturn(IOHIDReportType type, uint32_t id, uint8_t *buf, CFIndex *len) {
        if (type == kIOHIDReportTypeFeature && id == 2 && *len >= 2) { buf[0] = 2; buf[1] = FINGERS; *len = 2; return kIOReturnSuccess; }
        return kIOReturnUnsupported;
    });
    IOHIDUserDeviceSetDispatchQueue(dev, dispatch_queue_create("probe", NULL));
    IOHIDUserDeviceActivate(dev);
    printf("device up\n");
    fflush(stdout);
    sleep(2); // let services match

    if (!strcmp(argv[1], "hold")) {
        sleep(argc > 2 ? atoi(argv[2]) : 30);
    } else if (!strcmp(argv[1], "swipe") && argc > 2) {
        int n = argc > 3 ? atoi(argv[3]) : 3;
        int dx = 0, dy = 0;
        if (!strcmp(argv[2], "up")) dy = -1; else if (!strcmp(argv[2], "down")) dy = 1;
        else if (!strcmp(argv[2], "left")) dx = -1; else if (!strcmp(argv[2], "right")) dx = 1;
        int x = 1200, y = 2000;
        for (int i = 0; i <= 40; i++) { // 40 steps of 30 units (~1.2 mm) at 8 ms
            send(n, x + dx * 30 * i, y + dy * 30 * i, 1);
            usleep(8000);
        }
        send(n, x + dx * 1200, y + dy * 1200, 0);
        sleep(1);
    }
    IOHIDUserDeviceCancel(dev);
    return 0;
}
