# QSOE — binary downloads

Pre-built images and kernels of [QSOE](https://qsoe.net), one directory per
release under `releases/<version>/bin/`. The source is at
[gitlab.com/qsoe](https://gitlab.com/qsoe); the manuals are at
[github.com/qsoe-dev/doc](https://github.com/qsoe-dev/doc).

The latest release is **0.4** — [what's new](https://qsoe.net/qsoe_0.4.html).

## What each file is (0.4)

| File | What it is |
|---|---|
| `nvme.img.gz` | The self-booting disk image: the mr-bml boot loader, both kernels, the boot archive, and the system volume with the base system installed. |
| `virtio.img.gz` | QSOE/L's root disk under QEMU, beside `nvme.img` (QEMU's `virt` machine gives seL4 no NVMe). |
| `run-nvme.sh` | The QEMU launcher for the two images. |
| `modpkg.cpio` | The boot archive. One file boots both kernels on every board. |
| `skimmer-qemu.bin`, `skimmer-sifive.bin`, `skimmer-vf2.bin`, `skimmer-k3.bin` | QSOE/N: the Skimmer kernel, per board, as the flat image mr-bml's `kernel` command loads. |
| `skimmer-k3.elf` | QSOE/N for the K3 as an ELF — the form the K3's QSOE/N entry boots. |
| `sel4-qemu.elf`, `sel4-sifive.elf`, `sel4-vf2.elf` | QSOE/L: the seL4 kernel, per board, booted by mr-bml's `multiboot3` command with `modpkg.cpio` as its module. |
| `sel4-k3-15.elf` | QSOE/L for the K3: seL4 on [k3sel4](https://gitlab.com/sel4-frontier/k3sel4), 15 harts. |
| `mrbml-efi-riscv64_1.0_riscv64.deb` | The mr-bml boot loader, 1.0, as a Debian package. |
| `SHA512SUMS` | SHA-512 digests of the files above. |

The boards are the SiFive HiFive Unmatched (`sifive`), the StarFive
VisionFive 2 (`vf2`) and the SpacemiT K3 Pico-ITX (`k3`).

## Checking the files

```
sha512sum -c SHA512SUMS
```

The same command works on QSOE itself.

## Running under QEMU

```
gunzip nvme.img.gz virtio.img.gz
NVME_IMG=./nvme.img VIRTIO_IMG=./virtio.img ./run-nvme.sh n --uefi    # QSOE/N
NVME_IMG=./nvme.img VIRTIO_IMG=./virtio.img ./run-nvme.sh l --uefi    # QSOE/L
```

`--uefi` boots through the distribution's edk2 (`qemu-efi-riscv64`). Pick the
entry for the variant in mr-bml's menu, and log in as `root` (password `QSOE`)
or `user` (password `skimmer`).

## On a board

The kernels, the boot archive and the boot loader are here for putting QSOE on
a board; chapter 2 of the
[User Guide](https://github.com/qsoe-dev/doc/blob/main/UserGuide.pdf) says what
that takes.

## License

Apache-2.0; see `LICENSE`.
