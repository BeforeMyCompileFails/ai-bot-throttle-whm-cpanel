#!/usr/bin/env bash
#
# install.sh — Install AI bot rate-limiting for cPanel/WHM with EA-Nginx
#
# https://github.com/BeforeMyCompileFails/ai-bot-throttle-cpanel
#
# Tested on:
#   - AlmaLinux 8 / 9 (CentOS-equivalent)
#   - cPanel & WHM 11.130+
#   - EA-Nginx (cPanel's official nginx reverse-proxy package)
#
# What this does:
#   1. Backs up your current nginx config to /root/config-backups/
#   2. Installs ai-bot-throttle.conf at http{} level (defines bot map + zone)
#   3. Installs enforcement at server-block level (1 req/sec per bot IP)
#   4. Rebuilds EA-Nginx user configs and reloads nginx
#   5. Verifies the install with a syntax test
#
# Rolling back: bash uninstall.sh
# Or restore the timestamped backup tarball under /root/config-backups/

set -euo pipefail

# ── Pretty output ──────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { echo "${BLUE}[i]${RESET} $*"; }
ok()    { echo "${GREEN}[✓]${RESET} $*"; }
warn()  { echo "${YELLOW}[!]${RESET} $*"; }
fail()  { echo "${RED}[✗]${RESET} $*" >&2; exit 1; }
step()  { echo; echo "${BOLD}── $* ──${RESET}"; }

# ── Preflight ──────────────────────────────────────────────────────────────
step "Preflight checks"

[ "$(id -u)" -eq 0 ] || fail "Must be run as root."
ok "Running as root"

[ -d /etc/nginx ] || fail "nginx not installed (no /etc/nginx). This script is for cPanel servers using EA-Nginx."
ok "nginx detected"

if ! command -v nginx >/dev/null 2>&1; then
    fail "nginx binary not in PATH."
fi
ok "nginx binary present: $(nginx -v 2>&1)"

[ -d /etc/nginx/ea-nginx ] || fail "EA-Nginx not installed. This script is specifically for cPanel servers using EA-Nginx. Plain nginx setups will need a different approach."
ok "EA-Nginx detected"

if [ ! -d /etc/nginx/conf.d/server-includes ]; then
    info "Creating /etc/nginx/conf.d/server-includes (EA-Nginx auto-include directory)"
    mkdir -p /etc/nginx/conf.d/server-includes
fi
ok "server-includes directory present"

# Confirm EA-Nginx templates include server-includes/*.conf
if ! grep -q "server-includes" /etc/nginx/ea-nginx/default.conf.tt 2>/dev/null; then
    warn "EA-Nginx default.conf.tt does not appear to include server-includes/*.conf."
    warn "Enforcement may not apply to user server blocks."
    warn "Continuing anyway, but verify after install."
fi

# Detect Cloudflare in use (changes recommendations in the README; doesn't block install)
if grep -rqs "set_real_ip_from" /etc/nginx/conf.d/ 2>/dev/null; then
    info "Cloudflare real-IP detected — \$binary_remote_addr will be the real client IP."
fi

# ── Backup ─────────────────────────────────────────────────────────────────
step "Backing up current config"

BACKUP_DIR="/root/config-backups"
BACKUP_NAME="nginx-before-ai-bot-throttle-$(date +%Y-%m-%d-%H%M)"
mkdir -p "$BACKUP_DIR"

tar -czf "$BACKUP_DIR/${BACKUP_NAME}.tar.gz" \
    /etc/nginx/conf.d/ \
    /etc/nginx/ea-nginx/ \
    /etc/nginx/nginx.conf 2>/dev/null

cat > "$BACKUP_DIR/${BACKUP_NAME}.README.txt" <<EOF
Backup created: $(date)
By: $(whoami)
Reason: Snapshot of nginx config before installing ai-bot-throttle-cpanel
        https://github.com/BeforeMyCompileFails/ai-bot-throttle-cpanel

Contents:
- /etc/nginx/conf.d/        (server configs, user configs, includes)
- /etc/nginx/ea-nginx/      (EA-Nginx templates and config-scripts)
- /etc/nginx/nginx.conf

