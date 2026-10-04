#!/bin/bash
#
# run-nvme.sh -- boot the QSOE NVMe disk image under QEMU.
#
# Boots build/nvme.img the way a user would the published download: firmware
# runs mr-bml from the image's EFI System Partition, whose menu starts either
# variant.  No `-kernel` -- everything comes off the disk.
#
# TWO FIRMWARE CHAINS, and the default is ours:
#
#   hfi (default)  our own stack, the same one a board runs:
#                    QEMU reset ROM -> HFI BIOS SPL (M-mode)
#                                   -> the FIT off the disk's ESP
#                                   -> OpenSBI -> U-Boot + the BIOS
#                                   -> mr-bml -> QSOE
#                  The BIOS loads the virtio-gpu VideoBIOS Module, which cold-
#                  inits the GPU, leaves a colour text console on the display
#                  and publishes a Controller Handoff Block.  That is what
#                  makes `devc-hficon` -- and the whole on-screen console --
#                  testable without a card in a slot.
#
#   uefi           stock edk2 from pflash.  Kept because it is a useful
#                  control: it exercises mr-bml's UEFI path with NO VideoBIOS
#                  in the chain, so a screen problem can be attributed.  It
#                  publishes no handoff block, so hficon correctly finds
#                  nothing there.
#
# The two QSOE variants need different machines (a QEMU limitation, not a QSOE
# one):
#   QSOE/N  -- `aia=aplic-imsic` so PCIe MSI-X reaches devb-nvme; its root
#              /usr is NVMe p8 (/dev/nvme0n1p8).
#   QSOE/L  -- stock seL4 has no AIA, so it runs on the PLIC machine and takes
#              its root /usr from a virtio-mmio disk (virtio.img, /dev/vblk0).
#              The NVMe disk still carries the firmware, mr-bml and the kernels.
# So the launch picks the machine for you; both disks are attached for L.
#
# SMP IS MANDATORY -- at least two harts, on every path.  The VideoBIOS runs
# its character generator on a hart of its own, so a single-hart machine has
# nowhere to put it; and QSOE is an SMP system on both kernels.  Asking for one
# hart is refused rather than quietly downgraded.
#
# There is no menu, and the variant is NOT optional.  It picks the machine, and
# the two machines are not interchangeable: choose QSOE/N's and then pick
# QSOE/L in mr-bml, and seL4 gets a box with no PLIC and no root disk -- it
# stops after `Loading sel4-qemu.elf ...` and never prints another byte.  The
# firmware, by contrast, IS defaulted: ours, always, unless --uefi says
# otherwise.
#
# Usage:
#   ./run-nvme.sh n | nq       QSOE/N on the HFI BIOS chain
#   ./run-nvme.sh l | lq       QSOE/L on the HFI BIOS chain
#   ./run-nvme.sh n --uefi     QSOE/N under stock edk2
#   ./run-nvme.sh l --uefi     QSOE/L under stock edk2
#
# Env overrides: QEMU, NVME_IMG, VIRTIO_IMG, N_CPUS/N_MEM, L_CPUS/L_MEM,
#                HFI_BIOS (the firmware tree), QEMU_CPU, GRAPHIC=1,
#                EDK2_CODE/EDK2_VARS (the --uefi path only).
# The mr-bml menu and the kernel both speak over the serial console (stdio);
# GRAPHIC=1 additionally opens the display window -- which on the hfi chain is
# where the VideoBIOS console actually appears.
#
# Copyright (c) 2026 Yuri Zaporozhets <yuriz@qsoe.net>
# SPDX-License-Identifier: Apache-2.0

set -e

TOP=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$TOP/build
# Image paths default to the umbrella build dir, but are overridable so a
# user who downloaded (rather than built) the images can point us straight at
# the unpacked files:  NVME_IMG=./nvme.img VIRTIO_IMG=./virtio.img ./run-nvme.sh
NVME_IMG=${NVME_IMG:-$BUILD/nvme.img}
VIRTIO_IMG=${VIRTIO_IMG:-$BUILD/virtio.img}
# The image's partition geometry, as the umbrella Makefile lays it out -- needed
# to rewrite one partition in place.  Keep in step with NVME_PARTS there.
NVME_PARTS="1 4 16 1 1 48 8 16"
NVME_ESP_PART=3

QEMU=${QEMU:-qemu-system-riscv64}

