#!/bin/bash
# check-vm.sh — Validate zstdfs kext loading prerequisites on the VM.
# Usage: ./scripts/check-vm.sh [user@host]  (default: agent@192.168.64.5)

HOST="${1:-agent@192.168.64.5}"
BUNDLE_ID="com.zstdfs.DecmpfsZstd"
KEXT_PATH="/Library/Extensions/DecmpfsZstd.kext"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
ok()   { printf "  ${GRN}✓${NC}  %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC}  %s\n" "$*"; }
warn() { printf "  ${YEL}!${NC}  %s\n" "$*"; }

vmrun() {
    sshpass -p sandbox ssh -q \
        -o StrictHostKeyChecking=no \
        -o IdentitiesOnly=yes \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password \
        -o ConnectTimeout=10 \
        "$HOST" "$@" 2>/dev/null
}

printf "\n=== zstdfs-mac-kext VM check (%s) ===\n\n" "$HOST"

# ── 1. Connectivity ──────────────────────────────────────────────────────────
echo "[1] Connectivity"
if vmrun "true"; then
    ok "SSH reachable"
else
    fail "Cannot reach $HOST — is the VM running?"; exit 1
fi
echo ""

# ── 2. Security Policy in LocalPolicy (smb bits + auxi) ─────────────────────
echo "[2] Security Policy (LocalPolicy IMG4)"
LP=$(vmrun "ls /System/Volumes/iSCPreboot/*/LocalPolicy/*.img4 2>/dev/null | head -1" || true)
if [[ -z "$LP" ]]; then
    fail "No LocalPolicy img4 found"
else
    TAGS=$(vmrun "strings \"$LP\" 2>/dev/null | tr '\n' ','")
    grep_tag() { echo "$TAGS" | grep -c "$1" 2>/dev/null || echo 0; }
    smb2=$(grep_tag "smb2"); smb1=$(grep_tag "smb1"); auxi=$(grep_tag "auxi")
    [[ $smb2 -gt 0 ]] && ok "smb2=1  Permissive Security — kexts allowed via AuxKC" \
        || { [[ $smb1 -gt 0 ]] \
            && warn "smb1=1 only  Reduced Security — kexts need user approval (no smb2)" \
            || fail "No smb1/smb2  Full Security — third-party kexts blocked"; }
    [[ "${auxi:-0}" -gt 0 ]] && ok "auxi present  AuxKC registered in LocalPolicy" \
        || fail "auxi absent   AuxKC not built/registered — kext won't load at boot"
fi
echo ""

# ── 3. SIP ────────────────────────────────────────────────────────────────────
echo "[3] SIP (csrutil)"
SIP=$(vmrun "csrutil status 2>/dev/null" || echo "unknown")
if echo "$SIP" | grep -q "disabled"; then
    ok "SIP disabled  security bypass boot-args will work; ad-hoc signing accepted"
else
    warn "SIP enabled   AuxKC flow still works with proper signing; boot-arg bypasses stripped by iBoot"
fi
echo ""

# ── 4. Kernel boot args ───────────────────────────────────────────────────────
echo "[4] Kernel boot args (kern.bootargs)"
KARGS=$(vmrun "sysctl -n kern.bootargs 2>/dev/null" || echo "")
if [[ -z "$KARGS" ]]; then
    warn "kern.bootargs empty  iBoot is stripping security boot-args (expected with SIP on)"
else
    ok "kern.bootargs: $KARGS"
    echo "$KARGS" | grep -q "amfi_get_out_of_my_way" \
        && ok "  amfi_get_out_of_my_way=1 active" \
        || warn "  amfi_get_out_of_my_way=1 NOT active"
fi
NVRAM_ARGS=$(vmrun "nvram boot-args 2>/dev/null | cut -f2" || echo "")
[[ -n "$NVRAM_ARGS" ]] && ok "NVRAM boot-args: $NVRAM_ARGS" || warn "NVRAM boot-args: (empty)"
echo ""

# ── 5. Kext signature ────────────────────────────────────────────────────────
echo "[5] Kext code signature"
if vmrun "test -d \"$KEXT_PATH\""; then
    ok "Bundle present: $KEXT_PATH"
    SIGLINE=$(vmrun "codesign -d --verbose=1 \"$KEXT_PATH\" 2>&1 | grep 'flags='" || echo "")
    if echo "$SIGLINE" | grep -q "adhoc"; then
        fail "Ad-hoc signed  AMFI rejects com.apple.* bundle ID + ad-hoc when SIP is on"
        warn "  Fix options:"
        warn "    A) Sign with Developer ID certificate"
        warn "    B) Change bundle ID to non-apple prefix (e.g. com.zstdfs.DecmpfsZstd)"
        warn "    C) Disable SIP via Recovery Mode (then ad-hoc works)"
    elif echo "$SIGLINE" | grep -qE "0x0\(none\)|none"; then
        fail "Unsigned"
    elif [[ -z "$SIGLINE" ]]; then
        warn "Could not read signature"
    else
        ok "Signature: $SIGLINE"
    fi
