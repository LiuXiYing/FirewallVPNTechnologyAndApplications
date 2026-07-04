# 企业级网络安全架构搭建与攻防演练

## 一、实验环境

- 操作系统：Kali Linux 2024.1
- WireGuard版本：v1.0.20220627
- iptables版本：v1.8.7 (nf_tables)
- 其他工具：iproute2, tcpdump, curl, net-tools, python3

## 二、拓扑图和地址规划
### 网络拓扑

![alt text](21-topology.png)

**节点说明：**

| 节点 | 角色 | 必须实现的功能 |
|:-----|:-----|:--------------|
| `fw` | 防火墙+VPN网关 | 5个veth接口（含VPN物理链路）、IP转发、FORWARD规则、NAT、WireGuard |
| `office` | 办公网主机 | 模拟内网员工 |
| `guest` | 访客网主机 | 模拟访客设备 |
| `dmz` | 对外服务器 | 运行Web服务(8080)和管理服务(22) |
| `internet` | 外网主机 | 模拟互联网用户 |
| `remote` | 远程员工 | 通过VPN接入 |

---

### 地址规划表

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | WireGuard VPN隧道 |

> **模拟环境补充说明**：由于本实验所有 namespace 都运行在同一台宿主机上，remote 命名空间无法直接访问 fw 的公网地址 `203.0.113.1`。因此 `setup.sh` 额外创建了辅助 veth 对 `veth-remote/veth-rem-host`（`192.0.2.0/24`）和 `veth-vpn-fw/veth-vpn-host`（`198.51.100.0/30`），仅用于在单主机环境下模拟 remote 到 fw 的底层互联网可达性。这两个辅助网段不属于老师给定拓扑的正式地址规划。

**规划优势总结**
网段隔离：5 个网段10.20.0.0/24、10.30.0.0/24、10.40.0.0/24、203.0.113.0/24、10.10.10.0/24完全不重叠，满足题目不同网段要求；
网关规范：统一使用各网段.1作为防火墙网关，运维规则清晰，方便记忆和故障排查；
测试地址规范：各区域统一用.2作为测试主机 IP，便于后续防火墙安全策略、路由、NAT、VPN 连通性调试；
安全分区合理：按照企业经典安全区域划分（办公区、访客区、DMZ 服务器区、外网、VPN 远程区），符合等保、企业防火墙常规部署设计思路。

## 三、第一部分：网络规划与基础搭建
### setup.sh 脚本文件说明
该 Shell 脚本用于快速搭建基于 Linux 网络命名空间（Network Namespace）的网络拓扑环境，模拟包含防火墙（fw）、办公区（office）、访客区（guest）、DMZ 区（dmz）、公网（internet）、远程端（remote）的网络架构，并完成基础的网络配置与连通性测试。

**核心功能拆解**

**1. 脚本基础配置**
#!/bin/bash：指定脚本解释器为 Bash。
set -e：脚本执行过程中若任意命令返回非 0 退出码，立即终止脚本执行，避免错误扩散。

**2. 核心函数**：clean_env（清理旧环境）
删除旧命名空间：遍历 fw、office、guest、dmz、internet、remote 所有命名空间，执行 ip netns del 命令删除（忽略不存在的错误）。
删除旧虚拟网卡：遍历 veth-fw-office、veth-office、veth-rem-host、veth-vpn-fw 等所有成对虚拟网卡（veth），执行 ip link del 命令删除（忽略不存在的错误）。
作用：确保每次执行脚本时，从干净的环境开始搭建，避免旧配置干扰。

**3. 拓扑搭建流程**
步骤 1：执行环境清理
调用 clean_env 函数，删除历史残留的命名空间和虚拟网卡。

步骤 2：创建网络命名空间
创建 6 个独立的网络命名空间，模拟不同网络区域：
fw：防火墙（核心转发节点）
office：办公区网络
guest：访客区网络
dmz：隔离区（DMZ）网络
internet：公网环境
remote：远程端（通过 WireGuard VPN 接入）

步骤 3：创建成对虚拟网卡（veth pair）并绑定命名空间
veth pair 是 Linux 虚拟网卡，成对创建且一端数据可直通另一端，用于实现不同命名空间的网络连通：
office <-> fw：创建 veth-fw-office（绑定 fw）和 veth-office（绑定 office）
guest <-> fw：创建 veth-fw-guest（绑定 fw）和 veth-guest（绑定 guest）
dmz <-> fw：创建 veth-fw-dmz（绑定 fw）和 veth-dmz（绑定 dmz）
internet <-> fw：创建 veth-fw-inet（绑定 fw）和 veth-inet（绑定 internet）
remote <-> 宿主机：创建 veth-remote（绑定 remote）和 veth-rem-host（留在宿主机），在单主机模拟环境中为 remote 提供一条模拟互联网出口
宿主机 <-> fw VPN链路：创建 veth-vpn-fw（绑定 fw，IP 198.51.100.1）和 veth-vpn-host（留在宿主机，IP 198.51.100.2），在单主机模拟环境中为 remote 提供到达 fw WireGuard endpoint 的三层路径

步骤 4：配置防火墙（fw）网卡 IP 并启动网卡
为 fw 内的所有 veth 网卡配置静态 IP，并启动网卡（含回环网卡 lo）：
表格
| 网卡名称 | IP 地址 | 网段说明 |
|:-----|:-----|:---------|
| veth-fw-office | 10.20.0.1/24 | 办公区互联网段|
| veth-fw-guest  | 10.30.0.1/24 | 访客区互联网段|
| veth-fw-dmz | 10.40.0.1/24 | DMZ 区互联网段|
| veth-fw-inet	| 203.0.113.1/24 | 公网互联网段|

> 辅助接口（单主机模拟环境使用，不写入正式地址规划表）：`veth-vpn-fw` 配置 `198.51.100.1/30`，用于在 namespace 环境中模拟 remote 到 fw 的底层可达路径。

步骤 5：配置各区域主机 IP 并启动网卡
为 office/guest/dmz/internet 命名空间内的网卡配置静态 IP，并启动网卡（含回环网卡 lo）：
表格
| 命名空间 | 网卡名称 | IP 地址 | 
|----------|----------|---------|
| office   | veth-office | 10.20.0.2/24 |
| guest    | veth-guest  | 10.30.0.2/24 |
| dmz      | veth-dmz    | 10.40.0.2/24 |
| internet | veth-inet   | 203.0.113.10/24 |

remote 节点的 VPN 隧道地址 `10.10.10.2/24` 在 WireGuard 配置中分配（见下文）。

> 单主机模拟环境补充：remote 命名空间额外配置物理侧地址 `192.0.2.10/24`，宿主机侧 `veth-rem-host` 为 `192.0.2.1`、`veth-vpn-host` 为 `198.51.100.2`，仅用于在 namespace 环境中模拟 remote 经互联网访问 fw 的过程，不属于老师给定拓扑的正式地址规划。

步骤 6：配置默认路由
为所有区域主机配置默认网关（指向 fw 对应网段的 IP），确保流量通过 fw 转发：
office：默认路由 → 10.20.0.1（fw）
guest：默认路由 → 10.30.0.1（fw）
dmz：默认路由 → 10.40.0.1（fw）
internet：默认路由 → 203.0.113.1（fw）