# The HFI BIOS tree.  Its QEMU target must have been built once:
#   make -C <tree> TARGET=qemu VIDEOBIOS_BLOB=../virtio-gpu-videobios/virtio-gpu-videobios.vbm
HFI_BIOS=${HFI_BIOS:-$HOME/proj/RISC-V/hfi-bios}
HFI_SPL=$HFI_BIOS/u-boot/spl/u-boot-spl.bin
HFI_FIT=$HFI_BIOS/u-boot/u-boot.itb
# Where the BIOS keeps SAVE SETTINGS: QEMU virt's second 32 MiB CFI bank at
# 0x22000000, attached as pflash unit 1.  Runtime state, not a build product --
# deleting it is the equivalent of pulling the CMOS battery.  Unit 0 is left
# free on purpose: QEMU redirects the reset vector into it, which would bypass
# the SPL entirely.
HFI_VARS=${HFI_VARS:-$BUILD/hfi-vars.fd}
HFI_VARS_MB=32
# CONFIG_ENV_SIZE from the firmware's U-Boot config -- the size of the saved
# environment block that lives at the start of this bank.
HFI_ENV_SIZE=0x20000
# The emulated part.  RVA23 because that is what the VideoBIOS is written
# against (it uses Zawrs when told to; see the module's CHARGEN_WAIT note).
QEMU_CPU=${QEMU_CPU:-rva23s64}

# The stock-edk2 control path.
EDK2_CODE=${EDK2_CODE:-/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd}
EDK2_VARS=${EDK2_VARS:-/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd}
# Writable NVRAM copy (edk2 needs a writable VARS store); persisted so the
# firmware's boot order survives across runs.  It lives beside the disk
# image -- build/ in the source tree, and wherever the images were unpacked
# for a downloaded release, which has no build/ to put it in.
VARS_RW=${VARS_RW:-$(dirname "$NVME_IMG")/qemu-vars.fd}

# Per-variant machine sizing.  ONE HART MORE THAN THE KERNEL USES, on both:
# the VideoBIOS character generator takes a whole processor of its own and
# never gives it back, so a machine sized for the kernel alone leaves it
# nowhere to go.
#
# For QSOE/L that is not a preference, it is arithmetic.  seL4's RISC-V
# elfloader does not read the device tree: it starts harts
# CONFIG_FIRST_HART_ID .. +CONFIG_MAX_NUM_NODES-1 (0..3 here) unconditionally
# and then spins until all four report ready.  A generator inside that range
# is therefore fatal -- the elfloader waits forever for a hart that is busy
# generating characters -- and mr-bml marking it `status = "disabled"` buys
# nothing, because nothing in that path looks.  So the machine gets
# CONFIG_MAX_NUM_NODES + 1 harts and the module is built with
# VBM_CHARGEN_SCAN_DOWN=1, which makes the generator claim the HIGHEST hart:
# hart 4, just past the range seL4 owns.  Keep the two in step: raising
# CONFIG_MAX_NUM_NODES in lq/.config means raising L_CPUS by the same amount.
N_CPUS=${N_CPUS:-8};  N_MEM=${N_MEM:-2G}
L_CPUS=${L_CPUS:-5};  L_MEM=${L_MEM:-1G}

# The floor, in one place.  One hart is not a smaller QSOE, it is a machine
# neither the VideoBIOS nor either kernel is built for.
QSOE_MIN_HARTS=2

usage() {
    echo "usage: $(basename "$0") {n|nq|l|lq} [--uefi]   (the variant is required)" >&2
}

# ---- pick the variant and the firmware ------------------------------------
# The firmware chain defaults to ours; the variant has no default at all.
#
# `variant` is NOT the question "which OS" -- mr-bml asks that, on the screen,
# with both entries in front of you.  It picks the MACHINE, because the two want
# different ones and QEMU will not offer both at once (see the note above).  The
# mr-bml menu therefore still has two entries here and only one of them can run
# on the machine we are about to build, which is precisely why this cannot be
# guessed for you: a wrong guess is a silent hang, not an error.  The launch
# banner below names the entry that works.
variant=
firmware=hfi
for arg in "$@"; do
    case "$arg" in
        n|nq|N|NQ)  variant=n ;;
        l|lq|L|LQ)  variant=l ;;
        --uefi)     firmware=uefi ;;
        --hfi)      firmware=hfi ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "error: unknown argument '$arg'" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$variant" ]]; then
    echo "error: say which variant to boot -- it selects the machine, and the" >&2
    echo "       machines are not interchangeable." >&2
    usage
    exit 1
fi

if [[ "$variant" == n ]]; then
    CPUS=$N_CPUS; MEM=$N_MEM
