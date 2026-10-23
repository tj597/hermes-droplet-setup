# Hosting Hermes on a DigitalOcean droplet + Hermes WebUI

A from-scratch guide to standing up an always-on Hermes agent on a DigitalOcean
droplet, reachable from a browser and the Hermex iPhone app over a self-hosted
Tailscale network (Headscale). No public exposure of the agent UI.

**Audience:** someone with a DigitalOcean account, a domain they control, and a
Hermes install on their own machine. Commands assume macOS or Linux locally.

**The shape of it (control plane / data plane split):**

```
   YOUR LAPTOP (control plane)                 DIGITALOCEAN DROPLET (data plane)
   ┌───────────────────────────┐               ┌──────────────────────────────────┐
   │ Hermes desktop app        │               │ Hermes agent (installed here)    │
   │  ├ DO MCP  (account mgmt) │  SSH/tailnet  │  ├ inference key ONLY            │
   │  ├ Porkbun MCP (DNS)      │ ────────────► │  ├ hermes-webui  :8787 (0.0.0.0) │
   │  └ DO PAT, Porkbun keys   │               │  ├ Headscale   127.0.0.1:8080    │
   │                           │               │  └ Caddy        :443 (TLS)       │
   └───────────────────────────┘               └──────────────────────────────────┘
                                                          ▲ WireGuard (tailnet)
                                                          │  100.64.0.x
                                              iPhone (Hermex) · laptop browser
```

Credential rule: **account-wide credentials stay on your laptop; the droplet
holds only the inference key.** The droplet is the exposed box — it gets the
least privilege.

Throughout, replace:

| Placeholder | Meaning | Example |
|---|---|---|
| `<DROPLET_IP>` | droplet public IPv4 | `203.0.113.10` |
| `<DOMAIN>` | your root domain | `example.com` |
| `<SUBDOMAIN>` | subdomain for the VPN control server | `headscale` |
| `<REGION>` | DO region slug nearest you | `tor1` |
| `<TAILNET_IP>` | droplet's tailnet IP (assigned later) | `100.64.0.x` |

---

## Part 0 — Decisions before you start

| Decision | Recommendation | Why |
|---|---|---|
| Droplet size | `s-1vcpu-2gb` if you can; `s-1vcpu-1gb` works | 1 GB **requires** the swap step (Part 4) or installs thrash |
| Image | Ubuntu 24.04 LTS | what this guide was built on |
| Region | nearest to you | latency to the tailnet |
| Auth | SSH key only, no passwords | Part 4 disables password auth anyway |
| Backups | enable | ~20% of droplet cost, cheap insurance |

You need **two different DigitalOcean credentials** — do not conflate them:

- **Model Access Key** — lets Hermes call the inference API (`inference.do-ai.run`).
  Created by hand in the DO Control Panel (GenAI Platform). **There is no API to
  create these.**
- **Personal Access Token** (`dop_v1_…`) — lets you (and the DO MCP) manage the
  account: droplets, SSH keys, firewalls. Created under API in the Control Panel.

An inference key will 401 on the account API and vice versa.

---

## Part 1 — Local Hermes + the two MCP servers

Install Hermes on your laptop, then wire up the DigitalOcean MCP so you can drive
provisioning by conversation, and the Porkbun MCP so you can create the DNS record.

```bash
# DigitalOcean MCP — apps,droplets,accounts,networking gives you droplet/key/firewall tools
hermes config set mcp_servers.digitalocean.command npx
hermes config set mcp_servers.digitalocean.args '["-y","@digitalocean/mcp","--services","apps,droplets,accounts,networking"]'
hermes config set mcp_servers.digitalocean.enabled true
```

Put the token in the environment file (never inline in a chat message — see
Appendix A on redaction):

```bash
printf 'DIGITALOCEAN_API_TOKEN=%s\n' 'dop_v1_REPLACE_ME' >> ~/.hermes/.env
chmod 600 ~/.hermes/.env
```

