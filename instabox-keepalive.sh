#!/bin/sh
# InstaBox keepalive — keep your cloud machines from idling out.
#
# InstaBox pauses a machine after 30 minutes with no activity. This script holds
# an *activity lease* on your machines and renews it before it expires, so they
# stay running. Nothing is installed inside the machine being kept alive: the
# renewer runs somewhere that is always on — a VPS, a NAS, another InstaBox
# machine, or an Android phone running Termux.
#
#   Install (interactive):
#     sh instabox-keepalive.sh install
#
#   Install (no prompts):
#     IBK_KEYS=ibk_xxx sh instabox-keepalive.sh install
#     IBK_KEYS=ibk_aaa,ibk_bbb IBK_MACHINE=qqq sh instabox-keepalive.sh install
#
#   Everyday commands:
#     sh instabox-keepalive.sh status       what is running and where it is
#     sh instabox-keepalive.sh once         renew one time, then exit
#     sh instabox-keepalive.sh logs         recent activity
#     sh instabox-keepalive.sh restart
#     sh instabox-keepalive.sh release      drop the leases (idle pause returns)
#     sh instabox-keepalive.sh uninstall
#
# Works with systemd, OpenRC, Termux (Termux:Boot + wake lock) or, failing
# those, a plain background process. Needs only sh and curl.
#
# Before the free plan's max-run cap, the daemon suspends and immediately
# resumes the machine to start a fresh run, so the platform never pauses it
# and never starts a cooldown. Set IBK_ROTATE=0 to leave the cap alone.
set -u

APP=instabox-keepalive
API_DEFAULT=https://api.instabox.sh
DEFAULT_TTL=300
DEFAULT_LEASE=keepalive
# Set this after you publish this file, so `curl ... | sh` can install itself.
SELF_URL=${IBK_SELF_URL:-https://raw.githubusercontent.com/samperez10/instashit-keepalive/main/instabox-keepalive.sh}

[ "$(id -u)" -eq 0 ] && DEFAULT_HOME=/etc/instabox-keepalive \
                     || DEFAULT_HOME=${XDG_CONFIG_HOME:-$HOME/.config}/instabox-keepalive
BASE=${IBK_HOME:-$DEFAULT_HOME}
CONF=$BASE/config
LOG=$BASE/keepalive.log
PID=$BASE/keepalive.pid
SELF=$BASE/keepalive.sh
UNIT=/etc/systemd/system/$APP.service
INIT=/etc/init.d/$APP

WANT_START=1
FORCE=0
ASSUME_YES=0
BACKEND=${IBK_BACKEND:-}

TTL=$DEFAULT_TTL
LEASE=$DEFAULT_LEASE
API_URL=${IBK_API_URL:-$API_DEFAULT}
MACHINES=
ROTATE=${IBK_ROTATE:-1}
ROTATE_MARGIN=${IBK_ROTATE_MARGIN_MIN:-10}
KEY=
HTTP_CODE=
HTTP_BODY=
VERBOSE=${IBK_VERBOSE:-0}
TMP=
ERRFILE=

# ---------------------------------------------------------------- output ----
say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

have_tty() { ( : </dev/tty ) 2>/dev/null; }

ask() { # ask <prompt> [default] -> ANSWER
	ANSWER=${2:-}
	if have_tty; then
		if [ -n "$ANSWER" ]; then
			printf '%s [%s]: ' "$1" "$ANSWER" >/dev/tty
		else
			printf '%s: ' "$1" >/dev/tty
		fi
		IFS= read -r reply </dev/tty || reply=
		[ -n "$reply" ] && ANSWER=$reply
	fi
}

ask_secret() { # ask_secret <prompt> -> ANSWER (hidden when a tty exists)
	ANSWER=
	have_tty || return 0
	printf '%s' "$1" >/dev/tty
	stty -echo </dev/tty 2>/dev/null
	IFS= read -r ANSWER </dev/tty || ANSWER=
	stty echo </dev/tty 2>/dev/null
	printf '\n' >/dev/tty
}

confirm() { # confirm <prompt> [y]
	d=${2:-n}
	ask "$1 (y/N)" ""
	case "$ANSWER" in y|Y|yes|YES) return 0 ;; esac
	[ "$d" = y ] && [ -z "$ANSWER" ]
}

mask() {
	v=$1
	n=${#v}
	if [ "$n" -le 10 ]; then
		printf '%s' "$v"
	else
		printf '%s...%s' "$(printf %s "$v" | cut -c1-8)" "$(printf %s "$v" | cut -c$((n - 3))-$n)"
	fi
}

# ------------------------------------------------------------------ json ----
# The API answers small JSON bodies; these two helpers avoid a jq dependency.
json_get() { # json_get <json> <key> -> scalar value or empty
	printf '%s' "$1" | tr -d '\r\n' | awk -v k="$2" '
		{
			s = $0
			p = index(s, "\"" k "\"")
			if (p == 0) exit
			rest = substr(s, p + length(k) + 2)
			if (!sub(/^[ \t]*:[ \t]*/, "", rest)) exit
			if (substr(rest, 1, 1) == "\"") {
				rest = substr(rest, 2)
				v = ""; esc = 0
				for (j = 1; j <= length(rest); j++) {
					ch = substr(rest, j, 1)
					if (esc) { v = v ch; esc = 0; continue }
					if (ch == "\\") { esc = 1; continue }
					if (ch == "\"") break
					v = v ch
				}
			} else {
				if (!match(rest, /^[^,} \t]+/)) exit
				v = substr(rest, RSTART, RLENGTH)
			}
			if (v != "null") print v
		}'
}

