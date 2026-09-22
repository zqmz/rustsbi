#!/usr/bin/env bash
#
# Boot a minimal Linux userspace through U-Boot on RustSBI Prototyper in QEMU.
#
# The boot chain is QEMU -> u-boot-spl (with RustSBI Prototyper embedded as the
# OpenSBI payload) -> RustSBI -> u-boot.itb (U-Boot proper) -> Linux kernel ->
# busybox init -> /etc/init.d/rcS. U-Boot loads the kernel off an ext4 partition
# with `ext4load` and starts it with `booti`, matching the repository guide
# `firmware/docs/booting-linux-kernel-in-qemu-using-uboot-and-rustsbi.md`.
#
# Linux and BusyBox are built from checksum-pinned release archives and only
# their build *products* are cached. The U-Boot build is never cached: the SPL
# embeds the RustSBI firmware, so it must be rebuilt from the commit under test
# every run. RustSBI itself is rebuilt from the commit under test and is never
# cached.
#
# Requires: `cargo prototyper build` to have produced the firmware, plus
# qemu-system-riscv64, riscv64-linux-gnu-gcc, swig, python3-dev, parted,
# e2fsprogs, qemu-utils, xz and a host toolchain.

set -euo pipefail

readonly KERNEL_VERSION="6.12.110"
readonly KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
readonly KERNEL_SHA256="8cee19e1839bb6ff4d5254d761933ae6ab670492d5ed030e09a80538320d5c4c"

readonly BUSYBOX_VERSION="1.36.1"
readonly BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
readonly BUSYBOX_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"

readonly UB_VERSION="2024.04"
readonly UB_URL="https://github.com/u-boot/u-boot/archive/refs/tags/v${UB_VERSION}.tar.gz"
readonly UB_SHA256="d6b57ce574a0a0504a5b6596644ceacb7f77bde9353779bcf2fde07c4b9a2b92"

readonly CROSS_COMPILE="riscv64-linux-gnu-"
readonly SMOKE_MARKER="RUSTSBI-SMOKE-OK"

# Text that means the boot already went wrong. A panic halts the machine while
# QEMU stays alive, so without this the job would sit out the whole timeout and
# then report only that the marker never appeared.
readonly BOOT_FAILURE_PATTERN="Kernel panic|not syncing|Attempted to kill init"

readonly CACHE_DIR="${MINIMAL_LINUX_UBOOT_CACHE_DIR:-.cache/minimal-linux-uboot}"
readonly WORK_DIR="${MINIMAL_LINUX_UBOOT_WORK_DIR:-.minimal-linux-uboot/work}"
readonly RUSTSBI="${MINIMAL_LINUX_UBOOT_RUSTSBI:-target/riscv64gc-unknown-none-elf/release/rustsbi-prototyper.bin}"
readonly LOG_DIR="${QEMU_LOG_DIR:-qemu-logs}"
readonly LOG_FILE="${LOG_DIR}/prototyper-minimal-linux-uboot.log"

readonly KERNEL_IMAGE="${CACHE_DIR}/linux-${KERNEL_VERSION}-Image"
readonly BUSYBOX_INSTALL="${CACHE_DIR}/busybox-${BUSYBOX_VERSION}-install"
readonly DISK_IMAGE="${WORK_DIR}/linux-rootfs.img"

# Populated by build_uboot; kept as mutable globals because the tree lives
# under WORK_DIR and is rebuilt every run.
UB_SPL=""
UB_ITB=""

readonly BOOT_TIMEOUT_SECS="${MINIMAL_LINUX_UBOOT_BOOT_TIMEOUT_SECS:-240}"
readonly DOWNLOAD_CONNECT_TIMEOUT_SECS="${MINIMAL_LINUX_UBOOT_DOWNLOAD_CONNECT_TIMEOUT_SECS:-30}"
readonly DOWNLOAD_TIMEOUT_SECS="${MINIMAL_LINUX_UBOOT_DOWNLOAD_TIMEOUT_SECS:-900}"

