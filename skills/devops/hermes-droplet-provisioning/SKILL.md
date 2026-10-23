---
name: hermes-droplet-provisioning
description: "Use when provisioning a Hermes droplet and WebUI."
version: 0.1.0
author: "@tj597, Hermes Agent"
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [hermes, droplet, digitalocean, hermes-webui, headscale, tailscale, provisioning, runbook]
    related_skills: [hermes-webui-remote-access, hermes-droplet-audit, hermes-agent]
---

# Provisioning a Hermes Droplet

Agent-executable runbook: stand up an always-on Hermes agent on a DigitalOcean droplet,
reachable from a browser and the Hermex iPhone app over a self-hosted Headscale tailnet.
The agent UI is never exposed publicly. This file is the runbook an agent EXECUTES;
`hermes-droplet-setup.md` is the human-readable companion that explains the why — ship both.

## When to Use

- User asks to host Hermes on a server / VPS / droplet / "always-on box"
- User wants Hermes reachable from a phone or browser without exposing it publicly
- User wants hermes-webui on a remote host that does not exist yet

**Don't use for:** hardening or auditing an existing droplet (that's `hermes-droplet-audit`);
installing the web UI on a host that already exists (`hermes-webui-remote-access`).

## Step Tags — obey these, they are the point of this skill

- **AGENT** — the agent acts, then asserts the result before moving on.
- **HUMAN** — stop and ask the user. Never type a secret yourself, never guess a
  username, never act on a value the user has not confirmed.
- **CHECKPOINT** — end your turn. The next step is physically impossible for this
  session; resume in a new one.

## Prerequisites

Two **different** DigitalOcean credentials — never conflate them (an inference key
401s on the account API and vice versa):

- **Model Access Key** — for the inference API. Created by hand in the DO Control
  Panel. **There is no API to create these** (HUMAN).
- **Personal Access Token** (`dop_v1_…`) — for account management via the DO MCP.

MCP servers (agent installs, then a CHECKPOINT — MCP tools load only at session start,
and there is **no `hermes mcp reload`**):

- `digitalocean` — `npx -y @digitalocean/mcp --services apps,droplets,accounts,networking`
- `porkbun` — `npx -y @porkbunllc/mcp-server` (only if DNS is on Porkbun)

Secrets live in `~/.hermes/.env` only. Use `scripts/add-env-secret.sh` — never inline a
`NAME=value` literal in a chat message (secret redaction mangles them and breaks quoting).

## Intake — collect ALL of this before step 1

Asking for these one at a time mid-run is how agents strand a half-built droplet. Get
them up front, then confirm them back in one block:

| Input | Notes |
|---|---|
| `DROPLET_NAME` | e.g. `hermes` |
| `REGION` | DO slug nearest the user, e.g. `tor1` |
| `SIZE` | `s-1vcpu-2gb` recommended; `s-1vcpu-1gb` works **only** with Part 4 swap |
| `DOMAIN` / `SUBDOMAIN` | root domain + subdomain for the VPN control server |
| `SSH_KEY_PATH` | path to the user's **public** key locally |
| `WEBUI_PASSWORD` | must be URL-safe: no spaces, quotes, or backslashes |
| Account keys | `DIGITALOCEAN_API_TOKEN`, Model Access Key, Porkbun keys (if used) |

## Procedure

### 1. AGENT — install the MCP servers

```bash
hermes config set mcp_servers.digitalocean.command npx
hermes config set mcp_servers.digitalocean.args '["-y","@digitalocean/mcp","--services","apps,droplets,accounts,networking"]'
hermes config set mcp_servers.digitalocean.enabled true
hermes config set mcp_servers.porkbun.command npx
hermes config set mcp_servers.porkbun.args '["-y","@porkbunllc/mcp-server"]'
hermes config set mcp_servers.porkbun.enabled true
```

Then HUMAN: have the user run `scripts/add-env-secret.sh` for each key over a
`terminal` SSH-style session (`-t` so the hidden `read -s` prompt works). Verify with
`hermes mcp list`. **Completion:** both servers listed and enabled.

