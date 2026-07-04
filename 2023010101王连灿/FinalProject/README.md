### README.md格式要求

```markdown
# 企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：
- WireGuard版本：
- iptables版本：
| 项目 | 信息 |
|------|------|
| 操作系统 | CentOS Stream 10 |
| 内核版本 | Linux 6.11.0 |
| 架构 | x86_64 |
| WireGuard 版本 | v1.0.0 |
| iptables 版本 | v1.8.10 (nf_tables) |
| iproute2 版本 | 6.10.0 |
| Python 版本 | 3.12 |
| tcpdump 版本 | 4.99.4 |
| 虚拟化平台 | VMware Workstation 17 |
| 内存 | 4 GB |
| CPU | 2 核 |
本实验在单台 CentOS Stream 10 虚拟机中，使用 Linux 网络命名空间（Network Namespace）、veth 虚拟网卡、iptables 防火墙和 WireGuard VPN 技术，模拟了完整的企业级网络环境。

## 二、拓扑图和地址规划
（手绘或工具绘制的拓扑图）
（地址规划表）
```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│ internet (外网主机)                                                                 │
│ IP：203.0.113.10/24                                                                 │
│        │                                                                            │
│        ▼ veth-inet                                                                  │
┌─────────────────────┐                                                               │
│ fw 外网接口         │                                                               │
│ veth-fw-inet        │                                                               │
│ IP：203.0.113.1/24  │                                                               │
└──────────┬──────────┘                                                               │
           │                                                                          │
           ▼                                                                          │
┌─────────────────────────────────────────────────────────────────────────────────────┐
│ fw 防火墙 + VPN 网关核心节点                                                          │
│ 隧道接口 wg0：10.10.10.1/24                                                          │
│ VPN底层接口 veth-fw-remote：192.168.200.1/30                                         │
└───┬───────────────┬────────────────┬────────────────────┬────────────────────────┘
    │               │                │                        │
    ▼               ▼                ▼                        ▼
veth-fw-office  veth-fw-guest   veth-fw-dmz             veth-fw-remote
    │               │                │                        │
    ▼               ▼                ▼                        ▼
┌─────────┐  ┌─────────┐    ┌────────────┐        ┌─────────────────────────────┐
│ office  │  │ guest   │    │ dmz        │        │ remote VPN客户端           │
│ 办公网  │  │ 访客网  │    │ Web服务器  │        │ VPN隧道IP：10.10.10.2/24   │
│10.20.0.2│  │10.30.0.2│    │10.40.0.2   │        │ 底层链路：192.168.200.2/30│
└─────────┘  └─────────┘    └────────────┘        └─────────────────────────────┘
### 2.1 网络拓扑图
本节展示本实验的整体网络架构。如图所示，‘w’作为核心防火墙与 VPN 网关，通过 5 对 veth 虚拟网卡分别连接 ‘office’（办公网）、‘guest’（访客网）、‘dmz’（DMZ 服务区）、‘internet’（模拟外网）以及 ‘remote’（VPN 客户端底层链路）。所有跨区域流量必须经过 ‘fw’ 处理，从而实现集中访问控制与安全审计。
‘remote’ 通过底层链路（192.168.200.0/30）与 ‘fw’ 建立 WireGuard VPN 隧道，获得虚拟 IP 地址 10.10.10.2，进而安全访问办公网和 DMZ 服务区。
### 2.2 地址规划表
本实验共涉及 6 个网段，覆盖办公、访客、DMZ、外网、VPN 底层通信及 VPN 加密隧道。所有地址均遵循 RFC 1918 私有地址规范（除模拟外网使用 RFC 5737 文档示例地址外），确保不会与公网地址冲突。各区域的默认网关均指向 `fw` 侧对应接口，保障流量统一经由防火墙处理。
| 区域 | 网段 | fw侧接口 | fw侧地址 | 主机接口 | 主机地址 | 子网掩码 | 默认网关 |
|:-----|:-----|:---------|:---------|:---------|:---------|:---------|:---------|
| office | 10.20.0.0/24 | veth-fw-office | 10.20.0.1 | veth-office | 10.20.0.2 | 255.255.255.0 | 10.20.0.1 |
| guest | 10.30.0.0/24 | veth-fw-guest | 10.30.0.1 | veth-guest | 10.30.0.2 | 255.255.255.0 | 10.30.0.1 |
| dmz | 10.40.0.0/24 | veth-fw-dmz | 10.40.0.1 | veth-dmz | 10.40.0.2 | 255.255.255.0 | 10.40.0.1 |
| internet | 203.0.113.0/24 | veth-fw-inet | 203.0.113.1 | veth-inet | 203.0.113.10 | 255.255.255.0 | 203.0.113.1 |
| remote底层 | 192.168.200.0/30 | veth-fw-remote | 192.168.200.1 | veth-remote | 192.168.200.2 | 255.255.255.252 | 192.168.200.1 |
| VPN隧道 | 10.10.10.0/24 | wg0 | 10.10.10.1 | wg0 | 10.10.10.2 | 255.255.255.0 | — |

### 2.3 网段选择依据
各网段的选择综合考虑了地址规划规范、区域隔离需求和实验环境的可读性。具体如下：
| 网段 | 选择理由 |
|:-----|:---------|
| 10.20.0.0/24 | RFC 1918 私有地址，用于办公网络，与访客、DMZ 保持网段隔离 |
| 10.30.0.0/24 | RFC 1918 私有地址，用于访客网络，与办公网严格隔离，仅允许访问外网 |
| 10.40.0.0/24 | RFC 1918 私有地址，用于 DMZ 服务区，对外暴露 Web 服务，内网访问受控 |
| 203.0.113.0/24 | RFC 5737 文档示例地址，用于模拟外网，避免与真实公网地址冲突 |
| 192.168.200.0/30 | RFC 1918 私有地址，用于 VPN 底层链路，仅承载 fw 与 remote 之间的 WireGuard 通信 |
| 10.10.10.0/24 | RFC 1918 私有地址，用于 VPN 加密隧道，是 remote 访问内网的虚拟通信网络 |
## 三、第一部分：网络规划与基础搭建
（包含setup.sh的说明和连通性测试结果）
### 3.1 网络命名空间技术简介
Linux 网络命名空间（Network Namespace）是内核提供的网络隔离机制，每个命名空间拥有独立的网络协议栈、路由表、防火墙规则和网络接口。在本实验中，我们创建了 6 个独立的网络命名空间来模拟企业网络中的不同安全区域：
| 命名空间 | 角色 | 职责 |
|:---------|:-----|:-----|
| `fw` | 防火墙 + VPN 网关 | 转发跨区域流量、执行防火墙策略、提供 VPN 接入 |
| `office` | 办公网主机 | 模拟内网员工，访问 DMZ 和外网 |
| `guest` | 访客网主机 | 模拟访客设备，仅能访问外网 |
| `dmz` | 对外服务器 | 运行 Web 服务（8080）和管理服务（22） |
| `internet` | 外网主机 | 模拟互联网用户，访问 DMZ 服务 |
| `remote` | 远程员工 | 通过 VPN 安全接入内网 |
### 3.2 veth 虚拟网卡技术原理
veth（Virtual Ethernet）设备总是成对出现的虚拟网卡，数据包从一端进入，从另一端发出，相当于一条虚拟网线连接两个网络命名空间。本实验创建了 5 对 veth，将 `fw` 分别与 `office`、`guest`、`dmz`、`internet`、`remote` 连接。
形成如下拓扑：
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              veth 连接关系示意图                                      |
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  office     veth-office ────────── veth-fw-office    │                               │
│  (10.20.0.2)        ║                   ║            │                               │ 
│                     ╚═══════════════════╝            │                               │
│                                                      │                               │
│  guest      veth-guest ─────────── veth-fw-guest     │                               │
│  (10.30.0.2)        ║                   ║            │                               │
│                     ╚═══════════════════╝            │                               │
│                                                      │                               │
│  dmz        veth-dmz ───────────── veth-fw-dmz       │                               │
│  (10.40.0.2)        ║                   ║            │              fw               │
│                     ╚═══════════════════╝            │         (网 关)               |
│                                                      │                               |
│  internet   veth-inet ──────────── veth-fw-inet      │                               │
│  (203.0.113.10)      ║                   ║           │                               │
│                      ╚═══════════════════╝           │                               │
│                                                      │                               │
│  remote     veth-remote ────────── veth-fw-remote    │                               │
│  (192.168.200.2)     ║                   ║           │                               │
│                      ╚═══════════════════╝           │                               │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
连接关系表如下：

| 区域 | 区域侧接口 | IP 地址 | veth 对 | fw 侧接口 | IP 地址 | 用途 |
|:-----|:-----------|:--------|:--------|:----------|:--------|:-----|
| office | veth-office | 10.20.0.2/24 | ⟷ | veth-fw-office | 10.20.0.1/24 | 办公网网关 |
| guest | veth-guest | 10.30.0.2/24 | ⟷ | veth-fw-guest | 10.30.0.1/24 | 访客网网关 |
| dmz | veth-dmz | 10.40.0.2/24 | ⟷ | veth-fw-dmz | 10.40.0.1/24 | DMZ 网关 |
| internet | veth-inet | 203.0.113.10/24 | ⟷ | veth-fw-inet | 203.0.113.1/24 | 外网接口 |
| remote | veth-remote | 192.168.200.2/30 | ⟷ | veth-fw-remote | 192.168.200.1/30 | VPN 底层链路 |

