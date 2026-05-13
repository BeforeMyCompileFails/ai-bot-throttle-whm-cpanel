#!/usr/bin/env bash
#
# uninstall.sh — Remove AI bot rate-limiting cleanly
#
# https://github.com/BeforeMyCompileFails/ai-bot-throttle-whm-cpanel
#
# This removes:
#   /etc/nginx/conf.d/ai-bot-throttle.conf
#   /etc/nginx/conf.d/server-includes/ai-bot-throttle.conf
#
# Then rebuilds EA-Nginx user configs and restarts nginx.

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()  { echo "${BLUE}[i]${RESET} $*"; }
ok()    { echo "${GREEN}[✓]${RESET} $*"; }
warn()  { echo "${YELLOW}[!]${RESET} $*"; }
fail()  { echo "${RED}[✗]${RESET} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Must be run as root."

info "Removing AI bot throttle configs"

REMOVED=0
for f in \
    /etc/nginx/conf.d/ai-bot-throttle.conf \
    /etc/nginx/conf.d/server-includes/ai-bot-throttle.conf
do
    if [ -f "$f" ]; then
        rm -f "$f"
        ok "Removed $f"
        REMOVED=$((REMOVED+1))
    fi
done

if [ "$REMOVED" -eq 0 ]; then
    warn "Nothing to remove — configs not found. Maybe already uninstalled?"
    exit 0
fi

info "Testing nginx config syntax"
nginx -t 2>&1 || fail "nginx -t failed after removal. This shouldn't happen — please investigate."

info "Rebuilding EA-Nginx user configs"
/scripts/ea-nginx config --all > /tmp/ea-nginx-uninstall.log 2>&1 || \
    warn "ea-nginx config --all returned non-zero. Check /tmp/ea-nginx-uninstall.log"

info "Restarting nginx"
systemctl restart nginx
sleep 2
systemctl is-active --quiet nginx || fail "nginx failed to restart. Run: journalctl -u nginx -n 50"

ok "Uninstall complete. AI bots are no longer rate-limited."
echo
echo "  Your most recent pre-install backup is in /root/config-backups/"
echo "  (look for files named nginx-before-ai-bot-throttle-*.tar.gz)"
echo