machines_tsv() { # stdin: a machines list response -> "id<TAB>name<TAB>state" per line
	tr -d '\r\n' | awk '
		function jstr(o, k,   p, rest, q) {
			p = index(o, "\"" k "\"")
			if (p == 0) return ""
			rest = substr(o, p + length(k) + 2)
			if (!sub(/^[ \t]*:[ \t]*/, "", rest)) return ""
			if (substr(rest, 1, 1) != "\"") return ""
			rest = substr(rest, 2)
			q = index(rest, "\"")
			if (q == 0) return ""
			return substr(rest, 1, q - 1)
		}
		{
			s = $0
			p = index(s, "\"machines\"")
			if (p == 0) next
			s = substr(s, p + 10)
			b = index(s, "[")
			if (b == 0) next
			s = substr(s, b + 1)
			depth = 0; instr = 0; esc = 0; buf = ""
			for (i = 1; i <= length(s); i++) {
				c = substr(s, i, 1)
				if (instr) {
					if (depth > 0) buf = buf c
					if (esc) esc = 0
					else if (c == "\\") esc = 1
					else if (c == "\"") instr = 0
					continue
				}
				if (c == "\"") {
					instr = 1
					if (depth > 0) buf = buf c
					continue
				}
				if (c == "{") {
					if (depth == 0) buf = "{"; else buf = buf c
					depth++
					continue
				}
				if (c == "}") {
					if (depth == 1) {
						print jstr(buf, "id") "\t" jstr(buf, "name") "\t" jstr(buf, "state")
						buf = ""
					} else if (depth > 1) {
						buf = buf c
					}
					if (depth > 0) depth--
					continue
				}
				if (depth > 0) { buf = buf c; continue }
				if (c == "]") exit
			}
		}'
}

# ------------------------------------------------------------------ http ----
http() { # http <METHOD> <PATH> [JSON body] -> HTTP_CODE + HTTP_BODY
	m=$1
	p=$2
	d=${3:-}
	if [ -n "$d" ]; then
		HTTP_CODE=$(curl -sS -m "${IBK_TIMEOUT:-60}" -X "$m" "$API_URL$p" \
			-H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
			-d "$d" -o "$TMP/body" -w '%{http_code}' 2>"$TMP/err") || HTTP_CODE=0
	else
		HTTP_CODE=$(curl -sS -m "${IBK_TIMEOUT:-60}" -X "$m" "$API_URL$p" \
			-H "X-API-Key: $KEY" \
			-o "$TMP/body" -w '%{http_code}' 2>"$TMP/err") || HTTP_CODE=0
	fi
	case "$HTTP_CODE" in ''|*[!0-9]*) HTTP_CODE=0 ;; esac
	HTTP_BODY=$(cat "$TMP/body" 2>/dev/null || true)
	[ "$HTTP_CODE" = 200 ] || [ "$HTTP_CODE" = 201 ] || [ "$HTTP_CODE" = 202 ] || [ "$HTTP_CODE" = 204 ]
}

api_error() { # api_error -> "HTTP 409 machine_not_running: <message>"
	code=$(json_get "$HTTP_BODY" code)
	msg=$(json_get "$HTTP_BODY" message)
	[ -n "$code" ] || code=unknown
	[ -n "$msg" ] || msg=$(printf '%s' "$HTTP_BODY" | head -c 160)
	printf 'HTTP %s %s: %.160s' "$HTTP_CODE" "$code" "$msg"
}

hint_for_error() {
	case "$HTTP_CODE" in
		401)
			say "  The key was rejected. Check it was copied in full and not revoked." >&2
			say "  Keys are created at instabox.sh -> Profile -> API keys." >&2
			;;
		403)
			say "  The key is missing a scope. Use a key with machines:write." >&2
			;;
		404)
			say "  Nothing matched. Check the machine name (instabox ls shows names)." >&2
			;;
		0)
			say "  Could not reach $API_URL. Check the network/proxy." >&2
			;;
	esac
}

# ---------------------------------------------------------------- config ----
load_config() {
	[ -f "$CONF" ] || die "not installed yet. Run: sh $0 install"
	TTL=$DEFAULT_TTL
	LEASE=$DEFAULT_LEASE
	ACCOUNTS=
	BACKEND=
	while IFS= read -r line; do
		case "$line" in
			''|\#*) continue ;;
			TTL=*) TTL=${line#TTL=} ;;
			LEASE=*) LEASE=${line#LEASE=} ;;
			API_URL=*) API_URL=${line#API_URL=} ;;
			ROTATE=*) ROTATE=${line#ROTATE=} ;;
			ROTATE_MARGIN=*) ROTATE_MARGIN=${line#ROTATE_MARGIN=} ;;
			BACKEND=*) BACKEND=${line#BACKEND=} ;;
			ACCOUNT=*) ACCOUNTS="$ACCOUNTS
${line#ACCOUNT=}" ;;
		esac
	done < "$CONF"
	[ -n "$ACCOUNTS" ] || die "no API key in $CONF. Run: sh $0 install"
	RENEW=${IBK_RENEW_EVERY:-$((TTL * 3 / 5))}
	[ "$RENEW" -lt 20 ] 2>/dev/null && RENEW=20
	case "$ROTATE" in 0|off|OFF|false|FALSE|no|NO) ROTATE=0 ;; *) ROTATE=1 ;; esac
	case "$ROTATE_MARGIN" in ''|*[!0-9]*) ROTATE_MARGIN=10 ;; esac
	[ "$ROTATE_MARGIN" -gt 120 ] 2>/dev/null && ROTATE_MARGIN=120
	return 0
}

for_each_account() { # for_each_account <function>; calls fn <key> <machines>
	fn=$1
	printf '%s\n' "$ACCOUNTS" | while IFS='|' read -r key machines; do
		[ -n "$key" ] || continue
		KEY=$key
		MACHINES=$machines
		"$fn" "$key" "$machines"
	done
}

fail_mark() { printf 'x\n' >> "$ERRFILE"; }