每对 veth 的两端分别位于两个命名空间中，各自配置 IP 地址后即可实现跨命名空间的二层通信，为三层路由提供基础。

### 3.3 setup.sh 脚本详细设计
`setup.sh` 是企业网络拓扑的自动化搭建脚本，总代码约 150 行，包含 8 个核心功能模块。脚本设计遵循 **幂等性** 原则——可重复运行，每次执行结果一致。
脚本执行流程如下：
┌─────────────────────────────────────────────────────────────────────────────┐
│                        setup.sh 脚本执行流程                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模块 1：环境清理                                                          │
│  └── 删除所有旧 namespace 和 veth 设备，保障可重复运行                      │
│                        ↓                                                   │
│  模块 2：创建 6 个网络命名空间                                              │
│  └── fw、office、guest、dmz、internet、remote                              │
│                        ↓                                                   │
│  模块 3：创建 5 对 veth 虚拟网线                                            │
│  └── 连接 fw 与各区域（office、guest、dmz、internet、remote）              │
│                        ↓                                                   │
│  模块 4：配置 IP 地址                                                      │
│  └── fw 侧 5 个接口 + 各区域主机接口                                       │
│                        ↓                                                   │
│  模块 5：配置默认路由                                                      │
│  └── 所有区域默认网关指向 fw                                               │
│                        ↓                                                   │
│  模块 6：开启 IP 转发                                                      │
│  └── net.ipv4.ip_forward=1                                                 │
│                        ↓                                                   │
│  模块 7：启用回环接口                                                      │
│  └── 每个命名空间 lo 接口 up                                               │
│                        ↓                                                   │
│  模块 8：自动化连通性测试                                                  │
│  └── 5 组 ping 验证所有基础链路                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

#### 模块 1：环境清理（保障可重复运行）
本模块负责删除所有旧的网络命名空间和残留的 veth 虚拟网卡，确保脚本可重复运行。
设计要点：
循环遍历 6 个命名空间（fw、office、guest、dmz、internet、remote），逐个删除
2>/dev/null 忽略不存在的命名空间报错
|| true 确保脚本不会因删除失败而中断
自动清理系统残留的 veth 虚拟网卡，避免命名冲突
##### 为什么需要环境清理？
在实验过程中，脚本可能需要多次执行（调试、重置、重新搭建）。如果没有清理步骤，第二次执行时会因为"命名空间已存在"或"veth 设备已存在"而报错。清理步骤确保了脚本的幂等性——无论执行多少次，结果都是一致的。

#### 模块 2：创建 6 个网络命名空间
本模块创建 6 个独立的网络命名空间，每个命名空间拥有独立的网络协议栈、路由表和防火墙规则。
各命名空间的角色与职责：
| 命名空间 | 角色 | 职责 | 安全级别 |
| ---- | ---- | ---- | ---- |
| fw | 防火墙 + VPN 网关 | 转发跨区域流量、执行防火墙策略、提供 VPN 接入 | 最高（核心） |
| office | 办公网主机 | 模拟内网员工，访问 DMZ 和外网 | 高 |
| guest | 访客网主机 | 模拟访客设备，仅能访问外网 | 低（受控） |
| dmz | 对外服务器 | 运行 Web 服务（8080）和管理服务（22） | 中（暴露外网） |
| internet | 外网主机 | 模拟互联网用户，访问 DMZ 服务 | 无（外部） |
| remote | 远程员工 | 通过 VPN 安全接入内网 | 受 VPN 控制 |
#### 技术原理：
Linux 网络命名空间（Network Namespace）是内核级隔离机制。每个命名空间拥有：
独立的网络协议栈（TCP/IP 协议族）
独立的路由表（可配置不同的默认网关）
独立的防火墙规则（iptables/netfilter）
独立的网络接口（物理或虚拟）
独立的 socket 缓冲区
一个命名空间中的网络配置和流量完全不受其他命名空间影响，实现了网络层面的强隔离。
##### 为什么 fw 作为唯一路由节点？
fw 命名空间承担所有跨区域流量的转发与控制。这种 集中式路由架构 的优势：
统一策略管理：所有防火墙规则只需在 fw 上配置
完整流量可见：所有跨区域流量都经过 fw，便于监控和审计
简化管理：只需维护一个节点的路由和防火墙配置
最小权限：各区域之间不能直接通信，必须经过 fw 的检查

#### 模块 3：创建 5 对 veth 虚拟网线
##### 技术原理：
veth（Virtual Ethernet）是 Linux 内核中的虚拟网络设备，总是成对出现。数据包从一端进入，从另一端发出，相当于一条虚拟网线连接两个网络命名空间。veth 设备工作在网络 L2 层（数据链路层），可以配置 MAC 地址、IP 地址，参与 ARP 和路由。
##### 完整连接关系：
| veth 对 | fw 侧接口 | 区域侧接口 | 连接区域 | 用途 |
|--------|-----------|------------|----------|------|
| veth-fw-office ↔ veth-office | veth-fw-office | veth-office | office | 办公网通信 |
| veth-fw-guest ↔ veth-guest | veth-fw-guest | veth-guest | guest | 访客网通信 |
| veth-fw-dmz ↔ veth-dmz | veth-fw-dmz | veth-dmz | dmz | DMZ 服务区通信 |
| veth-fw-inet ↔ veth-inet | veth-fw-inet | veth-inet | internet | 外网通信 |
| veth-fw-remote ↔ veth-remote | veth-fw-remote | veth-remote | remote | VPN 底层链路 |
##### veth 连接拓扑图：
┌─────────────────────────────────────────────────────────────────────────────┐
│                           veth 连接关系                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  veth-fw-office  ←───→  veth-office    (fw ←───→ office)                   │
│  veth-fw-guest   ←───→  veth-guest     (fw ←───→ guest)                    │
│  veth-fw-dmz     ←───→  veth-dmz       (fw ←───→ dmz)                      │
│  veth-fw-inet    ←───→  veth-inet      (fw ←───→ internet)                 │
│  veth-fw-remote  ←───→  veth-remote    (fw ←───→ remote 底层)              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
#### 模块 4：配置 IP 地址
本模块为 fw 的 5 个接口和各区域主机配置 IP 地址。

##### fw 侧接口配置
| 接口 | IP 地址 | 子网掩码 | 所属区域 | 角色 |
| ---- | ---- | ---- | ---- | ---- |
| veth-fw-office | 10.20.0.1 | 255.255.255.0 | office | 办公网网关 |
| veth-fw-guest | 10.30.0.1 | 255.255.255.0 | guest | 访客网网关 |
| veth-fw-dmz | 10.40.0.1 | 255.255.255.0 | dmz | DMZ 网关 |
| veth-fw-inet | 203.0.113.1 | 255.255.255.0 | internet | 外网接口 |
| veth-fw-remote | 192.168.200.1 | 255.255.255.252 | remote | VPN 底层网关 |

##### 各区域主机配置
| 区域 | 接口 | IP 地址 | 子网掩码 | 默认网关 |
| ---- | ---- | ---- | ---- | ---- |
| office | veth-office | 10.20.0.2 | 255.255.255.0 | 10.20.0.1 |
| guest | veth-guest | 10.30.0.2 | 255.255.255.0 | 10.30.0.1 |
| dmz | veth-dmz | 10.40.0.2 | 255.255.255.0 | 10.40.0.1 |
| internet | veth-inet | 203.0.113.10 | 255.255.255.0 | 203.0.113.1 |
| remote | veth-remote | 192.168.200.2 | 255.255.255.252 | 192.168.200.1 |

#### 模块 5：配置默认路由
本模块为各区域主机配置默认路由，所有流量指向 fw 对应的网关地址。
┌─────────────────────────────────────────────────────────────────────────────┐
│                        路由设计原理图                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   任何需要离开本区域的流量都必须经过 fw                                     │
│                                                                             │
│   office (10.20.0.2) ──→ 默认网关 10.20.0.1 ──→ fw 路由决策               │
│   guest  (10.30.0.2) ──→ 默认网关 10.30.0.1 ──→ fw 路由决策               │
│   dmz    (10.40.0.2) ──→ 默认网关 10.40.0.1 ──→ fw 路由决策               │
│   internet(203.0.113.10)→ 默认网关 203.0.113.1 ──→ fw 路由决策            │
│   remote (192.168.200.2)→ 默认网关 192.168.200.1 ──→ fw 路由决策          │
│                                                                             │
│   ★ 这种设计实现了集中式流量控制                                           │
│   ★ 所有跨区域通信都需要经过防火墙检查                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
##### 为什么需要配置默认路由？
默认路由是 IP 路由表中的特殊条目，用于指定"当目标 IP 不在本地子网中时，数据包应该发往何处"。如果没有配置默认路由，主机只知道如何发送数据到本地子网，不知道如何发送到其他网络。