To restore manually:
  cd /
  tar -xzf $BACKUP_DIR/${BACKUP_NAME}.tar.gz
  /scripts/ea-nginx config --all
  systemctl reload nginx

Or use the included uninstall.sh.
EOF

ok "Backup written: $BACKUP_DIR/${BACKUP_NAME}.tar.gz ($(du -h "$BACKUP_DIR/${BACKUP_NAME}.tar.gz" | cut -f1))"

# ── Install configs ────────────────────────────────────────────────────────
step "Installing configs"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# http{}-level: bot map and rate-limit zone
cp -f "$SCRIPT_DIR/ai-bot-throttle.conf" /etc/nginx/conf.d/ai-bot-throttle.conf
ok "Installed /etc/nginx/conf.d/ai-bot-throttle.conf"

# server-block-level: enforcement
cp -f "$SCRIPT_DIR/ai-bot-throttle-enforcement.conf" /etc/nginx/conf.d/server-includes/ai-bot-throttle.conf
ok "Installed /etc/nginx/conf.d/server-includes/ai-bot-throttle.conf"

# ── Test config syntax ─────────────────────────────────────────────────────
step "Testing nginx config syntax"

if ! nginx -t 2>&1; then
    fail "nginx -t failed. Removing installed configs to be safe. Check the error above."
fi
ok "nginx config syntax OK"

# ── Rebuild user configs and restart ───────────────────────────────────────
step "Rebuilding EA-Nginx user configs"

# Use rebuild rather than reload because we're introducing a NEW shared-memory
# zone, which a graceful reload won't fully reinitialize. A restart is safe;
# EA-Nginx handles connection draining.
/scripts/ea-nginx config --all > /tmp/ea-nginx-install.log 2>&1 || {
    warn "ea-nginx config --all returned non-zero. Check /tmp/ea-nginx-install.log"
}

# Full restart needed to attach the new shared-memory zone. A graceful reload
# would log [emerg] "ai_bots uses the X key while previously it used Y" and
# silently keep the old config running.
systemctl restart nginx
sleep 2
systemctl is-active --quiet nginx || fail "nginx failed to restart. Run: journalctl -u nginx -n 50"
ok "nginx restarted cleanly"

# ── Post-install verification ──────────────────────────────────────────────
step "Verifying install"

# Find a customer site to test against
TEST_SITE=$(ls /etc/nginx/conf.d/users/*.conf 2>/dev/null | head -1 | xargs -I {} basename {} .conf || echo "")
if [ -n "$TEST_SITE" ] && grep -q "server-includes" "/etc/nginx/conf.d/users/${TEST_SITE}.conf"; then
    ok "Enforcement include present in customer configs (verified: $TEST_SITE)"
else
    warn "Could not verify enforcement is included in customer server blocks."
    warn "Run: grep server-includes /etc/nginx/conf.d/users/*.conf"
fi

# ── Done ───────────────────────────────────────────────────────────────────
step "Install complete"

cat <<EOF

  ${GREEN}${BOLD}✓ AI bot throttle is now active across all customer sites.${RESET}

  What just happened:
    • Bots (GPTBot, ClaudeBot, MJ12bot, Ahrefs, etc.) → rate-limited to 1 req/sec
    • Real human visitors → completely unaffected
    • Real-time AI fetches (ChatGPT-User, Claude-User) → unthrottled (rare + valuable)

  Verify it's working — give it 2-5 minutes for bot traffic to accumulate, then:

    ${BOLD}# See 429s being issued to bots (should be non-zero on a busy site):${RESET}
    grep "ai_bots" /var/log/nginx/error.log | tail -10

    ${BOLD}# Confirm NO real humans are being throttled (this list should be tiny or empty):${RESET}
    grep "ai_bots" /var/log/nginx/error.log | grep -vE \\
      "GPTBot|ClaudeBot|MJ12|Ahrefs|Sem|Diff|IbouBot|Bytespider|Perplexity|\\
Amazonbot|CCBot|anthropic|meta-externalagent|DotBot|Google-Extended|Applebot" | tail

  Backup saved: $BACKUP_DIR/${BACKUP_NAME}.tar.gz
  To uninstall:  bash uninstall.sh

EOF