QEMU_PID=""

# Fetch a pinned archive, verifying its digest on every run so a corrupted or
# substituted download fails the job instead of silently changing the test.
download_asset() {
  local url=$1
  local destination=$2
  local digest=$3
  local temp

  if [[ -f "$destination" ]] && printf '%s  %s\n' "$digest" "$destination" | sha256sum --check --status; then
    echo "Using cached $(basename "$destination")" >&2
    return
  fi

  echo "Downloading $url" >&2
  mkdir -p "$(dirname "$destination")"
  temp=$(mktemp "${destination}.part.XXXXXX")

  if ! curl --fail --location \
    --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT_SECS" \
    --max-time "$DOWNLOAD_TIMEOUT_SECS" \
    --retry 3 \
    --retry-all-errors \
    --retry-max-time "$DOWNLOAD_TIMEOUT_SECS" \
    --output "$temp" \
    "$url"; then
    rm -f "$temp"
    return 1
  fi

  if ! printf '%s  %s\n' "$digest" "$temp" | sha256sum --check --status; then
    echo "Checksum mismatch for $url" >&2
    rm -f "$temp"
    return 1
  fi

  mv "$temp" "$destination"
}

# `make Image` stops short of modules and device trees. The U-Boot path boots
# off an ext4 partition on a virtio block device, so the kernel must have those
# drivers built in (not as modules, since `Image` ships no modules).
prepare_kernel() {
  local tarball="${WORK_DIR}/linux-${KERNEL_VERSION}.tar.xz"
  local tree="${WORK_DIR}/linux-${KERNEL_VERSION}"
  local option

  if [[ -s "$KERNEL_IMAGE" ]]; then
    echo "Using cached Linux ${KERNEL_VERSION} kernel image" >&2
    return
  fi

  mkdir -p "$WORK_DIR" "$CACHE_DIR"
  download_asset "$KERNEL_URL" "$tarball" "$KERNEL_SHA256"

  rm -rf "$tree"
  tar -xJf "$tarball" -C "$WORK_DIR"
  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" defconfig

  # The riscv defconfig is expected to carry everything this boot needs, so
  # check it rather than trust it: if a defconfig revision drops one of these,
  # the job should say which option went missing instead of booting into an
  # unexplained silence.
  for option in EXT4_FS VIRTIO_BLK VIRTIO_PCI SERIAL_8250_CONSOLE DEVTMPFS; do
    if [[ $("${tree}/scripts/config" --file "${tree}/.config" --state "$option") != y ]]; then
      echo "riscv defconfig no longer enables ${option}" >&2
      return 1
    fi
  done

  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" Image

  cp "${tree}/arch/riscv/boot/Image" "$KERNEL_IMAGE"
}

# BusyBox is linked statically because the root filesystem carries no shared
# libraries. `make install` lays out the applet symlinks under _install, which
# is what gets cached.
prepare_busybox() {
  local tarball="${WORK_DIR}/busybox-${BUSYBOX_VERSION}.tar.bz2"
  local tree="${WORK_DIR}/busybox-${BUSYBOX_VERSION}"

  if [[ -x "${BUSYBOX_INSTALL}/bin/busybox" ]]; then
    echo "Using cached BusyBox ${BUSYBOX_VERSION} installation" >&2
    return
  fi

  mkdir -p "$WORK_DIR" "$CACHE_DIR"
  download_asset "$BUSYBOX_URL" "$tarball" "$BUSYBOX_SHA256"

  rm -rf "$tree"
  tar -xjf "$tarball" -C "$WORK_DIR"
  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" defconfig

  # Settings -> Build Options -> Build static binary (no shared libs). defconfig
  # leaves CONFIG_STATIC unset; the build reads .config directly, so flipping
  # the line is enough and no oldconfig pass is needed.
  sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' "${tree}/.config"
  grep -q '^CONFIG_STATIC=y' "${tree}/.config" || echo 'CONFIG_STATIC=y' >>"${tree}/.config"

  # `tc` still uses the CBQ scheduler constants, which Linux 6.8 dropped from
  # its UAPI headers, so the applet no longer compiles against a current
  # toolchain (busybox 1.37.0 is affected too). An initramfs smoke test has no
  # use for traffic control, so drop the applet rather than pin old headers.
  sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' "${tree}/.config"
  grep -q '^# CONFIG_TC is not set$' "${tree}/.config" || echo '# CONFIG_TC is not set' >>"${tree}/.config"

  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" install

  rm -rf "$BUSYBOX_INSTALL"
  cp -a "${tree}/_install" "$BUSYBOX_INSTALL"
}