else
    fail "Kext not found at $KEXT_PATH"
fi
echo ""

# ── 6. kmutil diagnostics ────────────────────────────────────────────────────
echo "[6] kmutil print-diagnostics"
DIAG=$(vmrun "kmutil print-diagnostics --bundle-path \"$KEXT_PATH\" 2>&1" || echo "failed to run")
if echo "$DIAG" | grep -qiE "error|fail|bad"; then
    FIRSTERR=$(echo "$DIAG" | grep -iE "error|fail|bad" | head -2)
    fail "$FIRSTERR"
else
    ok "No errors"
fi
echo ""

# ── 7. KextPolicy user approval ──────────────────────────────────────────────
echo "[7] KextPolicy user approval"
DB="/private/var/db/SystemPolicyConfiguration/KextPolicy"
APPROVED=$(vmrun "sudo sqlite3 $DB \"SELECT bundle_id FROM kext_policy WHERE bundle_id='$BUNDLE_ID';\" 2>/dev/null" || echo "")
if [[ -z "$APPROVED" ]]; then
    APPROVED=$(vmrun "sudo sqlite3 $DB \"SELECT bundle_id FROM kext_policy_mdm WHERE bundle_id='$BUNDLE_ID';\" 2>/dev/null" || echo "")
fi
if [[ "$APPROVED" == "$BUNDLE_ID" ]]; then
    ok "Approved in KextPolicy"
else
    fail "Not approved in KextPolicy — kmutil load won't trigger AuxKC build"
    warn "  Run: sudo kmutil load --bundle-path $KEXT_PATH   (accept the prompt in System Settings)"
fi
echo ""

# ── 8. AuxKC file ────────────────────────────────────────────────────────────
echo "[8] AuxKC in Preboot"
UUID=$(vmrun "ls /System/Volumes/Preboot/ 2>/dev/null | grep -E '^[0-9A-F-]{36}$' | head -1" || echo "")
AUXKC="/System/Volumes/Preboot/${UUID}/System/Library/KernelCollections/AuxKernelExtensions.kc"
SZ=$(vmrun "ls -lh \"$AUXKC\" 2>/dev/null | awk '{print \$5}'" || echo "")
if [[ -n "$SZ" ]]; then
    ok "AuxKC present ($SZ): $AUXKC"
    IN_AUXKC=$(vmrun "kmutil inspect -v --collection \"$AUXKC\" 2>/dev/null | grep -c \"$BUNDLE_ID\"" || echo "0")
    [[ "${IN_AUXKC:-0}" -gt 0 ]] && ok "Our kext is in AuxKC" \
        || warn "AuxKC exists but our kext not in it — needs rebuild"
else
    fail "AuxKC not found at preboot path"
fi
echo ""

# ── 9. Loaded in kernel ───────────────────────────────────────────────────────
echo "[9] Loaded in kernel"
LOADED=$(vmrun "kextstat 2>/dev/null | grep \"$BUNDLE_ID\"" || echo "")
[[ -n "$LOADED" ]] && ok "LOADED: $LOADED" || fail "Not loaded (kextstat: nothing for $BUNDLE_ID)"
echo ""

# ── 10. Stale kcgen experiment state ─────────────────────────────────────────
echo "[10] Stale kcgen experiment state"
OSE=$(vmrun "nvram osenvironment 2>/dev/null | cut -f2" || echo "")
[[ "$OSE" == "kcgen" ]] \
    && warn "osenvironment=kcgen still set  clear with: sudo nvram -d osenvironment" \
    || ok "osenvironment NVRAM: clean"
BOOTARGS=$(vmrun "nvram boot-args 2>/dev/null | cut -f2" || echo "")
echo "$BOOTARGS" | grep -q "osenvironment=kcgen" \
    && warn "osenvironment=kcgen in boot-args  clean with: sudo nvram boot-args=\"\$(nvram boot-args | cut -f2 | sed 's/ osenvironment=kcgen//')\"" \
    || ok "boot-args: no stale osenvironment"
WRAPPER=$(vmrun "test -f /Library/LaunchDaemons/com.aaa.kcgend-wrapper.plist && echo yes || echo no" || echo no)
[[ "$WRAPPER" == "yes" ]] \
    && warn "Stale kcgend-wrapper plist present  remove: sudo rm /Library/LaunchDaemons/com.aaa.kcgend-wrapper.plist" \
    || ok "kcgend-wrapper LaunchDaemon: gone"
KCGEND_DISABLED=$(vmrun "launchctl print-disabled system 2>/dev/null | grep 'com.apple.kcgend.*disabled' | wc -l | tr -d ' '" || echo 0)
[[ "${KCGEND_DISABLED:-0}" -ge 1 ]] \
    && warn "Real kcgend is disabled  re-enable: sudo launchctl enable system/com.apple.kcgend" \
    || ok "com.apple.kcgend: enabled"
echo ""

printf "=== done ===\n"
