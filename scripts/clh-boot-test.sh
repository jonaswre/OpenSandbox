#!/usr/bin/env bash
# Copyright 2026 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License")
# ...
#
# Quick CLH boot test — no sudo, no networking.
# Validates: kernel boots → root mounts → OpenRC starts → execd launches.
#
# Usage: ./scripts/clh-boot-test.sh
set -euo pipefail

WORK_DIR="/tmp/opensandbox-clh-e2e"
OVERLAY="/tmp/clh-boot-test-overlay.qcow2"
SERIAL="/tmp/clh-boot-test.log"
TIMEOUT=30

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[BOOT-TEST]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
fail() { echo -e "${RED}[ FAIL ]${NC} $*"; exit 1; }

# Prerequisites
[[ -x /usr/local/bin/cloud-hypervisor ]] || fail "cloud-hypervisor not installed"
[[ -f "${WORK_DIR}/images/vmlinuz-lts" ]]     || fail "Kernel not found. Run ./scripts/clh-e2e-setup.sh --setup first"
[[ -f "${WORK_DIR}/images/initramfs-lts" ]]   || fail "Initrd not found"
[[ -f "${WORK_DIR}/images/alpine-test.qcow2" ]] || fail "Disk image not found"
[[ -r /dev/kvm ]] || fail "/dev/kvm not readable"

# COW overlay so base image stays clean
rm -f "$OVERLAY" "$SERIAL"
qemu-img create -f qcow2 -b "${WORK_DIR}/images/alpine-test.qcow2" -F qcow2 "$OVERLAY" >/dev/null 2>&1

log "Booting Alpine VM (no network, ${TIMEOUT}s timeout)..."

/usr/local/bin/cloud-hypervisor \
  --kernel "${WORK_DIR}/images/vmlinuz-lts" \
  --initramfs "${WORK_DIR}/images/initramfs-lts" \
  --cmdline "console=ttyS0 root=/dev/vda rootfstype=ext4 modules=virtio_pci,virtio_blk,ext4 rw" \
  --disk "path=${OVERLAY}" \
  --cpus boot=1 \
  --memory size=1024M \
  --serial "file=${SERIAL}" \
  --console off &
CLH_PID=$!

ROOT_MOUNTED=false
OPENRC_STARTED=false
EXECD_STARTED=false

for i in $(seq 1 "$TIMEOUT"); do
    sleep 1
    if ! kill -0 "$CLH_PID" 2>/dev/null; then
        log "CLH exited at ${i}s"
        break
    fi
    [[ -f "$SERIAL" ]] || continue

    if ! $ROOT_MOUNTED && grep -q "Mounting root: ok" "$SERIAL" 2>/dev/null; then
        ROOT_MOUNTED=true
        ok "Root mounted  (${i}s)"
    fi
    if ! $OPENRC_STARTED && grep -q "OpenRC.*is starting up" "$SERIAL" 2>/dev/null; then
        OPENRC_STARTED=true
        ok "OpenRC init   (${i}s)"
    fi
    if ! $EXECD_STARTED && grep -q "Starting execd" "$SERIAL" 2>/dev/null; then
        EXECD_STARTED=true
        ok "execd started (${i}s)"
        break
    fi
done

kill "$CLH_PID" 2>/dev/null; wait "$CLH_PID" 2>/dev/null
rm -f "$OVERLAY"

echo ""
PASS=true
$ROOT_MOUNTED   || { echo -e "${RED}FAIL${NC} root mount";   PASS=false; }
$OPENRC_STARTED || { echo -e "${RED}FAIL${NC} openrc init";  PASS=false; }
$EXECD_STARTED  || { echo -e "${RED}FAIL${NC} execd start";  PASS=false; }

if $PASS; then
    echo -e "${GREEN}ALL PASS — CLH boot pipeline verified.${NC}"
else
    echo ""
    echo "Serial log: $SERIAL"
    tail -20 "$SERIAL"
    exit 1
fi