else
    CPUS=$L_CPUS; MEM=$L_MEM
fi

# ---- the SMP floor --------------------------------------------------------
# Refuse rather than downgrade.  A single-hart boot does not fail cleanly: the
# VideoBIOS has no hart to put its character generator on, and what the user
# sees is a blank screen with no error, which is the worst way to learn this.
if (( CPUS < QSOE_MIN_HARTS )); then
    echo "error: $CPUS hart(s) requested; QSOE needs at least $QSOE_MIN_HARTS." >&2
    echo "       The VideoBIOS runs its character generator on a hart of its own," >&2
    echo "       and both kernels are SMP systems.  Raise N_CPUS / L_CPUS." >&2
    exit 1
fi

# ---- preflight checks -----------------------------------------------------
if [[ ! -f "$NVME_IMG" ]]; then
    echo "error: $NVME_IMG not built -- run 'make nvme' first" >&2
    exit 1
fi
if [[ "$variant" == l && ! -f "$VIRTIO_IMG" ]]; then
    echo "error: $VIRTIO_IMG not built -- run 'make virtio' first" >&2
    exit 1
fi

NVME=( -drive "file=$NVME_IMG,if=none,format=raw,id=nvm0" )

# ---- the machine ----------------------------------------------------------
# acpi=off is essential on BOTH variants and both firmware chains.  With ACPI
# on (the edk2 default on virt) the firmware boots the OS in ACPI mode and
# hands it a minimal device tree stripped of per-cpu `mmu-type` and the root
# `model`; Skimmer's hart filter then finds zero S-mode harts and panics ("no
# S-mode-capable cpu@ node"), and /sys/board comes up empty.  acpi=off makes
# the firmware forward QEMU's full DTB instead -- the same one a native
# -kernel boot sees, and the one carrying the VideoBIOS handoff node.
if [[ "$variant" == n ]]; then
    # AIA machine: PCIe MSI-X delivery for devb-nvme.  NVMe behind a root port
    # to mirror the FU740 (controller behind the host's PCIe root port).
    MACHINE="virt,acpi=off,aia=aplic-imsic"
    DEVS=(
        -device "pcie-root-port,id=rp0,bus=pcie.0,chassis=1"
        -device "nvme,drive=nvm0,serial=qsoe,bus=rp0"
    )
else
    # PLIC machine for stock seL4.  NVMe present (the firmware reads its FIT,
    # mr-bml and the kernel off it, polled -- no MSI); the virtio-mmio disk
    # carries QSOE/L's root /usr.
    MACHINE="virt,acpi=off"
    DEVS=(
        -device "nvme,drive=nvm0,serial=qsoe"
        -drive "file=$VIRTIO_IMG,if=none,format=raw,id=vblk0"
        -device "virtio-blk-device,drive=vblk0"
    )
fi

