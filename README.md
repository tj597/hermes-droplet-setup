# Hermes droplet — setup guide + agent runbook

Stand up an always-on Hermes agent on a DigitalOcean droplet, reachable from a browser
and the Hermex iPhone app over a self-hosted Tailscale network (Headscale). The agent
UI is never exposed publicly.

Two artifacts, two audiences:

| Path | For |
|---|---|
| [`hermes-droplet-setup.md`](https://github.com/tj597/hermes-droplet-setup/blob/main/hermes-droplet-setup.md) | Humans. Read it top to bottom, or hand it to someone who wants to understand what each step does and why. |
| [`skills/devops/hermes-droplet-provisioning/`](https://github.com/tj597/hermes-droplet-setup/tree/main/skills/devops/hermes-droplet-provisioning) | Agents. A runbook an agent loads and executes, stopping at the HUMAN and CHECKPOINT steps. |

Ship them together: the skill assumes the reader can consult the guide for the reasoning
behind each step.

## Repository layout

| File | What it is |
|---|---|
| [`hermes-droplet-setup.md`](https://github.com/tj597/hermes-droplet-setup/blob/main/hermes-droplet-setup.md) | The human-readable guide — 12 parts plus appendices. |
| [`skills/devops/hermes-droplet-provisioning/SKILL.md`](https://github.com/tj597/hermes-droplet-setup/blob/main/skills/devops/hermes-droplet-provisioning/SKILL.md) | The agent-executable runbook. |
| [`skills/devops/hermes-droplet-provisioning/scripts/add-env-secret.sh`](https://github.com/tj597/hermes-droplet-setup/blob/main/skills/devops/hermes-droplet-provisioning/scripts/add-env-secret.sh) | Hidden-prompt secret writer — keeps secrets out of shell history and chat. |
| [`README.md`](https://github.com/tj597/hermes-droplet-setup/blob/main/README.md) | This file. |
| [`LICENSE`](https://github.com/tj597/hermes-droplet-setup/blob/main/LICENSE) | MIT. |
| [`.gitignore`](https://github.com/tj597/hermes-droplet-setup/blob/main/.gitignore) | Blocks `.env`, `*.bak.*`, and Hermes state files. |

## Install the skill

```bash
mkdir -p ~/.hermes/skills/devops
cp -R skills/devops/hermes-droplet-provisioning ~/.hermes/skills/devops/
# then restart Hermes — skills load at session start
```

Ask your agent to list its skills; `hermes-droplet-provisioning` should appear,
described as "Use when provisioning a Hermes droplet and WebUI."

## What the agent can and cannot do

The skill tags every step `AGENT` / `HUMAN` / `CHECKPOINT`:

- **AGENT** — it executes and verifies (droplet, firewall, hardening, swap, installs,
  Headscale, Caddy, systemd, verification).
- **HUMAN** — needs you: creating the DigitalOcean Model Access Key and PAT, entering
  secrets, choosing a region, the Tailscale login, pairing Hermex.
- **CHECKPOINT** — ends its turn. The first is the MCP restart: MCP servers load only at
  session start, so it configures them, asks you to restart Hermes, and stops.

It is **not unattended**. Expect to supply credentials and make choices at marked points.

## Phone setup (Hermex)

Part 11 of the [guide](https://github.com/tj597/hermes-droplet-setup/blob/main/hermes-droplet-setup.md),
step 12 of the [skill](https://github.com/tj597/hermes-droplet-setup/blob/main/skills/devops/hermes-droplet-provisioning/SKILL.md).
Two App Store apps are required:

- **Tailscale** — the WireGuard client.
- **Hermex** — a native third-party iPhone/iPad client for `hermes-webui`
  (https://hermexapp.com/), not affiliated with the upstream project.

The stock iOS Tailscale app points at Tailscale's own control server, so it must be
re-pointed at your Headscale before it can reach the droplet.

## Security note

Account-wide credentials — the DigitalOcean PAT, the Porkbun API keys — stay on your
workstation. The droplet receives only its inference key. The droplet is the exposed
machine, so it gets the least privilege.

The provided [`.gitignore`](https://github.com/tj597/hermes-droplet-setup/blob/main/.gitignore)
blocks `.env`, `*.bak.*`, and Hermes state files. Never `git init` at or above
`~/.hermes/` — that tree holds live credentials.

## License

MIT — see [`LICENSE`](https://github.com/tj597/hermes-droplet-setup/blob/main/LICENSE).