# --------------------------------------------------------------- leases ----
list_machines() { # uses $KEY -> $TMP/machines.tsv
	if ! http GET /v1/machines; then
		printf 'account %s: %s\n' "$(mask "$KEY")" "$(api_error)" >&2
		hint_for_error
		return 1
	fi
	printf '%s' "$HTTP_BODY" | machines_tsv > "$TMP/machines.tsv"
	return 0
}

select_machines() { # select_machines <filter> -> $TMP/selected.tsv, prints nothing
	filter=$1
	: > "$TMP/selected.tsv"
	if [ -z "$filter" ] || [ "$filter" = all ] || [ "$filter" = ALL ]; then
		cat "$TMP/machines.tsv" > "$TMP/selected.tsv"
		return 0
	fi
	missing=
	for want in $(printf '%s' "$filter" | tr ',' ' '); do
		row=$(awk -F '\t' -v t="$want" '
			{ n++ }
			tolower($1) == tolower(t) || tolower($2) == tolower(t) || (t ~ /^[0-9]+$/ && t + 0 == n) {
				print; found = 1; exit
			}
			END { if (!found) exit 1 }' "$TMP/machines.tsv") || row=
		if [ -n "$row" ]; then
			printf '%s\n' "$row" >> "$TMP/selected.tsv"
		else
			missing="$missing $want"
		fi
	done
	if [ -n "$missing" ]; then
		printf 'account %s: no machine named%s\n' "$(mask "$KEY")" "$missing" >&2
		return 1
	fi
	return 0
}

wake_machine() { # wake_machine <id> -> 0 woke / 2 cooling down / 1 failed
	id=$1
	code=$(curl -sS -m 60 -X POST "$API_URL/v1/machines/$id/wake" \
		-H "X-API-Key: $KEY" -H "Idempotency-Key: wake-$id-$$-$(date +%s)" \
		-o "$TMP/wake" -w '%{http_code}' 2>/dev/null) || code=0
	case "$code" in
		200|201|202) return 0 ;;
		409) grep -qi 'machine_cooldown' "$TMP/wake" && return 2 ;;
	esac
	return 1
}

# ------------------------------------------------------- run-time rotation ----
# A lease stops the *idle* pause, but not the free plan's max-run cap: when a run
# reaches it, InstaBox pauses the machine and starts a cooldown (5-20 minutes,
# longer if it keeps happening). The only way around that is to start a fresh
# run ourselves, just before the cap: suspend, then resume at once. Memory and
# processes survive a suspend, so the visible cost is a few seconds of freeze.
iso_epoch() { # iso_epoch <RFC3339 UTC> -> epoch seconds; fails on anything else
	v=$1
	case "$v" in ''|*[!0-9T:.Zz+-]*) return 1 ;; esac
	v=${v%Z}; v=${v%z}
	v=${v%+00:00}; v=${v%-00:00}
	case "$v" in *[+-][0-9][0-9]:[0-9][0-9]) return 1 ;; esac
	v=$(printf '%.19s' "$v")
	case "$v" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	Y=$(printf '%s' "$v" | cut -c1-4)
	Mo=$(printf '%s' "$v" | cut -c6-7)
	D=$(printf '%s' "$v" | cut -c9-10)
	h=$(printf '%s' "$v" | cut -c12-13)
	mi=$(printf '%s' "$v" | cut -c15-16)
	s=$(printf '%s' "$v" | cut -c18-19)
	awk -v Y="$Y" -v Mo="$Mo" -v D="$D" -v h="$h" -v mi="$mi" -v s="$s" 'BEGIN {
		y = Y + 0; m = Mo + 0
		if (m <= 2) { y -= 1; m += 12 }
		era = int(y / 400); yoe = y - era * 400
		doy = int((153 * (m - 3) + 2) / 5) + D - 1
		doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
		print (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s
	}'
}

post_action() { # post_action <id> <suspend|resume|start> -> HTTP code
	curl -sS -m 90 -X POST "$API_URL/v1/machines/$1/$2" \
		-H "X-API-Key: $KEY" -H "Idempotency-Key: $2-$1-$$-$(date +%s)" \
		-o "$TMP/action" -w '%{http_code}' 2>/dev/null || true
}

wait_state() { # wait_state <id> <state> <seconds>
	i=0
	while [ "$i" -lt "$3" ]; do
		sleep 1
		if http GET "/v1/machines/$1" && [ "$(json_get "$HTTP_BODY" state)" = "$2" ]; then
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

rotate_one() { # rotate_one <id> <name> -> 0 rotated
	t0=$(date +%s)
	code=$(post_action "$1" suspend)
	case "$code" in
		200|202) ;;
		*)
			log "rotate $2: suspend refused (HTTP ${code:-0}), will retry next round"
			return 1
			;;
	esac
	if ! wait_state "$1" suspended 20; then
		log "rotate $2: did not reach suspended, will retry next round"
		return 1
	fi
	code=$(post_action "$1" resume)
	case "$code" in
		200|202) ;;
		*)
			code=$(post_action "$1" start)
			;;
	esac
	if ! wait_state "$1" running 40; then
		log "rotate $2: did not come back running, will retry next round"
		return 1
	fi
	log "rotated $2: run timer reset, down $(( $(date +%s) - t0 ))s"
	return 0
}

maybe_rotate() { # maybe_rotate <id> <name> -> 0 rotated / 1 not needed
	[ "$ROTATE" = 1 ] || return 1
	if ! http GET "/v1/machines/$1"; then
		return 1
	fi
	[ "$(json_get "$HTTP_BODY" state)" = running ] || return 1
	maxrun=$(json_get "$HTTP_BODY" maxRunMinutes)
	case "$maxrun" in ''|*[!0-9]*) return 1 ;; esac
	[ "$maxrun" -gt 0 ] || return 1
	cool=$(json_get "$HTTP_BODY" cooldownUntil)
	if [ -n "$cool" ]; then
		ce=$(iso_epoch "$cool") || ce=
		[ -n "$ce" ] && [ "$ce" -gt "$(date +%s)" ] && return 1
	fi
	started=$(json_get "$HTTP_BODY" runStartedAt)
	se=$(iso_epoch "$started") || return 1
	remain=$(( (se + maxrun * 60 - $(date +%s)) / 60 ))
	if [ "$remain" -gt "$ROTATE_MARGIN" ]; then
		return 1
	fi
	[ "$VERBOSE" = 1 ] && log "rotate $2: $remain min of run left (margin ${ROTATE_MARGIN})"
	rotate_one "$1" "$2"
}