### 2. CHECKPOINT — end your turn

MCP tools are discovered only at session start. Tell the user to restart Hermes
(relaunch the desktop app) and **end the turn**. Do not attempt steps 3+ now — the
`mcp__digitalocean__*` tools do not exist yet. Resume in the new session.

### 3. AGENT — create the droplet and its firewall

Verify the MCP is live first (`hermes mcp test digitalocean`), then via MCP tools:

1. `key_create` — upload the user's **public** key.
2. `droplet_create` — image `ubuntu-24-04-x64`, size `SIZE`, region `REGION`, the new key,
   backups **on**.
3. `firewall_create` — inbound **TCP 22 only**, outbound all; attach the droplet.

**Completion:** `droplet_get` returns `active` with a public IPv4. Record `DROPLET_IP`.

The SSH-only firewall is deliberate. Everything else opens only when a service needs it,
and the agent UI port (8787) **stays closed forever**.

### 4. HUMAN-confirmed — first login and hardening

**Gate: do not guess the SSH user.** fail2ban bans four wrong usernames for an hour on
port 22, and a banned agent cannot reach the box to fix itself. Confirm the user
then SSH as `root` (that is what the key is installed for):

```bash
ssh -i ~/.ssh/<key> root@<DROPLET_IP>
```

On the droplet (AGENT):

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-deploy
chmod 440 /etc/sudoers.d/90-deploy
printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\n' \
  > /etc/ssh/sshd_config.d/99-hardening.conf
systemctl restart ssh
```

**Completion gate — verify BEFORE closing the root session** that `deploy` still gets in:

```bash
ssh -i ~/.ssh/<key> deploy@<DROPLET_IP> 'sudo -n whoami'   # → root
```

If that fails, fix it while you still have the root session. Then install fail2ban.

### 5. AGENT — swap (MANDATORY on 1 GB)

`hermes update` runs `npm ci` + `vite build`, pinning ~58% of RAM. On 1 GB without swap
it thrashes 15+ minutes and can leave `node_modules` half-written.

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=20 && echo 'vm.swappiness=20' | sudo tee -a /etc/sysctl.conf
```

**Completion:** `free -h` shows a non-zero swap row.

### 6. AGENT — install Hermes on the droplet

```bash
sudo apt-get -y install build-essential git python3 python3-venv
ssh -i ~/.ssh/<key> deploy@<DROPLET_IP> \
  'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
```

`build-essential` matters — the installer needs a compiler and silently defers without it.
The launcher is **not** on the non-interactive SSH PATH; prefix remote commands with
`export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"`.
**Completion:** `hermes --version` prints a version over SSH.

### 7. AGENT — DNS record

Create an **A** record `<SUBDOMAIN>.<DOMAIN>` → `<DROPLET_IP>` (Porkbun MCP or the API).
**Completion:** `dig +short <SUBDOMAIN>.<DOMAIN>` returns the droplet IP — Caddy's TLS
issuance in step 8 depends on it, so wait for propagation.

### 8. AGENT — Headscale (self-hosted Tailscale) + Caddy

```bash
ssh deploy@<DROPLET_IP> 'cd /tmp && \
  wget -q https://github.com/juanfont/headscale/releases/download/v0.29.3/headscale_0.29.3_linux_amd64.deb && \
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ./headscale_0.29.3_linux_amd64.deb'
```

`/etc/headscale/config.yaml`: `server_url: https://<SUBDOMAIN>.<DOMAIN>`,
`listen_addr: 127.0.0.1:8080`, `metrics_listen_addr: 127.0.0.1:9090`.

`sudo apt-get -y install caddy` and `/etc/caddy/Caddyfile`:

```
<SUBDOMAIN>.<DOMAIN> {
    reverse_proxy 127.0.0.1:8080
}
```

```bash
sudo systemctl restart headscale caddy && sudo systemctl enable headscale caddy
```

