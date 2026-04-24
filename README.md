# kprxy（中文优先）

`kprxy` 是一个面向 Linux 的模块化代理管理工具。产品目标是：

- 普通用户按“创建服务 -> 创建本地代理入口 -> 导出配置 -> 查看状态”完成流程
- 高级用户仍可使用模板/监听入口/路由等细粒度控制
- 默认与 3x-ui、其他 Xray/sing-box 项目安全共存

## Quick Start（最短路径）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KaikiDeishuuu/KPROXY/main/install.sh)
kprxy
```

常用命令：

```bash
kprxy update
kprxy service-wizard
kprxy status
kprxy uninstall
```

## 核心概念（先讲人话）

- 服务：对外可用的代理服务（例如 VLESS/REALITY、Shadowsocks 2022）
- 本地代理入口：本机 SOCKS5/HTTP/Mixed 入口
- 转发：把本地入口流量转发到指定出站目标
- 路由与规则：控制流量走向

高级概念（在“高级设置”中）：

- 协议模板：定义协议/加密/传输参数
- 监听入口：定义端口监听方式并可绑定协议模板

## 一键搭建向导（推荐）

```bash
kprxy service-wizard
```

该向导会自动完成：

- 创建协议模板（服务主体）
- 自动创建并绑定公网监听入口（元数据绑定）

这让普通用户无需先理解“模板/入站绑定”即可完成服务创建。

## 安装与启动

见上方 Quick Start。

## 状态命令

```bash
kprxy status
kprxy status summary
kprxy status engine
kprxy status cert
kprxy status conflict
```

状态输出包含：安装状态、内核状态、端口监听、配置状态、systemd 状态、证书状态、冲突检测。

## 卸载 / 清理 / 重置

默认保守：`uninstall` 保留数据。

```bash
kprxy uninstall
kprxy uninstall --keep-data
kprxy uninstall --purge
kprxy cleanup
kprxy reset
```

非交互自动确认：

```bash
kprxy uninstall --keep-data --yes
kprxy uninstall --purge --yes
kprxy cleanup --yes
kprxy reset --yes
```

行为说明：

- `uninstall` / `--keep-data`：移除启动器、kprxy 服务、kprxy 私有二进制；保留配置/证书/日志/状态/导出
- `uninstall --purge`：彻底删除 kprxy 自有资源（不可恢复）
- `cleanup`：仅清理临时/缓存/导出产物
- `reset`：重置状态与配置为基线，保留框架安装

## 菜单架构（中文优先）

主菜单：

1. 创建与管理服务
2. 本地代理与转发
3. 路由与规则
4. 证书与域名
5. 订阅与导出
6. 运行状态与诊断
7. 核心与运行控制
8. 备份、清理与卸载
9. 高级设置
0. 退出

设计意图：

- 普通用户优先看到“服务、本地代理、导出、状态”
- “协议模板/监听入口”等抽象概念后置到“高级设置”

## 与 3x-ui / 其他面板的共存策略

- 默认隔离：`/opt/kprxy`（root）或 `<项目目录>/.runtime/kprxy`（非 root）
- systemd 服务名隔离：`kprxy-xray`、`kprxy-singbox`
- 卸载默认只处理 kprxy 自有资源
- 不会默认删除 `xray.service`、`sing-box.service` 或 3x-ui 服务

## 默认隔离路径（root）

- 项目目录：`/opt/kprxy`
- 私有二进制：`/opt/kprxy/bin/`
- 配置：`/opt/kprxy/runtime/xray/config.json`、`/opt/kprxy/runtime/sing-box/config.json`
- 日志：`/opt/kprxy/runtime/log/`
- 证书：`/opt/kprxy/certs/`

## 注意事项

- `--purge` 不可逆
- `--yes` 仅建议用于自动化场景
- 依赖 `jq`（缺失时依赖 manifest 的能力不可用）