#### 模块 6：开启 IP 转发
本模块在 fw 命名空间中开启 IP 转发功能，使 fw 能够在不同接口之间路由数据包。
ip转发工作原理：
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IP 转发工作原理                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   office 发送包到 dmz:                                                      │
│                                                                             │
│   1. office 发出包 (目标 10.40.0.2)                                        │
│      ↓                                                                      │
│   2. 包到达 fw 的 veth-fw-office 接口                                      │
│      ↓                                                                      │
│   3. fw 查找路由表，决定从哪个接口转发                                      │
│      ↓                                                                      │
│   4. fw 将包从 veth-fw-dmz 接口发出                                       │
│      ↓                                                                      │
│   5. 包到达 dmz (10.40.0.2)                                                │
│                                                                             │
│   ★ 如果没有 ip_forward=1，第 3 步失败，包被丢弃                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
##### ip_forward 的必要性：
fw 有多个网络接口，连接不同的子网。ip_forward=1 允许 fw 在不同的接口之间转发数据包，实现跨网段通信。若该配置缺失，即使防火墙规则完全正确，流量也无法在不同区域间转发。
##### 风险提示：
开启 IP 转发会将 Linux 主机变成路由器。在真实生产环境中，需要配合防火墙规则来控制哪些流量可以被转发。
#### 模块 7：回环接口启用
本模块为所有命名空间启用回环接口（loopback）。
##### 回环接口的作用
| 功能 | 说明 |
| ---- | ---- |
| 本地通信 | 进程之间通过 127.0.0.1 通信 |
| 测试工具 | ping 127.0.0.1 验证协议栈正常 |
| 服务绑定 | 服务监听 0.0.0.0 时包含 lo 接口 |
| 路由表 | lo 接口通常有 127.0.0.0/8 路由 |
##### 为什么需要单独启用？
默认情况下，新创建的命名空间的回环接口是 DOWN 状态。如果不启用，命名空间内的进程无法使用 127.0.0.1 进行本地通信。
---
#### 模块 8：自动化连通性测试
脚本内置 5 组 ping 测试，验证所有基础链路的连通性，实现 "搭建即验证" 的自动化流程。
##### 测试覆盖范围
| 测试编号 | 源命名空间 | 源 IP | 目标命名空间 | 目标 IP | 验证内容 |
| ---- | ---- | ---- | ---- | ---- | ---- |
| 1 | office | 10.20.0.2 | fw | 10.20.0.1 | office 网段连通性 |
| 2 | guest | 10.30.0.2 | fw | 10.30.0.1 | guest 网段连通性 |
| 3 | dmz | 10.40.0.2 | fw | 10.40.0.1 | dmz 网段连通性 |
| 4 | internet | 203.0.113.10 | fw | 203.0.113.1 | 外网网段连通性 |
| 5 | remote | 192.168.200.2 | fw | 192.168.200.1 | VPN 底层链路连通性 |

#### 测试策略
1. 每组测试发送 2 个 ICMP Echo Request 包
2. 检测 0% 丢包率才算通过
3. 使用 `&&` 和 `||` 组合显示清晰的 ✓/✗ 状态
4. 测试失败不会中断脚本

### 3.4 setup.sh 完整脚本代码详细注释
#!/bin/bash
# =============================================================================
# setup.sh - CentOS Stream 10 企业网络拓扑搭建脚本
# 功能：创建 6 个网络命名空间，通过 5 对 veth 虚拟网卡连接，配置 IP 和路由
# 设计原则：幂等性（可重复运行，每次执行结果一致）
# =============================================================================

# 脚本遇到任何错误立即退出，避免级联故障
set -e

echo "====== CentOS 10 网络拓扑搭建 ======"

# =============================================================================
# 模块 1：环境清理（保障可重复运行）
# =============================================================================
# 循环删除所有业务网络命名空间，忽略不存在的命名空间报错
for ns in fw office guest dmz internet remote; do
    ip netns del $ns 2>/dev/null || true
done

# 清理系统残留的 veth 虚拟网卡
# 1. ip link 列出所有网络接口
# 2. grep veth 筛选出 veth 类型的接口
# 3. awk '{print $2}' 提取接口名称（去掉末尾的冒号）
# 4. sed 's/://' 删除接口名末尾的冒号
# 5. xargs -I {} ip link del {} 逐个删除 veth 设备
ip link | grep veth | awk '{print $2}' | sed 's/://' | xargs -I {} ip link del {} 2>/dev/null

# =============================================================================
# 模块 2：创建 6 个网络命名空间
# =============================================================================
# 每个命名空间拥有独立的网络协议栈、路由表和防火墙规则
ip netns add fw       # 防火墙 + VPN 网关（核心路由节点）
ip netns add office   # 办公网主机（模拟内网员工）
ip netns add guest    # 访客网主机（模拟访客设备，仅能访问外网）
ip netns add dmz      # DMZ 服务区（对外提供 Web 服务）
ip netns add internet # 模拟外网（模拟互联网用户）
ip netns add remote   # 远程 VPN 客户端（通过 VPN 安全接入内网）

# =============================================================================
# 模块 3：创建 5 对 veth 虚拟网线
# =============================================================================
# veth 设备总是成对出现，数据包从一端进入从另一端发出
# 相当于一条虚拟网线连接两个网络命名空间

# 3.1 office 连接：fw ←───→ office
# 创建 veth 对，一端命名为 veth-fw-office（fw 侧），另一端命名为 veth-office（office 侧）
ip link add veth-fw-office type veth peer name veth-office
# 将两端分别放入对应的命名空间
ip link set veth-fw-office netns fw
ip link set veth-office netns office

# 3.2 guest 连接：fw ←───→ guest
ip link add veth-fw-guest type veth peer name veth-guest
ip link set veth-fw-guest netns fw
ip link set veth-guest netns guest

# 3.3 dmz 连接：fw ←───→ dmz
ip link add veth-fw-dmz type veth peer name veth-dmz
ip link set veth-fw-dmz netns fw
ip link set veth-dmz netns dmz

# 3.4 internet 连接：fw ←───→ internet
ip link add veth-fw-inet type veth peer name veth-inet
ip link set veth-fw-inet netns fw
ip link set veth-inet netns internet

# 3.5 remote 底层连接：fw ←───→ remote（承载 WireGuard 公网通信）
ip link add veth-fw-remote type veth peer name veth-remote
ip link set veth-fw-remote netns fw
ip link set veth-remote netns remote

# =============================================================================
# 模块 4：配置 fw 防火墙的 5 个接口 IP 地址
# =============================================================================

# 4.1 office 网关接口：10.20.0.1/24
ip netns exec fw ip addr flush dev veth-fw-office  # 清空旧 IP（幂等性保障）
ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
ip netns exec fw ip link set veth-fw-office up      # 启用接口

# 4.2 guest 网关接口：10.30.0.1/24
ip netns exec fw ip addr flush dev veth-fw-guest
ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
ip netns exec fw ip link set veth-fw-guest up

# 4.3 dmz 网关接口：10.40.0.1/24
ip netns exec fw ip addr flush dev veth-fw-dmz
ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
ip netns exec fw ip link set veth-fw-dmz up

# 4.4 外网接口：203.0.113.1/24（模拟公网地址）
ip netns exec fw ip addr flush dev veth-fw-inet
ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
ip netns exec fw ip link set veth-fw-inet up

# 4.5 remote 底层通信网关接口：192.168.200.1/30（点对点链路）
ip netns exec fw ip addr flush dev veth-fw-remote
ip netns exec fw ip addr add 192.168.200.1/30 dev veth-fw-remote
ip netns exec fw ip link set veth-fw-remote up

# 4.6 启用 fw 命名空间的回环接口（本地通信必需）
ip netns exec fw ip link set lo up

# =============================================================================
# 模块 5：配置各区域主机接口 IP 地址和默认路由
# =============================================================================

# 5.1 office 办公主机：10.20.0.2/24，网关 10.20.0.1
ip netns exec office ip addr flush dev veth-office
ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
ip netns exec office ip link set veth-office up
ip netns exec office ip link set lo up
# 删除可能存在的默认路由（幂等性保障）
ip netns exec office ip route del default 2>/dev/null || true
# 所有离开本区域的流量经过 fw 网关
ip netns exec office ip route add default via 10.20.0.1

# 5.2 guest 访客主机：10.30.0.2/24，网关 10.30.0.1
ip netns exec guest ip addr flush dev veth-guest
ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
ip netns exec guest ip link set veth-guest up
ip netns exec guest ip link set lo up
ip netns exec guest ip route del default 2>/dev/null || true
ip netns exec guest ip route add default via 10.30.0.1

# 5.3 dmz 服务器：10.40.0.2/24，网关 10.40.0.1
ip netns exec dmz ip addr flush dev veth-dmz
ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
ip netns exec dmz ip link set veth-dmz up
ip netns exec dmz ip link set lo up
ip netns exec dmz ip route del default 2>/dev/null || true
ip netns exec dmz ip route add default via 10.40.0.1

# 5.4 internet 外网主机：203.0.113.10/24，网关 203.0.113.1
ip netns exec internet ip addr flush dev veth-inet
ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
ip netns exec internet ip link set veth-inet up
ip netns exec internet ip link set lo up
ip netns exec internet ip route del default 2>/dev/null || true
ip netns exec internet ip route add default via 203.0.113.1

# 5.5 remote 远程主机：192.168.200.2/30，网关 192.168.200.1
ip netns exec remote ip addr flush dev veth-remote
ip netns exec remote ip addr add 192.168.200.2/30 dev veth-remote
ip netns exec remote ip link set veth-remote up
ip netns exec remote ip link set lo up
ip netns exec remote ip route del default 2>/dev/null || true
ip netns exec remote ip route add default via 192.168.200.1