> 单主机模拟环境补充：remote 命名空间的默认路由指向宿主机模拟网关 `192.0.2.1`；fw 额外添加回程路由 `192.0.2.0/24 via 198.51.100.2`，确保 remote 模拟公网地址 `192.0.2.10` 发出的流量能够正确返回。

步骤 7：开启 IP 转发
执行 sudo sysctl -w net.ipv4.ip_forward=1 同时开启 fw 命名空间和宿主机的 IPv4 转发功能；
由于宿主机默认 FORWARD 链可能被 Docker 等程序设为 DROP，额外添加 ACCEPT 规则放通 veth-rem-host 与 veth-vpn-host 之间的转发，保证 remote 到 fw VPN endpoint 的三层可达。

**4. WireGuard VPN 自动配置**
脚本自动生成固定密钥对，分别在 fw 和 remote 命名空间创建 wg0 接口并建立隧道：

| 参数 | fw 端 | remote 端 |
|:-----|:------|:----------|
| 接口 | wg0 | wg0 |
| IP | 10.10.10.1/24 | 10.10.10.2/24 |
| 监听/对端端口 | 51820 | - |
| Endpoint | - | 203.0.113.1:51820 |
| AllowedIPs | 10.10.10.2/32 | 10.20.0.0/24, 10.40.0.0/24 |

> 单主机模拟环境实际值：Endpoint 为 `198.51.100.1:51820`；fw 端 AllowedIPs 为 `10.10.10.2/32, 192.0.2.0/24`；remote 端 AllowedIPs 为 `10.10.10.0/24, 10.20.0.0/24, 10.40.0.0/24`。

fw 端添加 10.10.10.0/24 dev wg0 路由；remote 端添加 10.20.0.0/24 和 10.40.0.0/24 dev wg0 路由，实现分流访问办公区和 DMZ。

**5. 连通性测试**
脚本最后执行 3 类连通性测试：
基础连通性：各区域 ping fw 网关、remote ping 模拟外网网关（192.0.2.1）；
VPN 隧道连通性：fw/remote 互 ping VPN 隧道地址（10.10.10.1 / 10.10.10.2）；
跨 VPN 访问：remote 访问 office（10.20.0.2）和 dmz（10.40.0.2）。
每个测试执行 2 次 ping 包或 curl 请求，输出测试结果。

> 单主机模拟环境下，脚本额外测试 remote 到 fw 辅助 VPN 链路地址（198.51.100.1）的可达性，用于验证底层转发路径正常。

脚本使用说明
执行权限：需以 root 或 sudo 权限执行（涉及网络命名空间、网卡配置等系统操作）。
依赖环境：Linux 系统（需支持 ip netns、ip link、ip route、wg 等工具，并启用 WireGuard 内核模块）。
执行命令：sudo ./setup.sh。

**注意事项：**
脚本执行前会清理同名命名空间 / 网卡，避免冲突；
setup.sh 已包含 VPN 自动配置，无需再手动运行 wg-quick；
防火墙规则（iptables）在 firewall.sh 中单独配置，需在 setup.sh 之后执行。

### 连通性测试结果
![alt text](01-topology.png)

## 四、第二部分：防火墙策略实现

### 访问控制矩阵

| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 |成功，正常返回网页目录|如下图|
| office | dmz:22 | 失败+LOG |失败+LOG（REJECT + 日志有 OFFICE-TO-DMZ-SSH 前缀）|如下图|
| guest | office:任意 | 失败+LOG |失败+LOG（REJECT + 日志有 GUEST-TO-OFFICE 前缀，规则5~6有包计数）|如下图|
| guest | dmz:8080 | 失败+LOG |失败+LOG（REJECT + 日志有 GUEST-TO-DMZ 前缀，规则7~8有包计数）|如下图|
| guest | internet:任意 | 成功 |成功（ping 203.0.113.10 通，规则9有包计数）|如下图|
| office | internet:任意 | 成功 |成功（ping 203.0.113.10 通，规则10有包计数）|如下图|
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |成功（curl http://203.0.113.1:8080/ 返回 dmz 的 HTTP 页面）	|如下图|
| internet | dmz:22 | 失败 |失败（REJECT + 日志有 INET-TO-DMZ-SSH 前缀，规则17~18有包计数）|如下图|

![alt text](04-access-success.png)
![alt text](05-access-deny.png)

#### 规则列表截图

![alt text](02-firewall-rules.png)
![alt text](03-nat-rules.png)

### firewall.sh 完整说明 
**1、脚本整体概述**
firewall.sh 是配合 setup.sh 网络拓扑的Linux iptables 状态防火墙配置脚本，仅在 fw 网络命名空间内执行过滤、日志、NAT 转发规则，实现企业典型四层安全分区（Office 办公、Guest 访客、DMZ 服务器、Internet 外网）的访问隔离、流量审计、内网共享上网、外网发布 DMZ 服务。

*前置环境依赖*
已执行 setup.sh 搭建好 6 个网络命名空间与 veth 虚拟网卡；
fw 命名空间已开启 net.ipv4.ip_forward=1；
系统具备 iptables、ip netns、连接跟踪模块 nf_conntrack。
脚本头部基础参数
#!/bin/bash：bash 解释器
set -e：任意命令异常直接退出，避免规则配置错乱

**2、各函数模块逐行详解**
(1). initialize () 防火墙初始化（基线安全策略）
sudo ip netns exec fw iptables -F        # 清空filter表所有规则
sudo ip netns exec fw iptables -F -t nat # 清空nat表NAT规则
sudo ip netns exec fw iptables -X        # 删除自定义空链
sudo ip netns exec fw iptables -P INPUT ACCEPT  # 防火墙本机入站放行
sudo ip netns exec fw iptables -P OUTPUT ACCEPT # 防火墙本机出站放行
sudo ip netns exec fw iptables -P FORWARD DROP # 核心：跨区域转发默认全部拒绝

安全基线逻辑：采用最小权限原则，所有跨网段流量默认阻断，仅手动放行允许业务，防止横向渗透。

(2). configure_state () 状态检测规则（有状态防火墙核心）
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ESTABLISHED：内网主动发起请求的回程响应包（如 office 访问外网，外网回包）
RELATED：关联连接（ICMP 差错、FTP 数据通道等附属流量）
作用：只需放行NEW 新建连接，自动放行所有应答流量，无需双向写规则，简化配置。

(3). configure_office () 办公区访问 DMZ 策略
网段：Office 10.20.0.0/24，DMZ 10.40.0.0/24
允许 Office 访问 DMZ 8080 业务端口
匹配入接口 veth-fw-office、出接口 veth-fw-dmz，仅放行新建 TCP 8080 连接，用于业务系统访问。
拒绝 Office 访问 DMZ 22 SSH 管理端口（带日志审计）
先 LOG 记录阻断日志，前缀OFFICE-TO-DMZ-SSH，日志级别 4；
再 REJECT 返回 TCP 重置包，客户端直接断开，无超时等待；
管控风险：禁止员工直连服务器 SSH，防止服务器被暴力破解。

(4). configure_guest () 访客网强隔离策略
网段：Guest 10.30.0.0/24
拒绝 Guest 访问 Office 内网
日志限流limit 5/min，防止日志刷屏；返回 ICMP 主机不可达。
拒绝 Guest 访问 DMZ 服务器区
访客完全隔离内部资产，仅允许互联网。
允许 Guest 访问 Internet 外网
放行访客新建外网请求，配合 SNAT 实现访客上网。

