#!/bin/sh
# One-command Cloudflare deploy for instabox-keepalive-worker.js.
#
# Needs Node.js 18+ (npx comes with it). Uses wrangler, Cloudflare's CLI.
# If you would rather not install anything, paste the worker into the
# dashboard instead; README.md has the four steps.
#
#   sh deploy-worker.sh
#
# Environment alternatives (no prompts):
#   IBK_KEYS=ibk_xxx CLOUDFLARE_API_TOKEN=... sh deploy-worker.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKER="$HERE/instabox-keepalive-worker.js"
NAME=${IBK_WORKER_NAME:-instabox-keepalive}
TTL=${IBK_TTL:-900}
TOKEN=${IBK_WORKER_TOKEN:-}

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have_tty() { ( : </dev/tty ) 2>/dev/null; }

ask_secret() {
	ANSWER=
	have_tty || return 0
	printf '%s' "$1" >/dev/tty
	stty -echo </dev/tty 2>/dev/null
	IFS= read -r ANSWER </dev/tty || ANSWER=
	stty echo </dev/tty 2>/dev/null
	printf '\n' >/dev/tty
}

ask() {
	ANSWER=${2:-}
	have_tty || return 0
	printf '%s [%s]: ' "$1" "$ANSWER" >/dev/tty
	IFS= read -r reply </dev/tty || reply=
	[ -n "$reply" ] && ANSWER=$reply
	return 0
}

[ -f "$WORKER" ] || die "instabox-keepalive-worker.js not found next to this script"
command -v npx >/dev/null 2>&1 || die "npx not found. Install Node.js 18+ or use the dashboard setup instead."

if [ -n "${IBK_KEYS:-}" ]; then
	KEYS=$IBK_KEYS
else
	ask_secret "InstaBox API key (comma separated for several accounts): "
	KEYS=$ANSWER
	[ -n "$KEYS" ] || die "no key entered"
fi

if [ -z "$TOKEN" ]; then
	if have_tty; then
		say ""
		say "A token protects the worker's URLs. Press Enter to generate one."
		ask_secret "Token: "
		TOKEN=$ANSWER
	fi
	[ -n "$TOKEN" ] || TOKEN=$( (openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32) )
fi

say ""
say "Worker name : $NAME"
say "Lease TTL   : ${TTL}s (cron runs every 5 minutes)"
say "Token       : $TOKEN"
say ""
say "Deploying with wrangler. The first run asks you to log in to Cloudflare."
say ""

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ibk-worker.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
cp "$WORKER" "$WORK/worker.js"

cat > "$WORK/wrangler.toml" <<EOF
name = "$NAME"
main = "worker.js"
compatibility_date = "2026-11-01"

[triggers]
crons = ["*/5 * * * *"]
EOF

cd "$WORK" || die "cannot enter $WORK"

run_wrangler() {
	npx --yes wrangler@4 "$@"
}

if ! run_wrangler deploy; then
	die "deploy failed. If it was a login problem, run 'npx wrangler login' and try again."
fi

say ""
say "Storing secrets..."
printf '%s' "$KEYS" | run_wrangler secret put INSTABOX_API_KEY >/dev/null || die "could not store INSTABOX_API_KEY"
printf '%s' "$TOKEN" | run_wrangler secret put TOKEN >/dev/null || die "could not store TOKEN"
printf '%s' "$TTL" | run_wrangler secret put INSTABOX_LEASE_TTL >/dev/null || true

say ""
say "Testing with /status ..."
sleep 2
URL=$(run_wrangler deployments list --json 2>/dev/null | tr ',' '\n' | sed -n 's/.*"url": *"\([^"]*\)".*/\1/p' | head -n 1)
if [ -n "$URL" ]; then
	curl -fsS -m 30 "$URL/status?token=$TOKEN" | head -c 600 || true
	say ""
	say "Status URL: $URL/status?token=$TOKEN"
else
	say "Deployed. Open Workers & Pages -> $NAME to see its URL, then:"
	say "  <url>/status?token=$TOKEN"
fi

say ""
say "Done. The cron trigger renews every machine every 5 minutes."
say "Remember: this worker holds your API key. Keep the token private."
