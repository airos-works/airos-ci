# airos-ci

Build pipelines for **air/OS**, jmgasper's fork of Haiku
([jmgasper/haiku](https://github.com/jmgasper/haiku)). They run on the
self-hosted build server **airos-build** (Cisco C240, Ubuntu 26.04,
192.168.1.200) through GitHub Actions runners, one per repository.

| Pipeline | Runs from | On | Makes |
|---|---|---|---|
| Images | `jmgasper/haiku` `.github/workflows/airos-images.yml` | pushes to `master`, nightly, by hand | `airos-x86_64.iso` (X399 and other PCs; EFI and BIOS), `airos-arm64.iso` (ROCK 5 ITX and other UEFI arm64 boards), `airos-rpi4.img` (Raspberry Pi 4 SD card for Balena Etcher; boots with no install), `airos-cubie.img` (Radxa Cubie A7S SD card) |
| Applications | each app repository's `.github/workflows/airos.yml` → [`app.yml`](.github/workflows/app.yml) | pushes to the default branch | x86_64 and arm64 packages of Amp, airTime, Kiri, Clipper, airShot, Burrow, Natter, Turbo Chook and Snap, and x86_64 packages of WordCraft and Aurora; every app builds from its `main` branch (Burrow: `master`); a rolling `latest` release and the "Latest builds" section of each README |
| Office and Media | each image build → [`build-pinned.sh`](apps/build-pinned.sh) | source pins and image SDK | Clipper, WordCraft, GridCraft, DeckCraft and PdfCraft (Office), PhotoCraft and LightCraft (Media) for x86_64 and ARM64, with verified Deskbar menu links |
| Summit | `jmgasper/summit` `.github/workflows/airos.yml` → [`summit.yml`](.github/workflows/summit.yml) | pushes to `main`, nightly at 13:17 UTC (two hours before the images) | `summit_webkit` (the WebKit engine) and `summit` (the browser); with `haiku-releases`, the same for stock Haiku R1/beta6 ([below](#builds-for-stock-haiku)) |
| SDKs and dependencies | this repository, [`sdk-deps.yml`](.github/workflows/sdk-deps.yml) | changes to `sdk/`, `deps/`, `lib/` or the fork pins, by hand | cross SDKs, third-party libraries, firmware, the GL stacks |

The applications and Summit go into the **package pool**
(`/data2/airos/packages/{x86_64,arm64,any}`). Each image build takes the
newest successful builds from that pool, and stops if any application in
`IMAGE_APPS` (`images/build-image.sh`) is missing from it. Office and Media are built directly
for each image SDK from [`apps/office.lock.json`](apps/office.lock.json) and
[`apps/media.lock.json`](apps/media.lock.json), so both architectures use the
same reviewed sources. Update those pins to select newer versions; a pin
must be a commit on the repository's `main`, and a pin off `main`, missing
apps or incorrect menu links stop the image build. Turbo Chook's own workflow
still builds its packages into the pool, but no image takes them since
2026-10-19.

## Builds for stock Haiku

`AIROS_TARGET` says what a build is for: `airos` (the default) or a Haiku
release, `r1beta6`, for a stock installation of that release without any
air/OS change. Summit is built for both. For a release:

- the SDK is `sdk/build-release-sdk.sh x86_64 r1beta6`
  (`/data1/airos/sdk/x86_64-r1beta6`). Its sysroot is the release itself:
  every package of its ISO (checked against the published SHA-256), its
  `haiku_devel`, the private headers of its commit, and HaikuPorts devel
  packages. Only the compiler (the same GCC 13.3 as the release's
  `gcc_syslibs`) and the host tools are the air/OS SDK's;
- every tree is the target's own, named after the SDK: `summit/x86_64-r1beta6`,
  `webkit-x86_64-r1beta6`, `gl/x86_64-r1beta6`, `appbuild-x86_64-r1beta6`;
- packages go to `/data2/airos/packages-r1beta6/x86_64`, which no image
  reads, and are published as the rolling `latest-haiku` release and the
  README's "Latest Haiku builds" section (`apps/publish.sh`).

Haiku has no arm64 release, so the release targets are x86_64 only.

## What the images contain

- Haiku from `jmgasper/haiku` `master`, built with the CI profiles in
  `tools/airos/ci/UserBuildConfig`: `nightly-airos-x86_64`, `airos-arm64`,
  `airos-rpi4` and `airos-cubie`. They contain the fork's drivers and settings, and none of the
  lab tooling (no telnet shell, no SSH keys or password hashes).
- **Summit**, the default web browser (a post-install script makes it the
  preferred app for http/https links, HTML and XHTML), with its engine
  `summit_webkit`. The engine has GL compositing, WebGL, WebRTC and media
  playback.
- Amp, airTime, Kiri, airShot and Burrow.
- **Snap** (jmgasper/snap), in Deskbar's Demos folder beside GLTeapot: a
  photo booth whose camera effects are GLSL shaders on the GPU, some of them
  reacting to the microphone or to music. It runs only where OpenGL 3.1 is
  hardware accelerated (tested on AMD's radeonsi; NVIDIA's Zink and the ARM
  boards' drivers where they offer 3.1) and says why elsewhere. arm64
  builds link the GL stack's libglvnd (`deps/build-gl.sh`), which the arm64
  SDK does not have.
- x86_64: **Aurora**, which runs Electron apps (pgAdmin 4's desktop app, for
  one) as native windows on Summit's engine, with HaikuPorts' Node.js 22
  (`nodejs22`, the version its runtime is tested with). arm64 has no Node.js.
- **Office**, between Applications and Utilities in Deskbar: Clipper,
  WordCraft, GridCraft, DeckCraft and PdfCraft on every target. The Craft
  apps use the pinned Rust nightly with a compiled standard library; ARM64
  uses `sdk/targets/aarch64-unknown-haiku.json`. PDFCraft’s ARM64 AWS-LC
  build uses static ARMv8-A capabilities because AWS-LC has no Haiku
  runtime CPU probe.
- **Media**, between Office and Utilities in Deskbar: PhotoCraft (layered
  image editor) and LightCraft (photo library and RAW developer) on every
  target, built the same way. LightCraft embeds the craft-fonts collection
  pinned beside it. Both render with Vulkan where the machine has a hardware
  driver and fall back to the CPU otherwise.
- x86_64: Qt 6 (`qt6_base` and what it needs): HaikuPorts' package with the
  Haiku platform plugin from jmgasper/qt6-haikuplugins `airos`, which draws at
  the desktop's density, at HaikuPorts' revision plus 100
  (`deps/build-qt-airos.sh`). Qt programs installed from HaikuDepot, such as
  Telegram, use it and are sharp at 125 to 175 percent.
- arm64: libraries built from the jmgasper forks (`airos_*` packages:
  OpenSSL, curl, nghttp2, SQLite, TagLib, PCRE2, Scintilla, Lexilla),
  `rock5_ffmpeg` (FFmpeg 6.1.6 with Rockchip MPP hardware decoding),
  `wpa_supplicant`, libpng 1.6.44 as `libpng16` (Haiku's PNG translator is
  built with it), FreeType 2.14.3 as `freetype` (app_server's font engine,
  built as HaikuPorts builds it for x86_64, with PNG; only bzip2 is left out;
  in place of the arm64 repository's bootstrap 2.6.3; Haiku is compiled
  against it), and the GL stack:
  - ROCK 5: Mesa Panfrost with the Mali CSF firmware;
  - Pi 4: Mesa V3D and V3DV;
  - Cubie A7S: Mesa PowerVR Vulkan, Zink OpenGL and its firmware, built by
    `deps/build-cubie.sh` from the Haiku tree’s pinned Mesa source and patches.
    The same recipe builds U-Boot and stages the pinned Radxa boot chain and
    AIC8800 firmware with the distributor’s notices. `sdk/build-cubie-host.sh`
    unpacks the Linux cross compiler and OpenSSL host headers from the
    checksum-pinned `sdk/cubie-host.lock.json`, without replacing the host’s
    Haiku multilib tools or requiring root.
- Every image includes the CA root certificate package for HTTPS. ARM64
  images stage an architecture-neutral copy using zlib compression so the
  trust store also works with bootstrap package readers.
- Every image has the system fonts: HaikuPorts' `noto` (Noto Sans, the
  default UI font, and Noto Sans Mono, the default fixed font) and
  `noto_sans_cjk_jp`. Haiku's arm64 repository has only a 2017 bootstrap
  `noto` without Noto Sans Mono, so ARM64 images stage zlib copies of the
  current packages instead and the bootstrap one stays out.
- x86_64: HaikuPorts' packages for what the applications need. The x86_64
  `summit_webkit` carries a private Mesa with EGL (llvmpipe, zink), which
  needs HaikuPorts' LLVM 21 and Vulkan loader. Whatever the packages CI puts
  in the image still require (summit_webkit's libxslt, woff2 and libexecinfo,
  mupdf's GLib, Aurora's Node.js) is resolved from HaikuPorts: jam installs
  what its HaikuPorts list has, the rest goes in as package files.
- x86_64: the X399 workstation's NVIDIA stack, in
  `system/non-packaged`, so the boot menu's "Disable user add-ons" turns it
  off:
  - `nvidia_rm` (X547's Haiku OS layer with the RM core of NVIDIA 570.86.16)
    and its accelerant;
  - NVK (Vulkan, jmgasper/mesa-nvk, cross-built with Rust for its shader
    compiler);
  - the Zink OpenGL renderer (Mesa 22.0.5), which the boot script switches
    on only where there is an NVIDIA card;
  - the NVDEC H.264 decoder, which offers nothing on machines without an
    NVIDIA card.

  See [docs/x86_64-gpu.md](docs/x86_64-gpu.md).
- x86_64: the AMD GPU driver **amdgpu_drm** (Linux 6.18's amdgpu on a Linux
  compatibility layer, `jmgasper/linux-drm`) and **amdgpu_firmwares** (every
  amdgpu file of linux-firmware 20260916), as packages in `system/packages`;
  app_server drives it through the `amdgpu_kms` accelerant in `haiku.hpkg`.
  Its user land (libdrm, libva, libglvnd, Mesa's radeonsi, RADV and VA-API
  driver, the `amduvd` decoder) is in `system/non-packaged/amdgpu`, linked
  into place at boot only where amdgpu_drm drives a GPU.
  See [docs/x86_64-gpu.md](docs/x86_64-gpu.md#amd-amdgpu_drm).
- Wi-Fi and Bluetooth firmware (Intel, Realtek, MediaTek, Broadcom for the
  Pi) from `jmgasper/airos-firmware` and the Raspberry Pi firmware forks.

Each image comes with a `manifest.json` listing every package that went in,
with its SHA-256, the Haiku commit and the airos-ci commit that built it
(`recipe`: its fork, Office and Media pins), also named in the GitHub release. Images are smoke-tested in QEMU:
x86_64 and arm64 must reach the graphical session; for the Pi, the SD card
layout is checked. Cubie validates the GPT, boot-chain sectors and ESP files,
then boots the image through UEFI on QEMU’s ARM64 virt machine. These checks
do not emulate the boards’ GPUs or qualify their physical hardware. x86_64 boots twice, with a legacy BIOS from a CD and with UEFI
(OVMF) from a USB stick through the EFI system partition, as a PC does; the
UEFI boot's log and screenshot are `serial-uefi-usb.log` and
`screen-uefi-usb.png`. Images are served at
`http://airos-build.local/images/<target>/latest/`.
After the smoke test, `images/publish-github.py` verifies the compressed and
uncompressed image hashes, uploads the image, SHA-256 file and manifest to a
draft GitHub release, verifies GitHub's asset digests, then publishes it as
an immutable prerelease in `jmgasper/haiku`. Tags start with
`image-x86_64-`, `image-arm64-`, `image-rpi4-` or `image-cubie-`. Re-running the publisher
verifies an existing published release without replacing its assets.
The public website discovers the newest published release for each target.

First-boot setup can grow the Pi's system volume to fill the SD card:
[docs/rpi4-sd-auto-resize.md](docs/rpi4-sd-auto-resize.md).

## Build dashboard

`http://192.168.1.200/` (also `http://airos-build.local/`) shows:
- the latest image of each target, with its smoke-test screenshot;
- buttons that start a new build from the latest master of x86_64,
  ARM64/EFI, Raspberry Pi, Cubie A7S, or all four. Optionally the build is clean,
  with Haiku compiled from scratch;
- for every build in progress, whoever started it (the page, CI or a
  shell): its stage, a progress bar, the time elapsed, an estimate of the
  time left from the stages of earlier builds of that image, jam's targets,
  and the log.

`dashboard/server.py` runs as the systemd service `airos-dashboard`, behind
the nginx that serves the files under `/images/`. `images/build-image.sh`
and `images/smoke-test.sh` record each build in `/data2/airos/builds`
(`lib/status.py`). Set it up, or update it, with
`sudo dashboard/install.sh`.

## Repository layout

| Path | What |
|---|---|
| `lib/` | `env.sh` (server layout, locks), `sdk.sh` (cross SDK environment), `fork.sh` (check out a fork at its pinned commit) |
| `sdk/build-sdk.sh ARCH [REF]` | builds Haiku at REF: `haiku.hpkg`, `haiku_devel.hpkg`, the host tools, a sysroot. Writes `/data1/airos/sdk/ARCH` |
| `sdk/build-release-sdk.sh ARCH RELEASE` | the SDK of a stock Haiku release (`x86_64 r1beta6`) from the release's own packages. Writes `/data1/airos/sdk/ARCH-RELEASE` |
| `deps/build-deps.sh ARCH` | arm64: the app libraries from the forks (`deps/recipes/`) as `airos_*` packages, and libpng and FreeType as HaikuPorts' `libpng16`, `freetype` and their `_devel` packages (also run by each arm64 image build). x86_64: HaikuPorts packages (`deps/haikuports.py`) |
| `deps/build-firmware.sh` | firmware packages and image inputs, checked against pinned hashes |
| `deps/build-gl.sh` | arm64 GL: Mesa Panfrost (ROCK 5), V3D and V3DV (Pi), libglvnd, GLU, GLTeapot; run by every ROCK 5 and Pi image build |
| `deps/build-gl-x86_64.sh` | x86_64 GL for Summit's engine: libglvnd and Mesa (llvmpipe, softpipe, zink); with `AIROS_TARGET=r1beta6`, against that release |
| `deps/build-nvidia.sh` | x86_64 NVIDIA: `nvidia_rm`, `nvidia_rm_modeset`, the accelerant, the NVDEC media add-on |
| `deps/build-amdgpu.sh` | x86_64 AMD: the `amdgpu_drm` and `amdgpu_firmwares` packages, the `amduvd` media add-on, the image's AMD user land |
| `deps/build-amdgpu-userland.sh` | x86_64 AMD GPU user land: libdrm, libva, libglvnd, Mesa (radeonsi, RADV, VA-API), static FFmpeg for `amduvd` |
| `deps/build-nvk.sh`, `deps/build-zink.sh` | x86_64: NVK (Vulkan) and the Zink renderer add-on of the OpenGL kit; run by every x86_64 image build |
| `sdk/build-rust.sh` | a pinned Rust nightly with std for x86_64 and ARM64 Haiku; bindgen and cbindgen for NVK's NAK |
| `apps/build-app-packages.sh` | cross-builds the applications, `summit_webkit` and `summit` into Haiku packages |
| `apps/ci-build-app.sh`, `apps/publish.sh` | the CI step of the app pipelines; the release and README update |
| `summit/` | the Summit pipeline: engine libraries (`build-deps.sh`), WebKit (`build-engine.sh`), packages (`build-summit.sh`) |
| `images/` | `build-image.sh TARGET` (`CLEAN=1`: Haiku from scratch), `smoke-test.sh TARGET`, the nginx that serves the images and the dashboard |
| `dashboard/` | the build dashboard (`server.py`, `index.html`, `install.sh`) |
| `forks/` | the third-party sources as jmgasper forks: `forks.json` (what and how), `forks.lock.json` (pinned commits), `make-forks.py`, `patches/` |
| `runner/register-runner.sh REPO` | adds a self-hosted runner for a repository |
| `server/provision.sh` | the build server's package setup after an Ubuntu install |

## Third-party sources: the forks

Every third-party component the images or packages build from is a
repository under [github.com/jmgasper](https://github.com/jmgasper), on an
`airos-*` branch: upstream at a release tag, plus the air/OS patches as
commits. These include Mesa, libglvnd, FFmpeg, Rockchip MPP, OpenSSL, curl,
SQLite, ICU, WebKit, the firmware, wpa_supplicant, OpenVPN and the rest.
`forks/forks.json` says how each is made: a GitHub fork plus patches, an
import of a release tarball, or a branch at an upstream tag. It also says
where each patch comes from: the Haiku or Summit tree at a pinned commit, or
`forks/patches/`. The builds check out exactly the commits in
`forks/forks.lock.json`.

```sh
forks/make-forks.py --only mesa --force   # remake one fork after changing its patches
```

## Build server layout

| Path | What |
|---|---|
| `/data1/airos/sdk/ARCH` | cross SDKs (`env.sh`, sysroot); `ARCH-RELEASE` for a stock Haiku release |
| `/data1/airos/build`, `/data1/airos/src` | Haiku build directories and worktrees; WebKit trees |
| `/data1/airos/deps/ARCH` | the third-party prefix the app builds compile against |
| `/data1/airos/summit/ARCH` | Summit's engine libraries and its SDK snapshot (`ARCH-RELEASE`: the Haiku build's) |
| `/data1/airos/gl`, `/data1/airos/image-inputs` | GL stacks, firmware and other files the images take |
| `/data2/airos/packages` | the package pool |
| `/data2/airos/packages-RELEASE` | packages for a stock Haiku release (not in any image) |
| `/data2/airos/artifacts/images` | images (the last five per target), served over HTTP |
| `/data2/airos/cache`, `/data2/airos/work`, `/data2/airos/locks` | downloads and git caches, scratch space, `flock` locks |
| `/data1/runner/REPO` | the GitHub runners (user `ghrunner`) |

Jobs from different repositories run at the same time. They coordinate
through locks:
- `haiku-ARCH`: exclusive to rebuild an SDK, its dependencies or an image;
  shared by app builds (`haiku-ARCH-RELEASE` for a release SDK, whose users
  also hold `haiku-ARCH` shared for its compiler).
- `summit-ARCH`: the Summit pipeline (`summit-ARCH-RELEASE` for a release).
- `webkit-build`: one engine compile at a time.
- `packages-ARCH`: updates to the pool.

## Adding a repository

1. `runner/register-runner.sh REPO` (with `gh` logged in as jmgasper and
   SSH access to the server; `SUDO_PASSWORD` in the environment).
2. Add `.github/workflows/airos.yml` that calls `app.yml` with the app's
   `build-app-packages.sh` name. Push it over SSH: the gh token cannot write
   workflow files.
3. Add a `build_APP` function to `apps/build-app-packages.sh` (and the app
   to its `main` loop), and the package name to `IMAGE_APPS` in
   `images/build-image.sh`: only the packages listed there go into the
   images, whatever the pool holds, and an image build stops without them.