(5). configure_dmz () DMZ 服务器区策略
网段：DMZ 10.40.0.0/24
允许 DMZ 主动访问外网（用于服务器补丁、接口调用）；
外网 Internet 禁止主动访问 Office/Guest 内网，拦截外部渗透内部核心区域，阻断外网横向入侵。

(6). configure_nat () NAT 地址转换（内网上网 + 外网发布服务）
 ① SNAT MASQUERADE 内网共享上网
对 Office/Guest/DMZ 三个内网段出站流量做源地址伪装，统一转换为防火墙公网 IP 203.0.113.1，实现多内网共用单个公网 IP 访问互联网。
②  DNAT 外网发布 DMZ 8080 服务
外网访问公网 IP 8080 端口时，目的地址转换为 DMZ 服务器 10.40.0.2:8080，对外暴露业务服务；配套 FORWARD 放行规则允许外网流量转发至 DMZ。
③  阻断外网访问 DMZ 22 SSH
外网禁止 SSH 登录服务器，仅开放 8080 业务端口，缩小攻击面，日志留存入侵尝试记录。
④  VPN 流量不执行 SNAT
由于 setup.sh 已添加 10.10.10.0/24 dev wg0 路由，fw 可直接将 VPN 回程流量转发回 remote，因此 VPN 访问 office/dmz 不做 MASQUERADE，保留原始源 IP 10.10.10.2，便于审计和远程主机识别。

(7). configure_office_inet () 办公区访问互联网
放行 Office 网段新建外网连接，配合 SNAT 实现员工正常上网。

(8). configure_vpn () VPN 远程访问规则
允许 VPN 客户端（wg0 接口进入，源地址 10.10.10.2）访问 office 网段和 dmz 的 8080 业务端口；
拒绝 VPN 访问 dmz:22 SSH 管理端口（带 VPN-TO-DMZ-SSH 日志前缀）；
拒绝 VPN 访问 guest 访客网段，与内网隔离策略保持一致。

(9). configure_vpn_nat () VPN SNAT 规则
VPN 流量不执行 SNAT，依赖 wg0 路由直接回程，保留 remote 原始源 IP。

(10). show_rules () 规则打印输出
打印 FORWARD 过滤链、nat 转换链完整规则，带行号、流量统计，方便调试排查连通性故障。

(11). main () 主执行流程
固定执行顺序：初始化 → 状态规则 → Office 策略 → Guest 隔离 → DMZ 策略 → NAT 转换 → 办公上网放行 → VPN 规则 → VPN NAT → 打印规则，顺序不可颠倒（iptables 规则从上至下匹配）。


**规则设计说明**
1. 防火墙规则顺序设计原理
iptables规则遵循从上到下依次匹配、匹配即停止的执行机制，本次规则按照「通用基础规则→业务放行规则→违规阻断日志规则→默认拒绝策略」的顺序编排，具体设计逻辑如下：

(1) 第 1 条：状态连接规则（RELATED,ESTABLISHED）优先配置
所有区域回程应答流量统一放行，只要是内网主动发起连接的返回数据包（比如办公机访问外网后外网回包、访问 DMZ 服务的响应报文）直接放行。只需要针对新建 NEW 连接做访问控制，无需双向配置放行规则，大幅简化规则数量，是有状态防火墙的核心前置规则，必须放在最顶部。

(2) 按信任级别从高到低配置内网区域规则：办公网 Office → 访客网 Guest → DMZ 服务器区 → 外网 Internet
先配置高信任区域（Office 办公区）的放行 / 阻断规则：允许办公网访问 DMZ 业务 8080 端口，同时阻断高危的 22 端口并记录日志；
再配置低信任区域（Guest 访客网）的强隔离规则：直接阻断访客访问办公内网、DMZ 服务器，仅放行访客访问外网；
接着配置 DMZ 对外、外网访问内网的防护规则：只允许外网访问 DMZ 的 8080 业务端口，彻底阻断外网主动访问办公区、访客内网，防止外网横向渗透入侵。

(3) 阻断规则遵循「先日志记录，再拒绝数据包」的顺序
所有违规访问行为，先通过LOG规则记录访问日志（添加自定义日志前缀、限制日志频率防止刷屏），再执行REJECT拒绝动作，既可以留存安全审计日志用于入侵溯源，又能精准管控非法流量。

(4) 全局默认策略兜底：FORWARD 链默认 DROP
所有没有被前面规则匹配到的跨网段流量，全部默认丢弃，遵循最小权限安全原则，只放行预设的合法业务流量，最大程度缩小网络攻击面。

2. 选择 REJECT 而非 DROP 的原因

（1）DROP：直接静默丢弃数据包，不返回任何响应报文
行为：防火墙收到非法数据包后直接丢弃，不会给源主机返回任何 ICMP/TCP 应答；
缺点：
客户端会一直等待超时，访问失败需要等待几十秒才能判定无法连通，故障排查效率极低；
黑客可以利用长时间超时特征，探测目标端口是否存在，进行端口扫描、隐蔽式踩点；
无法区分「端口关闭」「网络不通」「防火墙拦截」三种场景，故障定位困难。

（2）REJECT：主动返回拒绝应答报文（本次使用icmp-port-unreachable）
行为：防火墙丢弃数据包的同时，主动向源 IP 返回ICMP 端口不可达响应报文；
优势：
客户端瞬间收到拒绝反馈，立刻判定访问被拦截，无需长时间等待超时，方便运维人员快速验证防火墙策略是否生效（本次实验中可以快速确认访客、外网被内网拦截的效果）；
可以精准区分故障场景：收到拒绝报文 = 防火墙策略拦截；超时无响应 = 链路故障 / 路由异常；
对常规客户端友好，不会产生大量无效重传数据包，节约带宽资源；
配合前置LOG日志规则，既能实现安全审计，又能提升网络调试、策略验证的效率，非常适合教学实验、企业内网边界场景。


## 五、第三部分：VPN远程接入
### WireGuard配置说明

**fw端（服务端）**：
- `Address = 10.10.10.1/24`：VPN隧道地址
- `ListenPort = 51820`：监听端口
- `AllowedIPs = 10.10.10.2/32`：只接受 remote 的 VPN 地址（严格限制）

**remote端（客户端）**：
- `Address = 10.10.10.2/24`：VPN隧道地址
- `Endpoint = 203.0.113.1:51820`：fw 的外网地址和端口（与老师拓扑图一致）
- `AllowedIPs = 10.20.0.0/24,10.40.0.0/24`：只有访问 office 和 dmz 网段时走 VPN 隧道，其他流量走本地（split-tunnel设计）

> **单主机模拟环境实际配置**：由于 remote 命名空间在同一台宿主机上无法直接访问 `203.0.113.1`，`setup.sh` 实际将 Endpoint 设置为辅助地址 `198.51.100.1:51820`，并通过 `veth-vpn-fw/veth-vpn-host` 模拟底层可达性。同时 fw 端 `AllowedIPs` 额外包含 `192.0.2.0/24`，以接收从 remote 模拟公网地址 `192.0.2.10` 封装而来的 WireGuard 外层 UDP 报文。

### VPN 配置说明：AllowedIPs 设计思路

