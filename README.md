# Proxy Stack（中文优先说明）

面向 Linux 服务器的模块化 Bash 代理维护框架，强调**可长期维护**、**状态可追踪**、**导出可复用**，适合个人/小规模自建场景。

> English note: A short English appendix is kept at the end for quick reference. Main documentation is Chinese-first.

## 1. 项目简介

Proxy Stack 通过 `install.sh`（主入口）与 `forward.sh`（转发入口）提供交互式菜单，将常见代理维护流程拆分到 `lib/*.sh` 模块。核心状态由 `state/manifest.json` 持久化管理，导出文件按时间戳写入 `output/`，避免覆盖旧结果。

## 2. 功能特性

- 双引擎支持：`xray-core`、`sing-box`
- 分层协议栈预设（VLESS / Shadowsocks 2022）
- 入站、出站、路由、转发、证书、诊断、备份恢复
- 订阅/导出能力：
  - 分享链接（share links）
  - Base64 订阅
  - Clash Meta 客户端配置
  - Xray 客户端配置
  - sing-box 客户端配置
  - 初始化规则包（首次导入友好）
  - 客户端配置 + 初始化规则包（组合导出）
  - 本地代理路由模板导出
- 输出目录使用时间戳子目录（保守覆盖策略）

## 3. 支持的协议栈

当前预设包括（以菜单与代码实现为准）：

- VLESS-Vision-TLS
- VLESS-Vision-uTLS-REALITY
- VLESS-gRPC-uTLS-REALITY
- VLESS-Reality-XHTTP
- Shadowsocks 2022（可选 TLS）

## 4. 目录结构

```text
.
├── install.sh
├── forward.sh
├── lib/
│   ├── stack.sh
│   ├── inbound.sh
│   ├── outbound.sh
│   ├── route.sh
│   ├── subscribe.sh
│   ├── cert.sh
│   ├── forward.sh
│   ├── launcher.sh
│   ├── diagnostic.sh
│   ├── backup.sh
│   └── ...
├── templates/
│   ├── clash/
│   ├── xray/
│   ├── singbox/
│   ├── rules/
│   └── systemd/
├── state/
│   └── manifest.json
├── output/
└── backups/
```

## 5. 安装方式

首次安装完成后，项目会自动写入可执行启动器 `kprxy`（优先 `/usr/local/bin/kprxy`，无 root 权限时回退 `~/.local/bin/kprxy`），后续不需要重复执行远程 `curl | bash`。

### 5.1 一键安装命令（远程）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) \
  --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

### 5.2 手动安装方式（Git clone）

```bash
git clone https://github.com/<user>/<repo>.git
cd <repo>
chmod +x install.sh forward.sh
bash install.sh
```

### 5.3 安装后如何再次启动

```bash
kprxy
```

支持参数透传（当前已接入）：

```bash
kprxy update
kprxy export
kprxy doctor
kprxy logs
kprxy info
kprxy config repo --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

## 6. 更新方式

推荐方式（已安装启动器后）：

```bash
kprxy update
```

`kprxy update` 的仓库元数据解析优先级：

1. 显式 CLI 参数（`--gh-user/--gh-repo/--gh-branch`）
2. 已持久化元数据（`state/repo-meta.conf`）
3. 内置默认值（仅当不是 `<user>/<repo>/<branch>` 占位符）

若三层都无法得到真实值，会明确失败并提示使用：

```bash
kprxy config repo --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

也可以查看当前状态：

```bash
kprxy info
```

或使用远程安装脚本升级：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) \
  --upgrade \
  --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

说明：升级会同步脚本与模板，`state/manifest.json` 会保留。
同时会刷新 `state/repo-meta.conf`（当仓库元数据可确定时）。

## 7. 卸载/清理说明

```bash
# 1) 停服务（若已安装）
sudo systemctl stop proxy-stack-xray proxy-stack-singbox 2>/dev/null || true

# 2) 删除 systemd 单元（若存在）
sudo rm -f /etc/systemd/system/proxy-stack-xray.service
sudo rm -f /etc/systemd/system/proxy-stack-singbox.service
sudo systemctl daemon-reload

# 3) 删除启动器（按你的安装模式选择）
sudo rm -f /usr/local/bin/kprxy
rm -f "$HOME/.local/bin/kprxy"

# 4) 删除项目目录（按你的安装模式选择）
sudo rm -rf /opt/kprxy /usr/local/share/kprxy
rm -rf "$HOME/.local/share/kprxy"

# 5) 可选：删除运行产物
rm -rf "$HOME/.config/proxy-stack" "$HOME/.cache/proxy-stack"
```

## 7.1 PATH 提示策略（减少重复噪音）