```bash
# Porkbun MCP — 96 tools: domains, DNS, transfers, SSL
hermes config set mcp_servers.porkbun.command npx
hermes config set mcp_servers.porkbun.args '["-y","@porkbunllc/mcp-server"]'
hermes config set mcp_servers.porkbun.enabled true
```

Porkbun keys come from Porkbun → Account → **API Access**. You must also toggle
**API Access** on for the specific domain. Note the keys are `pk1_`/`sk1_` and are
**not** masked by Hermes's secret redactor — treat them carefully.

Store them in `~/.hermes/.env` the same way (`PORKBUN_API_KEY`, `PORKBUN_SECRET_API_KEY`).

**Restart Hermes.** MCP tools are discovered only at startup, so the
`mcp__digitalocean__*` and `mcp__porkbun__*` tools won't exist until you relaunch.

---

## Part 2 — Create the droplet (and its firewall)

Have an SSH public key ready (e.g. generated in Bitwarden or `ssh-keygen -t ed25519`).

Via the DO MCP, in order:

1. `key-create` — upload the **public** key.
2. `droplet-create` — image `ubuntu-24-04-x64`, size `s-1vcpu-2gb` (or `s-1vcpu-1gb`),
   region `<REGION>`, with that key, backups **on**.
3. `firewall-create` — name it (e.g. `hermes-firewall`), inbound **TCP 22 only**,
   outbound all; attach the droplet.

That SSH-only firewall is deliberate: everything else gets opened only when a
service genuinely needs it, and the agent UI port (8787) **stays closed forever**.

Save the droplet IP as `<DROPLET_IP>`, and note the droplet ID.

---

## Part 3 — First login and hardening