renew_one() { # renew_one <id> <name> -> 0 ok / 1 failed / 2 skipped
	id=$1
	name=$2
	tries=0
	while :; do
		if http PUT "/v1/machines/$id/activity-leases/$LEASE" "{\"ttlSeconds\":$TTL}"; then
			expires=$(json_get "$HTTP_BODY" expiresAt)
			[ "$VERBOSE" = 1 ] && log "renewed $name -> $expires"
			printf '%s\n' "$expires" > "$TMP/last-expires"
			return 0
		fi
		case "$HTTP_CODE" in
			409)
				if printf '%s' "$HTTP_BODY" | grep -qi 'machine_cooldown'; then
					raf=$(printf '%s' "$HTTP_BODY" | grep -o 'Retry-After[^0-9]*[0-9]*' | grep -o '[0-9]*$')
					log "skipped $name: platform cooldown${raf:+ (about ${raf}s left)}"
					return 2
				fi
				if printf '%s' "$HTTP_BODY" | grep -Eqi 'not_running|suspended|stopped'; then
					tries=$((tries + 1))
					if [ "$tries" -gt 3 ]; then
						log "failed $name: still not running after 3 wake attempts"
						return 1
					fi
					wake_machine "$id"
					wake_rc=$?
					case "$wake_rc" in
						2) log "skipped $name: platform cooldown"; return 2 ;;
					esac
					if [ "$wake_rc" -ne 0 ]; then
						# Manual pause or stop: wake does not undo those.
						code=$(post_action "$id" resume)
						case "$code" in
							200|202) ;;
							*) post_action "$id" start >/dev/null ;;
						esac
					fi
					sleep 3
					continue
				fi
				;;
		esac
		log "failed $name: $(api_error)"
		return 1
	done
}

acct_renew() { # acct_renew <key> <machines filter>
	if ! list_machines; then
		fail_mark
		return 1
	fi
	if ! select_machines "$2"; then
		fail_mark
		return 1
	fi
	total=$(wc -l < "$TMP/selected.tsv" | tr -d ' ')
	if [ "$total" -eq 0 ]; then
		log "account $(mask "$1"): no machines in this account"
		return 0
	fi
	ok=0
	bad=0
	skip=0
	expires=
	while IFS='	' read -r id name state; do
		[ -n "$id" ] || continue
		# Rotate before renewing, so the machine never reaches the platform cap.
		maybe_rotate "$id" "${name:-$id}"
		renew_one "$id" "${name:-$id}"
		case $? in
			0) ok=$((ok + 1)) ;;
			2) skip=$((skip + 1)) ;;
			*) bad=$((bad + 1)) ;;
		esac
	done < "$TMP/selected.tsv"
	expires=$(cat "$TMP/last-expires" 2>/dev/null || true)
	summary="$ok/$total renewed"
	[ "$skip" -gt 0 ] && summary="$summary, $skip skipped"
	[ "$bad" -gt 0 ] && summary="$summary, $bad failed"
	log "account $(mask "$1"): $summary${expires:+ (lease until $expires)}"
	[ "$bad" -eq 0 ] || { fail_mark; return 1; }
	return 0
}

acct_release() {
	if ! list_machines; then fail_mark; return 1; fi
	if ! select_machines "$2"; then fail_mark; return 1; fi
	while IFS='	' read -r id name state; do
		[ -n "$id" ] || continue
		if http DELETE "/v1/machines/$id/activity-leases/$LEASE"; then
			log "released $name"
		elif [ "$HTTP_CODE" = 404 ]; then
			log "no lease on $name"
		else
			log "failed to release $name: $(api_error)"
			fail_mark
		fi
	done < "$TMP/selected.tsv"
}

machine_run_left() { # machine_run_left <id> -> minutes left in this run, or nothing
	http GET "/v1/machines/$1" || return 1
	maxrun=$(json_get "$HTTP_BODY" maxRunMinutes)
	case "$maxrun" in ''|*[!0-9]*) return 1 ;; esac
	[ "$maxrun" -gt 0 ] || return 1
	started=$(json_get "$HTTP_BODY" runStartedAt)
	se=$(iso_epoch "$started") || return 1
	printf '%s' $(( (se + maxrun * 60 - $(date +%s)) / 60 ))
}

acct_status() {
	if ! list_machines; then fail_mark; return 1; fi
	if ! select_machines "$2"; then fail_mark; return 1; fi
	printf '  account %s\n' "$(mask "$1")"
	if [ ! -s "$TMP/selected.tsv" ]; then
		printf '    (no machines)\n'
		return 0
	fi
	while IFS='	' read -r id name state; do
		[ -n "$id" ] || continue
		left=
		if [ "$ROTATE" = 1 ]; then
			left=$(machine_run_left "$id" 2>/dev/null) || left=
		fi
		printf '    %-24s %-12s %s' "${name:-$id}" "${state:-?}" "$id"
		[ -n "$left" ] && printf '  run left %sm' "$left"
		printf '\n'
	done < "$TMP/selected.tsv"
}

# New temp dir for one run; removed by run_with_tmp.
new_tmp() {
	TMP=$(mktemp -d "${TMPDIR:-/tmp}/ibk.XXXXXX" 2>/dev/null) \
		|| { TMP=$BASE/tmp.$$; mkdir -p "$TMP" || die "cannot create a temp dir"; }
	ERRFILE=$TMP/failed
	: > "$ERRFILE"
}

