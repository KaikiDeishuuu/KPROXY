# kprxy（中文优先）

`kprxy` 是一个面向 Linux 的模块化代理管理工具，默认与 3x-ui/其他 Xray/sing-box 工具隔离共存。

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
kprxy status traffic
kprxy uninstall
```

## 新的转发/路由心智模型

把对象分成 5 类：

- 公网服务入口：对外服务监听（通常由“创建服务”自动生成）
- 本地代理入口：本机 SOCKS5/HTTP/Mixed 监听
- 上游代理与出口：direct/block/dns/socks5/http/vless/shadowsocks/selector
- 转发链：把“本地入口”绑定到“上游出口”，并带一条关联路由
- 路由规则：按入口/域名/IP/网络匹配流量到目标出口

推荐顺序：

1. 创建本地代理入口
2. 创建上游代理与出口
3. 创建转发链（推荐）
4. 在“路由与规则”精细化匹配条件
5. 用 `kprxy status traffic` 做健康检查

## 菜单结构（转发/路由重构后）

主菜单核心路径：

1. 创建与管理服务
2. 本地代理与转发
3. 上游代理与出口
4. 路由与规则
5. 证书与域名
6. 订阅与导出
7. 运行状态与诊断
8. 核心与运行控制
9. 备份、清理与卸载
10. 高级绑定/编排
11. 高级设置

## 本地代理入口

在“本地代理与转发”可执行：

- 查看/创建/编辑/删除本地入口
- 创建/查看/编辑/启停/删除转发链
- 查看绑定诊断

创建后会提示下一步（例如去创建转发链或绑定路由）。

## 上游代理与出口

在“上游代理与出口”可执行：

- 查看/创建/编辑/删除上游出口
- 支持 direct、block、dns、socks5、http、vless、shadowsocks、selector

创建后会提示下一步（例如去创建转发链或路由规则）。

## 路由规则全生命周期（含删除）

在“路由与规则”可执行：

- 查看
- 创建
- 编辑
- 启用/禁用
- 删除（支持引用检测）
- 上移/下移
- 手动设置优先级
- 匹配测试

支持匹配维度：

- 入口标签（inbound/local-entry tag）
- 域名后缀
- 域名关键词
- IP/CIDR
- 网络类型（tcp/udp）
- 兜底规则（全部条件留空）

## 删除与引用安全

关键对象删除前会做引用检测并提供安全处理：

- 删除入口：检测路由/转发链引用，可选择“解绑后删除”
- 删除上游出口：检测路由/转发链引用，可选择“改为 direct 后删除”
- 删除路由规则：检测转发链引用，可选择“解绑后删除”
- 删除转发链：可选“仅删链对象”或“级联删除自动创建对象”

## 状态与诊断

```bash
kprxy status
kprxy status summary
kprxy status engine
kprxy status cert
kprxy status conflict
kprxy status traffic
kprxy status reality
```

`status traffic` 会显示：

- 本地入口/公网入口/上游出口/路由/转发链数量
- 路由缺失出口引用
- 路由缺失入口引用
- 转发链绑定失效
- 未被引用的本地入口
- 未被引用的上游出口

## 证书与协议行为

- TLS 型服务（如 VLESS-Vision-TLS、Shadowsocks 2022-TLS）：需要证书
- REALITY 型服务：默认不要求为节点域名签发 TLS 证书
- REALITY 创建时会单独要求 `serverName/dest`，避免和 `address` 混用

## 卸载 / 清理 / 重置

```bash
kprxy uninstall
kprxy uninstall --keep-data
kprxy uninstall --purge
kprxy cleanup
kprxy reset
```

默认保守：`uninstall` 保留数据，`--purge` 才彻底清理（不可恢复）。

## 与 3x-ui / 其他项目共存

- 二进制隔离：`/opt/kprxy/bin/*`
- 配置隔离：`/opt/kprxy/runtime/*`
- 服务名隔离：`kprxy-xray` / `kprxy-singbox`
- 证书隔离：`/opt/kprxy/certs/*`
- 卸载默认只处理 kprxy 自有资源，不覆盖他人服务/配置
