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
- 本机代理入口：本机 SOCKS5/HTTP/Mixed 监听（给本机程序连接）
- 上游代理出口：direct/block/dns/socks5/http/vless/shadowsocks/selector（流量最终去向）
- 转发链：把“本地入口”绑定到“上游出口”，并带一条关联路由
- 路由规则：按入口/域名/IP/网络匹配流量到目标出口

三层核心模型：

`入口 -> 规则 -> 出口`

说明：
- 入口：流量从哪里进来（例如 `127.0.0.1:1080`）
- 规则：按什么条件分配流量（入口标签/域名/IP/网络）
- 出口：流量最终从哪里出去（direct 或远端上游）

推荐顺序：

1. 创建本机代理入口
2. 创建上游代理出口
3. 创建转发链（推荐）
4. 在“路由规则”精细化匹配条件
5. 用 `kprxy status traffic` 做健康检查

## 菜单结构（转发/路由重构后）

主菜单核心路径：

1. 创建与管理服务
2. 本机代理入口与转发
3. 上游代理出口
4. 路由规则
5. 证书与域名
6. 订阅与导出
7. 运行状态与诊断
8. 核心与运行控制
9. 备份、清理与卸载
10. 高级绑定/编排
11. 高级设置

## 本机代理入口

在“本机代理入口与转发”可执行：

- 查看/创建/编辑/删除本地入口
- 创建/查看/编辑/启停/删除转发链
- 查看绑定诊断

创建入口后会提示：
- 本机程序如何连接（如 `127.0.0.1:<port>`）
- 下一步去“转发链”或“路由规则”完成流量分配

## 上游代理出口

在“上游代理出口”可执行：

- 查看/创建/编辑/删除上游出口
- 支持 direct、block、dns、socks5、http、vless、shadowsocks、selector

创建出口后会提示：该出口不会自动被使用，需由“路由规则”或“转发链”指向它。

## 路由规则全生命周期（含删除）

在“路由规则”可执行：

- 查看
- 创建
- 编辑
- 启用/禁用
- 删除（支持引用检测）
- 上移/下移
- 手动设置优先级
- 匹配测试

创建/编辑路由时默认使用“选择列表”而不是手输标签：

- 可直接选择服务入口（自动绑定运行标签 `stack-<stack_id>`）
- 可直接选择本机入口（SOCKS5/HTTP/Mixed）
- 支持单选、多选（逐项勾选）
- 仍保留“手动输入标签（高级）”作为覆盖模式
- 默认先显示“简洁单选列表”；多选/手动/任意入口放在“高级选择”里

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

## VLESS + REALITY + 上游出口排障要点

- 路由规则中的入口匹配支持三种写法：
- 本机入口 tag（如 `local-socks-xxxx`）
- 服务名称（如 `vless-real`）
- stack_id（如 `stack-xxxx` 的原始 ID）
- 渲染时会自动映射为运行入站标签 `stack-<stack_id>`，避免“测试命中但运行不命中”。

- 对于 SOCKS5/HTTP 上游，如果需要认证，请确认配置了用户名和密码。
- `kprxy status traffic` 会显示 `SOCKS5/HTTP 出口鉴权缺失`。
- `kprxy status reality` 会显示每个 REALITY 服务的：
- 运行入站标签
- 首条匹配规则与目标出口
- 目标出口远端与鉴权状态

## 常见场景说明

如果你要的是：
“客户端连接我的 VLESS 服务，再从 JP SOCKS5 上游出口转发”

常用路径是：
1. 创建与管理服务（对外入口）
2. 上游代理出口（创建 JP SOCKS5）
3. 路由规则（把对应流量指向 JP SOCKS5）

如果你还希望服务器本机程序也走代理，再额外创建：
- 本机代理入口（SOCKS5/HTTP/Mixed）

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