# =============================================================================
# 模块 6：开启防火墙内核 IP 转发功能
# =============================================================================
# ip_forward=1 使 fw 能够在不同接口之间路由数据包
# 这是实现跨网段通信的核心配置，若缺失则流量无法在不同区域间转发
ip netns exec fw sysctl -w net.ipv4.ip_forward=1
# 全局接口转发开关同步开启
ip netns exec fw sysctl -w net.ipv4.conf.all.forwarding=1

# =============================================================================
# 模块 7：自动化连通性测试（搭建即验证）
# =============================================================================
echo -e "\n====== 连通性测试开始 ======"

# 测试 1：office → fw（验证办公网到防火墙的连通性）
ip netns exec office ping -c 2 10.20.0.1 && echo "✓ office -> fw 连通正常" || echo "✗ office -> fw 连通失败"

# 测试 2：guest → fw（验证访客网到防火墙的连通性）
ip netns exec guest ping -c 2 10.30.0.1 && echo "✓ guest -> fw 连通正常" || echo "✗ guest -> fw 连通失败"

# 测试 3：dmz → fw（验证 DMZ 到防火墙的连通性）
ip netns exec dmz ping -c 2 10.40.0.1 && echo "✓ dmz -> fw 连通正常" || echo "✗ dmz -> fw 连通失败"

# 测试 4：internet → fw（验证外网到防火墙的连通性）
ip netns exec internet ping -c 2 203.0.113.1 && echo "✓ internet -> fw 连通正常" || echo "✗ internet -> fw 连通失败"

# 测试 5：remote → fw 底层链路（验证 VPN 底层通信链路）
ip netns exec remote ping -c 2 192.168.200.1 && echo "✓ remote -> fw 底层链路连通正常" || echo "✗ remote -> fw 底层链路连通失败"

echo -e "\n====== 企业网络拓扑全部搭建完成 ======"
### 3.5 连通性测试结果汇总
| 测试编号 | 源 | 目标 | 平均延迟 | 丢包率 | 状态 |
| ---- | ---- | ---- | ---- | ---- | ---- |
| 1 | office (10.20.0.2) | fw (10.20.0.1) | 0.040 ms | 0% | 连通 |
| 2 | guest (10.30.0.2) | fw (10.30.0.1) | 0.084 ms | 0% | 连通 |
| 3 | dmz (10.40.0.2) | fw (10.40.0.1) | 0.247 ms | 0% | 连通 |
| 4 | internet (203.0.113.10) | fw (203.0.113.1) | 0.091 ms | 0% | 连通 |
| 5 | remote (192.168.200.2) | fw (192.168.200.1) | 0.114 ms | 0% | 连通 |

#### 结果分析
1. 所有 5 组测试均为 0% 丢包率，证明 veth 虚拟链路、IP 地址分配、默认路由配置全部无误；
2. 全网平均延迟均维持在 0.1 ms 左右，符合纯本地虚拟网络设备低延迟的性能特征；
3. 基础网络拓扑搭建完全成功，链路层、网络层通信正常，可继续开展后续防火墙访问控制、VPN 隧道、NAT 端口转发等实验配置。

### 3.6 搭建验证截图说明
截图：`01-topology.png`
![拓扑搭建连通性测试截图](01-topology.png)
该截图展示了 `setup.sh` 脚本执行完毕后的完整终端输出，包含以下关键信息：
1. 5 组 ping 连通性测试完整 ICMP 交互报文与统计数据；
2. 每组链路测试的通过标识 `✓`；
3. 全部链路 0% 丢包率的验证结果。

## 四、第二部分：防火墙策略实现
（包含firewall.sh的说明和访问控制矩阵）
### 4.1 iptables 防火墙技术简介
iptables 是 Linux 内核中的包过滤框架，由 Netfilter 项目提供支持。它通过定义规则链（Chain）和规则（Rule）来实现对网络数据包的过滤、修改和转发。本实验使用 iptables 的 FORWARD 链实现跨区域流量控制，使用 NAT 表实现 SNAT 和 DNAT。
#### iptables 的三张主要表
| 表名 | 功能 | 本实验使用 |
| ---- | ---- | ---- |
| filter | 包过滤（ACCEPT/DROP/REJECT） |  FORWARD 链 |
| nat | 网络地址转换（SNAT/DNAT） |  PREROUTING/POSTROUTING |
| mangle | 包修改（TOS/TTL 等） |  未使用 |
本实验的规则架构：
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FORWARD 链规则执行顺序                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  第1步：状态检测（ESTABLISHED,RELATED）→ ACCEPT                            │
│         ↓                                                                   │
│  第2步：office → dmz:8080 → ACCEPT                                         │
│         ↓                                                                   │
│  第3步：office → internet → ACCEPT                                         │
│         ↓                                                                   │
│  第4步：guest → internet → ACCEPT                                          │
│         ↓                                                                   │
│  第5步：dmz → internet → ACCEPT                                            │
│         ↓                                                                   │
│  第6步：internet → dmz:8080 (配合DNAT) → ACCEPT                           │
│         ↓                                                                   │
│  第7步：VPN → office → ACCEPT                                              │
│         ↓                                                                   │
│  第8步：VPN → dmz:8080 → ACCEPT                                            │
│         ↓                                                                   │
│  第9步：违规流量识别 → LOG → REJECT                                        │
│         ↓                                                                   │
│  第10步：兜底拒绝 → LOG → REJECT                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
### 4.2 firewall.sh 完整脚本代码、注释和详细说明
#### 4.2.1 脚本概述
`firewall.sh` 为企业多区域网络访问控制脚本，运行于 `fw` 防火墙命名空间，基于 `iptables/netfilter` 实现**区域隔离、端口精细化放行、流量日志审计、NAT 地址转换**四大核心能力。

整体设计逻辑：
1. 清空历史旧规则，保障脚本幂等可重复执行；
2. 设置全局默认策略：`FORWARD` 转发默认拒绝，仅显式放行合法流量；
3. 首行配置连接状态跟踪规则，放行回程响应报文；
4. 按 Office / Guest / DMZ / Internet / VPN 分区域配置放行、日志、拒绝策略；
5. 全局兜底日志记录所有未匹配流量，统一拒绝；
6. 配置内网上网 SNAT 伪装 + 外网访问 DMZ DNAT 端口转发。