1. **作用核心**
AllowedIPs 是 WireGuard 的访问控制 + 路由下发双重配置项，既用来校验数据包源 / 目的 IP 是否合法，也会自动在本机生成对应网段的路由，指定哪些流量需要走 VPN 隧道传输。
2. **服务端 fw 的 AllowedIPs**
`10.10.10.2/32`
精准只允许这一个远程 VPN 客户端 IP 接入，防止其他非法 IP 冒用密钥接入 VPN；
只有源 IP 为10.10.10.2的流量才会被 WireGuard 接收处理，其他 IP 数据包直接丢弃；
精准绑定单个客户端，实现最小权限接入，避免网段滥用带来的内网安全风险。

> 单主机模拟环境下，`setup.sh` 实际使用 `10.10.10.2/32, 192.0.2.0/24`，额外加入 `192.0.2.0/24` 是为了让 fw 能够接收从 remote 模拟公网地址 `192.0.2.10` 封装而来的 WireGuard 外层 UDP 报文。

3. **客户端 remote 的 AllowedIPs**
`10.20.0.0/24,10.40.0.0/24`
路由下发：配置的所有网段会自动添加到客户端路由表，访问这两段内网的流量全部转发到 wg0 VPN 隧道，经过防火墙进入企业内网；
访问控制：只有目的地址属于这两个网段的流量才会通过 VPN 加密传输，其余流量（如访问互联网）默认不走 VPN，走本地原路由；
安全边界：限制 VPN 用户仅能访问企业授权的办公网、DMZ 区网段，禁止访问 VPN 隧道网段之外的其他区域（如访客 guest 网段 10.30.0.0/24），契合之前防火墙访问控制策略，防止 VPN 用户越权访问隔离区域。

> 单主机模拟环境下，`setup.sh` 实际使用 `10.10.10.0/24,10.20.0.0/24,10.40.0.0/24`，额外包含 `10.10.10.0/24` 是为了在 remote 本地生成到 VPN 隧道的路由。
4. **设计总结**
最小权限原则：服务端精准绑定单个客户端 IP，客户端仅开放授权内网网段；
路由自动化：无需手动添加静态路由，AllowedIPs 自动生成隧道路由，简化远程内网访问配置；
双重安全：兼顾加密隧道接入校验 + 内网访问范围限制，即使密钥泄露，非法 IP 也无法接入、无法越权访问其他网段。

**验证VPN隧道状态**

```bash
# 查看fw端
sudo ip netns exec fw wg show
# 应显示：latest handshake时间、transfer有数据

# 查看remote端
sudo ip netns exec remote wg show
# 应显示：latest handshake时间、transfer有数据
```

**结果**
![alt text](06-vpn-status.png)

**VPN访问测试**

```bash
# 应成功：VPN访问office
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/

# 应成功：VPN访问dmz:8080
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/

# 应失败+LOG：VPN访问dmz:22
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:22/

# 应失败：VPN访问guest
sudo ip netns exec remote ping -c 2 10.30.0.2
```
**测试结果**
![](07-vpn-success.png)
![](08-vpn-deny.png)

**查看remote路由表**

```bash
sudo ip netns exec remote ip route
# 应能看到10.20.0.0/24和10.40.0.0/24走wg0接口
```

![alt text](22-remote-route.png)

## 六、第四部分：安全审计与日志分析
### LOG规则说明
1. **LOG 规则配置位置与格式说明**
本次在fw防火墙命名空间的iptables FORWARD转发链中，所有非法跨区域访问均配置先日志记录、再拒绝数据包的规则，核心配置格式示例：
```bash
# 访客访问办公网日志规则
-A FORWARD -i veth-fw-guest -o veth-fw-office -j LOG \
--log-level 4 \
--log-prefix "GUEST-TO-OFFICE: " \
--limit 5/min --limit-burst 10
# 日志后执行REJECT拒绝
-A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT --reject-with icmp-port-unreachable
```
2. **关键参数设计解释**
- --log-prefix 自定义日志前缀
为每一类违规访问设置唯一标识前缀，如OFFICE-TO-DMZ-SSH、GUEST-TO-OFFICE、INET-TO-DMZ-SSH，可以快速筛选定位违规流量的源区域、目的区域，实现安全事件分类审计。
- --log-level 4（INFO 级别）
日志级别设置为信息级，既可以完整记录五元组（源 IP、目的 IP、源端口、目的端口、协议）数据包信息，又不会记录系统冗余调试日志，方便后期安全排查。
- --limit 5/min --limit-burst 10 日志限流机制
限制每分钟最多生成 5 条审计日志，突发峰值最多 10 条。作用：
防止端口扫描、暴力攻击产生海量日志刷屏，占用服务器磁盘空间；
避免日志文件快速膨胀导致系统故障，保障审计日志长期可留存。
规则执行顺序：先 LOG，后 REJECT
必须先记录日志再丢弃数据包，保证所有被拦截的非法访问行为都会留存审计记录；若先拒绝再日志，会导致部分攻击流量丢失日志，无法完成溯源。
3. **所有审计日志覆盖场景**
- 办公网访问 DMZ 区 22 端口 SSH 高危连接拦截日志；
- 访客网访问办公内网所有流量拦截日志；
- 访客网访问 DMZ 服务器区所有流量拦截日志；
- 外网主动访问办公内网、访客网的拦截日志；
- 外网尝试连接 DMZ 服务器 22 端口 SSH 的攻击拦截日志。
4. **日志查看命令（fw 命名空间内执行）**
```bash
# 方式1：查看内核环形缓冲区实时日志
sudo ip netns exec fw dmesg -w | grep -E "OFFICE|GUEST|INET"

# 方式2：筛选指定类型安全事件日志
sudo ip netns exec fw dmesg | grep "GUEST-TO-OFFICE" > guest_attack.log
```

**触发违规访问场景**

```bash
# 场景1：guest尝试访问office
sudo ip netns exec guest curl --max-time 2 http://10.20.0.2:8000/

# 场景2：guest尝试访问dmz
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/

# 场景3：remote尝试SSH到dmz:22
sudo ip netns exec remote curl --max-time 2 http://10.40.0.2:22/

# 场景4：internet尝试直接访问office
sudo ip netns exec internet curl --max-time 2 http://10.20.0.2:8000/

# 场景5：internet尝试访问dmz未映射端口
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:3306/
```

**结果**
![alt text](24-violation-fail.png)

**LOG规则配置截图**
![alt text](23-iptables-log.png)

**实时监控日志**

```bash
# 打开新终端，实时查看内核日志
sudo journalctl -k -f
# 或使用 dmesg -w
```
![alt text](09-logs-realtime.png)

**统计日志**

```bash
# 统计各类事件频次
sudo journalctl -k --no-pager | grep -c "GUEST-TO-OFFICE"
sudo journalctl -k --no-pager | grep -c "GUEST-TO-DMZ"
sudo journalctl -k --no-pager | grep -c "VPN-TO-DMZ-SSH"
sudo journalctl -k --no-pager | grep -c "INET-TO-OFFICE"
sudo journalctl -k --no-pager | grep -c "VPN-DENY"

# 查看最近10条安全日志
sudo journalctl -k --no-pager | grep -E "GUEST-|VPN-|INET-" | tail -10
```
![alt text](10-logs-stats.png)