You can SSH as root initially (that's what the key is installed for), then create a
non-root sudo user and lock root out.

```bash
ssh -i ~/.ssh/<your_key> root@<DROPLET_IP>
```

On the droplet:

```bash
# 1. Non-root user with the same SSH key, passwordless sudo
adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
cp ~/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-deploy
chmod 440 /etc/sudoers.d/90-deploy

# 2. Harden sshd — key-only, no root
printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\n' \
  > /etc/ssh/sshd_config.d/99-hardening.conf
systemctl restart ssh
```

Verify **before** closing the session that you can log in as `deploy`:

```bash
ssh -i ~/.ssh/<your_key> deploy@<DROPLET_IP> 'sudo -n whoami'
# → root
```

Then install fail2ban and keep the OS patched:

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get -y install fail2ban
sudo systemctl enable --now fail2ban
```

> fail2ban default is aggressive-ish; this build used `maxretry 4 / bantime 3600s`
> on port 22. Worst case, four wrong usernames buys an hour of lockout — and only on
> port 22, since 80/443 are unaffected. Keep your key safe.

---

## Part 4 — Swap (mandatory on a 1 GB droplet)

`hermes update` runs `npm ci` + `vite build`, which pins ~58% of RAM. On 1 GB with no
swap it thrashes for 15+ minutes and can leave `node_modules` half-written.

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=20 && echo 'vm.swappiness=20' | sudo tee -a /etc/sysctl.conf
free -h   # confirm the swap row is non-zero
```

---

## Part 5 — Install Hermes on the droplet

```bash
sudo apt-get -y install build-essential git python3 python3-venv
ssh -i ~/.ssh/<your_key> deploy@<DROPLET_IP> \
  'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
```

`build-essential` matters — the installer needs a compiler for native Python deps and
will defer/fail without it.

The Hermes launcher lands at `~/.local/bin/hermes`, which is **not** on the
non-interactive SSH PATH. Prefix remote commands:

```bash
ssh -i ~/.ssh/<your_key> deploy@<DROPLET_IP> \
  'export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"; hermes --version'
```

---

## Part 6 — DNS record

Create an **A** record pointing the subdomain at the droplet. With the Porkbun MCP
(or via the API): host `<SUBDOMAIN>`, type `A`, answer `<DROPLET_IP>`, TTL 300.

Confirm propagation before Part 7 — Caddy's TLS issuance needs it:

```bash
dig +short <SUBDOMAIN>.<DOMAIN>   # should return <DROPLET_IP>
```

---

## Part 7 — Headscale (self-hosted Tailscale) + Caddy

This gives you a private WireGuard network for free, controlled by your own droplet.
Headscale is the control server; it binds to loopback and Caddy terminates TLS in
front of it.

```bash
# Install Headscale (check github.com/juanfont/headscale/releases for current version)
ssh -i ~/.ssh/<your_key> deploy@<DROPLET_IP> 'cd /tmp && \
  wget -q https://github.com/juanfont/headscale/releases/download/v0.29.3/headscale_0.29.3_linux_amd64.deb && \
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ./headscale_0.29.3_linux_amd64.deb'
```

Edit `/etc/headscale/config.yaml` on the droplet:

```yaml
server_url: https://<SUBDOMAIN>.<DOMAIN>
listen_addr: 127.0.0.1:8080
metrics_listen_addr: 127.0.0.1:9090
# ip_prefixes / dns defaults are fine for a small personal tailnet
```

Install Caddy and point it at Headscale:

```bash
sudo apt-get -y install caddy
```

`/etc/caddy/Caddyfile`:

```
<SUBDOMAIN>.<DOMAIN> {
    reverse_proxy 127.0.0.1:8080
}
```

```bash
sudo systemctl restart headscale caddy
sudo systemctl enable headscale caddy
```

**Now open the firewall** — inbound TCP **80 and 443** (80 for the ACME challenge,
443 for TLS). Do it via the DO MCP (`firewall-add-rules`) so the rule state stays
visible in the API. Confirm 8787 is **not** in the rules.

Create your Headscale user and confirm it's live:

```bash
ssh -i ~/.ssh/<your_key> deploy@<DROPLET_IP> 'sudo headscale users create admin && sudo headscale users list'
curl -sI https://<SUBDOMAIN>.<DOMAIN>/health   # caddy should answer
```

> `headscale preauthkeys create --user` takes the **numeric** user ID, not the name —
> the name errors with `strconv.ParseUint`.

---

## Part 8 — Join devices to the tailnet

Do this **from each device**. The client is the stock Tailscale app/binary; only the
login server points at your Headscale.

```bash
# On the droplet: mint a key (reusable, short expiry)
KEY=$(sudo headscale preauthkeys create --user <USER_ID> --reusable --expiration 24h | tail -1)
```

Join each device:

```bash
# macOS (GUI app):
#   Tailscale menu → Log in to a custom server → https://<SUBDOMAIN>.<DOMAIN>
# CLI client on Linux (the droplet is a node on its own tailnet):
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --login-server https://<SUBDOMAIN>.<DOMAIN> \
  --auth-key "$KEY" --hostname <name> --accept-dns=false
sudo tailscale ip -4
```

`--accept-dns=false` stops the control server rewriting the host's resolver.

Join in this order: **your laptop first** (it's the first admin node), then the
**droplet itself**, then the **iPhone** (the iOS app needs its own "custom
coordination server" flow — see Part 11). Verify from a client, not the server:

```bash
tailscale ping <other-node>     # confirms the WireGuard path
```

---

## Part 9 — Install Hermes WebUI (the web/phone surface)

The web UI is a **separate** project (third-party, MIT) that drives the agent already
installed on the droplet. It is not part of the Hermes agent install.

```bash
ssh -i ~/.ssh/<your_key> deploy@<DROPLET_IP> 'export PATH="$HOME/.local/bin:$HOME/.hermes/bin:$PATH"; \
  git clone https://github.com/nesquena/hermes-webui.git ~/hermes-webui && \
  cd ~/hermes-webui && python3 bootstrap.py 8787 --host 0.0.0.0 --no-browser --skip-agent-install'
```

- `--host 0.0.0.0` — binds all interfaces, but the DO firewall blocks 8787, so the
  **tailnet is the only way in**.
- `--skip-agent-install` — "the agent is already here, don't run the installer."

Create `~/.hermes/webui.env` (chmod 600). **Avoid spaces, quotes, and backslashes in
the password** — it's parsed as a systemd `EnvironmentFile`:

```
HERMES_WEBUI_HOST=0.0.0.0
HERMES_WEBUI_PORT=8787
HERMES_WEBUI_PASSWORD=<a-strong-url-safe-password>
HERMES_WEBUI_AGENT_CACHE_MAX=2
```

`HERMES_WEBUI_AGENT_CACHE_MAX` is the big memory lever — it defaults to **25** warm
agent instances, each pinning a full transcript. On 1 GB set it to **2** (or 1).

**systemd user service** — `~/.config/systemd/user/hermes-webui.service`:

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
systemctl --user daemon-reload
systemctl --user enable --now hermes-webui.service
sudo loginctl enable-linger deploy      # REQUIRED — else it dies at logout, never starts at boot
```

`--foreground` is **mandatory**: without it `bootstrap.py` detaches a child and exits,
systemd sees the tracked PID die and respawns into a port already held by the orphan,
looping forever.

---

## Part 10 — Give the droplet its inference credential

The droplet's agent needs the **Model Access Key** — and only that. Do **not** copy
your DO PAT or Porkbun keys onto the droplet.

Write the key without putting it in a chat/command line (Appendix A). On the droplet,
`~/.hermes/.env` gets:

```
HERMES_CUSTOM_INFERENCE_DO_AI_RUN_API_KEY=<model-access-key>
```

Then wire the provider. **Set `key_env` on both the `model` and the provider entry** —
omitting it on the provider yields a silent 401 with `Authorization: Bearer
no-key-required`:

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
`agent.reasoning_effort` value `medium` with `HTTP 400` (valid: `low high xhigh max`).
If you use that model:

```bash
hermes config set agent.reasoning_effort high
```

---

## Part 11 — Hook up the phone (Hermex)

**Install two App Store apps:**

| App | What it is | Link |
|---|---|---|
| Tailscale | the WireGuard client | `apps.apple.com/app/tailscale/id1470499037` |
| Hermex | native iPhone/iPad client for `hermes-webui` — third-party, not affiliated with upstream | `apps.apple.com/us/app/hermex/id6767006319` |

Hermex drives the *same* `hermes-webui` server you installed in Part 9. Site and
source: `https://hermexapp.com/` · `https://github.com/uzairansaruzi/hermex`.

**11a. Join the tailnet on iOS.** The stock Tailscale app points at Tailscale's own
control server by default — you must re-point it at your Headscale:

1. Open Tailscale → tap the profile icon (top-right) → **Settings**.
2. If you're not signed in to any other tailnet, tap **Log in**; otherwise tap the
   signed-in user.
3. Tap the menu (top-right) → **Use a custom coordination server**.
4. Enter `https://<SUBDOMAIN>.<DOMAIN>` and tap **Log in**.

Do this *after* Part 8, so Headscale is live to answer the login. Confirm the phone
shows up with `sudo headscale nodes list` on the droplet.

**11b. Pair Hermex.**

1. Make sure Tailscale is **connected** (VPN toggle on) — Hermex reaches the droplet
   over the tailnet, so with the VPN off it cannot connect at all.
2. Open Hermex → enter server URL `http://<TAILNET_IP>:8787` and the
   `HERMES_WEBUI_PASSWORD` from Part 9.
3. The URL is stored in the iOS Keychain.

**Use the raw tailnet IP, not a hostname.** `--accept-dns=false` (Part 8) means
Headscale never hands out DNS names, so `http://<TAILNET_IP>:8787` is the reliable
address. WireGuard encrypts the transport, so plain `http://` is fine here.

A wrong password is the #1 sign-in failure — and it presents as an *unreachable
server*, which sends people debugging the network when the problem is the password.

---

## Part 12 — Verify end to end

```bash
# 1. WebUI healthy, local
ssh deploy@<DROPLET_IP> 'curl -s http://127.0.0.1:8787/health'      # {"status":"ok",...}

# 2. Reachable from a CLIENT over the tailnet (not from the server)
curl -s http://<TAILNET_IP>:8787/health

# 3. Auth is enforced
curl -s -o /dev/null -w '%{http_code}\n' http://<TAILNET_IP>:8787/   # 302 → /login (good)

# 4. Service + linger
systemctl --user is-active hermes-webui.service                      # active
loginctl show-user deploy | grep Linger                              # Linger=yes

# 5. An actual agent turn — the only test that proves credentials work
ssh deploy@<DROPLET_IP> 'export PATH="$HOME/.local/bin:$PATH"; hermes -z "what host are you on and which model?"'
```

An up WebUI with no provider credentials answers `hermes -z` with "not connected to
any AI provider yet" — `/health` alone does not prove a working setup.

---

## Appendix A — Handling secrets over chat/SSH

A chat message is a hostile transport for shell commands. Secret-redaction filters
match `NAME=value`-shaped fragments and replace the value with `***`, **silently
breaking quoting** (an unbalanced quote that then fails under `set -e`).

Instead: write a script locally, `scp` it to the host, `chmod 700`, and run it with an
interactive (`-t`) SSH session so a hidden `read -s` prompt takes the secret:

```bash
ssh -t deploy@<DROPLET_IP> 'bash ~/add-key.sh'
```

Scripts should be idempotent (strip the old line, append the new, atomic write),
back up before writing, and `chmod 600` both temp and target. End with a real
verification — a live agent turn, not just `/health`.

## Appendix B — Known failure modes on this build

| Symptom | Cause | Fix |
|---|---|---|
| `:8787` refuses **instantly** (RST), unit says `active`, `NRestarts` in the hundreds | `bootstrap.py` silently fell back to a broken local `.venv` (no pip); the ~6s restart cycle is slower than systemd's start-limit window, so it loops silently | install `python3.x-venv`, install `pyyaml` + `cryptography` into the store python (below) |
| `ModuleNotFoundError: No module named 'api'` loop | `HERMES_WEBUI_PYTHON` misspelled (`python3.14` vs `python3`) or a symlink alias → `prepare_launch()` re-execs under `-I`, losing `PYTHONPATH` | point `HERMES_WEBUI_PYTHON` at the store python `~/.hermes/tools/python-3.14*/bin/python3`, spelled exactly `python3` |
| WebUI breaks after every `hermes update` | update re-extracts `~/.hermes/tools/`, wiping the store interpreter's site-packages | re-run the store-python `pyyaml cryptography` install |
| `pkill -f "server.py"` over SSH kills your own shell (exit 255) | the pattern matches the remote `bash -c` command line | kill by port: `PID=$(sudo ss -tlnp | grep ':8787' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2); kill "$PID"` |
| `Failed to connect to user scope bus` over SSH | `XDG_RUNTIME_DIR` unset in non-login sessions | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` before `systemctl --user` |

## Appendix C — Maintenance

- **Update the agent:** `hermes update` on the droplet — but do it **without** a shell
  `timeout` wrapper (a timeout can kill `npm ci` mid-install). Detach it and tail a log:
  ```bash
  ssh deploy@<DROPLET_IP> 'setsid nohup bash -c "exec hermes update" > /tmp/hupd.log 2>&1 < /dev/null &'
  ssh deploy@<DROPLET_IP> 'tail -20 /tmp/hupd.log'
  ```
- **Never pipe a long remote command through `tail`** — it buffers until exit, giving
  you zero visibility while it runs.
- **Re-verify after every update:** `/health`, then a live `hermes -z` turn.
- **Optional self-heal:** a droplet-local cron that restarts the WebUI and repairs the
  store python needs **no account credentials** (it's all local), so it stays inside
  the security boundary. Worth adding if you won't always be at your laptop when
  something breaks.
