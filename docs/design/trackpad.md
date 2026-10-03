# A virtual trackpad: not without an entitlement from Apple

vhid cannot ship a virtual trackpad today. A HID device made from user space or DriverKit needs an entitlement that Apple grants on request, and vhid's signing team does not hold one. On studious the kernel refused the smallest such device, even as root. With AMFI relaxed to stand in for the entitlement, the device reached Apple's multitouch stack, but the stack delivered no touches from it and a three-finger swipe did nothing. The one route known to produce gestures is a kernel extension that impersonates a Magic Trackpad. A kext needs Apple's kext signing grant instead, and loads only on a Mac whose owner has lowered its security in recoveryOS, which vhid cannot ask of its users. So gestures stay with the key, button and click routes in [gestures.md](gestures.md).

Measured on studious on 2026-10-03: macOS 15.0.1 on a Mac Studio (Mac13,1), SIP disabled. vhid's signing team is 6R988MUU27.

## What studious refused

[trackpad-probe.c](trackpad-probe.c) creates the smallest device that could show a gesture: an IOHIDUserDevice whose report descriptor is a digitizer touch screen (usage page 0x0D, usage 0x04) with five contacts and a contact count. It then reports fingers sliding 48 mm in one direction.

- **Run as bmf:** `IOHIDUserDeviceCreateWithProperties` returned NULL.
- **Run as root:** NULL again. The kernel logged `IOHIDResourceDeviceUserClient:0x0 trackpad-probe is not entitled`. IOHIDFamily's `IOHIDResourceDeviceUserClient::initWithTask` (in `IOHIDResourceUserClient.cpp`) checks only for the entitlement, never for root.
- **Ad hoc signed, claiming `com.apple.developer.hid.virtual.device`:** AMFI killed the process at launch, logging `bailing out because of restricted entitlements`. The entitlement is valid only with a provisioning profile that grants it, and none of the team's profiles do.

## With AMFI relaxed, the device reached Apple's stack and gave nothing

The boot-arg `amfi_get_out_of_my_way=1` makes AMFI accept an ad hoc binary's restricted entitlements, so it can stand in for Apple's grant on a test Mac. studious ran the probe that way, then had the boot-arg removed again.

- The kernel created the device. IOHIDFamily marked it `HIDVirtualDevice`, and AppleMultitouchDriver's `AppleMultitouchHIDService` matched it, with an `AppleMultitouchDevice` and a user client beneath.
- [trackpad-mtwatch.c](trackpad-mtwatch.c), listening through MultitouchSupport, found the device as family 0, built in, with `0 cols X 0 rows`. Over a three-finger swipe up it received no contact frames.
- Nothing appeared on screen. studious has the three- and four-finger vertical swipe set to Mission Control (`TrackpadThreeFingerVertSwipeGesture = 2`), and a `screencapture` during the swipe matched one taken before it.

So a standard touch screen named Apple gets as far as the multitouch stack, which does not know its geometry and drops its contacts.

## What a shipped device would need

There are three ways to make the device. Each needs its own entitlement from Apple, requested through Apple's capability request form. Developer forum threads describe such requests waiting for months.

| Route | Entitlement | Notes |
| --- | --- | --- |
| IOHIDUserDevice (IOKit), as the probe uses | `com.apple.developer.hid.virtual.device` | IOHIDFamily marks every device created this way `HIDVirtualDevice` and sets its `Transport` to `Virtual`. |
| CoreHID's `HIDVirtualDevice` (macOS 15) | the same | Same kernel path. Apple documents a one-time TCC approval for some actions. |
| A DriverKit driver of vhid's own | `com.apple.developer.driverkit.family.hid.device` and the related DriverKit grants | Nothing forces the virtual mark or transport. It would sit beside the pqrs driver ([installing.md](../installing.md)), whose grants belong to pqrs's team and cannot be borrowed. |

Each device is its own IOService, so nothing found makes a second device exclusive with the pqrs driver.

## Which device would macOS turn into gestures?

Gestures such as switching Spaces, Mission Control, pinch and rotate come from Apple's closed multitouch stack (AppleMultitouchDriver and MultitouchSupport), not from IOHIDFamily. IOHIDFamily's generic event driver turns a standard digitizer touchpad into digitizer and pointer events only (`IOHIDEventDriver.cpp`, `setDigitizerProperties`). So a device has to reach Apple's stack. Studious has three matching rules a device could aim at:

- **A touch screen named Apple.** AppleMultitouchDriver's personality `AppleMultitouchHIDService (0x0D,0x04)` matches a HID interface with usage 0x0D/0x04 and `Manufacturer` `Apple`, and parses it as a standard digitizer (`parser-type 1`). This is the probe's device, and the stack dropped its contacts.
- **Apple's user-device page.** The personality `MTUserDevice` matches usage page 0xFF60, usage 7, with no vendor check. Its report format is not public.
- **A Magic Trackpad clone.** `AppleMultitouchTrackpadHIDEventDriver` matches vendor 0x05AC with the Magic Trackpad's product IDs, 0x0265 and 0x0324, and does not check the transport. The trackpad speaks a private protocol: input report 0x02 and fixed replies to feature reports 0xD1, 0xD3, 0xA1, 0xC8 and 0xDB. [VoodooInput](https://github.com/acidanthera/VoodooInput) reverse-engineered it (`VoodooInputSimulatorDevice.cpp`). Its Hackintosh kexts get native swipes, Mission Control, pinch and rotate this way. Nobody has published a clone made as an IOHIDUserDevice or with DriverKit. Whether the stack refuses a device marked virtual is unknown.

## Routes not taken

- **Synthetic gesture events.** Mac Mouse Fix, LinearMouse and others post private CGEvent gesture types to fake Dock swipes. That reaches around the devices ([development.md#scope](../development.md#scope)), and those events are undocumented. Mac Mouse Fix had to fix its dock-swipe events after a macOS release broke them.
- **`MTDeviceInjectFrame`.** MultitouchSupport exports this private function, but it injects frames into a multitouch device that already exists. Studious has none, and the function reaches around the devices too.

## Asking again

The entitlement is worth requesting only once a device is shown to make a gesture, and that can be tested on studious without it. The next device to try is the Magic Trackpad clone, built from VoodooInput's protocol into the probe.

To run a probe with AMFI relaxed, set the boot-arg and reboot, sign the probe ad hoc with an entitlements plist that sets `com.apple.developer.hid.virtual.device` to true, and run it as bmf. Root changes nothing. Remove the boot-arg and reboot when done, so studious stays a stock Mac.

    sudo nvram boot-args="amfi_get_out_of_my_way=1" && sudo reboot
    clang -framework IOKit -framework CoreFoundation -o trackpad-probe trackpad-probe.c
    codesign -f -s - --entitlements probe.entitlements trackpad-probe
    ./trackpad-probe swipe up 3 & sleep 1; ./trackpad-mtwatch
    sudo nvram -d boot-args && sudo reboot

A device works when trackpad-mtwatch prints frames and the swipe opens Mission Control. Only then does the request to Apple follow. A granted entitlement cannot ride on a bare binary: it needs a bundle with the provisioning profile at `Contents/embedded.provisionprofile`, signed with the team's certificate and the same entitlements plist.