**查看规则计数器**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
# pkts和bytes列显示每条规则匹配的数据包数和字节数
```
*说明*
本实验使用 network namespace 架构，iptables LOG 目标产生的内核日志消息不经过主机 dmesg/journalctl 缓冲区，因此无法通过 journalctl 提取到包含 IN/OUT/SRC/DST/DPT 完整字段的日志文本。但通过以下方式确认了日志审计功能的正常工作：
- 每条 LOG 规则的 iptables 计数器（pkts 字段）均有非零匹配值
- 每条 LOG 规则与其后继 REJECT 规则的 pkts 数值一致，证明被拒绝流量均经过 LOG 记录
- 通过 tcpdump 抓包可观察到对应的 ICMP port unreachable / TCP reset 响应

### 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office |1|1|是|
| guest→dmz |1|1|是|
| VPN→dmz:22 |1|1|是|
| internet→office |1|1|是|
| VPN其他违规 |1|1|是|

### 日志分析报告

#### 1. 从日志中能获取哪些安全信息？

内核日志包含丰富的信息：时间戳、主机名、log-prefix标识、IN/OUT接口名、SRC/DST源目的地址、PROTO协议类型、SPT/DPT端口号等。通过这些信息可以：
- 识别攻击来源（源IP、入口接口）
- 判断攻击目标（目的IP、目的端口）
- 分析攻击类型（端口扫描、SSH爆破、Web攻击等）
- 建立攻击时间线
- 统计攻击频率和模式

#### 2. LOG规则为什么要放在REJECT之前？

iptables规则按顺序匹配，匹配到第一条符合条件的规则后就执行动作（ACCEPT/DROP/REJECT/LOG），不再继续匹配后续规则。LOG是非终止型目标（non-terminating target），数据包经过LOG后继续匹配下一条规则。如果LOG在REJECT之后，数据包已经被REJECT丢弃，永远不会到达LOG规则，日志就不会被记录。

#### 3. 速率限制如何防止日志洪水攻击？

`-m limit --limit 5/min --limit-burst 10` 使用令牌桶算法：
- `--limit 5/min`：平均每分钟最多记录5条日志
- `--limit-burst 10`：初始令牌桶容量为10，允许突发10条
- 当攻击者大量发包时，超过速率的包不会产生日志，防止日志文件被写满导致磁盘耗尽（日志洪水攻击）

#### 4. 不同log-prefix的作用是什么？

不同log-prefix用于分类标识不同的安全事件类型：
- 便于日志检索和过滤（如`grep "GUEST-TO-OFFICE"`）
- 便于统计各类事件的发生频率
- 便于设置不同的告警级别（如VPN-TO-DMZ-SSH无速率限制说明更需要关注）
- 便于自动化安全响应（如检测到频繁的INET-TO-OFFICE可自动封禁IP）



## 七、第五部分：攻防演练
### 5.1 攻击方演练

#### 攻击1：guest扫描office网段

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**失败原因分析**：防火墙配置了`guest -> office`的REJECT规则，所有从guest到office的ICMP包都被拒绝。防火墙返回icmp-admin-prohibited，guest收到"目标不可达"响应。攻击者无法通过ping扫描发现office网段存活主机，因为防火墙在边界统一拦截，不区分具体主机。

#### 攻击2：尝试绕过防火墙访问dmz:22

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**失败原因分析**：防火墙的`guest -> dmz`规则匹配的是入口接口（`-i veth-fw-guest`）和出口接口（`-o veth-fw-dmz`），不关心源端口。无论攻击者使用什么源端口，只要数据包从guest接口进入、目标是dmz，就会被REJECT。改变源端口无法绕过基于接口+方向的访问控制。

#### 攻击3：思考伪造VPN流量

```bash
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/
```

**问题：攻击者能否伪造源地址为10.10.10.2的包来访问内网？**

**答案：不能。** 原因如下：
1. VPN流量通过`wg0`接口进入，规则匹配`-i wg0`，而非仅靠源地址
2. WireGuard使用加密隧道，无法从外部伪造合法的WireGuard包
3. 即使能伪造源地址，回包会路由到真正的10.10.10.2，攻击者收不到
4. 防火墙有状态检测，未建立连接的包会被默认DROP

**REJECT vs DROP 的信息泄露差异**：REJECT会立即返回响应，攻击者可以根据响应时间判断目标是否存在（端口开放/关闭/过滤）；DROP静默丢弃，攻击者只能等待超时。REJECT虽然方便排查，但在生产环境中对敏感服务建议使用DROP。

### 5.2 防御方分析

#### 从日志识别攻击

查看最近的拒绝日志：
```bash
sudo journalctl -k --since "10 minutes ago" --no-pager | grep -E "GUEST-|VPN-|INET-"
```

**回答问题**：
1. 从日志的哪些字段可以判断这是来自guest的攻击？
>答：从`IN=veth-fw-guest`字段可以判断攻击来自guest区域；`SRC=10.30.0.2`确认了具体攻击源IP
2. 如果日志中IN=veth-fw-guest OUT=veth-fw-office，说明了什么？
>答：`IN=veth-fw-guest OUT=veth-fw-office`说明数据包从guest接口进入、试图从office接口出去，即guest正在尝试访问office
3. 为什么看到大量相同来源的日志应该引起警惕？ 
>答：大量相同来源的日志说明可能正在遭受扫描或暴力攻击，需要立即响应

#### 分析规则防御效果

**回答问题**：
1. 哪条规则拦截了guest访问office？
>答：查看`iptables -L FORWARD -n -v --line-numbers`，pkts计数>0的REJECT规则就是拦截了guest访问office的规则
2. 如果guest→office的规则计数很高，说明了什么？
>答：高计数说明guest→office方向存在持续的攻击尝试
3. REJECT和DROP在安全性上有什么区别？
>答：REJECT返回响应让客户端快速知道被拒绝，DROP静默丢弃增加攻击者时间成本。从安全角度看DROP更好（隐藏网络结构），从运维角度看REJECT更便于排查问题

### 5.3 边界测试与改进方案
#### 选择的问题：dmz:8080对外开放

**风险分析**：
dmz:8080 端口通过 DNAT 对外开放，使得互联网用户可以直接访问内部 DMZ 区的 Web 服务。这带来了多项安全风险。首先，Web 服务可能存在代码漏洞（如 SQL 注入、XSS、命令注入等），攻击者可以利用这些漏洞入侵服务器，进而以此为跳板攻击内网。其次，该端口完全暴露在互联网上，容易成为 DDoS 攻击的目标，大量恶意请求可能导致服务瘫痪。第三，缺乏访问频率限制使得暴力破解（如针对 Web 登录页面）和目录扫描（如 dirb、gobuster）难以被检测。第四，如果没有 HTTPS 加密，数据传输过程中可能被中间人攻击窃取敏感信息。最后，对外开放的端口还会暴露服务器软件和操作系统版本信息，为攻击者提供更有针对性的攻击向量。

**改进方案**：
```bash
# 1. 限制单IP最大并发连接数为10
sudo ip netns exec fw iptables -I FORWARD 1 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset

# 2. 限制新连接速率（每秒最多5个新连接）
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m limit --limit 5/sec --limit-burst 10 \
  -j ACCEPT

