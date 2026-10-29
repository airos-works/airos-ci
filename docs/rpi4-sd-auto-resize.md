# Raspberry Pi and Cubie A7S first-boot setup

The Pi and Cubie A7S images include **First-Boot Setup** (`rpi_installer`,
named Raspberry Pi Setup before version 1.2). On first
boot it asks whether to use the whole SD card for air/OS. Choose **Use entire
SD card**, confirm, choose a time zone in step 2, and restart. **Keep current
size** proceeds directly to time zone selection. **Later** offers the unfinished
step again next boot. Applications → First-Boot Setup can reopen it manually.
A system on a layout the app does not expand (such as a Cubie eMMC
installation) can skip straight to the time zone.
Version 1.1 preserves UTC while changing zones, and records the two steps
separately. The Pi image retries NTP automatically and includes the CA bundle
required by Summit and curl.

The image remains small for flashing. Its BFS filesystem reserves bitmap
and journal space at creation (`block_size 4096; growable true`). The app
validates the boot device and the image's layout (the Pi's MBR with FAT32 +
BFS, or the Cubie's GPT with its boot chain, ESP + BFS), saves the original
partition table, then extends only the BFS partition; on the Cubie it also
moves the backup GPT to the card's end. The next boot grows
BFS before publishing files, without moving existing data or invoking the
experimental general resize ioctl.

The `airos-rpi4` and `airos-cubie` profiles require `rpi_installer` in the
image package set; `images/build-image.sh rpi4|cubie` selects it from the
ARM64 package pool, and the Cubie's boot script starts it like the Pi's. Build the
app from the workspace's `apps/rpi-installer` using the Haiku tree's
`tools/airos/build-arm64-app-packages.sh ... rpi_installer`, then install the
package into the pool under the `packages-arm64` lock.

Host filesystem tests cover 128 GB, 128 GiB and 2 TiB growth. Native ARM64
emulation covers the prompt, decline, cancel, expansion, restart and saved
completion. Pi SD-controller emulation also passed the filesystem growth
and SD flush barriers. The reported physical 128 GB card was checked on 2026-10-07: its partition
and BFS sizes agree, and an offline allocation check is clean. It booted when
the NanoKVM's empty USB LUN was replaced with valid idle media.

See [the implementation and validation notes](https://github.com/airos-works/haiku/blob/master/docs/rpi4/INSTALLER.md).
