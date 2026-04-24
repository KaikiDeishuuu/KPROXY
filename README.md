# kprxy（中文优先）

`kprxy` 是一个面向 Linux 的模块化 Bash 代理维护工具。设计目标：

- 默认隔离运行
- 显式复用资源
- 自动检测冲突
- 与 3x-ui 等现有项目安全共存

## 核心特性

- 双引擎：Xray、sing-box
- 协议栈 / 入站 / 出站 / 路由 / 转发 / 证书 / 订阅导出
- 统一状态检查：`kprxy status`
- 诊断菜单与导出诊断包
- 证书状态与续期任务检测

## 安装与启动

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KaikiDeishuuu/KPROXY/main/install.sh)
kprxy
```

更新：

```bash
kprxy update
```

## 运行状态命令

```bash
kprxy status
kprxy status summary
kprxy status engine
kprxy status cert
kprxy status conflict
```

状态输出包含：

- 运行状态：Xray / sing-box 进程、PID、是否由 systemd 托管、服务名、二进制路径、配置路径
- 端口监听：协议栈端口、本地入站端口、转发监听端口（并显示占用进程）
- 配置状态：配置文件是否存在、路径、最后修改时间、最近渲染状态、当前校验结果
- systemd 状态：active/inactive/failed、enabled/disabled
- 证书状态：域名、fullchain/key 是否存在、issuer/subject/notBefore/notAfter、剩余天数、自动续费状态、续费任务是否存在
- 冲突检测：3x-ui 检测、其他 Xray/sing-box 实例、端口冲突、服务名冲突、配置路径隔离、证书路径复用提醒

## 菜单入口

主菜单 -> `日志与诊断` 提供：

1. 查看完整运行状态
2. 仅查看内核/进程状态
3. 仅查看证书状态
4. 仅查看冲突检测

## 与 3x-ui / 其他面板的兼容策略

`kprxy` 不会默认接管或重写其他面板配置，遵循以下策略：

1. 二进制隔离：默认使用私有引擎路径（如 `/opt/kprxy/bin/*`）
2. 配置隔离：默认使用私有配置路径（如 `/opt/kprxy/runtime/*`）
3. systemd 隔离：使用 `kprxy-xray.service` / `kprxy-singbox.service`
4. 端口冲突预防：创建监听端口前检查 manifest 与当前监听状态
5. 证书隔离：默认使用 `/opt/kprxy/certs/<domain>/`
6. 显式复用：仅在用户明确选择时复用外部证书路径

## 默认隔离路径（root 模式）

- 项目目录：`/opt/kprxy`
- 私有二进制：`/opt/kprxy/bin/`
- 运行配置：`/opt/kprxy/runtime/xray/config.json`、`/opt/kprxy/runtime/sing-box/config.json`
- 日志目录：`/opt/kprxy/runtime/log/`
- 证书目录：`/opt/kprxy/certs/`
- systemd 服务：`kprxy-xray`、`kprxy-singbox`

非 root 默认写入：`<项目目录>/.runtime/kprxy/`

## 证书管理说明

证书菜单支持：

- ACME 签发并安装到私有目录
- 自定义证书接入
  - 模式 1：复制到 kprxy 私有目录（推荐）
  - 模式 2：显式复用外部路径（不会由 kprxy 改写）
- 自动续期配置与测试

## 目录结构（简）

```text
.
├── install.sh
├── forward.sh
├── lib/
├── templates/
├── state/manifest.json
├── output/
└── backups/
```

## 注意事项

- 依赖 `jq`（缺失时会中止依赖相关功能）
- `kprxy` 以“共存优先”为原则，不会默认覆盖其他面板资源
- 若检测到现有 3x-ui 或其他实例，会给出冲突/共存提示