# 超过速率的丢弃
sudo ip netns exec fw iptables -I FORWARD 3 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -j DROP
```

**测试效果**：
```bash
# 使用ab进行压力测试验证
sudo ip netns exec internet apt install -y apache2-utils
sudo ip netns exec internet ab -n 50 -c 20 http://203.0.113.1:8080/
# 观察connlimit是否生效，超过10个并发连接应被拒绝
```

### 5.4 高级任务：追踪包的完整变化过程

**任务：追踪一次"remote通过VPN访问dmz:8080"的完整过程**

要求在4个位置同时抓包：

```bash
# 终端1：remote的wg0接口（看到封装前的包）
sudo ip netns exec remote tcpdump -ni wg0 -c 5

# 终端2：fw的wg0接口（看到解封装后的包）
sudo ip netns exec fw tcpdump -ni wg0 -c 5

# 终端3：fw的veth-fw-dmz接口（看到转发到dmz的包）
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5

# 终端4：fw的conntrack表
watch -n 1 'sudo ip netns exec fw cat /proc/net/nf_conntrack | grep 10.10'

# 终端5：触发访问
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

**填写包变化对比表：**

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 |10.10.10.2|10.40.0.2|tcp, sport→dport:8080| 封装前 |
| 2 | fw wg0 |10.10.10.2|10.40.0.2|tcp, sport→dport:8080| 解封装后 |
| 3 | fw veth-fw-dmz |10.10.10.2|10.40.0.2|tcp, sport→dport:8080| 转发到dmz |
| 4 | conntrack |10.10.10.2 ↔ 10.40.0.2	|sport↔8080	|tcp TIME_WAIT [ASSURED]| 连接跟踪记录 |

**数据包处理分析报告**
本次抓包基于 WireGuard VPN 环境，客户端remote通过 VPN 访问 DMZ 区域10.40.0.2:8080的 HTTP 服务，数据包完整处理流程分为四个阶段。
- 第一阶段在remote命名空间的wg0网卡，主机生成源 IP 为10.10.10.2、目的 IP10.40.0.2的 TCP 报文，该原始内网数据包经过 WireGuard 加密封装为 UDP 报文，通过 VPN 隧道发送至防火墙fw节点。
- 第二阶段数据包到达fw的wg0网卡，WireGuard 对加密报文解密，剥离外层 UDP 头部，还原出原始内网 IP 数据包，源、目的 IP 地址未发生变化。
- 第三阶段防火墙查询路由表，将原始 IP 报文从veth-fw-dmz网卡转发至 DMZ 网段，本次通信未配置源 NAT，数据包源 IP 仍为 VPN 客户端内网地址，经二层以太网封装后送达目标服务器。
- 第四阶段内核conntrack模块记录本次 TCP 双向连接五元组信息，连接结束后状态变为TIME_WAIT，同时防火墙依据连接跟踪表放行回程响应报文，完成本次 VPN 跨网段访问全过程。本次流量符合预设放行规则，因此数据包正常转发、HTTP 请求成功完成。

## 八、故障排查

### 场景1：DNAT配置了但外网无法访问

**重现故障**：
```bash
# 故意删除DNAT对应的FORWARD规则
sudo ip netns exec fw iptables -D FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 测试：internet访问fw:8080失败
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```

**排查过程**：
```bash
# 1. 检查DNAT规则是否存在
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v
# DNAT规则存在 ✓

# 2. 检查FORWARD规则是否放行DNAT后的流量
sudo ip netns exec fw iptables -L FORWARD -n -v | grep "10.40.0.2"
# 发现缺少放行规则 ✗

# 3. 用conntrack观察
sudo ip netns exec fw conntrack -L | grep 10.40.0.2
# 没有DNAT转换记录，说明包在FORWARD链被丢弃

# 4. 修复：重新添加FORWARD规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# 5. 验证修复：internet 访问 dmz:8080（应成功）"
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```

**根本原因**：DNAT只做目的地址转换，转换后的数据包还需要通过FORWARD链的检查。如果FORWARD链没有放行从internet接口到dmz接口、目的为10.40.0.2:8080的流量，DNAT转换后的包会被FORWARD默认DROP丢弃。

### 场景2：VPN隧道握手正常但业务访问失败

### 可能原因1：FORWARD防火墙规则缺失或顺序错误

**制造方法：**
```bash
# 删除VPN用户访问office的FORWARD放行规则
sudo ip netns exec fw iptables -D FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT
```
**故障现象**
- wg show 握手正常，有transfer计数
- 但 remote curl http://10.20.0.2:8000/ 超时失败

**排查过程**
- 确认隧道：wg show → 正常 ✓
- 查看路由：ip route get 10.20.0.2 → 走wg0，正确 ✓
- 查看FORWARD规则：iptables -L FORWARD -n -v | grep wg0 → 发现缺少 wg0→office 的ACCEPT规则 ✗
- 抓包验证：fw上 tcpdump -ni wg0 能抓到包 → 包到达fw但被iptables拦截

```bash
# 检查FORWARD规则
sudo ip netns exec fw iptables -L FORWARD -n -v | grep wg0
# 如果缺少VPN放行规则，需要重新运行vpn-setup.sh或手动添加
```
*根因：* 删除规则后，流量进入fw但被FORWARD链末尾的catch-all REJECT拦截。 用 -A 追加规则会排在REJECT之后导致不生效。

**修复方法**
```bash
# 使用 -I 在REJECT规则之前插入（假设REJECT在第26行）
sudo ip netns exec fw iptables -I FORWARD 26 \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT
```


**可能原因2：AllowedIPs配置错误**

**故障说明**：`AllowedIPs` 决定哪些目标网段的流量走WireGuard隧道。若remote端缺少目标网段，WireGuard不会为这些网段添加路由，流量走默认路由而非VPN隧道。

**制造方法**：
```bash
# 修改remote的WireGuard配置，去掉10.20.0.0/24
sudo tee /etc/wireguard/remote/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = <原私钥>

[Peer]
PublicKey = <fw公钥>
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.40.0.0/24    # 只包含dmz，不包含office
PersistentKeepalive = 25
EOF

# 重启WireGuard使配置生效
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

# 测试：访问office网段会失败
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
# 输出：curl: (28) Connection timed out
```

**排查过程**：

步骤1：确认VPN隧道层
```bash
sudo ip netns exec remote wg show
# latest handshake正常，transfer有数据 → 隧道本身没问题
```

步骤2：检查路由表
```bash
sudo ip netns exec remote ip route
# 输出中只看到 10.40.0.0/24 dev wg0，没有 10.20.0.0/24 dev wg0
```

步骤3：对比路由决策（关键区分点）
```bash
# 访问dmz网段 — 走wg0（正常）
sudo ip netns exec remote ip route get 10.40.0.2
# 输出：10.40.0.2 dev wg0 src 10.10.10.2

# 访问office网段 — 不走wg0（异常）
sudo ip netns exec remote ip route get 10.20.0.2
# 输出：10.20.0.2 via <默认网关> dev veth-remote  # 走了默认路由而非wg0！
```
对比结果：10.40.0.2走wg0，10.20.0.2走默认路由，说明AllowedIPs中缺少10.20.0.0/24。

步骤4：确认AllowedIPs配置
```bash
sudo ip netns exec remote wg showconf wg0 | grep -i allowed
# 输出：AllowedIPs = 10.40.0.0/24
# 缺少 10.20.0.0/24
```

