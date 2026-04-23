````markdown
# Build a Modular Personal Proxy Deployment Shell Framework

You are to design and implement a **personal-use proxy deployment shell framework** for Linux servers. This is **not** a web panel and **not** a single giant `install.sh`. It must be a **modular, maintainable, menu-driven Bash project** with clear separation of concerns, persistent state, template-based rendering, logging, diagnostics, certificate automation, routing, and export/subscription generation.

The end result should be suitable for **long-term personal maintenance**, not a one-off demo script.

---

## 1. Project Goal

Build a **Bash-based CLI framework** that can install, configure, manage, and export configurations for the following proxy stack features:

### 1.1 Dual engine support
- `xray-core`
- `sing-box`

### 1.2 Built-in protocol stack presets
At minimum, provide these preset stack templates:

1. `VLESS-Vision-TLS`
2. `VLESS-Vision-uTLS-REALITY`
3. `VLESS-gRPC-uTLS-REALITY`
4. `VLESS-Reality-XHTTP`
5. `Shadowsocks 2022`

Important:
- Do **not** implement these as five completely unrelated code paths.
- Internally model them using composable layers:
  - **Protocol layer**: `VLESS` / `Shadowsocks 2022`
  - **Security layer**: `TLS` / `REALITY`
  - **Transport layer**: `RAW(TCP)` / `gRPC` / `XHTTP`
  - **Flow layer**: `Vision`
  - **Fingerprint layer**: `uTLS`
- The five items above should be implemented as **preset templates** on top of this layered model.

### 1.3 Inbounds / outbounds / routing / forwarding
Support the following:

#### Inbounds
- Public server inbounds
  - `VLESS inbound`
  - `Shadowsocks inbound`
- Local proxy inbounds
  - `SOCKS5`
  - `HTTP`
  - `Mixed`

#### Outbounds
- `direct`
- `block`
- `dns`
- `socks5 upstream`
- `http upstream`
- `vless remote`
- `shadowsocks remote`
- `selector` where appropriate for `sing-box`

#### Routing / forwarding
Support at least:
- Route by `inbound tag`
- Route by `domain suffix`
- Route by `domain keyword`
- Route by `IP/CIDR`
- Route by `network type` (`TCP` / `UDP`)
- Default route
- Forwarding chains such as:
  - local `SOCKS/HTTP/Mixed inbound` -> upstream `SOCKS5`
  - local `SOCKS/HTTP/Mixed inbound` -> remote `VLESS`
  - local inbound -> `direct` / `block`

### 1.4 Certificates and auto-renewal
Support:
- One-click certificate issuance with `acme.sh`
- Modes:
  - `standalone`
  - `webroot`
  - `Cloudflare DNS API`
- Manual certificate installation
- Automatic renewal
- Automatic service reload after renewal

### 1.5 Subscription and export generation
Generate:
- Share links for single nodes
- Base64 subscription output
- Clash.Meta config
- Xray client config
- sing-box client config

### 1.6 Logging and diagnostics
Implement a logging and diagnostic system including:
- Installation logs
- Service runtime logs
- Xray access log
- Xray error log
- sing-box log
- Real-time log tailing
- Diagnostic bundle export containing:
  - systemd status
  - recent logs
  - listening ports
  - config summary
  - certificate status

---

## 2. Core implementation principles

### 2.1 Do not build a single huge shell file
This must be a **modular project** with a structure similar to:

```bash
proxy-stack/
├─ install.sh
├─ lib/
│  ├─ common.sh
│  ├─ os.sh
│  ├─ deps.sh
│  ├─ crypto.sh
│  ├─ cert.sh
│  ├─ xray.sh
│  ├─ singbox.sh
│  ├─ inbound.sh
│  ├─ outbound.sh
│  ├─ route.sh
│  ├─ render.sh
│  ├─ subscribe.sh
│  ├─ clash.sh
│  ├─ systemd.sh
│  ├─ logger.sh
│  ├─ diagnostic.sh
│  └─ backup.sh
├─ templates/
│  ├─ xray/
│  ├─ singbox/
│  ├─ clash/
│  └─ systemd/
├─ state/
│  └─ manifest.json
└─ output/
````

You may refine the layout, but the design must remain modular.

### 2.2 Persistent state via manifest

Do **not** rely on scattered shell variables as the primary state system.

You must design and use a persistent `state/manifest.json` that stores:

* engines
* stacks
* inbounds
* outbounds
* routing rules
* certificates
* logging settings
* export metadata
* installed versions

### 2.3 Interactive menu-driven CLI

The tool should be **interactive and menu-driven**, not just a flat argument parser.

However:

* internal functions must remain modular
* future non-interactive/CLI argument support should be possible

### 2.4 Idempotency

The framework must behave safely under repeated execution:

* repeated installation should not destroy existing state
* repeated certificate issuance should check current status
* repeated rendering should not append duplicate config blocks
* configs must be validated before reload/restart

### 2.5 Error handling and logging

Use:

* `set -euo pipefail`
* centralized logging functions
* explicit error messages
* optional debug mode

---

## 3. Main menu tree

Implement the following **top-level menu**:

```text
1. Stack Management
2. Inbound Management
3. Outbounds and Routing
4. Certificates and Domains
5. Subscriptions and Export
6. Logs and Diagnostics
7. Engines and Services
8. Backup and Restore
0. Exit
```

### 3.1 Stack Management

Submenu must include:

* List installed stacks
* Create new stack
* Edit stack
* Delete stack
* Enable/disable stack
* Re-render config

When creating a new stack, provide these presets:

* `VLESS-Vision-TLS`
* `VLESS-Vision-uTLS-REALITY`
* `VLESS-gRPC-uTLS-REALITY`
* `VLESS-Reality-XHTTP`
* `Shadowsocks 2022`
* `Custom template`

### 3.2 Inbound Management

Submenu:

* List inbounds
* Create public server inbound
* Create local inbound
* Edit inbound
* Delete inbound
* Bind inbound to stack

### 3.3 Outbounds and Routing

Submenu:

* List outbounds
* Create outbound
* Edit outbound
* Delete outbound
* List routing rules
* Create routing rule
* Create forwarding rule
* Reorder routing priority
* Test route matching

### 3.4 Certificates and Domains

Submenu:

* List certificates
* Issue certificate (ACME)
* Install custom certificate
* Configure auto-renewal
* Test renewal
* Manage SNI / REALITY handshake parameters

### 3.5 Subscriptions and Export

Submenu:

* Generate share links
* Generate Base64 subscription
* Export Clash.Meta
* Export Xray client config
* Export sing-box client config
* Export local proxy templates with routing

### 3.6 Logs and Diagnostics

Submenu:

* View installation log
* View Xray service log
* View sing-box service log
* View access log
* View error log
* Change log level
* Toggle DNS logging
* Configure log rotation
* Export diagnostic bundle
* Tail logs in real time

### 3.7 Engines and Services

Submenu:

* Install/upgrade xray-core
* Install/upgrade sing-box
* Start services
* Stop services
* Restart services
* Reload config
* Show versions
* Uninstall engines

### 3.8 Backup and Restore

Submenu:

* Backup manifest
* Backup config files
* Backup certificates
* Restore backup
* Roll back to previous version

---

## 4. Manifest design requirements

Design a clear `manifest.json` schema. At minimum:

```json
{
  "meta": {
    "project": "proxy-stack",
    "version": "0.1.0"
  },
  "engines": {},
  "stacks": [],
  "inbounds": [],
  "outbounds": [],
  "routes": [],
  "certificates": {},
  "logs": {},
  "exports": {}
}
```

Refine each object in detail.

### 4.1 Stack object

Must include fields such as:

* `stack_id`
* `name`
* `engine`
* `protocol`
* `security`
* `transport`
* `vision`
* `utls`
* `tls_cert_mode`
* `server`
* `port`
* `uuid`
* `flow`
* `reality settings`
* `grpc settings`
* `xhttp settings`
* `enabled`

### 4.2 Inbound object

Must include fields such as:

* `tag`
* `type`
* `listen`
* `port`
* `auth`
* `udp`
* stack binding reference

### 4.3 Outbound object

Must include fields such as:

* `tag`
* `type`
* direct/block/socks/http/vless/ss selector
* server/port/auth as needed

### 4.4 Route object

Must include fields such as:

* `name`
* `priority`
* `inbound_tag`
* `domain_suffix`
* `domain_keyword`
* `ip_cidr`
* `network`
* `outbound`

### 4.5 Certificates object

Must include fields such as:

* `domain`
* `fullchain path`
* `key path`
* `issuer`
* `renew mode`
* `renew enabled`

### 4.6 Logs object

Must include fields such as:

* `install_log`
* `xray_access`
* `xray_error`
* `singbox_log`
* `level`
* `dns_log`
* `mask_address`

---

## 5. Rendering and templating requirements

Configuration generation must follow a **template + renderer** model.

### Requirements

1. Do **not** hardcode huge JSON blobs directly inside shell logic
2. Use template files under `templates/`
3. Validate input parameters before rendering
4. Validate rendered configs before activation:

   * Xray: use `xray run -test`
   * sing-box: use its validation/check/format mechanism
5. On render failure, do **not** overwrite the last working config
6. On success:

   * back up the previous config
   * atomically replace the target config

---

## 6. Logging requirements

### 6.1 Installation log

All major framework operations must be logged to:

```text
/var/log/proxy-stack/install.log
```

### 6.2 Xray log support

Support configuring:

* access log path
* error log path
* log level
* DNS logging
* address masking

### 6.3 sing-box log support

Support separate log configuration and viewing for sing-box.

### 6.4 Diagnostic bundle

Export a `.tar.gz` bundle containing:

* manifest summary
* systemd status
* engine versions
* last 200 log lines
* listening ports
* certificate status
* summary of active stacks and routes

---

## 7. Engineering quality requirements

Strictly follow these constraints:

1. Use **Bash**
2. Target Debian/Ubuntu compatibility first
3. Write code in a **shellcheck-friendly** style
4. Use consistent function naming
5. Write clear comments
6. Do **not** use Python or Go as the primary implementation language
7. You may depend on:

   * `jq`
   * `curl`
   * `openssl`
   * `systemctl`
   * `tar`
   * `sed`
   * `awk`
   * `grep`
8. Centralize paths, service names, and log paths
9. Keep output clean and professional
10. Require confirmation for dangerous operations such as:

* deleting stacks
* overwriting certificates
* uninstalling engines
* clearing logs

---

## 8. Deliverables

Produce a **first working scaffold** of the project including at least:

1. `install.sh`
2. `lib/common.sh`
3. `lib/logger.sh`
4. `lib/crypto.sh`
5. `lib/cert.sh`
6. `lib/xray.sh`
7. `lib/singbox.sh`
8. `lib/inbound.sh`
9. `lib/outbound.sh`
10. `lib/route.sh`
11. `lib/render.sh`
12. `lib/subscribe.sh`
13. `lib/systemd.sh`
14. `lib/diagnostic.sh`
15. `lib/backup.sh`
16. Example template files
17. Initial `manifest.json`
18. `README.md`

---

## 9. Output format requirements

Output in this order:

1. Project directory tree
2. Key design notes
3. File contents, one file at a time
4. Code must be complete, not pseudocode
5. If a part is MVP-only, mark it clearly as `TODO`
6. The scaffold must be suitable for real continuation and maintenance, not disposable example code

---

## 10. Additional constraints

* Do **not** build a web UI
* Do **not** add a database dependency
* Do **not** optimize for flashy UX
* Optimize for stability, maintainability, and long-term personal use
* Keep the style engineering-oriented
* Do **not** centralize all logic into the main script
* Leave room for future extension:

  * `TUN` / `TPROXY`
  * `FakeDNS`
  * additional stack templates
  * non-interactive CLI mode

---

## 11. If the full output is too long

If output length becomes too large, then proceed in the following staged order:

### Stage 1

Output:

1. Full design summary
2. Directory tree
3. `install.sh`
4. `lib/common.sh`
5. `lib/logger.sh`
6. `state/manifest.json`
7. `README.md`

### Stage 2

Then continue with the remaining modules until the scaffold is complete.

Do not stop early. Continue until the project is structurally complete.

---

## 12. Style expectations

* Be precise and implementation-oriented
* Avoid generic high-level fluff
* Make sensible engineering tradeoffs
* Prefer safe defaults
* Assume this project will be maintained over time
* Use a layered architecture instead of copy-pasted per-protocol branches

Start now.

```
```
