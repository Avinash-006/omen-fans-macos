# OMEN Fans for macOS

A menu bar fan controller for the HP OMEN 16-wd0990tx (board 8BA9) running Intel macOS Tahoe through OpenCore. The app shows CPU and GPU temperatures, both fans’ measured RPM, and an animated fan that follows fan activity and respects Reduce Motion.

- **Automatic** gives HP firmware control of both fans.
- **Fixed speed** applies one setting to both fans. Each fan uses its own firmware maximum, so their RPM can differ.
- **Fan curve** interpolates between four editable temperature points using the hotter of the CPU and GPU sensors. The chart plots each fan’s target RPM. **Apply curve** runs and saves the configuration. The app starts in Automatic every time it launches.

## Compatibility and validation

The app and bridge target an x86-64 HP OMEN 16-wd0990tx with board 8BA9, BIOS F.26, and macOS 26.7.3 (Darwin 25.6.0). The bridge checks the HP board and WMI interface at runtime. GPU temperature requires the NVIDIA driver to publish `Temperature(C)` in the `NVAccel` IORegistry service. Live GPU temperature and fan RPM, the previous bridge’s fan override, and the curve interpolation have been verified on the development setup. Bridge 1.0.2’s Intel CPU temperature and firmware RPM queries still need post-reboot hardware validation. This is an early release.

The kernel bridge is an unsigned OpenCore-injected extension. Install it only on a compatible Hackintosh with a working OpenCore recovery path. Compiled packages are distributed as ZIP files.

## Install from a release

1. Download and extract the app ZIP and the bridge ZIP. The optional `SHA256SUMS.txt` verifies the downloads with `shasum -a 256 -c SHA256SUMS.txt` from the download directory.
2. Back up the **EFI used to boot macOS**. Copy `OmenFanBridge.kext` to `EFI/OC/Kexts`. When upgrading, first back up the old bundle and replace it in the same location.
3. Add the entry below to OpenCore’s `Kernel → Add`. If it already exists, keep the single existing entry. Validate the full configuration with the `ocvalidate` that matches your OpenCore version.

| Key | Value |
| --- | --- |
| `Arch` | `x86_64` |
| `BundlePath` | `OmenFanBridge.kext` |
| `Comment` | `HP OMEN 8BA9 fan control` |
| `Enabled` | `true` |
| `ExecutablePath` | `Contents/MacOS/OmenFanBridge` |
| `MinKernel` | `25.6.0` |
| `MaxKernel` | `25.6.99` |
| `PlistPath` | `Contents/Info.plist` |

4. Restart through that EFI. Move `OMEN Fans.app` into Applications and open it. Click the fan icon in the menu bar. The app is ad hoc signed. On a quarantined download, macOS may require the per-app **Open Anyway** approval in **System Settings → Privacy & Security**.
5. Check that both RPM values and both temperature readings appear. At idle, apply 100% in **Fixed speed** and compare measured RPM. Click **Return to automatic** before trying a custom curve.

## Temperature and cooling behavior

Manual controls are bounded to 70–100% of each fan’s firmware maximum. The app asks for full speed at 90 °C CPU or 83 °C GPU during an override. The bridge uses a 45-second lease, and the app renews it while an override is active. Firmware regains control when the lease expires, on app exit or sleep, or when macOS reports serious thermal pressure. Curve mode also hands control back when either temperature becomes unavailable. With an older bridge, the app labels RPM targets as estimates and may show no CPU reading.

## Troubleshooting and rollback

Quit the menu bar app before running its read-only probe, since the bridge accepts one client at a time.

```sh
"/Applications/OMEN Fans.app/Contents/MacOS/OmenFans" --probe
kmutil showloaded --list-only | grep local.omen.fans.bridge
```

- **Bridge offline:** Confirm which EFI booted macOS, check that its `Kernel → Add` entry points to the installed bundle, validate the config, then reboot from that EFI.
- **Missing CPU temperature or estimated graph targets:** Confirm bridge **1.0.2** is loaded after a restart. The Intel package sensor must be supported and report a valid value. The app also checks VirtualSMC’s `TC0D` key when it is available.
- **Missing GPU temperature:** Confirm your NVIDIA driver exposes `Temperature(C)` under the `NVAccel` service. Curve mode requires a valid reading from both sensors.
- **Rollback:** Quit the app and replace the bridge with the backed-up bundle, or disable the `OmenFanBridge.kext` entry and remove that bundle from `EFI/OC/Kexts`. Restart through the same EFI. If macOS fails to start, restore the known-good EFI configuration from another boot environment.

## Build from source

Use macOS Command Line Tools or Xcode with the macOS 26.5 SDK, including the Intel kernel headers and kernel module libraries. On a Mac with multiple developer tool installations, select the intended toolchain for the build using `DEVELOPER_DIR`.

```sh
./build.sh
```

The build produces `dist/OMEN Fans.app` and `dist/OmenFanBridge.kext`. Pass an output directory as the first argument to override `dist`. The build ad hoc signs the app and leaves the bridge unsigned for OpenCore injection.

## Technical references

The HP fan protocol follows the [upstream Linux HP WMI driver](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/hp/hp-wmi.c) and the [8BA9 board support patch](https://lkml.iu.edu/2607.3/00853.html). CPU temperature uses the Intel package Digital Thermal Sensor described in the [Intel Software Developer’s Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html). The optional SMC fallback uses the [VirtualSMC sensor key definitions](https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt). GPU telemetry comes from the [NullMoth NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver).