run_with_tmp() { # run_with_tmp <function> <args...>
	new_tmp
	rc=0
	"$@" || rc=1
	[ -s "$ERRFILE" ] && rc=1
	rm -rf "$TMP"
	return $rc
}

status_all() { for_each_account acct_status; }
renew_all()  { for_each_account acct_renew; }
release_all() { for_each_account acct_release; }

# ------------------------------------------------------------- processes ----
pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

running_pid() {
	[ -f "$PID" ] || return 1
	p=$(cat "$PID" 2>/dev/null || true)
	pid_alive "$p" || return 1
	printf '%s' "$p"
}

spawn_daemon() {
	if running_pid >/dev/null; then
		say "already running (pid $(running_pid))"
		return 0
	fi
	command -v setsid >/dev/null 2>&1 && SETSID=setsid || SETSID=
	# shellcheck disable=SC2086
	nohup $SETSID /bin/sh "$SELF" run >>"$LOG" 2>&1 &
	echo $! > "$PID"
	sleep 1
	if pid_alive "$(cat "$PID" 2>/dev/null)"; then
		say "started (pid $(cat "$PID"), log $LOG)"
		return 0
	fi
	say "failed to start. Last lines of $LOG:"
	tail -n 20 "$LOG" 2>/dev/null
	return 1
}

kill_daemon() {
	p=$(running_pid) || { say "not running"; rm -f "$PID"; return 0; }
	kill "$p" 2>/dev/null
	i=0
	while pid_alive "$p" && [ "$i" -lt 10 ]; do
		sleep 1
		i=$((i + 1))
	done
	pid_alive "$p" && kill -9 "$p" 2>/dev/null
	rm -f "$PID"
	say "stopped"
}

start_backend() {
	case "$BACKEND" in
		systemd) systemctl start "$APP.service" ;;
		openrc)  rc-service "$APP" start ;;
		termux)
			command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
			spawn_daemon
			;;
		*) spawn_daemon ;;
	esac
}

stop_backend() {
	case "$BACKEND" in
		systemd) systemctl stop "$APP.service" ;;
		openrc)  rc-service "$APP" stop ;;
		termux)
			command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
			kill_daemon
			;;
		*) kill_daemon ;;
	esac
}

backend_running() {
	case "$BACKEND" in
		systemd) systemctl is-active --quiet "$APP.service" ;;
		openrc)  rc-service "$APP" status >/dev/null 2>&1 ;;
		*) running_pid >/dev/null ;;
	esac
}

is_termux() { [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files/usr ]; }

