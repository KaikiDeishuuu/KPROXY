# Proxy Stack

Modular Bash framework for long-term personal proxy maintenance on Linux servers.

## Introduction

Proxy Stack is a shell-native, menu-driven framework with persistent manifest state, template-based rendering, engine lifecycle management, diagnostics, and export tooling. It is designed for maintainable personal operations, not for one-shot scripts or web panels.

## Supported Features

- Dual engines: xray-core and sing-box
- Layered stack presets:
  - VLESS-Vision-TLS
  - VLESS-Vision-uTLS-REALITY
  - VLESS-gRPC-uTLS-REALITY
  - VLESS-Reality-XHTTP
  - Shadowsocks 2022 (optional TLS mode)
- VLESS SNI camouflage and uTLS fingerprint parameters in stack/outbound/export paths
- Inbound/outbound/routing management
- Forwarding split into dedicated module and entrypoint:
  - `lib/forward.sh`
  - `forward.sh`
- ACME/manual certificate workflows
- Share links, Base64 subscription, Clash.Meta, Xray client, sing-box client export
- Initialized rules bundle generation for first-time subscription import:
  - `custom_direct.yaml`
  - `custom_proxy.yaml`
  - `custom_reject.yaml`
  - `lan.yaml`
  - `default_rules.yaml`
  - `README.md`
- Diagnostic bundle and backup/restore workflows
- Random-safe port assignment:
  - custom input accepted
  - Enter key auto-selects available port
  - avoids occupied/listening ports and manifest collisions

## Prerequisites

Required commands:

- `bash`
- `jq`
- `curl`
- `openssl`
- `tar`
- `sed`
- `awk`
- `grep`

Recommended commands:

- `systemctl`
- `ss`
- `journalctl`
- `base64`

`jq` is a required runtime dependency. Manifest operations and most management paths are jq-driven.

## Installation Examples

### Main Framework Install (Remote One-Line)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) \
  --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

### Framework Upgrade/Update (Remote)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) \
  --upgrade --install-dir "$HOME/proxy-stack" \
  --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

### Forwarding-Specific Setup Path

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) \
  --mode forward --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

After local bootstrap, forwarding can also be launched directly:

```bash
bash "$HOME/proxy-stack/forward.sh"
```

### Local Clone + Manual Install Path

```bash
git clone https://github.com/<user>/<repo>.git
cd <repo>
chmod +x install.sh forward.sh
bash install.sh
```

## Upgrade Notes

- Re-running the remote installer with `--upgrade` updates scripts/templates.
- Existing manifest state under `state/manifest.json` is preserved.

## Initialized Rules Bundle Workflow

Subscription/export workflow now supports initialized routing bundle output for first-time clients.

Menu path:

- `Subscriptions and Export -> Export initialized rules bundle`
- `Subscriptions and Export -> Export client config + initialized rules bundle`

Export outputs use versioned directories under `output/` to avoid blind overwrite, for example:

```text
output/client-rules-bundle-20260101-120000/
├── subscriptions/
│   ├── all.txt
│   └── all.b64.txt
├── clash/
│   ├── config.yaml
│   └── rules/
│       ├── custom_direct.yaml
│       ├── custom_proxy.yaml
│       ├── custom_reject.yaml
│       ├── lan.yaml
│       ├── default_rules.yaml
│       └── README.md
├── xray/
│   ├── client.json
│   └── client-<stack_id>.json
├── singbox/
│   ├── client.json
│   └── client-<stack_id>.json
└── rules/
  ├── custom_direct.yaml
  ├── custom_proxy.yaml
  ├── custom_reject.yaml
  ├── lan.yaml
  ├── default_rules.yaml
  └── README.md
```

Default diversion chain:

- LAN/private traffic -> DIRECT
- CN domain/IP -> DIRECT
- custom_reject -> REJECT/BLOCK
- custom_direct -> DIRECT
- custom_proxy -> PROXY
- fallback -> PROXY

Engine behavior:

- Clash.Meta directly references generated rule files in `clash/rules/`.
- Xray/sing-box client exports include embedded default fallback routing and also export standalone rules for manual extension.

## Uninstall Notes

This scaffold does not force-delete runtime state automatically. Recommended manual cleanup:

```bash
# stop services first if installed
sudo systemctl stop proxy-stack-xray proxy-stack-singbox 2>/dev/null || true

# remove systemd units if present
sudo rm -f /etc/systemd/system/proxy-stack-xray.service
sudo rm -f /etc/systemd/system/proxy-stack-singbox.service
sudo systemctl daemon-reload

# remove project directory
rm -rf "$HOME/proxy-stack"
```

## Forwarding Usage

Forwarding is implemented in dedicated module/script path and integrated with shared manifest/logging:

- module: `lib/forward.sh`
- entrypoint: `forward.sh`
- installer mode: `install.sh --mode forward`

Forwarding creation includes interactive port handling with Enter-for-random behavior.

## Runtime Constraint Handling (`jq` Missing)

### Design-time implementation

- Project intentionally depends on `jq`.
- Manifest read/write, route/export/render paths are jq-based.
- Code includes preflight checks and explicit failure messages for missing jq.

### Runtime behavior when jq is absent

- Installer preflight fails clearly and exits non-zero.
- jq-dependent runtime validation/execution is blocked by design.
- The framework does not fake successful execution.

### Expected output example (not confirmed execution result)

```text
========================================
 Dependency Check
========================================
[MISSING] jq (required for manifest/state runtime)
[OK] curl
...
[ERROR] Preflight dependency check failed.
[ERROR] Blocked: jq-dependent runtime validation/execution cannot run in this environment.
Remediation (Debian/Ubuntu): sudo apt-get update && sudo apt-get install -y jq
```

### Debian/Ubuntu jq remediation

```bash
sudo apt-get update && sudo apt-get install -y jq
```

## Directory Layout

```text
.
├── install.sh
├── forward.sh
├── README.md
├── lib/
│   ├── backup.sh
│   ├── cert.sh
│   ├── common.sh
│   ├── crypto.sh
│   ├── diagnostic.sh
│   ├── forward.sh
│   ├── inbound.sh
│   ├── logger.sh
│   ├── outbound.sh
│   ├── render.sh
│   ├── route.sh
│   ├── singbox.sh
│   ├── stack.sh
│   ├── subscribe.sh
│   ├── systemd.sh
│   ├── ui.sh
│   └── xray.sh
├── templates/
│   ├── clash/
│   ├── rules/
│   ├── singbox/
│   ├── systemd/
│   └── xray/
├── state/
│   └── manifest.json
├── output/
└── backups/
```

## Log Locations

Default root mode paths:

- install: `/var/log/proxy-stack/install.log`
- xray access: `/var/log/proxy-stack/xray-access.log`
- xray error: `/var/log/proxy-stack/xray-error.log`
- sing-box: `/var/log/proxy-stack/singbox.log`

Non-root fallback paths are under `.runtime/log/` in the project directory.
