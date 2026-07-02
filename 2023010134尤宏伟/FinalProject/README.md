# 防火墙与VPN技术及应用 — 期末大作业

## 项目概述

基于 Linux network namespace + iptables + WireGuard 的虚拟网络安全实验，模拟企业网络环境中的防火墙策略和 VPN 远程接入。

## 网络拓扑

```
                    ┌─────────────┐
                    │   internet  │
                    │ 203.0.113.10│
                    └──────┬──────┘
                           │ 203.0.113.0/24
                    ┌──────┴──────┐
                    │      fw     │
        ┌───────────┤ 203.0.113.1 ├───────────┐
        │           │  VPN Server │           │
        │           └──┬──┬──┬───┘     wg0   │
        │              │  │  │       10.10.10.1
        │              │  │  │              │
   ┌────┴───┐   ┌─────┴──┴┐ ┌──┴────┐  ┌───┴────┐
   │ office │   │  guest  │ │  dmz  │  │ remote │
   │10.20.0.2  │10.30.0.2 │ │10.40  │  │10.10   │
   └────────┘   └─────────┘ │.0.2   │  │.10.2   │
                            └───────┘  └────────┘
```

## 地址规划

| 区域 | 网段 | 防火墙侧 | 主机地址 |
|:-----|:-----|:---------|:---------|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 |
| VPN (wg0) | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 |

## 访问控制矩阵

| 来源 | 目标 | 端口 | 预期 | 说明 |
|:-----|:-----|:-----|:-----|:-----|
| office | dmz | 8080 | 允许 | Web服务访问 |
| office | dmz | 22 | 拒绝+LOG | SSH管理端口禁止 |
| office | internet | 任意 | 允许 | NAT上网 |
| guest | office | 任意 | 拒绝+LOG | 访客隔离 |
| guest | dmz | 任意 | 拒绝+LOG | 访客隔离 |
| guest | internet | 任意 | 允许 | NAT上网 |
| internet | dmz(经DNAT) | 8080 | 允许 | DNAT端口转发 |
| internet | 内网 | 任意 | 拒绝+LOG | 外部防护 |
| VPN | office | 任意 | 允许 | VPN接入内网 |
| VPN | dmz | 8080 | 允许 | VPN访问Web |
| VPN | dmz | 22 | 拒绝+LOG | VPN禁止SSH |
| VPN | guest | 任意 | 拒绝+LOG | VPN隔离 |

## 文件结构

```
FinalProject/
├── README.md              # 本文件
├── setup.sh               # 网络环境搭建脚本
├── firewall.sh             # 防火墙策略配置脚本
├── vpn-setup.sh            # WireGuard VPN配置脚本
├── vpn-fw.conf             # fw端VPN配置模板
├── vpn-remote.conf         # remote端VPN配置模板
├── test.sh                 # 完整测试脚本
├── audit.sh                # 安全审计脚本
├── attack.sh               # 攻防演练脚本
├── analysis.md             # 日志分析报告
├── troubleshooting.md     # 故障排查记录
├── screenshots/             # 运行截图目录（20张）
│   ├── 01-ip-netns-list.png
│   ├── 02-fw-ip-addr.png
│   ├── ...
│   └── 20-tcpdump.png
└── keys/                   # WireGuard密钥目录（自动生成）
```

## 运行步骤

### 1. 环境准备
```bash
# 安装依赖
sudo apt update
sudo apt install -y iproute2 iptables wireguard-tools python3 curl tcpdump conntrack

# 克隆项目
cd FinalProject/
```

### 2. 搭建网络环境
```bash
sudo bash setup.sh
```
**截图**: `01-ip-netns-list.png`, `02-fw-ip-addr.png`, `03-office-ip-route.png`, `04-base-ping.png`

### 3. 配置防火墙
```bash
sudo bash firewall.sh
```
**截图**: `05-iptables-forward.png`, `06-iptables-nat.png`

### 4. 配置VPN
```bash
sudo bash vpn-setup.sh
```
**截图**: `07-wg-show.png`, `08-vpn-ping.png`

### 5. 运行测试
```bash
sudo bash test.sh
```
**截图**: `09-office-dmz-pass.png` ~ `14-vpn-dmz-ssh-deny.png`

### 6. 安全审计
```bash
sudo bash audit.sh
```
**截图**: `15-violation-logs.png`, `16-log-stats.png`, `17-recent-logs.png`

### 7. 攻防演练
```bash
sudo bash attack.sh
```
**截图**: `18-attack-scan.png`, `19-defense-conntrack.png`, `20-tcpdump.png`

## 技术要点

### 防火墙策略
- **默认策略**: FORWARD 链设为 DROP，仅放行明确允许的流量
- **状态检测**: 优先放行 ESTABLISHED/RELATED 状态连接
- **区域隔离**: guest 与 office/dmz 完全隔离
- **端口控制**: 仅允许 office 访问 dmz:8080，禁止 SSH(22)
- **NAT**: 内网通过 MASQUERADE 访问外网；DNAT 转发 8080 端口
- **日志**: 所有拒绝流量记录到内核日志，使用 rate limit 防止日志洪水

### VPN 配置
- **协议**: WireGuard（轻量级、高性能）
- **隧道网段**: 10.10.10.0/24
- **权限控制**: VPN 用户仅可访问 office 和 dmz:8080
- **Endpoint**: 203.0.113.1:51820（fw公网地址）

### 安全审计
- **日志前缀**: GUEST-TO-OFFICE / GUEST-TO-DMZ / VPN-TO-DMZ-SSH / INET-TO-OFFICE
- **速率限制**: 5/min burst 10（防止日志洪水）
- **连接跟踪**: 使用 conntrack 查看活跃连接
- **连接数限制**: connlimit 防止单 IP 滥用

## 注意事项

1. **Endpoint 地址**: 拓扑图中 fw 公网地址为 203.0.113.1，请勿使用文档中的 192.0.2.1
2. **remote 网络**: remote 通过 internet 中转到达 fw，需在 internet 上开启 IP 转发
3. **WireGuard UDP**: 防火墙需放行 51820/UDP 端口供 VPN 握手
4. **测试服务**: dmz 上需启动 `python3 -m http.server 8080` 模拟 Web 服务
5. **权限**: 所有脚本需要 root 权限运行