detect_backend() {
	if [ "$(id -u)" -eq 0 ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
		echo systemd
	elif [ "$(id -u)" -eq 0 ] && command -v rc-update >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
		echo openrc
	elif is_termux; then
		echo termux
	else
		echo supervisor
	fi
}

ensure_curl() {
	command -v curl >/dev/null 2>&1 && return 0
	say "curl is missing, trying to install it..."
	if command -v pkg >/dev/null 2>&1; then
		pkg install -y curl
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-cache curl
	elif command -v apt-get >/dev/null 2>&1; then
		apt-get update -qq && apt-get install -y -qq curl
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q curl
	elif command -v yum >/dev/null 2>&1; then
		yum install -y -q curl
	elif command -v opkg >/dev/null 2>&1; then
		opkg update && opkg install curl
	fi
	command -v curl >/dev/null 2>&1 || die "curl is required. Install it and run again."
}

persist_self() {
	mkdir -p "$BASE" && chmod 700 "$BASE" 2>/dev/null
	if [ "$SELF" -ef "$0" ] 2>/dev/null; then
		return 0
	fi
	if [ -f "$0" ] && [ -r "$0" ]; then
		cp -f "$0" "$SELF.tmp" && chmod 755 "$SELF.tmp" && mv -f "$SELF.tmp" "$SELF" \
			|| die "cannot write $SELF"
	elif [ -n "$SELF_URL" ]; then
		say "Copying the script to $SELF ..."
		curl -fsSL -m 60 -o "$SELF.tmp" "$SELF_URL" || die "download failed ($SELF_URL)"
		chmod 755 "$SELF.tmp" && mv -f "$SELF.tmp" "$SELF" || die "cannot write $SELF"
	else
		die "run this from the downloaded file (curl -o $APP.sh ...), not from a pipe"
	fi
}

# ---------------------------------------------------------------- wizard ----
wizard() {
	say ""
	say "InstaBox keepalive setup"
	say "========================"
	say ""
	say "You need an API key. In the web console:"
	say "  instabox.sh -> Profile -> API keys -> Create key"
	say "  scope machines:write is enough."
	say ""
	: > "$TMP/accounts"

	n=0
	while :; do
		n=$((n + 1))
		[ "$n" -gt 1 ] && say "" && say "Account $n"
		tries=0
		while :; do
			ask_secret "  Paste API key $n (input hidden): "
			[ -n "$ANSWER" ] || { say "  No key entered." ; return 1; }
			KEY=$ANSWER
			if list_machines; then
				break
			fi
			say "  $(api_error)" >&2
			hint_for_error
			tries=$((tries + 1))
			[ "$tries" -ge 3 ] && die "giving up after 3 tries"
			say "" 
		done

		count=$(wc -l < "$TMP/machines.tsv" | tr -d ' ')
		if [ "$count" -eq 0 ]; then
			say "  This account has no machines yet. Add one at instabox.sh, then run install again."
			return 1
		fi
		say ""
		say "  Machines on this key:"
		awk -F '\t' '{ printf "   %2d) %-26s %s\n", NR, $2, $3 }' "$TMP/machines.tsv"
		say ""
		ask "  Keep which machines? all / numbers (1,3) / names" "all"
		sel=$ANSWER
		if ! select_machines "$sel"; then
			say "  Could not match: $sel"
			return 1
		fi
		names=$(cut -f2 "$TMP/selected.tsv" | paste -sd, - 2>/dev/null || true)
		[ "$sel" = all ] && names=
		printf '%s|%s\n' "$KEY" "$names" >> "$TMP/accounts"
		say "  $(wc -l < "$TMP/selected.tsv" | tr -d ' ') machine(s) selected."

		if [ "$n" -ge 10 ]; then
			break
		fi
		say ""
		confirm "  Add another account?" n || break
	done
	say ""
}

write_config() {
	umask 077
	{
		printf '%s\n' "# InstaBox keepalive config. Contains API keys: keep it private."
		printf 'TTL=%s\n' "$TTL"
		printf 'LEASE=%s\n' "$LEASE"
		printf 'API_URL=%s\n' "$API_URL"
		printf 'ROTATE=%s\n' "$ROTATE"
		printf 'ROTATE_MARGIN=%s\n' "$ROTATE_MARGIN"
		printf 'BACKEND=%s\n' "$BACKEND"
		while IFS='|' read -r k m; do
			[ -n "$k" ] || continue
			printf 'ACCOUNT=%s|%s\n' "$k" "$m"
		done < "$TMP/accounts"
	} > "$CONF" || die "cannot write $CONF"
	chmod 600 "$CONF"
}

load_accounts_from_config() {
	ACCOUNTS=
	while IFS= read -r line; do
		case "$line" in ACCOUNT=*) ACCOUNTS="$ACCOUNTS
${line#ACCOUNT=}" ;; esac
	done < "$CONF"
}

# --------------------------------------------------------------- install ----
do_install() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--ttl=*) TTL=${1#*=} ;;
			--ttl) TTL=${2:-}; shift ;;
			--lease=*) LEASE=${1#*=} ;;
			--lease) LEASE=${2:-}; shift ;;
			--rotate=*) ROTATE=${1#*=} ;;
			--rotate) ROTATE=${2:-}; shift ;;
			--rotate-margin=*) ROTATE_MARGIN=${1#*=} ;;
			--machine=*) IBK_MACHINE=${1#*=} ;;
			--machine) IBK_MACHINE=${2:-}; shift ;;
			--no-start) WANT_START=0 ;;
			--force) FORCE=1 ;;
			-y|--yes) ASSUME_YES=1 ;;
			*) die "unknown option: $1 (see --help)" ;;
		esac
		shift
	done

	ensure_curl
	mkdir -p "$BASE" && chmod 700 "$BASE" 2>/dev/null
	new_tmp
	BACKEND=$(detect_backend)

	if [ -n "${IBK_KEYS:-}" ]; then
		# Non-interactive: one comma-separated key list, one optional filter.
		: > "$TMP/accounts"
		for k in $(printf '%s' "$IBK_KEYS" | tr ',' ' '); do
			printf '%s|%s\n' "$k" "${IBK_MACHINE:-}" >> "$TMP/accounts"
		done
		TTL=${IBK_TTL:-$TTL}
		LEASE=${IBK_LEASE:-$LEASE}
	else
		have_tty || die "no terminal for the setup questions. Use: IBK_KEYS=ibk_xxx sh $0 install"
		if [ -f "$CONF" ] && [ "$FORCE" -eq 0 ]; then
			say ""
			say "An installation already exists in $BASE."
			say "Re-running setup keeps nothing from the old one except the lease settings."
			confirm "Reconfigure now?" n || die "cancelled"
		fi
		wizard || die "setup cancelled"
	fi

	case "$TTL" in ''|*[!0-9]*) die "TTL must be a number of seconds (30-3600)" ;; esac
	if [ "$TTL" -lt 30 ] || [ "$TTL" -gt 3600 ]; then
		die "TTL must be between 30 and 3600 seconds"
	fi
	case "$ROTATE" in 0|off|OFF|false|FALSE|no|NO) ROTATE=0 ;; *) ROTATE=1 ;; esac
	case "$ROTATE_MARGIN" in ''|*[!0-9]*) ROTATE_MARGIN=10 ;; esac
	[ "$ROTATE_MARGIN" -gt 120 ] 2>/dev/null && ROTATE_MARGIN=120
	[ -s "$TMP/accounts" ] || die "no API key configured"

	persist_self
	write_config
	unset IBK_KEYS

	say ""
	say "Testing the connection..."
	VERBOSE=1
	if ! load_config; then
		exit 1
	fi
	if ! run_with_tmp renew_all; then
		say ""
		say "The test failed, so nothing was started. The config is kept at:"
		say "  $CONF"
		say "Fix the problem and run: sh $SELF install"
		exit 1
	fi
	say "OK: leases are being renewed."
	say ""

	install_service

	say ""
	say "Installed."
	say "  config    $CONF (mode 600)"
	say "  log       $(log_path)"
	say "  backend   $BACKEND"
	if [ "$ROTATE" = 1 ]; then
		say "  rotation  on: suspends and resumes immediately when ${ROTATE_MARGIN} min of run are left"
	else
		say "  rotation  off: the platform pauses the machine at its max-run cap"
	fi
	if [ "$WANT_START" -eq 1 ]; then
		say "  status    running"
	else
		say "  status    installed, not started (--no-start)"
	fi
	say ""
	say "Useful commands:"
	say "  sh $SELF status     show machines and state"
	say "  sh $SELF logs       recent renewals"
	say "  sh $SELF once       renew right now"
	say "  sh $SELF release    stop keeping machines awake"
	say "  sh $SELF uninstall  remove everything"
	if [ "$BACKEND" = termux ]; then
		say ""
		say "Android note: install the Termux:Boot app and open it once, so the"
		say "keepalive starts again after a reboot. Android may still stop"
		say "background apps on aggressive battery savers; exclude Termux."
	fi
}