#### 4.2.2 完整可执行脚本代码
```bash
#!/bin/bash
# firewall.sh - 企业多区域iptables防火墙完整版规则
# 运行环境：fw 网络命名空间
# 功能：区域访问隔离、端口精细管控、流量日志审计、SNAT/DNAT地址转换

# 1. 清空filter、nat表原有规则与自定义链
ip netns exec fw iptables -F
ip netns exec fw iptables -t nat -F
ip netns exec fw iptables -X
ip netns exec fw iptables -t nat -X

# 2. 设置全局默认策略
# FORWARD链默认DROP：所有跨网段流量无匹配则直接拒绝
# INPUT/OUTPUT默认ACCEPT：防火墙本机进出流量不限制
ip netns exec fw iptables -P FORWARD DROP
ip netns exec fw iptables -P INPUT ACCEPT
ip netns exec fw iptables -P OUTPUT ACCEPT

# ========== 核心模块：连接状态检测（必须放在FORWARD第一条） ==========
# 放行已建立连接、关联子连接的回程报文，保障访问双向通信
ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ========== 模块1：Office办公内网区域规则 ==========
# 允许办公网访问DMZ 8080业务Web端口
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
# 访问DMZ 22管理端口先记录审计日志，再拒绝
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -m limit --limit 5/min -j LOG --log-prefix "OFFICE-DMZ-SSH: "
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j REJECT
# 办公网完全允许访问互联网外网
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-inet -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== 模块2：Guest访客隔离区域规则 ==========
# 禁止访客访问办公内网，非法访问写入日志
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -m limit --limit 5/min -j LOG --log-prefix "GUEST-TO-OFFICE: "
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT
# 禁止访客访问DMZ业务服务器，非法访问写入日志
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -m limit --limit 5/min -j LOG --log-prefix "GUEST-TO-DMZ: "
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT
# 访客仅允许访问互联网外网
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== 模块3：DMZ服务区规则 ==========
# DMZ服务器主动向外网发起访问完全放行
ip netns exec fw iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== 模块4：Internet外网访问规则 ==========
# 外网仅允许访问DMZ 8080Web业务端口
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
# 外网禁止访问内网Office，记录非法访问日志
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -m limit --limit 5/min -j LOG --log-prefix "INET-TO-OFFICE: "
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT
# 外网禁止访问访客Guest区域，记录非法访问日志
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -m limit --limit 5/min -j LOG --log-prefix "INET-TO-GUEST: "
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT
# 外网禁止访问DMZ 22管理SSH端口，记录日志后拒绝
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -m limit --limit 5/min -j LOG --log-prefix "INET-TO-DMZ-SSH: "
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# ========== 模块5：WG VPN远程客户端规则 ==========
# VPN远程员工可访问办公内网全部网段
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
# VPN允许访问DMZ 8080Web业务端口
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
# VPN访问DMZ 22SSH端口记录日志并拒绝
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "VPN-TO-DMZ-SSH: "
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j REJECT
# VPN所有未匹配流量统一记录日志并拒绝
ip netns exec fw iptables -A FORWARD -i wg0 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "VPN-DENY: "
ip netns exec fw iptables -A FORWARD -i wg0 -j REJECT

# ========== 兜底全局拒绝规则 ==========
# 所有未匹配上述放行规则的跨网段流量，先日志审计，再返回端口不可达拒绝报文
ip netns exec fw iptables -A FORWARD -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "FORWARD-DENY: "
ip netns exec fw iptables -A FORWARD -j REJECT --reject-with icmp-port-unreachable

# ========== NAT地址转换规则（nat表PREROUTING/POSTROUTING链） ==========
# SNAT内网上网伪装：Office/Guest/DMZ访问互联网自动伪装为公网接口IP
ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE
# DNAT端口转发：外网访问公网8080端口，转发至DMZ内网Web服务器10.40.0.2:8080
ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080

echo " 防火墙规则加载完成！"
#### 4.2.3 脚本核心模块功能拆解
1. **初始化清理模块**
- `iptables -F / -t nat -F`：清空 filter、nat 表所有规则；
- `iptables -X / -t nat -X`：删除全部自定义用户链；
作用：多次重复执行脚本无规则残留，实现幂等性。

2. **默认安全策略**
`FORWARD` 全局默认策略为 `DROP`，遵循最小权限安全原则：不主动放行任何跨区域流量，仅手动添加合法访问规则，从底层阻断非法跨网段通信。

3. **conntrack 状态跟踪（核心基础规则）**
放置在 FORWARD 链第一条，作用：
内网主动发起访问外网 / DMZ 时，服务器回程响应报文自动放行，无需双向配置放行规则，简化防火墙配置。

4. **分区域访问控制逻辑**
##### Office 办公区
- 允许：访问 DMZ 8080 业务、访问全网互联网；
- 禁止：DMZ 22 SSH 管理端口（日志记录 + 拒绝）；

##### Guest 访客区
- 仅允许：访问外网互联网；
- 完全阻断：访问 Office、DMZ，所有非法流量写入审计日志；

##### DMZ 服务区
- 主动向外网发起请求全部放行；
- 外网仅可访问 8080Web，22 管理端口严格拦截；

##### Internet 外网
- 仅开放 DMZ 业务 8080 端口；
- 禁止访问内网 Office、Guest、DMZ 管理端口；

##### VPN 远程接入
- 可信 VPN 客户端可访问 Office 内网、DMZ 8080；
- 拦截 DMZ SSH 及其他未知流量，日志留存。

5. **流量日志审计机制**
所有被拒绝的非法访问均配置 LOG 规则，搭配流量限速 `limit 5/min` 防止日志风暴，每条日志带专属前缀（如`GUEST-TO-OFFICE`），便于后期溯源排查攻击行为。

6. **NAT 转换规则**
- SNAT MASQUERADE：内网三个私有网段访问互联网自动伪装为公网出口 IP，实现内网上网；
- DNAT 端口转发：外网用户通过公网 IP:8080 直接访问内网 DMZ 业务服务器，对外隐藏真实内网地址。
#### 4.2.3 规则设计说明
1. **规则顺序**：状态检测（ESTABLISHED,RELATED）必须放在第一条，确保回包被放行；随后是具体业务放行规则；最后是 LOG+REJECT 拦截规则和兜底拒绝。
2. **REJECT vs DROP**：本实验内网环境采用 REJECT，因为客户端能立即收到“端口不可达”错误，体验好；而 DROP 会使客户端超时等待，不利于内部排错。对于外部攻击者，REJECT 也能有效阻止访问，且不影响安全性。
### 4.3 访问控制测试矩阵
#### 一、成功场景
| 测试场景 | 测试命令 | 预期结果 | 实际结果 | 截图 |
| ---- | ---- | ---- | ---- | ---- |
| office → dmz:8080 | curl http://10.40.0.2:8080/ | 返回 HTML |  返回 HTML 目录列表 | 04-access-success.png |
| office → internet | ping 203.0.113.10 | 0% loss |  0% loss | 04-access-success.png |
| guest → internet | ping 203.0.113.10 | 0% loss |  0% loss | 04-access-success.png |
| dmz → internet | curl http://203.0.113.10/ | 成功 |  成功 | 04-access-success.png |
| internet → fw:8080 | curl http://203.0.113.1:8080/ | 返回 HTML (DNAT) |  返回 HTML 目录列表 | 04-access-success.png |

#### 二、失败场景
| 测试场景 | 测试命令 | 预期结果 | 实际结果 | 截图 |
| ---- | ---- | ---- | ---- | ---- |
| office → dmz:22 | curl http://10.40.0.2:22/ | 拒绝 |  Connection refused | 05-access-deny.png |
| guest → office | curl http://10.20.0.2:8000/ | 拒绝 |  Connection refused | 05-access-deny.png |
| guest → dmz:8080 | curl http://10.40.0.2:8080/ | 拒绝 |  Connection refused | 05-access-deny.png |
| internet → office | curl http://10.20.0.2:8000/ | 拒绝 |  Connection refused | 05-access-deny.png |
| internet → dmz:22 | curl http://203.0.113.1:22/ | 拒绝 |  Connection refused | — |
##### 测试结果整体分析
所有预期放行场景均可正常连通，页面 / ICMP 数据包无丢包，验证放行规则配置无误；
所有禁止访问场景全部连接拒绝，符合区域隔离安全策略；
非法访问流量均会被内核记录系统日志，可通过 dmesg 查看带自定义前缀的审计记录，满足安全审计需求；
DNAT 端口转发、SNAT 内网伪装功能正常，内外网业务访问通路完整闭环。
##### 防火墙规则截图说明
1. 截图：`02-firewall-rules.png`
展示 fw 命名空间内 iptables FORWARD 链完整规则列表，包含区域放行、日志审计、拒绝、状态检测等全部访问控制规则。
2. 截图：`03-nat-rules.png`
展示 nat 表 PREROUTING、POSTROUTING 链规则，包含内网 SNAT 上网伪装与外网访问 DMZ 的 DNAT 端口转发配置。

## 五、第三部分：VPN远程接入
（包含WireGuard配置说明和测试结果）
### 5.1 WireGuard 技术简介
WireGuard 是一个极简、高性能的现代 VPN 协议，运行于 Linux 内核空间。与传统的 OpenVPN 或 IPsec 相比，WireGuard 具有以下显著优势：
特性	说明
轻量级	代码量仅约 4000 行，远小于 OpenVPN 的 10 万行
高性能	基于内核运行，加密开销极低，延迟小
现代加密	使用 Curve25519、ChaCha20、Poly1305、BLAKE2s
易于配置	配置文件简洁，无需管理证书链
漫游支持	自动处理 IP 地址变化，适合移动办公
NAT 穿透	基于 UDP 协议，穿透能力强
### 5.2 WireGuard 密钥生成与配置文件
#### 5.2.1 密钥生成脚本
```bash
# 设置文件权限掩码，私钥文件仅所有者可读，防止密钥泄露
umask 077
# 生成防火墙服务端私钥 fw.key，同时导出公钥 fw.pub
wg genkey | tee fw.key | wg pubkey > fw.pub
# 生成远程客户端私钥 remote.key，同时导出客户端公钥 remote.pub
wg genkey | tee remote.key | wg pubkey > remote.pub

#### 5.2.2 fw 防火墙服务端配置（vpn-fw.conf）
[Interface]
# VPN隧道服务端内网IP地址与网段
Address = 10.10.10.1/24
# 服务端WireGuard私钥（对应fw.key）
PrivateKey = EGBfeBRThYc8WT0lSASt7pjcu+drrzYjtfD7ZdxxrkI=
# WireGuard默认监听UDP端口51820
ListenPort = 51820

[Peer]
# 远程客户端公钥（remote.pub）
PublicKey = 8NnZupZ7uMrHmsBTO+bRH7YEj1YdQPcUBmVlt0Z2hFE=
# 允许该客户端使用的隧道IP，单主机/32掩码
AllowedIPs = 10.10.10.2/32
# 保活包25秒发送一次，解决NAT环境下隧道断连问题
PersistentKeepalive = 25

#### 5.2.3 remote 远程客户端配置（vpn-remote.conf）
[Interface]
# VPN隧道客户端内网IP
Address = 10.10.10.2/24
# 客户端本地私钥（对应remote.key）
PrivateKey = QGVbBb0JImcYoUpEnThZI/I9MiomLT0N5JOFrzxkhnc=

[Peer]
# 防火墙服务端公钥（fw.pub）
PublicKey = 5Hjh6/V4uYAoQmtpiAzN6c811RXmO0lsdrL1+Lqq+C0=
# 服务端公网地址+监听端口，客户端建立隧道的连接地址
Endpoint = 192.168.200.1:51820
# 访问内网办公网段、DMZ业务网段全部流量走VPN隧道
AllowedIPs = 10.20.0.0/24, 10.40.0.0/24
# 客户端持续发送保活报文，维持UDP NAT映射
PersistentKeepalive = 25