Then, via the DO MCP (`firewall_add_rules`), open inbound **TCP 80 and 443** only.
**Confirm 8787 is NOT in the rules** — that is what keeps the agent private.

Create the Headscale user (AGENT) — note `--user` takes the **numeric** ID, not the name
(the name errors `strconv.ParseUint`):

```bash
sudo headscale users create admin && sudo headscale users list
```

**Completion:** `curl -sI https://<SUBDOMAIN>.<DOMAIN>/health` answers through Caddy.

### 9. HUMAN — join devices to the tailnet

Mint a key on the droplet (`sudo headscale preauthkeys create --user <ID> --reusable --expiration 24h`),
then the USER joins each device — the Tailscale GUI login is theirs to do:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --login-server https://<SUBDOMAIN>.<DOMAIN> \
  --auth-key "$KEY" --hostname <name> --accept-dns=false
```

Order: **laptop first** (first admin node), then the **droplet itself**, then the
**iPhone** — the iOS app needs its own "custom coordination server" flow (step 12).
**Completion:** `tailscale ping` between two nodes succeeds from a client, not the server.
Record the droplet's `TAILNET_IP`.

### 10. AGENT — install hermes-webui

The web UI is a separate third-party project driving the agent already installed here.

```bash
git clone https://github.com/nesquena/hermes-webui.git ~/hermes-webui
cd ~/hermes-webui && python3 bootstrap.py 8787 --host 0.0.0.0 --no-browser --skip-agent-install
```

Write `~/.hermes/webui.env` (chmod 600): `HERMES_WEBUI_HOST=0.0.0.0`,
`HERMES_WEBUI_PORT=8787`, `HERMES_WEBUI_PASSWORD=<from intake>`,
`HERMES_WEBUI_AGENT_CACHE_MAX=2`.

The cache cap is the dominant memory lever — default is **25** warm agents, each pinning
a full transcript; on 1 GB set it to **2**.

Systemd user unit `~/.config/systemd/user/hermes-webui.service` — **`--foreground` is
mandatory** (without it `bootstrap.py` detaches a child and exits; systemd sees its PID
die, respawns into a port held by the orphan, and loops forever):

```ini
[Unit]
Description=Hermes Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/hermes-webui
EnvironmentFile=%h/.hermes/webui.env
Environment=HOME=%h
Environment=PATH=%h/.local/bin:%h/.hermes/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash %h/hermes-webui/start.sh --foreground
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now hermes-webui.service
sudo loginctl enable-linger deploy   # REQUIRED — else it dies at logout, never starts at boot
```

Over SSH, `export XDG_RUNTIME_DIR=/run/user/$(id -u)` first or `systemctl --user` fails
with "Failed to connect to user scope bus".

**Completion:** `curl http://127.0.0.1:8787/health` → `"status":"ok"`.

### 11. AGENT — wire the inference credential (droplet gets ONLY this key)

HUMAN enters the Model Access Key via `scripts/add-env-secret.sh` into the droplet's
`~/.hermes/.env` as `HERMES_CUSTOM_INFERENCE_DO_AI_RUN_API_KEY`. Do **not** copy the DO
PAT or Porkbun keys to the droplet — it is the exposed box and gets the least privilege.

Then AGENT — **set `key_env` on BOTH the `model` and the provider entry.** Omitting it on
the provider yields a silent 401 with `Authorization: Bearer no-key-required`, which
looks like a bad key when the key is fine:

```bash
export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"
MODEL=deepseek-v4.1-flash
hermes config set model.provider inference-do-ai-run
hermes config set model.default "$MODEL"
hermes config set model.base_url https://inference.do-ai.run/v1
hermes config set model.api_mode chat_completions
hermes config set model.key_env HERMES_CUSTOM_INFERENCE_DO_AI_RUN_API_KEY
hermes config set providers.inference-do-ai-run.name Inference.do-ai.run
hermes config set providers.inference-do-ai-run.base_url https://inference.do-ai.run/v1
hermes config set providers.inference-do-ai-run.model "$MODEL"
hermes config set providers.inference-do-ai-run.discover_models true
hermes config set providers.inference-do-ai-run.key_env HERMES_CUSTOM_INFERENCE_DO_AI_RUN_API_KEY
```