log_path() {
	case "$BACKEND" in
		openrc) echo "/var/log/$APP.log" ;;
		*) echo "$LOG" ;;
	esac
}

install_service() {
	case "$BACKEND" in
		systemd)
			cat > "$UNIT" <<EOF
[Unit]
Description=InstaBox keepalive (activity lease renewer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=/bin/sh $SELF run
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
			systemctl daemon-reload
			systemctl enable "$APP.service" >/dev/null 2>&1
			[ "$WANT_START" -eq 1 ] && systemctl restart "$APP.service"
			;;
		openrc)
			cat > "$INIT" <<EOF
#!/sbin/openrc-run
name="$APP"
description="InstaBox activity lease renewer"
command="/bin/sh"
command_args="$SELF run"
command_background=true
pidfile="/run/$APP.pid"
output_log="/var/log/$APP.log"
error_log="/var/log/$APP.log"
EOF
			chmod 755 "$INIT"
			rc-update add "$APP" default >/dev/null 2>&1
			if [ "$WANT_START" -eq 1 ]; then
				rc-service "$APP" restart >/dev/null 2>&1 || rc-service "$APP" start >/dev/null 2>&1
			fi
			;;
		termux)
			if [ "$WANT_START" -eq 1 ]; then
				command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
				spawn_daemon
			fi
			mkdir -p "$HOME/.termux/boot" 2>/dev/null
			cat > "$HOME/.termux/boot/$APP" <<EOF
#!${PREFIX:-/data/data/com.termux/files/usr}/bin/sh
termux-wake-lock 2>/dev/null
exec sh "$SELF" start
EOF
			chmod 755 "$HOME/.termux/boot/$APP" 2>/dev/null
			say "Boot hook: $HOME/.termux/boot/$APP (needs the Termux:Boot app)"
			;;
		*)
			if command -v crontab >/dev/null 2>&1; then
				line="@reboot /bin/sh $SELF start >/dev/null 2>&1"
				(crontab -l 2>/dev/null | grep -vF "$SELF start"; printf '%s\n' "$line") | crontab - 2>/dev/null || true
			fi
			[ "$WANT_START" -eq 1 ] && spawn_daemon
			;;
	esac
}

# ----------------------------------------------------------- other verbs ----
do_run() {
	load_config
	mkdir -p "$BASE"
	log "keepalive started (ttl ${TTL}s, renew every ${RENEW}s, $(printf '%s\n' "$ACCOUNTS" | grep -c '|') account(s))"
	if [ "$ROTATE" = 1 ]; then
		log "rotation on: suspend + immediate resume when ${ROTATE_MARGIN} min of run remain"
	else
		log "rotation off"
	fi
	trap 'log "keepalive stopped"; exit 0' INT TERM HUP
	while :; do
		run_with_tmp renew_all || log "some machines failed; retrying in ${RENEW}s"
		n=$RENEW
		while [ "$n" -gt 0 ]; do
			if [ "$n" -gt 10 ]; then s=10; else s=$n; fi
			sleep "$s"
			n=$((n - s))
		done
	done
}

do_status() {
	load_config
	say "InstaBox keepalive"
	say "  backend   ${BACKEND:-unknown}"
	if backend_running; then say "  service   running"; else say "  service   not running"; fi
	if backend_running; then
		say "  ttl       ${TTL}s (renewed every ${RENEW}s)"
		say "  lease     $LEASE"
		if [ "$ROTATE" = 1 ]; then
			say "  rotation  on (${ROTATE_MARGIN} min before the cap)"
		else
			say "  rotation  off"
		fi
	fi
	say ""
	run_with_tmp status_all || true
}

do_once() {
	load_config
	VERBOSE=1
	run_with_tmp renew_all
}

do_release() {
	load_config
	run_with_tmp release_all
}

do_logs() {
	[ -f "$CONF" ] || die "not installed yet"
	load_config 2>/dev/null || true
	n=${1:-40}
	case "$BACKEND" in
		systemd)
			if command -v journalctl >/dev/null 2>&1; then
				journalctl -u "$APP.service" -n "$n" --no-pager
			else
				tail -n "$n" "$LOG" 2>/dev/null
			fi
			;;
		openrc) tail -n "$n" "/var/log/$APP.log" 2>/dev/null ;;
		*) tail -n "$n" "$LOG" 2>/dev/null ;;
	esac
}

do_start() {
	load_config
	start_backend
	sleep 1
	if backend_running; then
		say "running"
	else
		say "not running, check: sh $SELF logs"
		return 1
	fi
}

do_stop() {
	[ -f "$CONF" ] || die "not installed yet"
	load_config 2>/dev/null || true
	stop_backend
}

do_uninstall() {
	KEEP_FILES=0
	KEEP_LEASE=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--keep-files) KEEP_FILES=1 ;;
			--keep-lease) KEEP_LEASE=1 ;;
			-y|--yes) ASSUME_YES=1 ;;
			*) die "unknown option: $1" ;;
		esac
		shift
	done
	[ -f "$CONF" ] || { say "nothing installed in $BASE"; exit 0; }
	if [ "$ASSUME_YES" -eq 0 ] && have_tty; then
		confirm "Stop keeping machines awake and remove $BASE?" n || die "cancelled"
	fi
	load_config
	new_tmp
	if [ "$KEEP_LEASE" -eq 0 ]; then
		say "Releasing leases..."
		run_with_tmp release_all || warn "some leases could not be released"
	fi
	case "$BACKEND" in
		systemd)
			systemctl disable --now "$APP.service" >/dev/null 2>&1
			rm -f "$UNIT"
			systemctl daemon-reload >/dev/null 2>&1
			;;
		openrc)
			rc-service "$APP" stop >/dev/null 2>&1
			rc-update del "$APP" default >/dev/null 2>&1
			rm -f "$INIT"
			;;
		termux)
			stop_backend
			rm -f "$HOME/.termux/boot/$APP"
			;;
		*)
			stop_backend
			if command -v crontab >/dev/null 2>&1; then
				(crontab -l 2>/dev/null | grep -vF "$SELF start") | crontab - 2>/dev/null || true
			fi
			;;
	esac
	rm -f "$PID"
	if [ "$KEEP_FILES" -eq 1 ]; then
		say "Kept $BASE"
	else
		rm -rf "$BASE"
		say "Removed $BASE"
	fi
	say "Uninstalled."
}