### 5.3 VPN 状态验证
执行 `wg` 命令查看防火墙服务端 WireGuard 隧道完整运行状态，输出如下：
```text
=== fw 端状态 ===
interface: wg0
public key: 5Hjh6/V4uYAoQmtpiAzN6c811RXmO0lsdrL1+Lqq+C0=
listening port: 51820
peer: 8NnZupZ7uMrHmsBTO+bRH7YEj1YdQPcUBmVlt0Z2hFE=
endpoint: 192.168.200.2:47315
allowed ips: 10.10.10.2/32
latest handshake: 10 seconds ago
transfer: 180 B received, 124 B sent
#### 结果说明
1. 隧道接口 `wg0` 正常监听默认端口 `51820`；
2. 客户端对等节点公钥匹配配置文件，对等连接建立成功；
3. 最近握手仅间隔 10 秒，加密隧道协商正常；
4. 存在收发流量，证明 VPN 双向数据通路可用。
=== remote 路由表 ===
default via 192.168.200.1 dev veth-remote
10.10.10.0/24 dev wg0 proto kernel scope link src 10.10.10.2
10.20.0.0/24 dev wg0 scope link
10.40.0.0/24 dev wg0 scope link
192.168.200.0/30 dev veth-remote proto kernel scope link src 192.168.200.2
截图：`06-vpn-status.png`

### 5.4 VPN 访问测试
测试场景	预期结果	实际结果	截图
VPN → office:8000	成功	 返回 HTML	07-vpn-success.png
VPN → dmz:8080	成功	 返回 HTML	07-vpn-success.png
VPN → dmz:22	拒绝	 Connection refused	08-vpn-deny.png
VPN → guest	拒绝	 目标端口不可达	08-vpn-deny.png

## 六、第四部分：安全审计与日志分析
（包含LOG规则说明和日志分析报告）
### 6.1 LOG 规则配置及原理说明
本实验在防火墙 iptables 规则中集成了精细化日志审计功能，针对所有非法跨区域访问行为配置专属日志记录规则。通过自定义日志前缀区分违规流量类型，同时搭配速率限制机制，既能精准溯源攻击行为，又可防止高频恶意请求产生日志风暴，保障系统稳定性。

| 事件类型 | log-prefix 日志前缀 | 速率限制规则 | 规则说明 |
| ---- | ---- | ---- | ---- |
| guest 访问 office | GUEST-TO-OFFICE: | 5/min burst 10 | 限制每分钟最多记录5条日志，瞬时峰值10条，审计访客网非法访问办公网行为 |
| guest 访问 dmz | GUEST-TO-DMZ: | 5/min burst 10 | 限制每分钟最多记录5条日志，瞬时峰值10条，审计访客网非法访问DMZ服务区行为 |
| VPN 访问 dmz:22 | VPN-TO-DMZ-SSH: | 无限制 | VPN违规SSH访问属于高危操作，不做速率限制，全程完整记录所有访问日志 |
| internet 访问 office | INET-TO-OFFICE: | 5/min burst 10 | 限制每分钟最多记录5条日志，瞬时峰值10条，审计外网非法入侵内网办公区行为 |
| VPN 其他违规 | VPN-DENY: | 5/min burst 10 | 限制每分钟最多记录5条日志，瞬时峰值10条，统一审计VPN客户端所有未授权违规访问行为 |

### 6.2 日志触发统计与有效性验证
通过模拟各类非法访问场景，测试防火墙日志审计功能，所有预设违规规则均成功触发并记录日志，日志功能100%生效，可完整记录全网异常访问行为。

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
| ---- | ---- | ---- | ---- |
| guest→office | 1 | 1 | 是 |
| guest→dmz | 1 | 1 | 是 |
| VPN→dmz:22 | 1 | 1 | 是 |
| internet→office | 1 | 1 |是 |
| VPN 其他违规 | 1 | 1 | 是 |

截图：`09-logs-realtime.png`、`10-logs-stats.png`

#### 6.2.1 日志字段详细解读
| 日志字段 | 字段含义 | 安全分析价值 |
| ---- | ---- | ---- |
| IN=veth-fw-guest | 数据包从访客网接口进入防火墙 | 精准判定违规流量来源区域，确认攻击入口为访客隔离网段 |
| OUT=veth-fw-office | 数据包目标出口为办公网接口 | 明确攻击目标为核心办公内网，界定风险影响范围 |
| SRC=10.30.0.2 | 数据包源 IP 地址 | 精准定位违规访问终端 IP，支持溯源追责与封禁操作 |
| DST=10.20.0.2 | 数据包目标 IP 地址 | 确定被访问的内网核心主机，明确受保护资产 |
| DPT=8000 | 数据包目标端口 | 识别访问服务类型，判断违规访问的业务场景与攻击意图 |

### 6.3 整体日志分析报告
本次实验搭建的防火墙日志审计系统运行稳定、功能完备，实现了全网异常访问可视化、可溯源、可管控的安全审计目标，核心分析结论如下：
1. **规则精准有效**：所有自定义违规日志规则均正常触发，无漏记、错记情况，速率限制机制有效规避日志风暴问题，高危 VPN 违规操作无日志遗漏，安全审计粒度精细。
2. **区域隔离审计闭环**：针对访客网、外网、VPN 客户端的跨区域违规访问均可精准记录，完美匹配防火墙区域隔离策略，实现 “阻断 + 记录” 的双重安全防护。
3. **溯源能力完善**：日志包含流量入口、出口、源目 IP、目标端口等完整维度信息，可快速定位攻击来源、目标资产与访问行为，满足企业网络安全溯源与运维审计需求。
4. **安全防护闭环**：结合 iptables 访问拒绝规则 + 日志审计功能，不仅能实时拦截非法入侵，还可留存安全日志，为后续风险研判、策略优化、安全追责提供数据支撑。

## 七、第五部分：攻防演练
（包含攻击演练、防御分析、边界测试）
本章节基于已部署的多区域防火墙策略与日志审计体系，开展内网渗透扫描、策略绕过尝试、边界安全加固综合攻防演练。通过模拟攻击者从访客区域发起探测与越权访问，验证防火墙区域隔离有效性、规则抗绕过能力，并针对 DMZ 业务端口风险给出边界加固优化方案。
### 7.1 攻击方演练（模拟 Guest 攻击者渗透测试）
#### 攻击 1：办公网段存活主机扫描（横向探测）
**攻击目的**：模拟攻击者入驻访客网络后，通过 ICMP 批量扫描办公网段，探测内网存活主机，为后续横向渗透、端口扫描、漏洞攻击收集资产信息。

**攻击命令**
```bash
for i in {1..10}; do
  ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
**攻击环境**：攻击者位于 guest 访客隔离区域（10.30.0.0/24），尝试探测 office 办公核心网段（10.20.0.0/24）。

**攻击结果**：脚本执行完毕后，无任何存活主机输出，所有 ping 探测全部失效。

**结果详细分析**
- 防火墙默认全局策略为 `FORWARD DROP`，所有未显式放行的跨区域流量默认阻断；
- 专项安全规则配置了 guest→office 流量日志记录 + REJECT 拒绝，主动拦截所有访客网访问办公网的请求；
- 攻击者无法获取任何内网存活主机信息，办公网段资产完全隐藏，有效抵御内网横向扫描探测。

截图：`11-attack-scan.png`
#### 攻击 2：修改源端口尝试绕过防火墙策略
**攻击原理**：部分简易防火墙仅基于目标端口放行，攻击者可通过更换客户端源端口绕过限制。本次尝试修改本地随机高端口为 80、443 常用业务端口，试图绕过 DMZ 22 端口拦截策略，非法访问 DMZ 服务器 SSH 管理端口。

**攻击命令**
```bash
ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
**攻击场景说明**：目标为 DMZ 服务器 22 端口（SSH 管理端口），该端口已配置全局禁止访客访问规则，攻击者试图通过伪造源端口绕过访问控制。

**攻击结果**：两次不同源端口尝试，均返回 `Connection refused`，绕过失败。

**结果详细分析**
- 本次 iptables 防火墙策略基于区域接口、源网段、目标端口三元组匹配，与客户端本地源端口无关；
- 防火墙严格区分流量入口区域，只要流量来自 guest 区域，无论源端口如何修改，均会被匹配拒绝规则；
- 证明当前防火墙策略具备抗端口绕过能力，防护逻辑严谨，不存在策略绕过漏洞。
补充说明：目标 22 端口为 SSH 管理端口，非 HTTP 服务，因此网页访问提示解析失败，属于正常业务端口拒绝现象，进一步佐证端口未对外开放。
截图：`12-attack-bypass.png`
#### 攻击 3：伪造 VPN 源地址尝试访问内网
**攻击命令**
```bash
# 从 guest 尝试伪造 VPN 客户端 IP 访问 office
sudo ip netns exec guest ping -c 2 -I 10.10.10.2 10.20.0.2
# 结果：bind: Cannot assign requested address，无法伪造
#### 失败原因分析
即使攻击者通过 raw socket 成功构造源地址为 10.10.10.2 的数据包：
（1）防火墙 FORWARD 规则检查入口接口为 veth-fw-guest，而非 wg0，不会匹配 VPN 放行规则；
（2）该流量会被 guest→office 的 REJECT 规则拦截；
（3）Linux 内核默认启用 rp_filter（反向路径过滤），会检查源地址 10.10.10.2 是否应该从 veth-fw-guest 接口接收，由于 VPN 隧道地址应从 wg0 接口接收，内核会丢弃该包。
### 7.2 防御方日志与计数器分析
本次攻防演练所有非法攻击行为均被防火墙日志系统与规则计数器完整记录，实现攻击行为可追溯、可统计。
#### 日志审计分析
所有 guest 区域非法扫描、越权访问行为均触发预设日志规则，生成带 `GUEST-TO-OFFICE`、`GUEST-TO-DMZ` 前缀的审计日志，完整记录攻击流量的入接口、出接口、源目 IP、访问端口，安全溯源信息完整。
#### 规则计数器分析
防火墙规则计数器正常累加，所有拒绝规则均产生命中次数，证明：
- 攻击流量成功被防火墙捕获并匹配拦截规则；
- 无规则失效、漏拦截、绕过等安全问题；
- 防护策略实时生效，防御机制稳定可靠。
截图：`13-defense-logs.png`、`14-defense-counters.png`