# Build a 1GiB GPT-partitioned disk image whose first (ext4) partition holds
# the kernel image and the BusyBox root filesystem. The image is rebuilt every
# run so edits to rcS cannot go stale in a cache.
make_rootfs_image() {
  local rootfs="${WORK_DIR}/rootfs"
  local loop part start end size

  rm -rf "$rootfs" "$DISK_IMAGE"
  mkdir -p "$WORK_DIR"

  qemu-img create -q "$DISK_IMAGE" 1g
  parted -s "$DISK_IMAGE" mklabel gpt
  parted -s "$DISK_IMAGE" mkpart primary ext4 1MiB 100%
  parted -s "$DISK_IMAGE" set 1 boot on

  # Read the exact byte range of partition 1. The sizelimit must match the
  # partition exactly: if mkfs runs over a loop device that reaches the end of
  # the file, it overwrites the backup GPT header and the kernel later rejects
  # the filesystem as having bad geometry. Using offset+sizelimit also avoids
  # needing /dev/loopNpM partition nodes, which udev-less containers lack.
  part=$(parted -s "$DISK_IMAGE" unit B print | awk '/^ 1 /{print $2, $3}')
  start=$(echo "$part" | awk '{gsub(/B/,"",$1); print $1}')
  end=$(echo "$part" | awk '{gsub(/B/,"",$2); print $2}')
  size=$((end - start + 1))

  loop=$(priv losetup --find --show --offset "$start" --sizelimit "$size" "$DISK_IMAGE")
  priv mkfs.ext4 -q "$loop"

  mkdir -p "$rootfs"
  priv mount "$loop" "$rootfs"

  cp "$KERNEL_IMAGE" "$rootfs/Image"
  cp -a "${BUSYBOX_INSTALL}/." "$rootfs/"
  mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/etc/init.d"

  # busybox init runs /etc/init.d/rcS. The assertions make the marker mean
  # something specific: a riscv64 kernel reached userspace and mounted a
  # working /proc, not merely that some shell ran.
  cat >"$rootfs/etc/init.d/rcS" <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
/sbin/mdev -s
set -e
[ "$(uname -m)" = riscv64 ]
[ -r /proc/version ]
echo "RUSTSBI-SMOKE-OK"
EOF
  chmod +x "$rootfs/etc/init.d/rcS"

  priv umount "$rootfs"
  priv losetup -d "$loop"
  rmdir "$rootfs"
}

