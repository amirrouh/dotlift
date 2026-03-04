#!/bin/bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    echo "Usage: sudo $0 <new-config-file>"
    exit 1
fi

NEW_CONF="$1"
LOG="/var/log/wireguard_update.log"

if [[ -z "${NEW_CONF:-}" || ! -f "$NEW_CONF" ]]; then
    echo "Usage: sudo $0 <new-config-file>"
    exit 1
fi

# Find active WireGuard interface
IFACE=$(wg show interfaces | awk '{print $1}')

if [[ -z "$IFACE" ]]; then
    echo "No active WireGuard interface found. Checking /etc/wireguard for configs..."
    CONF_FILE=$(ls /etc/wireguard/*.conf 2>/dev/null | head -1)
    if [[ -z "$CONF_FILE" ]]; then
        echo "No WireGuard config found in /etc/wireguard/"
        exit 1
    fi
    IFACE=$(basename "$CONF_FILE" .conf)
fi

CONF_PATH="/etc/wireguard/${IFACE}.conf"
BACKUP_PATH="${CONF_PATH}.bak.$(date +%Y%m%d%H%M%S)"

# Copy new config to a temp location now (before we lose the shell)
STAGED_CONF=$(mktemp /tmp/wg-staged-XXXXXX.conf)
cp "$NEW_CONF" "$STAGED_CONF"

echo ""
echo "============================================"
echo "  WireGuard Config Update"
echo "============================================"
echo "  Interface:  $IFACE"
echo "  Config:     $CONF_PATH"
echo "  Backup:     $BACKUP_PATH"
echo "  Log:        $LOG"
echo "============================================"
echo ""
echo "WARNING: This will restart WireGuard."
echo "If you are connected via WireGuard, your SSH session WILL drop."
echo "The update will complete in the background regardless."
echo ""
read -rp "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    rm -f "$STAGED_CONF"
    echo "Aborted."
    exit 0
fi

echo ""
echo "Update will begin in 5 seconds. You can safely disconnect now."
echo ""
for i in 5 4 3 2 1; do
    echo "  Starting in ${i}..."
    sleep 1
done
echo ""
echo "Handing off to background process. Check results later with:"
echo "  cat $LOG"
echo ""

# Create log file now while we still have a working shell
touch "$LOG"

# Write the background worker script to a temp file to avoid quoting issues
WORKER=$(mktemp /tmp/wg-worker-XXXXXX.sh)
cat > "$WORKER" <<WORKEREOF
#!/bin/bash
# No set -e: we want this to keep going even if individual steps fail
LOG="$LOG"
IFACE="$IFACE"
CONF_PATH="$CONF_PATH"
BACKUP_PATH="$BACKUP_PATH"
STAGED_CONF="$STAGED_CONF"

{
    echo '========================================='
    echo "WireGuard update started at \$(date)"
    echo "Interface: \$IFACE"
    echo '========================================='

    # Grace period for SSH to finish flushing output
    sleep 3

    echo "Stopping wg-quick@\${IFACE}..."
    wg-quick down "\$IFACE" 2>/dev/null || systemctl stop "wg-quick@\${IFACE}" 2>/dev/null || true

    echo "Backing up to \$BACKUP_PATH"
    cp "\$CONF_PATH" "\$BACKUP_PATH"

    echo "Installing new config..."
    cp "\$STAGED_CONF" "\$CONF_PATH"
    chmod 600 "\$CONF_PATH"
    rm -f "\$STAGED_CONF"

    echo "Starting wg-quick@\${IFACE}..."
    wg-quick up "\$IFACE" 2>/dev/null || systemctl start "wg-quick@\${IFACE}"

    echo ""
    echo "Status after update:"
    wg show "\$IFACE"
    echo ""
    echo "Completed successfully at \$(date)"
    echo '========================================='
} >> "\$LOG" 2>&1

# Clean up worker script
rm -f "\$0"
WORKEREOF
chmod +x "$WORKER"

# Run detached from terminal and SSH session
nohup "$WORKER" &>/dev/null &
disown