# --------------------------------------------------------------- selftest ----
selftest() {
	new_tmp
	fails=0
	check() { # check <label> <got> <want>
		if [ "$2" = "$3" ]; then
			printf 'ok   %s\n' "$1"
		else
			printf 'FAIL %s\n     got:  %s\n     want: %s\n' "$1" "$2" "$3"
			fails=$((fails + 1))
		fi
	}

	compact='{"machines":[{"id":"m_1","name":"qqq","state":"running"},{"id":"m_2","name":"box-2","state":"suspended"}]}'
	pretty='{
  "machines": [
    { "id": "m_1", "name": "qqq", "state": "running", "maxRunMinutes": 480 },
    { "id": "m_2", "name": "box-2", "state": "suspended" }
  ],
  "nextCursor": null
}'
	want=$(printf 'm_1\tqqq\trunning\nm_2\tbox-2\tsuspended')
	check "machines compact" "$(printf '%s' "$compact" | machines_tsv)" "$want"
	check "machines pretty"  "$(printf '%s' "$pretty" | machines_tsv)" "$want"

	body='{"id":"m_1","name":"qqq","state":"running","autoSuspendAfterSeconds":1800,"expiresAt":"2026-11-18T12:34:56Z","ttlSeconds":300,"nested":{"state":"suspended"}}'
	check "json string" "$(json_get "$body" expiresAt)" "2026-11-18T12:34:56Z"
	check "json number" "$(json_get "$body" ttlSeconds)" "300"
	check "json first match" "$(json_get "$body" state)" "running"
	check "json missing" "$(json_get "$body" nope)" ""
	check "json null" "$(json_get '{"a":null}' a)" ""

	err='{"error":{"code":"machine_not_running","message":"machine is paused","retryable":false}}'
	check "error code" "$(json_get "$err" code)" "machine_not_running"

	want_date=$(date -u -d '2026-11-18T12:00:00Z' +%s 2>/dev/null || true)
	if [ -n "$want_date" ]; then
		check "iso epoch" "$(iso_epoch 2026-11-18T12:00:00Z)" "$want_date"
		check "iso epoch fraction" "$(iso_epoch 2026-11-18T12:00:00.987Z)" "$want_date"
		check "iso epoch +00:00" "$(iso_epoch 2026-11-18T12:00:00+00:00)" "$want_date"
	fi
	check "iso epoch rejects other zones" "$(iso_epoch 2026-11-18T12:00:00+08:00)" ""

	printf 'm_1\tqqq\trunning\nm_2\tbox-2\tsuspended\n' > "$TMP/machines.tsv"
	select_machines "box-2" >/dev/null 2>&1
	check "select by name" "$(cut -f1 "$TMP/selected.tsv")" "m_2"
	select_machines "2" >/dev/null 2>&1
	check "select by number" "$(cut -f2 "$TMP/selected.tsv")" "box-2"
	select_machines "all" >/dev/null 2>&1
	check "select all" "$(wc -l < "$TMP/selected.tsv" | tr -d ' ')" "2"
	select_machines "nope" >/dev/null 2>&1
	check "select missing fails" "$?" "1"

	rm -rf "$TMP"
	if [ "$fails" -eq 0 ]; then
		say "all tests passed"
		return 0
	fi
	say "$fails test(s) failed"
	return 1
}

usage() {
	cat <<'EOF'
InstaBox keepalive - keep cloud machines from idling out.

  sh instabox-keepalive.sh install      guided setup (key, machines, service)
  sh instabox-keepalive.sh status       machines, state and service status
  sh instabox-keepalive.sh once         renew once, then exit
  sh instabox-keepalive.sh logs [N]     recent activity (default 40 lines)
  sh instabox-keepalive.sh start|stop|restart
  sh instabox-keepalive.sh release      drop leases so idle pause works again
  sh instabox-keepalive.sh uninstall    remove service, hooks and config
  sh instabox-keepalive.sh selftest     run built-in parser checks

Non-interactive install:
  IBK_KEYS=ibk_aaa,ibk_bbb        API keys, one per account
  IBK_MACHINE=qqq,box2            optional filter (default: all machines)
  IBK_TTL=300                     lease length, 30-3600 seconds
  IBK_LEASE=keepalive             lease name
  IBK_ROTATE=1                    reset the run timer before the free-plan cap
  IBK_ROTATE_MARGIN_MIN=10        minutes of run left when a rotation starts

Options:
  --ttl=N --lease=NAME --rotate=0|1 --rotate-margin=N --machine=NAME --force --no-start -y

Files (root): /etc/instabox-keepalive, service: systemd/OpenRC
Files (user): ~/.config/instabox-keepalive, service: Termux or background
EOF
}

# ------------------------------------------------------------------ main ----
main() {
	cmd=${1:-}
	[ "$#" -gt 0 ] && shift
	case "$cmd" in
		install) do_install "$@" ;;
		status|--status) do_status ;;
		once|--once) do_once ;;
		release|--release) do_release ;;
		logs|--logs) do_logs "$@" ;;
		start) do_start ;;
		stop) do_stop ;;
		restart) do_stop; do_start ;;
		uninstall|--uninstall) do_uninstall "$@" ;;
		run|--run) do_run ;;
		selftest|--selftest) selftest ;;
		-h|--help|help|'') usage ;;
		*) usage >&2; exit 2 ;;
	esac
}

main "$@"
