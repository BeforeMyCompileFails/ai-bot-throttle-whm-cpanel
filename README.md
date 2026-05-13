# ai-bot-throttle-cpanel

Server-wide AI crawler and SEO scraper rate-limiting for cPanel/WHM servers running EA-Nginx. **Humans completely unaffected.** Bots get throttled to 1 req/sec at the nginx edge before reaching Apache or PHP-FPM.

## Why this exists

If you run a cPanel hosting box with even a few busy WordPress sites, you've probably noticed something has changed through 2025-2026:

- Server load oscillates between idle and brutally high for no obvious reason
- Periodic 360 Monitoring / Nagios / Uptime Robot CPU alerts that didn't fire a few months ago
- Customer support tickets about "the site feels slow sometimes"
- `top` shows multiple `php-fpm` workers pinned at 100% across multiple customer accounts simultaneously

You check the logs and find your customers' sites being crawled, at the same time, by:
- GPTBot (OpenAI)
- ClaudeBot (Anthropic)
- Bytespider (TikTok)
- PerplexityBot
- Amazonbot
- Google-Extended
- And the usual SEO offenders: MJ12bot, AhrefsBot, SemrushBot, DotBot, etc.

AI crawl volume has ramped substantially since late 2024. Sites that handled bot traffic fine a year ago now hit php-fpm pool limits regularly. The fix isn't to block these bots — your customers benefit from being in AI search indexes. The fix is to **slow them down so they crawl steadily instead of in bursts**.

## What this does

Adds two small nginx config files that:

1. Identify bot user-agents via a `map` directive
2. Apply per-IP rate limiting **only to bots** — humans bypass the rate limiter entirely via nginx's empty-key behavior
3. Return `429 Too Many Requests` to bots that exceed 1 req/sec (with a burst tolerance of 5)
4. Auto-include in every customer's server block via EA-Nginx's `/etc/nginx/conf.d/server-includes/` directory, so this survives EA-Nginx config rebuilds

**What it deliberately does NOT throttle:**
- Regular human visitors (any UA not matching the bot list)
- Real-time per-user AI fetches: `ChatGPT-User`, `Claude-User`, `Perplexity-User` — these mean *a human asked an AI to fetch your page right now to cite it*, which is rare and valuable
- Search engine crawlers from Google, Bing, etc. (their main crawlers, not the `-Extended` AI training variants)

## Compatibility