**Model-specific trap:** DO's `deepseek-v4.1-flash` rejects the default
`agent.reasoning_effort` value `medium` with HTTP 400 (valid: `low high xhigh max`).
Set `hermes config set agent.reasoning_effort high` for that model.

### 12. HUMAN — hook up the phone (Hermex)

Two App Store apps: **Tailscale** (the WireGuard client) and **Hermex** — a native
third-party client for hermes-webui (`https://hermexapp.com/`, App Store id 6767006319,
not affiliated with upstream). Hermex drives the same hermes-webui server from step 10.

**The stock iOS Tailscale app points at Tailscale's control server — re-point it at your
Headscale.** Do this after step 9 so Headscale is live to answer the login:

1. Tailscale → profile icon (top-right) → **Settings**.
2. Not signed in to any other tailnet → tap **Log in**; otherwise tap the signed-in user.
3. Menu (top-right) → **Use a custom coordination server**.
4. Enter `https://<SUBDOMAIN>.<DOMAIN>` → **Log in**.

Confirm the phone appears in `sudo headscale nodes list`. Then pair Hermex: with
Tailscale **connected**, enter `http://<TAILNET_IP>:8787` + the `HERMES_WEBUI_PASSWORD`.
Use the raw tailnet IP — `--accept-dns=false` means Headscale hands out no hostnames.
A wrong password presents as an *unreachable server*: it is the #1 failure and looks
like a network bug, so check the password before debugging the tailnet.

## Pitfalls

- **Never hand-edit `config.yaml`** — use `hermes config set`; a stray indent corrupts the
  file and breaks the live agent.
- **Never inline `NAME=value` secrets in chat** — redaction replaces the value with `***`,
  producing an unbalanced quote that fails under `set -e`.
- **Never pipe a long remote command through `tail`** — it buffers until exit, so you get
  zero visibility and cannot tell a slow job from a hung one. Detach and tail a log file:
  `ssh host 'setsid nohup bash -c "exec <cmd>" > /tmp/run.log 2>&1 < /dev/null &'`.
- **Never wrap a multi-stage installer in `timeout`** — you kill a working step. On macOS,
  `timeout` is not even present.
- **`pkill -f "server.py"` over SSH kills your own shell** (it matches the remote `bash -c`
  command line, exit 255). Kill by port:
  `PID=$(sudo ss -tlnp | grep ':8787' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2); kill "$PID"`.
- **Port 8787 refusing instantly (RST) with the unit `active` and `NRestarts` climbing** —
  `bootstrap.py` silently fell back to a `.venv` with no pip; the ~6s restart cycle is
  slower than systemd's start-limit window, so it loops silently. Fix by installing
  `pyyaml` + `cryptography` into the store python and pointing `HERMES_WEBUI_PYTHON` at
  `~/.hermes/tools/python-3.14*/bin/python3` (spelled exactly `python3`). Full detail in
  `hermes-webui-remote-access`. This **recurs after every `hermes update`**.

## Verification

Whatever the agent claims is unverified until this passes:

- `curl http://127.0.0.1:8787/health` on the droplet → `"status":"ok"`
- `curl http://<TAILNET_IP>:8787/health` **from a client** → 200
- `curl -o /dev/null -w '%{http_code}' http://<TAILNET_IP>:8787/` → 302 to `/login` (auth enforced)
- `systemctl --user is-active hermes-webui` → `active`; `loginctl show-user deploy | grep Linger` → `yes`
- **An actual agent turn:** `hermes -z "what host are you on and which model?"` → a real
  answer. An up WebUI with no credentials replies "not connected to any AI provider yet";
  `/health` alone proves nothing.