### 7.3 边界安全改进加固方案（并发连接防护）
原有防火墙策略仅实现区域访问隔离，但未针对对外开放的 DMZ 业务端口做流量风控。公网与内网均可访问 DMZ 8080 业务端口，存在单 IP 高频请求、CC 并发攻击、连接耗尽风险。因此新增基于连接数限制的边界加固规则。

#### 加固命令
```bash
ip netns exec fw iptables -I FORWARD 1 -p tcp --syn --dport 8080 -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
#### 参数原理说明
- `-I FORWARD 1`：将加固规则插入至转发链第一条，优先匹配、优先防护；
- `--syn`：仅针对 TCP 握手新建连接生效，不影响已建立的正常业务连接；
- `--connlimit-above 10`：限制单 IP 最大并发连接数为 10 条；
- `--connlimit-mask 32`：针对单个独立主机 IP 做连接限制，精准防护单 IP 攻击；
- `tcp-reset`：超限连接直接发送 TCP 复位包强制断开，阻断攻击流量。

#### 加固价值
- 有效防御 CC 攻击、连接耗尽攻击、高频恶意请求；
- 保障 DMZ 业务服务器稳定性，避免单用户占用全部业务连接；
- 在原有区域隔离基础上，新增流量风控、并发防护能力，边界安全防护更加立体。

截图：`15-improvement.png`

### 7.4 攻防整体总结
本次攻防演练完整验证了整套防火墙安全体系的可靠性：内网区域隔离严格，可抵御网段扫描、端口绕过等基础渗透攻击；日志审计可完整留存攻击行为，满足溯源需求；通过新增并发连接限制规则，弥补了传统访问控制仅控访问、不控流量的短板，最终实现**区域隔离 + 访问控制 + 日志审计 + 流量风控**的全方位边界安全防护体系。

## 八、故障排查
（包含至少3个故障场景的排查过程）
### 8.1 抓包截图说明
本次分别在 VPN 客户端、防火墙服务端、DMZ 服务器三处部署 tcpdump 抓包，完整观测 WireGuard 隧道封装、解封装、跨网段转发全过程流量变化。
截图：`16-tcpdump-remote.png`（客户端 wg0 隧道口抓包）
截图：`17-tcpdump-fw.png`（防火墙 wg0 隧道口抓包）
截图：`18-tcpdump-dmz.png`（防火墙连接 DMZ 的 veth 接口抓包）

### 8.2 数据包转发变化对比表
| 阶段 | 抓包观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
| ---- | ------------ | ------ | -------- | ---- | ---- |
| 1 | remote wg0 | 10.10.10.2 | 10.40.0.2:8080 | TCP | VPN 客户端内部明文业务流量，尚未加密封装 |
| 2 | fw wg0 | 10.10.10.2 | 10.40.0.2:8080 | TCP | 防火墙接收 WireGuard 报文并完成解封装，还原原始内网 TCP 流量 |
| 3 | fw veth-fw-dmz | 10.10.10.2 | 10.40.0.2:8080 | TCP | 防火墙通过二层虚拟接口转发原始内网报文至 DMZ 网段，源目 IP 全程无 NAT 转换 |

### 8.3 流量转发原理分析
#### 客户端封装阶段
VPN 客户端访问 DMZ 业务时，业务 TCP 报文进入本地 wg0 虚拟隧道网卡，WireGuard 内核程序对整个 IP 报文进行加密，封装到外层 UDP 数据包，通过物理接口发送到防火墙公网端口。抓包 remote wg0 仅能看到未加密的内网原始业务报文。

#### 防火墙解封装阶段
防火墙监听 51820 UDP 端口接收加密 WireGuard 报文，内核解密后剥离外层 UDP 头部，还原出内部 10.10.10.0/24 网段原始 TCP 报文，wg0 网卡可见完整明文内网流量。

#### 跨区域转发阶段
防火墙查询路由表，目标 10.40.0.0/24 匹配 DMZ 网段直连路由，直接从 veth-fw-dmz 虚拟网桥接口转发报文。全程未做源地址转换，DMZ 服务器可直接识别 VPN 客户端隧道内网 IP，便于日志审计溯源。
## 九、遇到的问题和解决方法
（实验过程中的实际问题和解决思路）
截图：`19-troubleshoot-dnat.png`
截图：`20-troubleshoot-vpn.png`
截图：`21-troubleshoot-conntrack.png`

### 9.1 场景 1：DNAT 配置后外网无法访问 DMZ 业务
#### 故障重现
删除 DNAT 规则（模拟配置错误或误操作）
ip netns exec fw iptables -t nat -D PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
#### 故障现象：
ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
# 结果：curl: (28) Connection timed out
#### 根本原因
nat 表 PREROUTING 链 DNAT 转发规则丢失，外网入站流量无法转换目标地址转发至内网 DMZ 主机。
#### 修复命令
```bash
ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
#### 经验教训：DNAT 规则是外网访问 DMZ 的核心配置，误删除会导致外网服务中断。建议定期备份 iptables 规则（iptables-save）。
####排查过程：
步骤	执行命令	输出结果	排查结论	
1	ip netns exec fw iptables -t nat -L PREROUTING -n -v	nat 表 PREROUTING 链为空，不存在 DNAT 转发规则	DNAT 转发规则被删除，缺少端口转发配置	
2	`ip netns exec dmz ss -tlnp	grep 8080`	LISTEN 0 5 *:8080 *:*	DMZ 服务器 8080 端口服务正常监听，服务侧无问题
3	`ip netns exec fw iptables -L FORWARD -n -v	grep 8080`	存在放行 8080 端口的 FORWARD 规则，数据包计数 pkts=0	流量从未进入 FORWARD 转发链，问题出在 NAT 预处理阶段
4	ip netns exec fw tcpdump -ni veth-fw-inet port 8080 -c 5	可捕获到外网访问 8080 的入站数据包	流量能够正常抵达防火墙外网接口，链路连通正常	
5	`ip netns exec fw conntrack -L	grep 8080`	无任何 8080 端口 DNAT 转换连接跟踪记录	数据包在 nat 表 PREROUTING 阶段丢弃，未完成目标地址转换
### 9.2 场景 2：VPN 隧道握手正常，但 VPN 客户端无法访问 DMZ
#### 故障现象
两端执行 `wg` 可看到正常握手与流量收发，VPN 客户端访问 `10.40.0.2:8080` 全部超时。
#### 故障重现
关闭 IP 转发（模拟系统重启或误操作）
ip netns exec fw sysctl -w net.ipv4.ip_forward=0
#### 根本原因
防火墙命名空间内核 IPv4 转发功能关闭，跨网段 VPN 流量无法路由转发至 DMZ 网段。
ip netns exec fw sysctl -w net.ipv4.ip_forward=1
#### 排查过程：
步骤	命令	结果	结论
1	ip netns exec fw wg show	latest handshake: 2 seconds ago	VPN 隧道正常 
2	ip netns exec remote ip route | grep 10.40	10.40.0.0/24 dev wg0 scope link	remote 路由正确 
3	ip netns exec fw sysctl net.ipv4.ip_forward	net.ipv4.ip_forward = 0	  IP 转发被关闭
4	ip netns exec fw iptables -L FORWARD -n -v | grep wg0	FORWARD 规则存在，pkts=0	包未被转发
5	ip netns exec fw tcpdump -ni wg0 -c 5	能看到 VPN 解封装后的包	包在路由阶段
### 9.3 场景 3：删除 ESTABLISHED,RELATED 规则后所有 TCP 连接失败
#### 故障现象
新建 TCP 请求可以发出去，但服务端回包全部被丢弃，网页、VPN、外网访问均无法建立完整连接。
#### 根本原因
缺少连接状态跟踪放行规则，防火墙无法识别 SYN-ACK、ACK 等回应报文，默认匹配 DROP 策略拦截回包。
TCP 是双向通信协议，没有状态检测时，防火墙不认识 SYN-ACK 包是已有连接的回包，将其当作新的连接请求处理。由于没有"dmz→office"的规则，SYN-ACK 包被拦截，导致 TCP 三次握手无法完成。
#### 状态检测的必要性：
状态检测让防火墙能识别属于已建立连接的流量，自动放行回包，极大简化了规则配置（从 2n 条减少到 n+1 条），是 iptables 的核心功能。没有状态检测，每个双向协议都需要配置正向和反向两条规则，管理复杂且容易遗漏。
#### 排查过程：
步骤	命令	结果	结论
1	ip netns exec fw iptables -L FORWARD -n -v	无状态检测规则，放行规则变成第 1 条	状态检测被删除
2	ip netns exec fw tcpdump -ni veth-fw-dmz -c 10	能看到 SYN 包到达 dmz，但无 SYN-ACK	回包被拦截
3	ip netns exec fw conntrack -L | grep 10.40.0.2	无任何连接记录	连接未建立

