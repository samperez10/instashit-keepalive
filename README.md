# InstaBox keepalive (easy install)

InstaBox pauses a machine after **30 minutes with no activity**. This repo keeps
your machines awake by renewing an official **activity lease** before it expires.
Nothing is installed inside the machine being kept alive.

Two ways to run it, both in English, both standalone (no dependency on the
original project's scripts):

| Where | What to use | Best for |
| --- | --- | --- |
| A VPS, NAS, router, another InstaBox machine, or Android/Termux | `instabox-keepalive.sh` | Always-on machine you control |
| Cloudflare, nothing to keep running | `instabox-keepalive-worker.js` + cron | No server at all |

## 1. Get an API key

1. Sign in at [instabox.sh](https://instabox.sh)
2. **Profile → API keys → Create key**
3. Scope **`machines:write`** is enough (it includes read)
4. Copy the key now (`ibk_...`); it is shown once

One key per account. Several accounts: separate keys, comma separated.

## 2. Install the daemon

```sh
curl -fsSL https://raw.githubusercontent.com/samperez10/instashit-keepalive/main/instabox-keepalive.sh -o keepalive.sh
sh keepalive.sh install
```

It asks for the key (input hidden), shows the machines it found, and lets you
keep **all** of them or pick a few by number. Then it tests the connection and
only starts the service if a real lease was renewed.

One-liner variant (no file left behind; the installer downloads its own copy
for the service):

```sh
sh -c 'curl -fsSL https://raw.githubusercontent.com/samperez10/instashit-keepalive/main/instabox-keepalive.sh | sh'
```

No prompts:

```sh
IBK_KEYS=ibk_xxx sh keepalive.sh install
IBK_KEYS=ibk_aaa,ibk_bbb IBK_MACHINE=qqq,box2 sh keepalive.sh install
```

The wizard works the same on a normal Linux box, on an InstaBox machine, and on
Android via Termux:

| System | What gets installed |
| --- | --- |
| systemd (Debian/Ubuntu/Fedora, InstaBox) | `instabox-keepalive.service` |
| OpenRC (Alpine) | `/etc/init.d/instabox-keepalive` |
| Termux | background process + wake lock + `~/.termux/boot` hook |
| anything else | background process, plus `@reboot` if `crontab` exists |

Files go to `/etc/instabox-keepalive` as root, or
`~/.config/instabox-keepalive` as a normal user. The key is only ever in
`config`, mode `600`.

> Running it **inside** the machine you want to keep alive works while that
> machine is running, but a suspended machine cannot renew itself. Keep the
> renewer on a second always-on machine if you can.

### Everyday commands

```sh
sh keepalive.sh status      # machines, state, service state
sh keepalive.sh logs        # last 40 lines
sh keepalive.sh once        # renew right now
sh keepalive.sh restart
sh keepalive.sh release     # drop leases, idle pause works again
sh keepalive.sh uninstall   # stop, remove hooks, release leases, delete config
```

Re-running `install` reconciles settings; `--force` skips the confirmation.

### Settings

Non-interactive environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `IBK_KEYS` | required | `ibk_aaa,ibk_bbb` — one per account |
| `IBK_MACHINE` | all | names or IDs, comma separated; `all` = everything |
| `IBK_TTL` | `300` | lease length, 30–3600 s |
| `IBK_LEASE` | `keepalive` | lease name |
| `IBK_ROTATE` | `1` | reset the run timer before the max-run cap (see below) |
| `IBK_ROTATE_MARGIN_MIN` | `10` | rotate when this many minutes of run remain |
| `IBK_HOME` | see above | where config and logs live |
| `IBK_API_URL` | `https://api.instabox.sh` | custom gateway only |
| `IBK_RENEW_EVERY` | `0.6 × TTL` | seconds between renewals |

Renewal is driven by a loop, not cron, so the interval is exact.

## 3. Cloudflare Worker (no server)

One file, one cron trigger, no always-on machine.

**Dashboard route**

1. Cloudflare → **Workers & Pages → Create → Worker**, name it, **Deploy**
2. **Edit code**, paste all of `instabox-keepalive-worker.js`, **Deploy**
3. **Settings → Variables and Secrets**

   | Name | Type | Value |
   | --- | --- | --- |
   | `INSTABOX_API_KEY` | Secret | `ibk_...` (or `ibk_aaa,ibk_bbb`) |
   | `TOKEN` | Secret | random string, e.g. `openssl rand -hex 16` |
   | `INSTABOX_LEASE_TTL` | Text | `900` |

4. **Settings → Triggers → Cron Triggers** → `*/5 * * * *`
5. Open `https://<worker>.workers.dev/status?token=...`

Also accepted: `INSTABOX_MACHINE`, `INSTABOX_LEASE`, `INSTABOX_ROTATE=0`
(disable the pre-cap rotation), `INSTABOX_ROTATE_MARGIN_MIN` (default 10), and a
KV binding named `LOG` if you want `/log`.

**CLI route**

```sh
sh deploy-worker.sh        # asks for the key, deploys, stores secrets, tests
```

Worker routes (all need `?token=` once `TOKEN` is set; add `&format=text` for
plain text, `&account=2` to target one account):

```
/            renew now
/status      machines and states (read-only, no lease is taken)
/accounts    which keys are configured (masked)
/log         last 48 runs (needs a KV binding named LOG, optional)
/release     drop leases
```

Per-account machine filters are `INSTABOX_MACHINE_1`, `_2`, … matching the
numbers shown by `/accounts`.

## Minimising interruptions on the free plan

Two different timers can pause a machine:

1. **Idle** — 30 minutes without activity. The lease defeats this completely.
2. **Max run** — a cap on one continuous run. On the free plan the service sets
   it (a run starts around 120 minutes and grows with real use up to ~480).
   Leases do **not** extend it, and the cap cannot be turned off.

Zero interruptions on the free plan therefore isn't possible. What is possible
is avoiding the expensive part: when the platform hits the cap it pauses the
machine and starts a **cooldown** (5–20 minutes, and 60–135 minutes for repeats)
during which nothing can wake it.

So the tool resets the run timer itself, a little before the cap:

```
state running, maxRunMinutes 120, runStartedAt now-115m
  -> suspend, wait for "suspended", resume immediately, wait for "running"
  -> fresh run, cooldown never starts
```

- Trigger: fewer than `IBK_ROTATE_MARGIN_MIN` (default 10) minutes of run left
- Measured downtime in testing: **2 seconds**; memory and processes survive a
  suspend, so apps keep running after the resume
- Machines with `maxRunMinutes: -1` (paid, unlimited) are never touched
- Machines already in a cooldown or not running are skipped
- `status` shows `run left 118m` when rotation is on; `logs` shows
  `rotated <name>: run timer reset, down 2s`
- Turn it off with `IBK_ROTATE=0` or `--rotate=0` (then the platform pauses the
  machine at the cap and the cooldown applies)

The Cloudflare Worker does the same on every cron run (`INSTABOX_ROTATE`,
`INSTABOX_ROTATE_MARGIN_MIN`). Since the cron is every 5 minutes, keep the margin
above 5 so a rotation is always attempted before the cap.

The one thing this cannot protect is a command running *during* the rotation:
it is frozen for those seconds, and an SSH session may drop and need a new
connection. Scheduling is opportunistic (whenever the cap is near), so if you
want rotations at quiet hours instead, that needs an extra window setting — ask.


## Things worth knowing

- **Free-plan max-run still applies.** A lease prevents the *idle* pause, but
  the free plan caps a single run (roughly 120–480 minutes). Rotation (above)
  resets that timer before the cap; if you turn rotation off, the platform pauses
  the machine and starts a cooldown, which the tool reports as
  `skipped ... platform cooldown`.
- **Machines that are paused or stopped by hand** never wake by themselves. The
  daemon tries `wake`, then `resume`, then `start`, and renews after that.
- **Idle-paused machines** are woken by the lease request itself, so nothing
  extra is needed for the normal case.
- **Key safety:** `machines:write` is enough. After a command-line install, the
  key is in shell history once — clear it, or use the wizard, which never echoes
  it. The Worker holds the key server-side; the token is what guards its URLs.
- **Uninstall frees the machines:** it releases the leases first, so they go
  back to pausing after 30 idle minutes.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `HTTP 401 invalid_key` | Key copied wrong, revoked, or expired. Make a new one. |
| `HTTP 403 missing_scope` | Recreate the key with `machines:write`. |
| `HTTP 404 not_found` on a name | Check `status` for the real name, or use all machines. |
| `HTTP 0` / nothing | No network, DNS or proxy problem reaching `api.instabox.sh`. |
| `skipped ... platform cooldown` | Normal after a max-run pause; wait for the cooldown. |
| Termux stops it overnight | Install Termux:Boot, open it once, and disable battery optimisation for Termux. |

## Updating an install

The installed copy is self-contained, so updating means running the new file
over it. Re-run the installer and keep the same settings:

```sh
sh instabox-keepalive.sh install --force
```

The wizard asks for the key again; on the same machine the config directory is
replaced, not merged. To keep the running config untouched (same key, same
machines) just replace the script and restart:

```sh
curl -fsSL https://raw.githubusercontent.com/samperez10/instashit-keepalive/main/instabox-keepalive.sh \
  -o /etc/instabox-keepalive/keepalive.sh
sh /etc/instabox-keepalive/keepalive.sh restart
```

That works because the daemon reads everything from the config file, not the
script. On systemd use `systemctl restart instabox-keepalive`, on OpenRC
`rc-service instabox-keepalive restart`.

## Repo layout

| File | What it is |
| --- | --- |
| `instabox-keepalive.sh` | installer + daemon (VPS / NAS / Termux / InstaBox box) |
| `instabox-keepalive-worker.js` | Cloudflare Worker version |
| `deploy-worker.sh` | optional wrangler deploy helper |
| `README.md` | this guide |

Never commit the generated `config` file: it holds the API key. `.gitignore`
covers it.

## License

MIT, same as the original project.