# ---- firmware-specific pieces ---------------------------------------------
if [[ "$firmware" == hfi ]]; then
    if [[ ! -f "$HFI_SPL" || ! -f "$HFI_FIT" ]]; then
        echo "error: the HFI BIOS QEMU target is not built." >&2
        echo "       Expected $HFI_SPL" >&2
        echo "       Build it with:" >&2
        echo "         make -C $HFI_BIOS TARGET=qemu \\" >&2
        echo "              VIDEOBIOS_BLOB=../virtio-gpu-videobios/virtio-gpu-videobios.vbm" >&2
        echo "       (or point HFI_BIOS= at another tree, or use --uefi)" >&2
        exit 1
    fi
    # The SPL reads the FIT (OpenSBI + U-Boot + the BIOS) off the ESP of the
    # disk it boots from -- the same partition mr-bml already lives on, so one
    # disk serves the whole chain and mr-bml's $prefix resolves on it too.
    # Staged here rather than in `make nvme`, because the FIT belongs to the
    # firmware tree and the image must stay bootable without one.
    if [[ ! -f "$BUILD/esp.img" ]]; then
        echo "error: $BUILD/esp.img not found -- run 'make nvme' first" >&2
        exit 1
    fi
    # Done every launch rather than stamped: `make nvme` rebuilds esp.img from
    # scratch, so any stamp would go stale in the one direction that matters
    # and the SPL would find no FIT.  It costs a 16 MiB partition write.
    echo ">>> staging $(basename "$HFI_FIT") onto the image's ESP"
    mcopy -o -i "$BUILD/esp.img" "$HFI_FIT" ::/u-boot.itb
    "$TOP/host_tools/mkgpt.py" --write-part "$NVME_ESP_PART" \
        "$NVME_IMG" "$BUILD/esp.img" $NVME_PARTS
    [[ -f "$HFI_VARS" ]] || {
        echo ">>> creating a ${HFI_VARS_MB} MiB BIOS settings flash at $HFI_VARS"
        # A blank chip is erased, i.e. all ones -- not zeros.
        tr '\000' '\377' < /dev/zero | \
            dd of="$HFI_VARS" bs=1M count=$HFI_VARS_MB iflag=fullblock status=none
        # ...then seed one setting the BIOS has no Set-Up entry for.
        #
        # bios_vidctrl_reserve=Enabled makes the BIOS publish EVERY VideoBIOS
        # claim -- cell array, palette, control block, doorbell, module image
        # -- into the OS device tree as /reserved-memory, instead of only the
        # Controller Handoff Block.  Without it the OS finds the console and
        # then allocates over the memory the console lives in; devc-hficon
        # says so, four times, and is right to.
        #
        # The environment block replaces U-Boot's built-in defaults when it is
        # imported, which is safe here and nowhere near as alarming as it
        # sounds: this firmware boots from its own BIOS front-end
        # (CONFIG_BOOTCOMMAND is empty) and reads only `bios_*` variables,
        # each meaningful when unset.  CONFIG_ENV_IS_IN_FLASH puts the block
        # at CONFIG_ENV_ADDR = 0x22000000, which is the base of this bank, so
        # it goes at offset 0.  Delete the file to get the defaults back.
        "$TOP/host_tools/mkubootenv.py" -o "$BUILD/.hfi-env.bin" \
            --size "$HFI_ENV_SIZE" bios_vidctrl_reserve=Enabled
        dd if="$BUILD/.hfi-env.bin" of="$HFI_VARS" conv=notrunc status=none
        echo ">>> settings flash seeded: bios_vidctrl_reserve=Enabled"
    }
    FIRMWARE_OPTS=(
        -bios "$HFI_SPL"
        -drive "if=pflash,format=raw,unit=1,file=$HFI_VARS"
    )
    # The display the VideoBIOS drives.  Present on both variants: it is the
    # whole point of this chain.
    FIRMWARE_OPTS+=( -device "virtio-gpu-pci" )
    # QEMU virt ships no USB; the BIOS key handlers (DELETE/F11) and QSOE's own
    # devu-xhci both want a keyboard on the emulated machine.
    FIRMWARE_OPTS+=( -device "qemu-xhci" -device "usb-kbd" )
else
    if [[ ! -f "$EDK2_CODE" ]]; then
        echo "error: edk2 firmware not found at $EDK2_CODE" >&2
        echo "       install qemu-efi-riscv64, or set EDK2_CODE=/path/to/CODE.fd" >&2
        exit 1
    fi
    [[ -f "$VARS_RW" ]] || cp "$EDK2_VARS" "$VARS_RW"
    FIRMWARE_OPTS=(
        -drive "if=pflash,unit=0,format=raw,file=$EDK2_CODE,readonly=on"
        -drive "if=pflash,unit=1,format=raw,file=$VARS_RW"
    )
fi

# mr-bml drives its menu over the serial console, so a display is not required
# even on the hfi chain: route serial (and the QEMU monitor) to stdio.
# GRAPHIC=1 opens the window too -- which on the hfi chain is where the
# VideoBIOS console appears, so it is the interesting one.
if [[ "${GRAPHIC:-0}" == "1" ]]; then
    DISPLAY_OPTS=( -serial mon:stdio -display gtk,zoom-to-fit=off )
else
    DISPLAY_OPTS=( -serial mon:stdio -display none )
fi

echo ">>> QSOE/${variant^^} on the ${firmware} chain: $MACHINE, $CPUS harts, $MEM"
if [[ "$firmware" == hfi ]]; then
    if [[ "$variant" == n ]]; then
        other=L; others="$(basename "$0") l"
    else
        other=N; others="$(basename "$0")"
    fi
    echo ">>> mr-bml offers both entries; this machine runs QSOE/${variant^^}."
    echo ">>>   QSOE/$other needs its own machine -- start it with: $others"
fi
set -x
exec "$QEMU" -machine "$MACHINE" -cpu "$QEMU_CPU" -smp "$CPUS" -m "$MEM" -no-reboot \
    "${FIRMWARE_OPTS[@]}" "${NVME[@]}" "${DEVS[@]}" "${DISPLAY_OPTS[@]}"