**根本原因**：WireGuard的 `AllowedIPs` 字段有双重作用：
1. **加密策略**：只有源地址在peer的AllowedIPs范围内的包才被接受解密
2. **路由策略**：wg-quick根据AllowedIPs自动添加内核路由，只有目标地址匹配的包才走wg0

remote端AllowedIPs只含10.40.0.0/24，WireGuard仅为该网段添加路由。发往10.20.0.0/24的包匹配不到wg0路由，走了默认路由，根本不会进入VPN隧道。

**修复方法**：
> 注意：仅用 `wg set` 修改AllowedIPs不会自动更新内核路由表，必须手动添加路由或重启WireGuard。

```bash
# 方法1：手动添加路由（快速修复，不改变配置文件）
sudo ip netns exec remote ip route add 10.20.0.0/24 dev wg0

# 方法2：修改配置文件后重启WireGuard（推荐，永久生效）
# 编辑 /etc/wireguard/remote/wg0.conf，将AllowedIPs改为：
# AllowedIPs = 10.20.0.0/24,10.40.0.0/24
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
# wg-quick up会自动根据AllowedIPs添加对应路由
```

**验证修复**：
```bash
# 确认路由已添加
sudo ip netns exec remote ip route | grep wg0
# 应同时看到 10.20.0.0/24 dev wg0 和 10.40.0.0/24 dev wg0

# 确认路由决策正确
sudo ip netns exec remote ip route get 10.20.0.2
# 应输出：10.20.0.2 dev wg0 src 10.10.10.2

# 测试访问
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
# 应返回HTTP 200
```

### 两原因对比快速定位

| 排查步骤 | 原因1（FORWARD规则缺失） | 原因2（AllowedIPs错误） |
|:--------|:----------------------|:----------------------|
| `wg show` | 握手正常 | 握手正常 |
| `ip route get 10.20.0.2` | 走wg0 ✓ | 走默认路由 ✗ |
| `tcpdump -ni wg0` on fw | 能抓到包 | 抓不到包 |
| `tcpdump -ni veth-fw-office` | 抓不到包 | 抓不到包 |
| `iptables -L FORWARD -n -v` | wg0→office规则pkts=0 | wg0→office规则pkts=0 |
| **定位关键** | 包到达fw的wg0但被FORWARD丢弃 | 包根本没进入VPN隧道，从remote就走错了 |

分层排查口诀：
```bash
# 1. 确认VPN隧道层
sudo ip netns exec remote wg show

# 2. 确认路由层（关键区分点！）
sudo ip netns exec remote ip route get 10.20.0.2
# 走wg0 → 路由正确，问题在fw的FORWARD
# 不走wg0 → 路由问题，检查AllowedIPs

# 3. 确认防火墙层
sudo ip netns exec fw iptables -L FORWARD -n -v | grep wg0

# 4. 分层抓包定位
sudo ip netns exec fw tcpdump -ni wg0 -c 5
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 5
```

### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

**重现故障**：
```bash
# 第一步：找到状态检测规则的行号
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers | grep ESTABLISHED
# 假设行号是1

# 第二步：删除状态检测规则
sudo ip netns exec fw iptables -D FORWARD 1

# 第三步：确认规则已删除（第一条不应再是ESTABLISHED,RELATED规则）
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5

# 测试：office访问dmz:8080
sudo ip netns exec office curl --max-time 10 http://10.40.0.2:8080/
# 输出：curl: (28) Connection timed out
```

**排查过程**：

**步骤1：确认ESTABLISHED,RELATED规则已被删除**
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5
```
正常情况下FORWARD链第一条应为 `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`。删除后第一条变为其他规则（如NEW状态放行规则）。若第一条仍为 `all -- * * 0.0.0.0/0 0.0.0.0/0` 且有pkts计数增长，说明规则未被成功删除。

**步骤2：观察连接跟踪表中的连接状态**
```bash
# 关键：必须在curl运行期间查看，连接结束后conntrack条目会被内核回收
# 方式一：通过 /proc/net/nf_conntrack（内核原生支持，无需额外安装工具）
sudo ip netns exec fw cat /proc/net/nf_conntrack | grep "10.40.0.2"

# 方式二：若已安装conntrack工具
sudo ip netns exec fw conntrack -L | grep "10.40.0.2"
```

输出示例：
```
tcp  6 58 SYN_RECV src=10.20.0.2 dst=10.40.0.2 sport=34060 dport=8080
     src=10.40.0.2 dst=10.20.0.2 sport=8080 dport=34060 mark=0 use=1
```

关键信息：
- **状态为 `SYN_RECV`**：服务端已收到SYN并发送了SYN-ACK，但客户端未收到（SYN-ACK被防火墙DROP），连接卡在半开状态
- **双向地址都有记录**：conntrack已看到请求和回复两个方向的数据包
- **连接永远无法进入ESTABLISHED**：三次握手无法完成

**步骤3：抓包证明SYN-ACK被拦截**
```bash
# 终端A：在dmz侧接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 "host 10.40.0.2 and port 8080"

# 终端B：在office侧接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 10 "host 10.20.0.2 and port 8080"

# 终端C：触发连接
sudo ip netns exec office curl --max-time 10 http://10.40.0.2:8080/
```

抓包结果：
- `veth-fw-dmz`：能看到SYN到达dmz、dmz回复SYN-ACK
- `veth-fw-office`：只能看到SYN发出，看不到SYN-ACK返回（被FORWARD链DROP）

tcpdump输出会显示重复重传模式：
```
10.20.0.2.xxxxx > 10.40.0.2.8080: Flags [S], seq ...     # SYN → 到达dmz
10.40.0.2.8080 > 10.20.0.2.xxxxx: Flags [S.], seq ...    # SYN-ACK ← dmz发出(FORWARD被DROP)
10.20.0.2.xxxxx > 10.40.0.2.8080: Flags [S], seq ...     # SYN 重传(没收到SYN-ACK)
10.40.0.2.8080 > 10.20.0.2.xxxxx: Flags [S.], seq ...    # SYN-ACK 重传(又被DROP)
```

**根本原因**：

状态检测规则 `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` 是状态防火墙的核心，用于放行已建立连接的返回流量。删除后：
1. office发出的SYN包匹配 `--ctstate NEW -j ACCEPT` 规则，成功到达dmz
2. dmz收到SYN后回复SYN-ACK，conntrack表中连接状态变为 `SYN_RECV`
3. SYN-ACK到达fw的FORWARD链，但它不属于NEW状态，也没有ESTABLISHED,RELATED规则放行
4. SYN-ACK被FORWARD链默认DROP丢弃
5. office收不到SYN-ACK，持续重传SYN，连接始终卡在 `SYN_RECV`
6. 客户端最终超时，连接失败

**修复方法**：
```bash
# 恢复状态检测规则（必须放在FORWARD链第一条）
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

**ESTABLISHED,RELATED的必要性**：状态检测是状态防火墙的核心功能。ESTABLISHED允许已建立连接的返回流量通过；RELATED允许与已有连接相关的流量（如FTP数据通道、ICMP差错消息）。没有这条规则，任何双向通信都无法正常工作，因为只有NEW状态的初始包能匹配放行规则，所有返回流量都会被默认DROP拦截。


## 九、遇到的问题和解决方法

本次企业级网络安全架构搭建实验中，先后遇到 4 类典型故障，结合抓包、路由排查、防火墙规则校验完成问题定位与修复，具体问题及解决思路如下：