| Requirement | Tested |
|-------------|--------|
| AlmaLinux 8 / 9 | ✓ |
| CloudLinux 8 / 9 | should work, same package layout |
| Rocky Linux 8 / 9 | should work, same package layout |
| cPanel & WHM | 11.130+ |
| EA-Nginx (cPanel's official nginx reverse-proxy) | ✓ required |
| Plain nginx (non-cPanel) | use the configs but not the installer |

Will NOT work on:
- LiteSpeed Web Server (use LiteSpeed's own bot-rules feature)
- Apache-only cPanel servers without EA-Nginx
- Direct Admin / Plesk / etc.

## Install

```bash
git clone https://github.com/BeforeMyCompileFails/ai-bot-throttle-cpanel.git
cd ai-bot-throttle-cpanel
sudo bash install.sh
```

The installer will:
1. Detect EA-Nginx
2. Back up your current config to `/root/config-backups/nginx-before-ai-bot-throttle-<timestamp>.tar.gz` with a README explaining what's in it
3. Drop two config files into place
4. Test syntax with `nginx -t`
5. Rebuild all EA-Nginx user configs (`/scripts/ea-nginx config --all`)
6. Restart nginx (full restart needed because we're adding a new shared-memory zone — a graceful reload silently keeps the old config)
7. Verify the enforcement directive is now present in customer configs

## Verify it's working

After install, give it 2-5 minutes for bot traffic to accumulate, then:

```bash
# See bots being throttled (should be non-zero on any busy site)
grep "ai_bots" /var/log/nginx/error.log | tail -10

# Should show entries like:
# [error] limiting requests, excess: 5.414 by zone "ai_bots", client: <IP>, request: "GET ..."

# Confirm NO real humans are being throttled (list should be empty or only show attackers using bot UAs)
grep "ai_bots" /var/log/nginx/error.log | grep -vE \
  "GPTBot|ClaudeBot|MJ12|Ahrefs|Sem|Diff|IbouBot|Bytespider|Perplexity|Amazonbot|CCBot|anthropic|meta-externalagent|DotBot|Google-Extended|Applebot"
```

And check from your customers' access logs:

```bash
# 429 status codes on a customer site = bots being rate-limited
tail -1000 /var/log/nginx/domains/example.com-ssl_log | awk '$9==429' | wc -l
```

## Uninstall

```bash
sudo bash uninstall.sh
```

Or manually restore from the timestamped backup:

```bash
cd /
sudo tar -xzf /root/config-backups/nginx-before-ai-bot-throttle-<timestamp>.tar.gz
sudo /scripts/ea-nginx config --all
sudo systemctl restart nginx
```

## Tuning

If `1r/s` is too aggressive (legitimate bots get too many 429s) or too lenient (load still spikes), edit `/etc/nginx/conf.d/ai-bot-throttle.conf`:

```nginx
limit_req_zone $ai_bot_limit_key zone=ai_bots:10m rate=1r/s;
```

- `rate=2r/s` — twice as much bot traffic allowed
- `rate=30r/m` — much stricter (one request every two seconds)

And in `/etc/nginx/conf.d/server-includes/ai-bot-throttle.conf`:

```nginx
limit_req zone=ai_bots burst=5 nodelay;
```

- `burst=10 nodelay` — allow larger bursts before 429-ing
- `burst=3` (no `nodelay`) — queue bursts up to 3 instead of rejecting; slows bots more gently

After editing, just `nginx -t && systemctl restart nginx`. Restart, not reload — see "Gotchas" below.

## Adding or removing bots from the list

Edit `/etc/nginx/conf.d/ai-bot-throttle.conf` and add a line to the `map`:

```nginx
"~*YourBotPattern" 1;
```

The `~*` makes it a case-insensitive regex match against the user-agent. Be careful with overly broad patterns — `"~*Mozilla"` would match every browser on earth.

## Gotchas

**1. You need a FULL nginx restart, not a reload, when changing the zone definition.**

If you edit the `limit_req_zone` key in `ai-bot-throttle.conf` (e.g. changing `$ai_bot_limit_key` to something else), a graceful reload will log this and silently keep running the OLD config:

```
[emerg] limit_req "ai_bots" uses the "$new_key" key while previously it used the "$old_key" key
```

The installer does the full restart for you. If you edit the file later, `systemctl restart nginx` (not `reload`).

**2. Behind Cloudflare? `$binary_remote_addr` works correctly only if `set_real_ip_from` is configured.**

cPanel's EA-Nginx ships with `conf.d/includes-optional/cloudflare.conf` that already does this — included in every user server block. If you've disabled that, the rate limit will bucket all Cloudflare-routed bot traffic into a handful of CF edge IPs and won't work correctly.

**3. CSF blocks don't apply to Cloudflare-proxied traffic.**

If you `csf -d <ip>` an attacker IP, that only blocks direct TCP connections. Cloudflare-proxied requests still arrive (because CSF sees them as coming from a CF edge IP, which is whitelisted). To block at the Cloudflare layer, either use Cloudflare's WAF directly, or enable CSF's Cloudflare integration via `CF_ENABLE = "1"` in `/etc/csf/csf.conf`. This is unrelated to bot throttling but worth knowing.

**4. WordPress sites still benefit hugely from page caching.**

This throttle is a defense, not a cure. The real long-term fix for AI crawler load is making your customers install WP Super Cache, W3 Total Cache, LiteSpeed Cache, or similar so cached HTML serves without ever invoking PHP. Bots crawling cached pages cost ~nothing.

## What's actually in the configs

`/etc/nginx/conf.d/ai-bot-throttle.conf` — http-level definitions:
- A `map` that sets `$is_ai_bot` to 1 for known bot UAs
- A second `map` that sets `$ai_bot_limit_key` to the client IP for bots, **empty string** for humans
- `limit_req_zone $ai_bot_limit_key zone=ai_bots:10m rate=1r/s;`

The empty-string-for-humans trick is the canonical nginx pattern for selective rate-limiting. When `limit_req_zone`'s key is empty, the rate limiter skips that request entirely — it doesn't even allocate a slot in shared memory. This is [documented behavior](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html#limit_req_zone).

`/etc/nginx/conf.d/server-includes/ai-bot-throttle.conf` — server-block-level enforcement:
- A single `limit_req zone=ai_bots burst=5 nodelay;` directive

EA-Nginx auto-includes everything in `/etc/nginx/conf.d/server-includes/*.conf` in every user server block on rebuild, so this applies to every customer site without modifying their individual configs.

## Origin story

This was written at 1 AM after a long night debugging a real cPanel server (sgc.hsplus.email's sibling box, `atlantis`) that started hitting load-avg 9 spikes after running fine for years. Root cause: the cumulative effect of GPTBot + ClaudeBot + Bytespider + MJ12bot + Ahrefs etc. all crawling 12 customer WordPress sites simultaneously had crossed a threshold the php-fpm pools couldn't absorb anymore.

The first draft of this throttle was buggy — it accidentally throttled real human visitors because of a subtle issue with how `$binary_remote_addr` interacts with composite map keys. We caught it because someone was browsing avto-kozmetika.si (a car-polish e-commerce site) at the time and their WP resource fetches were getting `[warn] delaying request` entries in the nginx error log. After two iterations and one painful `[emerg]` from trying to swap the zone key with a graceful reload, the current design works correctly: humans get an empty key (= skipped), bots get their IP as the key (= properly rate-limited).

The mistakes are baked into the code comments and README intentionally so other admins don't repeat them.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

PRs welcome, especially:
- Additional bot UA patterns as new crawlers emerge
- Testing on Rocky Linux / CloudLinux
- A version for plain nginx (no cPanel)
- A version for LiteSpeed (would use LS's bot rules)

Issues for problems or new bot identifications are also useful.

## Credits

Built by [BeforeMyCompileFails](https://github.com/BeforeMyCompileFails), with debugging help from Claude (Anthropic).
