// trackpad-mtwatch: lists the devices MultitouchSupport (Apple's private
// framework) knows, then prints every contact frame they deliver for 12 seconds.
// It lists devices once, at launch: start it after AppleMultitouchDevice shows
// in ioreg and before the swipe begins (docs/design/trackpad.md).
// Build: clang -w -F/System/Library/PrivateFrameworks -framework MultitouchSupport \
//          -framework CoreFoundation -o trackpad-mtwatch trackpad-mtwatch.c
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

// MultitouchSupport's contact record, as reverse-engineered by many projects.
typedef void *MTDeviceRef;
typedef struct {
    int frame; double timestamp; int identifier, state, unk1, unk2;
    float nx, ny, vx, vy, size; int zero1; float angle, majorAxis, minorAxis;
    float mx, my, mvx, mvy; int zero2[2]; float unk3;
} Finger;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, Finger *, int, double, int);
extern CFArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
extern void MTDeviceStart(MTDeviceRef, int);
extern int MTDeviceGetFamilyID(MTDeviceRef, int *);
extern int MTDeviceIsBuiltIn(MTDeviceRef);

static int frame(MTDeviceRef d, Finger *f, int n, double t, int fr) {
    (void)t; (void)fr;
    printf("frame dev=%p n=%d", d, n);
    for (int i = 0; i < n; i++) printf(" [%d %.2f,%.2f st%d]", f[i].identifier, f[i].nx, f[i].ny, f[i].state);
    printf("\n");
    fflush(stdout);
    return 0;
}

int main(void) {
    CFArrayRef l = MTDeviceCreateList();
    long c = CFArrayGetCount(l);
    printf("devices %ld\n", c);
    if (c == 0) { fprintf(stderr, "no multitouch devices: start this after the probe's device is up\n"); return 1; }
    for (long i = 0; i < c; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(l, i);
        int family = 0;
        MTDeviceGetFamilyID(d, &family);
        printf(" dev %p family %d builtin %d\n", d, family, MTDeviceIsBuiltIn(d));
        MTRegisterContactFrameCallback(d, frame);
        MTDeviceStart(d, 0);
    }
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 12, false);
    return 0;
}
