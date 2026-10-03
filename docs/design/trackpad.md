# A virtual trackpad: not without an entitlement from Apple

vhid cannot present a virtual trackpad today. Every way to create a HID device that macOS treats as touch input needs an entitlement that Apple grants on request, and vhid's signing team does not hold one. On studious the kernel refused the smallest such device, created as root with SIP disabled. Even with the entitlement, nobody has shown a virtual device that macOS turns into gestures from user space or DriverKit. The one route known to work is a kernel extension that impersonates a Magic Trackpad, so gestures stay with the key, button and click routes in [gestures.md](gestures.md).

Measured on studious on 2026-10-03: macOS 15.0.1 on a Mac Studio (Mac13,1), SIP disabled. vhid's signing team is 6R988MUU27.

## What studious refused

[trackpad-probe.c](trackpad-probe.c) creates the smallest device that could show a gesture: an IOHIDUserDevice whose report descriptor is a digitizer touch screen (usage page 0x0D, usage 0x04) with five contacts and a contact count. It then reports three fingers sliding up.

- **Run as bmf:** `IOHIDUserDeviceCreateWithProperties` returned NULL.
- **Run as root:** NULL again. The kernel logged `IOHIDResourceDeviceUserClient:0x0 trackpad-probe is not entitled`. IOHIDFamily's `IOHIDResourceUserClient::initWithTask` checks only for the entitlement, never for root.
- **Ad hoc signed, claiming `com.apple.developer.hid.virtual.device`:** AMFI killed the process at launch, logging `bailing out because of restricted entitlements`. The entitlement is valid only with a provisioning profile that grants it, and none of the team's profiles do.

## What a device would need

There are three ways to make the device. Each needs its own entitlement from Apple, requested through Apple's capability request form. Developer forum threads describe such requests waiting for months.

| Route | Entitlement | Notes |
| --- | --- | --- |
| IOHIDUserDevice (IOKit), as the probe uses | `com.apple.developer.hid.virtual.device` | IOHIDFamily marks every device created this way `HIDVirtualDevice` and sets its `Transport` to `Virtual`. |
| CoreHID's `HIDVirtualDevice` (macOS 15) | the same | Same kernel path. Apple documents a one-time TCC approval for some actions. |
| A DriverKit driver of vhid's own | `com.apple.developer.driverkit.family.hid.device` and the related DriverKit grants | Nothing forces the virtual mark or transport. It would sit beside the pqrs driver ([installing.md](../installing.md)), whose grants belong to pqrs's team and cannot be borrowed. |

Each device is its own IOService, so nothing found makes a second device exclusive with the pqrs driver.

## Would macOS turn its touches into gestures?

That is unproven, and it decides whether the entitlement is worth asking for. Gestures such as switching Spaces, Mission Control, pinch and rotate come from Apple's closed multitouch stack (AppleMultitouchDriver and MultitouchSupport), not from IOHIDFamily. IOHIDFamily's generic event driver turns a standard digitizer touchpad into digitizer and pointer events only (`IOHIDEventDriver.cpp`, `setDigitizerProperties`). So a device has to reach Apple's stack. Studious has three matching rules a device could aim at:

- **A touch screen named Apple.** AppleMultitouchDriver's personality `AppleMultitouchHIDService (0x0D,0x04)` matches a HID interface with usage 0x0D/0x04 and `Manufacturer` `Apple`, and parses it as a standard digitizer (`parser-type 1`). The probe names itself Apple for this reason. What the stack does with a touch screen's contacts, and whether a Mac turns them into trackpad gestures, was not seen.
- **Apple's user-device page.** The personality `MTUserDevice` matches usage page 0xFF60, usage 7, with no vendor check. Its report format is not public.
- **A Magic Trackpad clone.** `AppleMultitouchTrackpadHIDEventDriver` matches vendor 0x05AC with the Magic Trackpad's product IDs, 0x0265 and 0x0324, and does not check the transport. The trackpad speaks a private protocol: input report 0x02 and fixed replies to feature reports 0xD1, 0xD3, 0xA1, 0xC8 and 0xDB. [VoodooInput](https://github.com/acidanthera/VoodooInput) reverse-engineered it (`VoodooInputSimulatorDevice.cpp`). Its Hackintosh kexts get native swipes, Mission Control, pinch and rotate this way. Nobody has published a clone made as an IOHIDUserDevice or with DriverKit. Whether the stack refuses a device marked virtual is unknown.

## Routes not taken

- **Synthetic gesture events.** Mac Mouse Fix, LinearMouse and others post private CGEvent gesture types to fake Dock swipes. That reaches around the devices ([development.md#scope](../development.md#scope)), and those events are undocumented. Mac Mouse Fix had to fix its dock-swipe events after a macOS release broke them.
- **`MTDeviceInjectFrame`.** MultitouchSupport exports this private function, but it injects frames into a multitouch device that already exists. Studious has none, and the function reaches around the devices too.

## Asking again

The question reopens if the team gets `com.apple.developer.hid.virtual.device`. On studious, build and sign the probe with that profile, run it as `hold 30`, and look for `AppleMultitouchHIDService` under it in `ioreg -r -n IOHIDUserDevice -l`. If it is there, run `swipe up 3` and watch for Mission Control. If it is not, the next device to try is the Magic Trackpad clone.

    clang -framework IOKit -framework CoreFoundation -o trackpad-probe trackpad-probe.c
    sudo ./trackpad-probe hold 30
    sudo ./trackpad-probe swipe up 3