1. **内网 guest 网段访问外网出现连接超时，curl 请求长时间无法建立 TCP 连接**
**故障现象**：在 internet 命名空间正常启动 8080 端口 Web 服务后，guest 执行外网访问命令持续超时，防火墙外网网卡抓包未捕获任何数据包。
**原因分析**：宿主机全局开启 IP 转发不会作用于独立的网络命名空间，仅在宿主机开启转发无效，防火墙 fw 命名空间内未单独开启内核 IPv4 数据包转发功能，跨接口流量被内核直接丢弃；同时最初未确认 FORWARD 链状态规则优先级，回程流量存在被默认 DROP 策略拦截的风险。
**解决方法**：执行命令sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1，在 fw 命名空间单独开启 IP 转发；校验防火墙规则顺序，确保ESTABLISHED,RELATED状态放行规则位于 FORWARD 链第一条，保证内网请求的回程数据包可以正常转发，最终 SNAT 上网功能验证通过。
2. **iptables 配置日志规则后，使用 journalctl 无法检索到违规访问日志**
**故障现象**：配置带 LOG 前缀的拦截规则后，模拟 guest、office 违规访问内网，通过journalctl -k未抓取到预设前缀的审计日志。
**原因分析**：部分 Kali 系统内核日志默认输出至环形缓冲区 dmesg，未同步到 journald 服务日志库，iptables 的内核日志无法通过 journalctl 检索。
**解决方法**：更换日志查看方式，使用dmesg | grep 自定义日志前缀、dmesg -w实时监控内核日志，成功抓取到访客网段、办公网段的违规访问记录，完成安全审计验证。
3. **DNAT 端口映射配置完成后，外网无法通过防火墙公网 IP 访问 DMZ 区 Web 服务**
**故障现象**：PREROUTING 链配置 8080 端口 DNAT 转发规则后，internet 网段访问203.0.113.1:8080访问失败。
**原因分析**：仅配置目的地址转换规则，未在 FORWARD 链放行外网访问 DMZ 8080 端口的新建 TCP 流量，数据包完成 DNAT 转换后被默认 DROP 策略拦截。
**解决方法**：在 fw 防火墙中添加对应 FORWARD 放行规则，允许外网入站流量访问 DMZ 服务器 8080 端口，再次测试成功实现外网对内网业务的安全发布。
4. **WireGuard 远程 VPN 隧道启动握手失败，remote 客户端无法连接 fw 服务端**
**故障现象**：密钥、网段配置无误，但两端 wg 接口无法完成隧道握手。
**原因分析**：客户端 Endpoint 错误配置为 VPN 隧道内网地址或其他不可达地址，WireGuard 属于三层加密隧道协议，两端需要依托底层物理网段完成数据包传输，必须填写防火墙外网公网地址与监听端口；同时未加载 WireGuard 内核模块导致服务无法正常初始化。
**解决方法**：将 remote 端 Endpoint 修改为 `203.0.113.1:51820`（与老师拓扑图一致），执行 `modprobe wireguard` 加载内核模块，将配置文件放置在 `/etc/wireguard/` 系统路径下，通过 `wg-quick` 在对应命名空间启动隧道，最终 VPN 链路正常建立。

> 单主机模拟环境中，由于 remote 命名空间无法直接访问 `203.0.113.1`，`setup.sh` 实际使用辅助地址 `198.51.100.1:51820` 作为 Endpoint，并通过 `veth-vpn-fw/veth-vpn-host` 模拟底层可达性。

## 十、总结与思考

本次企业级网络安全架构搭建实验，依托 Linux 网络命名空间、veth 虚拟网卡完成企业多区域网络拓扑模拟，结合 iptables 防火墙、SNAT/DNAT 地址转换、WireGuard 加密 VPN、内核日志审计等技术，完整复现了企业边界安全防护体系。实验覆盖办公内网、访客网络、DMZ 业务区、互联网外网、远程 VPN 接入五大安全区域，通过精细化访问控制策略实现网络隔离、业务安全发布、远程安全办公、违规行为审计四大核心安全能力，让我对企业网络安全架构有了全方位、深层次的理解。
从架构设计层面来看，企业网络遵循**区域隔离、最小权限、边界防护、可审计追溯**四大核心设计原则。本次实验中，防火墙作为整个企业网络的安全边界，是所有区域流量的唯一出入口，通过 FORWARD 链访问控制策略实现横向隔离：办公区仅可访问 DMZ 业务的指定业务端口，禁止运维端口直接暴露；访客网络完全隔离，无法访问企业任何内网业务，仅允许访问互联网，避免访客终端存在恶意程序横向渗透内网的风险；外网仅能通过 DNAT 映射访问 DMZ 对外开放的 Web 服务，禁止主动发起对内网办公区、访客区的任何连接请求，从网络层阻断外部暴力扫描、渗透攻击的路径。最小权限原则是边界防护的核心，本次实验将 FORWARD 链默认策略设置为 DROP，仅手动放行业务必需的流量，最大限度缩小攻击面，避免因规则冗余带来的安全漏洞。
在网络地址转换技术应用上，SNAT 源地址伪装实现内网用户安全访问互联网，屏蔽内网私有网段拓扑，防止外网攻击者探测企业内网地址规划；DNAT 目的地址转换实现内网业务安全对外发布，仅暴露防火墙公网 IP，隐藏后端 DMZ 服务器真实内网地址，避免业务服务器直接暴露在公网遭受攻击，两种 NAT 技术共同构成企业内网与互联网之间的地址隔离屏障。同时本次实验通过 iptables 日志模块对所有违规拦截行为做带标签的内核日志记录，实现安全事件可追溯，一旦发生网络攻击、违规访问行为，管理员可以通过日志溯源攻击源、攻击行为，为应急响应、安全取证提供依据，这也是企业等保合规中安全审计的基本要求。
远程 VPN 接入技术则解决了企业移动办公、异地运维的安全需求，传统公网远程接入存在明文传输、地址伪造、身份冒用等风险，WireGuard 基于非对称密钥加密实现两端身份强认证，隧道内所有传输数据加密封装，同时结合防火墙精细化策略限制 VPN 客户端仅能访问办公网与 DMZ 授权业务，既满足远程办公的业务需求，又规避了远程接入带来的内网安全风险，是企业异地安全组网的主流实现方案。
实验过程中多次因 IP 转发、防火墙规则顺序、路由配置等基础问题出现网络连通故障，也让我意识到企业网络运维必须遵循分层排查思路：先保障二层链路、三层路由连通，再配置边界安全策略，每一条访问控制规则都需要结合业务场景严谨设计，规则的先后顺序、状态检测策略都会直接影响整体防护效果。同时安全防护不能仅依靠边界防火墙单一设备，企业完整的安全架构还需要搭配入侵检测系统、终端安全管控、日志集中平台、漏洞扫描等安全能力，形成边界、内网、终端、运维全维度的纵深防御体系。
本次实验将理论中的网络安全防护技术落地实操，让我深刻认识到企业网络安全架构的本质是在业务可用性与安全风险性之间寻找平衡，所有防护策略不能脱离实际业务场景，以最小权限为核心、以区域隔离为基础、以安全审计为兜底，才能构建稳定、可靠、合规的企业网络安全防护体系。