# Build U-Boot with the RustSBI firmware embedded as the OpenSBI payload. The
# build products are deliberately not cached: the SPL embeds the firmware, so
# they must be rebuilt from the commit under test every run.
build_uboot() {
  local tarball="${WORK_DIR}/u-boot-${UB_VERSION}.tar.gz"
  local tree="${WORK_DIR}/u-boot-${UB_VERSION}"

  mkdir -p "$WORK_DIR"
  download_asset "$UB_URL" "$tarball" "$UB_SHA256"

  rm -rf "$tree"
  tar -xzf "$tarball" -C "$WORK_DIR"

  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" \
    OPENSBI="$RUSTSBI" qemu-riscv64_spl_defconfig

  # Set the default boot command non-interactively, equivalent to the
  # menuconfig step in the repository guide. The single quotes keep
  # ${fdtcontroladdr} literal so U-Boot expands it at runtime.
  "${tree}/scripts/config" --file "${tree}/.config" --enable USE_BOOTCOMMAND
  # shellcheck disable=SC2016
  "${tree}/scripts/config" --file "${tree}/.config" --set-str BOOTCOMMAND \
    'ext4load virtio 0:1 84000000 Image; setenv bootargs root=/dev/vda1 rw console=ttyS0; booti 0x84000000 - ${fdtcontroladdr}'

  make -C "$tree" ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" \
    OPENSBI="$RUSTSBI" -j"$(nproc)"

  UB_SPL="${tree}/spl/u-boot-spl"
  UB_ITB="${tree}/u-boot.itb"
}

# Run a command with elevated privileges when running as a non-root user (CI
# runners) while staying a plain call inside a root container (local Docker).
priv() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

check_prerequisites() {
  test -s "$RUSTSBI" || {
    echo "Missing $RUSTSBI; run 'cargo prototyper build' first" >&2
    return 1
  }
  qemu-system-riscv64 --version
}

stop_qemu() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}

cleanup() {
  stop_qemu
}

start_qemu() {
  mkdir -p "$LOG_DIR"
  qemu-system-riscv64 \
    -machine virt \
    -smp 1 \
    -m 256M \
    -nographic \
    -no-reboot \
    -bios "$UB_SPL" \
    -device loader,file="$UB_ITB",addr=0x80200000 \
    -blockdev driver=file,filename="$DISK_IMAGE",node-name=hd0 \
    -device virtio-blk-device,drive=hd0 \
    >"$LOG_FILE" 2>&1 &
  QEMU_PID=$!
}

userspace_is_ready() {
  grep -Fq "$SMOKE_MARKER" "$LOG_FILE"
}

boot_has_failed() {
  grep -Eq "$BOOT_FAILURE_PATTERN" "$LOG_FILE"
}

report_boot_failure() {
  echo "Linux failed to boot:" >&2
  grep -E --max-count=5 "$BOOT_FAILURE_PATTERN" "$LOG_FILE" >&2 || true
  tail -n 120 "$LOG_FILE" || true
}

report_early_exit() {
  local qemu_exit
  set +e
  wait "$QEMU_PID"
  qemu_exit=$?
  set -e

  echo "QEMU exited before Linux reached userspace (exit=${qemu_exit})" >&2
  tail -n 120 "$LOG_FILE" || true
}

wait_for_userspace() {
  local elapsed
  for ((elapsed = 0; elapsed < BOOT_TIMEOUT_SECS; elapsed++)); do
    # The marker is checked first so a boot that succeeds just before a late
    # panic is still reported as the success it was.
    if userspace_is_ready; then
      return 0
    fi
    if boot_has_failed; then
      report_boot_failure
      return 1
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      # QEMU may have printed the marker and powered off since our last read.
      if userspace_is_ready; then
        return 0
      fi
      report_early_exit
      return 1
    fi
    sleep 1
  done

  # Check once more after the final sleep, including the timeout boundary.
  if userspace_is_ready; then
    return 0
  fi

  echo "Linux did not reach userspace within ${BOOT_TIMEOUT_SECS}s" >&2
  tail -n 120 "$LOG_FILE" || true
  return 1
}

main() {
  trap cleanup EXIT

  check_prerequisites
  prepare_kernel
  prepare_busybox
  make_rootfs_image
  build_uboot
  start_qemu
  wait_for_userspace

  echo "RustSBI booted Linux ${KERNEL_VERSION} via U-Boot to userspace successfully"
  echo "QEMU log: ${LOG_FILE}"
}

main "$@"