- 安装阶段：仅在启动器目录不在 PATH 时提示完整 PATH 配置建议。
- 运行阶段：默认不重复提示；仅在确实检测到 `kprxy` 不可解析且此前未提示过时，给出简短提醒。
- 项目通过状态标记文件抑制重复提示，避免每次启动都打印同一段 PATH 指引。

## 8. 交互式菜单说明

主菜单路径：

- Stack Management
- Inbound Management
- Outbounds and Routing
- Certificates and Domains
- Subscriptions and Export
- Logs and Diagnostics
- Engines and Services
- Backup and Restore

订阅/导出子菜单（当前实现）：

1. Generate share links
2. Generate Base64 subscription
3. Export Clash.Meta
4. Export Xray client config
5. Export sing-box client config
6. Export initialized rules bundle
7. Export client config + initialized rules bundle
8. Export local proxy templates with routing

## 9. 订阅与导出说明

导出统一由 `lib/subscribe.sh` 负责，所有输出写入 `output/<label>-<timestamp>/`：

- 分享链接：`subscriptions/all.txt`
- Base64：`subscriptions/all.b64.txt`
- Clash Meta：`clash/config.yaml`
- Xray：`xray/client.json` 与 `xray/client-<stack_id>.json`
- sing-box：`singbox/client.json` 与 `singbox/client-<stack_id>.json`
- 规则包：`rules/*`，并镜像到 `clash/rules/*`
- 本地路由模板：`local-proxy-routing-template.md`

### 组合导出工作流

选择 `Export client config + initialized rules bundle` 后，会在同一目录内依次尝试导出上述各类文件；若部分步骤失败会明确提示失败步骤，不会伪装全部成功。

## 10. 初始化规则配置说明

初始化规则包包含：

- `custom_direct.yaml`
- `custom_proxy.yaml`
- `custom_reject.yaml`
- `lan.yaml`
- `default_rules.yaml`
- `README.md`

设计理念：**保守初始化（conservative default）**。先保证可用和可解释，再逐步加规则，不鼓励一次性加过宽规则。

⚠️ 注意：不建议直接使用过宽通配规则（例如 `+.microsoft.com`），容易误伤业务与更新通道。建议先按实际域名/网段逐步补充。

## 11. 转发/链式代理说明

转发能力是独立入口：

- 安装时直接转发模式：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) \
  --mode forward --gh-user <user> --gh-repo <repo> --gh-branch <branch>
```

- 本地安装后启动转发入口：

```bash
kprxy --mode forward
```

转发模块路径：`lib/forward.sh`。

## 12. 证书与自动续费说明

证书菜单提供：

- 列出现有证书
- ACME 申请
- 手工证书安装
- 自动续期配置
- 续期测试
- SNI / REALITY 参数管理

对于 VLESS 相关配置，建议明确设置并校验：

- `SNI`（服务名）
- `fingerprint`（uTLS 指纹，如 `chrome`）

以上参数会影响导出链接与客户端配置匹配性。

## 13. 日志与诊断说明

日志/诊断菜单支持：

- 查看安装日志、服务日志、访问日志、错误日志
- 调整日志级别
- DNS 日志开关
- 日志轮转配置
- 导出诊断包
- 实时 tail

默认根用户模式日志目录：`/var/log/proxy-stack/`。

## 14. 输出目录结构示例

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
├── rules/
│   ├── custom_direct.yaml
│   ├── custom_proxy.yaml
│   ├── custom_reject.yaml
│   ├── lan.yaml
│   ├── default_rules.yaml
│   └── README.md
└── local-proxy-routing-template.md
```

## 15. 常见注意事项

- 本项目依赖 `jq`，缺失时会明确报错并退出。
- 不要伪造验证结果：无法执行的检查必须说明原因。
- 若当前没有启用的 VLESS 栈，Xray/sing-box 客户端导出会失败（这是预期保护行为）。
- `output/` 为历史产物目录，建议按时间定期清理。

## 16. TODO / 后续规划

- TODO：在具备 `shellcheck` 环境时补充标准化 lint 基线。
- TODO：补充非 Linux / BusyBox 下 `base64` 参数差异兼容处理（当前默认 GNU `base64 -w 0`）。
- TODO：为导出流程增加更细粒度摘要（成功/失败计数与建议修复提示）。

---

## English Appendix (brief)

- Main entry: `install.sh`
- Forwarding entry: `forward.sh`
- Export menu includes share links, Base64, Clash.Meta, Xray client, sing-box client, initialized rules bundle, combined export.
- Outputs are timestamped under `output/` to avoid blind overwrite.
- `jq` is required at runtime; missing dependency is treated as a hard error.