### 9.4实验过程遇到的问题和解决方法
| # | 问题描述 | 原因分析 | 解决思路 | 解决方法 |
| --- | --- | --- | --- | --- |
| 1 | 启动 Python HTTP 服务提示 Address already in use | 上一次 HTTP 服务进程残留占用端口，导致新服务无法监听端口 | 排查端口占用来源，强制清除残留进程，释放端口资源后重新启动服务 | `pkill -9 python3` 清理残留进程后重新启动 |
| 2 | WireGuard VPN 握手正常，但 ping 不通内网网段 | 防火墙仅放行 TCP 8080 业务端口，未放行 ICMP 协议，导致 ping 数据包被拦截 | 区分业务测试协议，ping 依赖 ICMP，业务测试依赖 TCP；可选择规避测试或补充放行 ICMP 规则 | 改用 curl 测试 TCP 业务，或新增 ICMP 放行规则 |
| 3 | 执行 dmesg -T 看不到 iptables 防火墙拦截日志 | 系统内核打印日志级别过低，内核自动过滤 iptables LOG 日志输出 | 临时调高系统内核日志打印级别，解锁内核调试日志输出，正常展示防火墙审计日志 | `echo "7 4 1 7" > /proc/sys/kernel/printk` 调高日志输出级别 |
| 4 | 执行 iptables 添加规则提示接口名不存在 | 手动输入 veth/wg 虚拟接口时出现拼写错误，系统无法识别网卡设备 | 先查询系统真实网卡列表，核对接口名称，杜绝手动拼写错误后再配置规则 | `ip link show` 查看所有网卡，复制正确接口名称 |
| 5 | WireGuard 密钥、配置文件无法编辑修改 | 配置文件归属 root 用户，普通用户权限不足，无读写修改权限 | 修改文件权限，开放读写权限，保证实验用户可正常编辑、保存配置文件 | `chmod 777 文件名` 放开文件读写权限 |
| 6 | 输入 wg-quik 提示 command not found | 命令拼写错误，正确命令为 wg-quick，Linux 命令严格区分拼写 | 核对 WireGuard 标准操作命令，修正拼写错误，使用官方标准命令启停隧道 | 使用标准命令 `wg-quick up/down wg0` |
| 7 | connlimit 模块报语法错误 | 重复书写 -m connlimit 参数或参数拼写错误，导致 iptables 规则解析失败 | 梳理 iptables 模块语法，一条规则仅加载一次 connlimit 模块，规范参数格式 | 修正规则，仅保留一条 `-m connlimit` 配置 |

## 十、总结与思考
（至少500字，包含对企业网络安全架构的整体理解）
通过本次完整的网络安全攻防与防火墙综合实验，我系统完成了区域网络隔离、WireGuard VPN隧道部署、iptables精细化访问控制、安全日志审计、渗透攻防测试、边界安全加固以及典型故障排查等一系列实操任务，全面掌握了中小型企业网络安全架构的核心组成与防护逻辑，对企业内网分区防护、边界安全管控、安全审计溯源的整体架构有了深刻、落地的认知。
在网络架构层面，本次实验模拟了企业典型的三段式网络架构，分别为访客网络、办公内网、DMZ服务区，完全贴合真实企业组网规范。办公网作为核心资产区域，存储企业内部业务数据与办公资源，安全等级最高；DMZ区域对外开放业务端口，用于部署对外服务，是企业网络的暴露面与风险点；访客网络为临时接入区域，安全性最低，需要严格隔离，禁止随意访问内网核心资源。实验中通过防火墙iptables区域隔离策略，实现了不同网段之间的权限划分，有效避免了横向渗透、越权访问等常见内网安全风险，让我理解了内网分区隔离是企业网络安全的第一道核心防线，可以最大限度缩小攻击面，防止单一区域被攻破后导致全网沦陷。
在安全防护机制层面，本次实验实现了访问控制、流量风控、日志审计三重防护体系。基础的FORWARD链规则实现了非法访问的拦截拒绝，基于connlimit模块的并发连接限制规则，有效防御了CC攻击、连接耗尽等流量层攻击，弥补了传统访问控制只控访问、不控流量的短板。同时，自定义LOG日志规则实现了违规行为的精准记录，通过日志字段可以完整溯源攻击来源、目标端口、流量路径，满足企业安全合规与事件追溯需求。结合VPN隧道的部署与测试，我认识到加密远程接入虽然提升了办公便捷性，但也带来了违规访问、端口绕过等安全隐患，必须搭配严格的区域策略与审计机制，才能平衡便利性与安全性。
在攻防演练与故障排查过程中，我验证了现有防火墙策略的可靠性。访客网段的端口扫描、源端口绕过等渗透尝试均被有效拦截，证明精细化的三元组匹配策略具备极强的抗绕过能力。同时通过排查DNAT转发失效、IP转发关闭、连接状态规则缺失等典型故障，我总结出企业网络故障的核心排查逻辑：遵循“底层连通性—路由转发—防火墙规则—服务配置”的分层排查思路，快速定位丢包与异常节点。
整体而言，本次实验让我清晰认识到，企业网络安全并非单一设备、单一规则的防护，而是区域隔离、边界管控、流量防护、日志溯源、风险加固结合的立体化安全体系。未来企业网络防护需要持续细化访问权限、强化边界流量风控、完善安全审计机制，同时定期开展攻防自测与故障演练，及时修补安全短板，才能有效抵御内外网各类网络攻击，保障企业核心网络资产与业务的安全稳定运行。
```

### 截图清单（至少20张）

| 序号 | 内容 | 文件名 |
|:-----|:-----|:-------|
| 1 | 拓扑搭建后的连通性测试 | 01-topology.png |
| 2 | 完整的防火墙规则列表 | 02-firewall-rules.png |
| 3 | NAT规则列表 | 03-nat-rules.png |
| 4 | 访问控制测试矩阵（成功场景） | 04-access-success.png |
| 5 | 访问控制测试矩阵（失败场景） | 05-access-deny.png |
| 6 | VPN隧道状态（wg show） | 06-vpn-status.png |
| 7 | VPN访问测试（成功） | 07-vpn-success.png |
| 8 | VPN访问测试（失败+LOG） | 08-vpn-deny.png |
| 9 | 日志实时监控 | 09-logs-realtime.png |
| 10 | 日志统计结果 | 10-logs-stats.png |
| 11 | 攻击演练场景1 | 11-attack-scan.png |
| 12 | 攻击演练场景2 | 12-attack-bypass.png |
| 13 | 防御分析-日志证据 | 13-defense-logs.png |
| 14 | 防御分析-规则计数器 | 14-defense-counters.png |
| 15 | 边界测试改进方案 | 15-improvement.png |
| 16 | 高级任务-remote抓包 | 16-tcpdump-remote.png |
| 17 | 高级任务-fw抓包 | 17-tcpdump-fw.png |
| 18 | 高级任务-conntrack | 18-conntrack.png |
| 19 | 故障排查场景1 | 19-troubleshoot-dnat.png |
| 20 | 故障排查场景2 | 20-troubleshoot-vpn.png |

---

## 评分标准

### 总分：100分 + 加分5分

| 部分 | 分值 | 评分细则 |
|:----|:-----|:---------|
| 第一部分：网络规划 | 20分 | 拓扑正确10分、脚本可运行5分、连通性验证5分 |
| 第二部分：防火墙策略 | 30分 | 规则完整性10分、访问控制正确性10分、NAT配置5分、规则设计5分 |
| 第三部分：VPN接入 | 20分 | 隧道建立8分、AllowedIPs配置6分、访问控制6分 |
| 第四部分：安全审计 | 15分 | LOG规则4分、日志提取4分、分析报告7分 |
| 第五部分：攻防演练 | 15分 | 攻击演练5分、防御分析5分、边界测试5分 |
| 高级任务（加分） | 5分 | 包追踪完整性3分、分析深度2分 |

### 扣分项

| 扣分原因 | 扣分 |
|:--------|:-----|
| 截图不清晰、缺失关键字段 | 每处-2分 |
| 规则错误导致安全漏洞 | 每处-5分 |
| 脚本无法运行、拓扑无法复现 | -10分 |
| README.md格式混乱、缺少必要说明 | -5分 |
| 故障排查报告敷衍、未深入分析 | -5分 |
| 抄袭或雷同 | 0分 |

### 优秀作业标准（90分以上）

1. 拓扑搭建脚本健壮，可重复运行，有完善的错误处理
2. 防火墙规则遵循最小权限原则，顺序合理，注释清晰
3. 访问控制测试全面，所有场景都有截图证据
4. VPN配置正确，AllowedIPs设计合理
5. 日志审计完整，分析报告深入，能提出改进建议
6. 攻防演练有创新性，能发现非明显的安全问题
7. 故障排查过程详细，思路清晰，能举一反三
8. README.md结构清晰，表达流畅，有个人思考
9. 完成高级任务，包追踪分析透彻

---

## 截止时间

**2026-07-03（18周结束前）**

届时关于期末大作业的PR将不会被合并。

---