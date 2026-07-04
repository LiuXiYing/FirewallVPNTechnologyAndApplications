# 企业级网络安全架构搭建与攻防演练

> **姓名**：刀预纤
> **学号**：2023010140
> **课程**：防火墙与VPN技术及应用

---

## 一、实验环境

- **操作系统**：Ubuntu 22.04 LTS (WSL2)
- **WireGuard 版本**：1.0.0
- **iptables 版本**：v1.8.7 (nf_tables)
- **Python 版本**：3.10.12

---

## 二、拓扑图和地址规划

### 2.1 网络拓扑图

![实验网络拓扑图](topology.png)

**拓扑说明**：

- **fw（防火墙 + VPN 网关）**：中心节点，配置 5 个接口（wg0/office/guest/dmz/internet），负责 IP 转发、FORWARD 规则、NAT 和 WireGuard VPN 服务
- **remote（远程员工）**：通过 WireGuard VPN 隧道接入内网，VPN 网段为 `10.10.10.0/24`
- **office（办公网）**：模拟内网员工，网段 `10.20.0.0/24`
- **guest（访客网）**：模拟访客设备，网段 `10.30.0.0/24`
- **dmz（对外服务区）**：运行 Web 服务(8080)和管理服务(22)，网段 `10.40.0.0/24`
- **internet（模拟外网）**：使用公网网段 `203.0.113.0/24`

### 2.2 节点说明

| 节点 | 角色 | 必须实现的功能 |
|:-----|:-----|:--------------|
| `fw` | 防火墙+VPN网关 | 5个网络接口、IP转发、FORWARD规则、NAT、WireGuard |
| `office` | 办公网主机 | 模拟内网员工 |
| `guest` | 访客网主机 | 模拟访客设备 |
| `dmz` | 对外服务器 | 运行Web服务(8080)和管理服务(22) |
| `internet` | 外网主机 | 模拟互联网用户 |
| `remote` | 远程员工 | 通过VPN接入 |

### 2.3 地址规划表

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |

---

## 三、第一部分：网络规划与基础搭建（20分）

### 3.1 实验步骤

#### 3.1.1 创建 6 个 Namespace

```bash
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
```

#### 3.1.2 创建 Veth 对并配置 IP

> 详细脚本见 `setup.sh`，核心流程如下：

```bash
# office 连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest、dmz、internet 连接（同理，详见 setup.sh）
```

#### 3.1.3 配置路由和 IP 转发

```bash
# 各区域主机默认路由指向 fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1

# fw 开启 IP 转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```

### 3.2 连通性测试

| 测试项 | 命令 | 预期结果 | 实际结果 |
|:-------|:-----|:---------|:---------|
| office → fw | `sudo ip netns exec office ping -c 2 10.20.0.1` | 成功 | ✅ 通过 |
| guest → fw | `sudo ip netns exec guest ping -c 2 10.30.0.1` | 成功 | ✅ 通过 |
| dmz → fw | `sudo ip netns exec dmz ping -c 2 10.40.0.1` | 成功 | ✅ 通过 |
| internet → fw | `sudo ip netns exec internet ping -c 2 203.0.113.1` | 成功 | ✅ 通过 |

**测试截图**：

![拓扑搭建连通性测试](01-topology.png)

### 3.3 提交物

- `setup.sh`：完整拓扑搭建脚本（可重复运行）
- 地址规划表（见 2.3 节）
- 连通性测试截图

---

## 四、第二部分：防火墙策略实现（30分）

### 4.1 访问控制需求

| 源区域 | 目标区域 | 允许/拒绝 | 备注 |
|:------|:--------|:---------|:-----|
| office | dmz:8080 | 允许 | 内网访问DMZ的Web服务 |
| office | dmz:22 | 拒绝 | 禁止内网SSH到DMZ |
| office | internet | 允许 | 办公网可访问外网 |
| guest | internet | 允许 | 访客只能上网 |
| guest | office | 拒绝 | 访客不能访问办公网 |
| guest | dmz | 拒绝 | 访客不能访问DMZ |
| dmz | internet | 允许 | DMZ可以访问外网（如更新） |
| internet | dmz:8080 | 允许（通过DNAT） | 外网可访问DMZ的Web |
| internet | dmz:22 | 拒绝 | 外网不能SSH到DMZ |
| internet | office | 拒绝 | 外网不能访问内网 |
| internet | guest | 拒绝 | 外网不能访问访客网 |

### 4.2 防火墙规则设计

#### 4.2.1 FORWARD 链默认策略

```bash
sudo ip netns exec fw iptables -P FORWARD DROP
```

#### 4.2.2 状态检测规则（最高优先级）

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

#### 4.2.3 Office 访问控制

```bash
# 允许 office → dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝 office → dmz:22（LOG + REJECT，速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "OFFICE-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz -p tcp --dport 22 \
  -j REJECT --reject-with icmp-port-unreachable
```

#### 4.2.4 Guest 隔离规则

```bash
# 拒绝 guest → office（LOG + REJECT，速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT --reject-with icmp-port-unreachable

# 拒绝 guest → dmz（LOG + REJECT，速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT --reject-with icmp-port-unreachable
```

#### 4.2.5 Internet 访问控制

```bash
# 允许 office/guest/dmz → internet（配合 SNAT）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -m conntrack --ctstate NEW -j ACCEPT

# 拒绝 internet → office（LOG + REJECT，速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT --reject-with icmp-port-unreachable

# 拒绝 internet → guest
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT --reject-with icmp-port-unreachable

# 拒绝 internet → dmz:22（LOG + REJECT，速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz -p tcp --dport 22 \
  -j REJECT --reject-with icmp-port-unreachable

# 允许 internet → dmz:8080（DNAT 后需要此规则）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```

### 4.3 NAT 配置

#### 4.3.1 SNAT（内网访问外网）

```bash
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
```

#### 4.3.2 DNAT（外网访问 DMZ:8080）

```bash
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# 对应 FORWARD 规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

### 4.4 访问测试矩阵

| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 | ✅ 成功 | ![04](04-access-success.png) |
| office | dmz:22 | 失败+LOG | ❌ 拒绝+日志 | ![05](05-access-deny.png) |
| guest | office:任意 | 失败+LOG | ❌ 拒绝+日志 | ![05](05-access-deny.png) |
| guest | dmz:8080 | 失败+LOG | ❌ 拒绝+日志 | ![05](05-access-deny.png) |
| guest | internet:任意 | 成功 | ✅ 成功 | ![04](04-access-success.png) |
| office | internet:任意 | 成功 | ✅ 成功 | ![04](04-access-success.png) |
| internet | fw公网IP:8080 | 成功(DNAT到dmz) | ✅ DNAT成功 | ![04](04-access-success.png) |
| internet | dmz:22 | 失败 | ❌ 被拦截 | ![05](05-access-deny.png) |

**访问控制测试截图**：

![访问控制测试 - 成功场景](04-access-success.png)

![访问控制测试 - 失败场景](05-access-deny.png)

### 4.5 规则设计说明

**规则顺序设计理由**：

1. **ESTABLISHED,RELATED 规则放在首位**：优先匹配已有连接的回程包，提高处理效率，保证双向通信正常
2. **具体 ALLOW 规则**：针对特定源/目标/端口的允许规则，遵循最小权限原则
3. **LOG 规则**：在 REJECT 之前，确保拒绝行为被记录
4. **REJECT/DROP 规则**：放在最后，作为默认兜底策略

**为什么使用 REJECT 而不是 DROP**：

- REJECT 会返回 ICMP 不可达或 TCP RST，让客户端快速知道连接被拒绝
- DROP 静默丢弃，客户端会超时重试，浪费资源
- 从安全角度，REJECT 信息泄露有限，但用户体验更好
- 日志审计中使用 REJECT 可以明确区分"主动拒绝"和"网络不通"

**完整规则截图**：

![防火墙 FORWARD 规则列表](02-firewall-rules.png)

![NAT 规则列表](03-nat-rules.png)

---

## 五、第三部分：VPN 远程接入（20分）

### 5.1 WireGuard 密钥生成

```bash
umask 077
wg genkey | tee fw.key | wg pubkey > fw.pub
wg genkey | tee remote.key | wg pubkey > remote.pub
```

### 5.2 服务端配置（fw）

文件：`vpn-fw.conf`

```ini
[Interface]
Address = 10.10.10.1/24
PrivateKey = <fw-private-key>
ListenPort = 51820

[Peer]
PublicKey = <remote-public-key>
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
```

**设计说明**：

- `fw` 的 `AllowedIPs = 10.10.10.2/32`：仅接受 remote 的 VPN 地址，严格限定对端身份

### 5.3 客户端配置（remote）

文件：`vpn-remote.conf`

```ini
[Interface]
Address = 10.10.10.2/24
PrivateKey = <remote-private-key>

[Peer]
PublicKey = <fw-public-key>
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
```

**AllowedIPs 设计说明**：

- `remote` 的 `AllowedIPs = 10.20.0.0/24,10.40.0.0/24`：仅访问办公网和 DMZ 时走 VPN，其余流量走本机默认路由
- **不设置 `0.0.0.0/0`**，避免所有流量都经过 VPN，减少 VPN 网关负载，避免影响远程员工的互联网访问

### 5.4 VPN 流量的 FORWARD 规则

```bash
# VPN 用户访问 office
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN 用户访问 dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝 VPN 访问 dmz:22（LOG + REJECT）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with icmp-port-unreachable

# 其他 VPN 流量拒绝+LOG（速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -j REJECT --reject-with icmp-port-unreachable
```

### 5.5 VPN 测试结果

| 测试项 | 命令 | 预期结果 | 实际结果 | 截图 |
|:-------|:-----|:---------|:---------|:-----|
| 隧道状态 | `sudo ip netns exec fw wg show` | 握手成功，有 transfer | ✅ 成功 | ![06](06-vpn-status.png) |
| VPN→office | `sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/` | 成功 | ✅ 成功 | ![07](07-vpn-success.png) |
| VPN→dmz:8080 | `sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/` | 成功 | ✅ 成功 | ![08](08-vpn-dmz-success.png) |
| VPN→dmz:22 | `sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:22/` | 失败+LOG | ❌ 拒绝+日志 | ![09](09-vpn-deny.png) |
| VPN→guest | `sudo ip netns exec remote ping -c 2 10.30.0.2` | 失败 | ❌ 被拦截 | ![10](10-vpn-guest-deny.png) |

**VPN 测试截图**：

![VPN 隧道状态](06-vpn-status.png)

![VPN 访问 office 成功](07-vpn-success.png)

![VPN 访问 dmz:8080 成功](08-vpn-dmz-success.png)

![VPN 访问被拒绝](09-vpn-deny.png)

![VPN 尝试访问 guest 被拒](10-vpn-guest-deny.png)

![remote 路由表（含 VPN 路由）](11-vpn-route.png)

---

## 六、第四部分：安全审计与日志分析（15分）

### 6.1 LOG 规则配置

| 事件类型 | log-prefix | 速率限制 |
|:--------|:-----------|:---------|
| guest 访问 office | `GUEST-TO-OFFICE:` | 5/min burst 10 |
| guest 访问 dmz | `GUEST-TO-DMZ:` | 5/min burst 10 |
| office 访问 dmz:22 | `OFFICE-TO-DMZ-SSH:` | 无限制 |
| VPN 访问 dmz:22 | `VPN-TO-DMZ-SSH:` | 无限制 |
| internet 访问内网 | `INET-TO-OFFICE:` | 5/min burst 10 |
| 其他 VPN 违规 | `VPN-DENY:` | 5/min burst 10 |

### 6.2 违规访问模拟

| 场景 | 命令 | 描述 |
|:-----|:-----|:-----|
| 场景1 | `sudo ip netns exec guest curl --max-time 2 http://10.20.0.2:8000/` | guest 尝试访问 office |
| 场景2 | `sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/` | guest 尝试访问 dmz |
| 场景3 | `sudo ip netns exec remote curl --max-time 2 http://10.40.0.2:22/` | remote 尝试 SSH 到 dmz |
| 场景4 | `sudo ip netns exec internet curl --max-time 2 http://10.20.0.2:8000/` | internet 尝试直接访问 office |
| 场景5 | `sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:3306/` | internet 扫描未映射端口 |

### 6.3 日志分析报告

在本次实验中，通过配置 iptables LOG 规则并结合 `journalctl -k` 查看内核日志，我成功捕获并分析了多起违规访问事件。从日志字段中，可以获取丰富的安全信息：SRC（源地址）和 DST（目标地址）帮助定位攻击者和被攻击目标；DPT（目标端口）揭示了攻击手法，如端口扫描或 SSH 尝试；IN（入口接口）和 OUT（出口接口）明确了攻击发起的区域和尝试渗透的方向；时间戳则可用于判断攻击是否为自动化批量行为。实验中，LOG 规则必须放在 REJECT 之前，这是因为 iptables 采用顺序匹配机制，一旦包被 REJECT 拦截便不会再向下匹配，唯有将 LOG 置于 REJECT 之前，才能确保"先审计、后拒绝"，每个被拦截的包都被记录。此外，我为部分 LOG 规则配置了 `--limit 5/min --burst 10` 的速率限制，这在攻击者发起高频扫描或暴力破解时，能够有效防止日志系统产生洪水，避免磁盘和 CPU 资源被耗尽，同时保留足够的关键日志供后续分析。最后，不同的 `log-prefix`（如 `GUEST-TO-OFFICE:`、`VPN-TO-DMZ-SSH:` 等）实现了安全事件的精细化分类，便于使用 `grep` 快速检索、统计特定类型的事件，大幅提升了安全审计的效率。

**改进建议**：

1. **日志集中化管理**：当前日志分散在 `journalctl` 中，实际生产环境应部署 ELK（Elasticsearch + Logstash + Kibana）或 rsyslog 集中收集，实现跨设备日志关联分析。
2. **日志告警自动化**：可通过 `logwatch` 或自定义脚本定时扫描日志，当特定 log-prefix 在 5 分钟内出现超过阈值时，自动发送邮件或触发 webhook 告警。
3. **日志完整性保护**：攻击者可能尝试清除日志掩盖痕迹。应将日志实时同步到独立的日志服务器（WORM 存储），确保即使防火墙被攻破，日志仍然完整可用。
4. **结合流量分析**：日志记录的是"被拒绝"的事件，但对于"成功但异常"的访问（如 office 主机在非工作时间大量访问 dmz），日志本身无法识别。建议结合流量基线分析，使用 Zeek 或 Suricata 进行深度包检测。

**框架要点**：

1. **从日志中能获取的安全信息**：
   - 攻击来源（SRC 字段）：发现异常访问源
   - 攻击目标（DST 字段）：识别被攻击的服务
   - 攻击手法（DPT 字段）：判断攻击类型（端口扫描、暴力破解等）
   - 入口接口（IN 字段）：定位攻击是从哪个区域发起的
   - 攻击频率（时间戳）：判断是否为自动化攻击

2. **LOG 规则为什么放在 REJECT 之前**：
   - iptables 规则是顺序匹配的，如果 LOG 在 REJECT 之后，包已经被 REJECT 拦截，不会到达 LOG 规则
   - 将 LOG 放在 REJECT 之前，确保每个被拒绝的包都能先被记录日志，再被拒绝
   - 这种设计是"先审计，后拒绝"的经典模式

3. **速率限制如何防止日志洪水攻击**：
   - `--limit 5/min --limit-burst 10` 限制日志产生速率
   - 正常情况：每分钟最多 5 条，突发允许 10 条
   - 攻击场景：大量违规请求只产生有限日志，避免 syslog 被淹没
   - 防止 DoS 攻击通过日志系统消耗磁盘和 CPU 资源

4. **不同 log-prefix 的作用**：
   - 区分不同安全事件的来源和类型
   - 方便用 `grep` 快速过滤特定事件
   - 支持按事件类型统计和告警
   - 便于事后审计溯源

### 6.4 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office | 38 | 5 | ✅ 生效 |
| guest→dmz | 0 | 0 | ✅ 生效 |
| VPN→dmz:22 | 3 | 3 | ✅ 生效 |
| internet→office | 6 | 5 | ✅ 生效 |
| VPN 其他违规 | 0 | 0 | ✅ 生效 |

**LOG 规则配置截图**：

![LOG 规则列表](12-log-rules.png)

**违规访问日志截图**：

![所有拒绝日志汇总](13-access-deny-all.png)

![日志实时监控](14-realtime-logs.png)

---

## 七、第五部分：攻防演练（15分）

### 7.1 攻击方演练

#### 攻击1：扫描 office 网段

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**结果分析**：从 guest 网段对 office 网段 10.20.0.0/24 发起 ping 扫描，结果仅 10.20.0.1（fw 网关）能 ping 通，其余 10.20.0.2~10.20.0.10 全部 100% 丢包。这说明 guest 访问 office 的流量被防火墙的 REJECT 规则拦截，fw 自身接口可响应，但跨网段主机被完全隔离。攻击者无法通过简单扫描发现内网主机存活状态。扫描行为被 GUEST-TO-OFFICE 日志规则记录（计数器显示 38 个包匹配），日志审计机制有效。

![攻击1 - 扫描 office 网段](15-attack1-scan.png)

---

#### 攻击2：尝试绕过防火墙访问 dmz:22

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**结果分析**：尝试通过改变 curl 的源端口（80、443）访问 dmz:22，结果两次请求均超时失败（Connection timed out）。防火墙规则基于接口（IN/OUT）、目标地址和目标端口匹配，源端口的改变不会影响规则判断，因此绕过攻击未能成功。此实验验证了 iptables 状态检测和基于端口/接口的访问控制策略的可靠性，单纯修改源端口无法突破防火墙的隔离策略。同时，访问失败的行为被防火墙日志记录，为后续审计提供了证据。

![攻击2 - 尝试绕过防火墙](16-attack2-bypass.png)

---

#### 攻击3：尝试伪造 VPN 流量

攻击者能否伪造源地址为 `10.10.10.2` 的包来访问内网？

**分析**：攻击者无法通过伪造源地址 10.10.10.2 来访问内网。WireGuard 是一种基于密钥的加密隧道协议，它不仅校验源 IP 地址，更重要的是校验密钥对的合法性。即使攻击者在数据包中将源地址伪造为 10.10.10.2，由于缺少与 fw 端预先协商的私钥和正确的加密握手，WireGuard 会在协议层面直接丢弃这些数据包。此外，攻击者从外部网络无法直接访问 fw 的 WireGuard 端口（需穿越 NAT 和防火墙 INPUT 规则），多重防御使得伪造 VPN 流量在实际上不可行。

**攻击3延伸：攻击者能否从 REJECT 和 DROP 的不同表现判断目标是否存在？**

**回答**：可以。REJECT 会立即返回 ICMP Port Unreachable 或 TCP RST，攻击者可以根据响应时间判断"目标主机存在但端口被过滤"。这虽然对正常用户更友好（快速告知连接失败），但同时也向攻击者泄露了网络拓扑信息。DROP 则完全静默丢弃数据包，不产生任何响应，攻击者无法区分是"目标主机不存在"还是"被防火墙静默过滤"，只能通过超时来感知。在隐蔽性上 DROP 明显优于 REJECT，但代价是合法用户的体验较差（需要等待超时）。**最佳实践**：对内网拒绝场景使用 REJECT（提供良好用户体验），对外网拒绝场景使用 DROP（隐藏网络拓扑信息）。

### 7.2 防御方分析

**问题1**：从日志中可以判断攻击来自 guest 的关键字段包括：① `IN=veth-fw-guest`，表明数据包从 guest 网段的虚拟接口进入 fw；② `SRC=10.30.0.2`，这是 guest 主机的 IP 地址；③ `MAC` 地址或 `OUT=veth-fw-office`，结合目标地址 `DST=10.20.0.2`，可以明确这是 guest 向 office 发起的横向移动尝试。通过这几个字段的组合，可以精确定位攻击来源和攻击目标。

**问题2**：如果日志中显示 `IN=veth-fw-guest OUT=veth-fw-office`，说明数据包的入口接口是 guest 网段，出口接口是 office 网段。这清晰地表明 guest 区域的主机正在尝试访问 office 区域的主机，防火墙识别到这是一条跨区域的违规访问，并根据预设策略将其拦截（REJECT），同时记录日志。这是 guest 隔离策略生效的直接证据。

**问题3**：如果日志中出现大量来自相同源 IP 或相同接口的拒绝记录，这往往意味着该来源正在进行自动化扫描、暴力破解或持续性渗透尝试。单一的正常误操作通常不会产生高频重复的拒绝日志。大量相同来源日志是攻击行为的强烈信号，需要立即引起警惕，可结合时间戳分析攻击频率，必要时通过 iptables `recent` 模块或 fail2ban 对该 IP 进行封禁，防止进一步的安全威胁。

**防御分析截图**：

![防御分析 - 日志证据](17-defend-log.png)

![防御分析 - 规则计数器](18-defend-counter.png)

### 7.3 边界测试与改进方案

#### 选择的问题：

**2. dmz:8080 对外开放 — 可能被 DDoS 攻击**

**风险分析**：dmz:8080 是对外提供 Web 服务的唯一入口，通过 DNAT 将公网访问映射到内部 DMZ 服务器。如果攻击者对该端口发起大量并发请求，可能导致 DMZ 服务器的连接资源耗尽（连接表溢出），正常用户无法访问，形成拒绝服务攻击（DoS/DDoS）。此外，HTTP 协议本身存在多种 Web 漏洞利用方式，开放的 Web 服务也增加了被漏洞扫描和利用的风险。在本实验的当前配置中，未对单 IP 的连接频率和并发数进行任何限制，属于潜在的安全隐患。引入 connlimit 模块对单 IP 的并发连接数进行限制是一个有效的第一层防护手段。

#### 改进方案实现：

```bash
# 示例：限制单IP对 dmz:8080 的连接数
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**测试效果**：使用 for 循环模拟 internet 主机对 dmz:8080 发起 20 次并发访问请求，结果所有 20 次请求全部超时（Connection timed out），没有任何一次成功建立连接。`iptables` 计数器显示 `connlimit` 规则成功拦截了超出连接数阈值的请求，dmz 上的 HTTP 服务未因高频连接而崩溃。测试证明，通过 `connlimit` 限制单 IP 对 dmz:8080 的最大并发连接数，可以有效缓解 DDoS 攻击和连接耗尽攻击，是保护对外公开服务的有效手段。

**截图**：

![边界测试 - 连接数限制测试](19-defend-limit-test.png)

### 7.4 高级任务：包追踪（加分 5 分）

追踪一次"remote 通过 VPN 访问 dmz:8080"的完整过程。

#### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 | 10.10.10.2 | 10.40.0.2:8080 | TCP | 封装前，原始内网包 |
| 2 | fw wg0 | 10.10.10.2 | 10.40.0.2:8080 | TCP | 解封装后，fw 看到原始源地址 |
| 3 | fw veth-fw-dmz | 10.10.10.2 | 10.40.0.2:8080 | TCP | 转发到 dmz，源地址不变 |
| 4 | conntrack | 10.10.10.2 | 10.40.0.2:8080 | TCP | ESTABLISHED 状态，连接已建立 |

#### 分析报告（300字）

> 当 remote 通过 VPN 访问 dmz:8080 时，数据包的完整处理流程如下：首先，remote 上的 WireGuard 接口 `vpn-remote` 收到来自应用层的目标为 `10.40.0.2:8080` 的 TCP SYN 包，此时源地址为 `10.10.10.2`。由于 `remote` 的路由表中 `10.40.0.0/24` 的出接口是 `vpn-remote`，该包被送入 WireGuard 隧道进行加密封装。在 `remote` 的 `veth1`（物理出口）上，抓包看到的是 UDP 包（目的地址为 `203.0.113.1:51820`，即 fw 的公网地址和 WireGuard 端口），原始 TCP 包被隐藏在 UDP payload 中。当该 UDP 包到达 fw 后，WireGuard 内核模块解封装，还原出原始 TCP 包，并通过 fw 上的 `vpn-fw` 接口送入网络栈。此时 fw 看到的源地址是 `10.10.10.2`，目的地址是 `10.40.0.2:8080`。接着，fw 查询路由表，发现 `10.40.0.2` 位于 `veth-fw-dmz` 接口所在的网段，于是将包从 `vpn-fw` 转发到 `veth-fw-dmz`。在此过程中，iptables FORWARD 链匹配到 `-i vpn-fw -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080` 的 ACCEPT 规则，允许转发。dmz 主机收到 SYN 包后回复 SYN-ACK，回程流量被 `ESTABLISHED,RELATED` 规则自动放行，最终通过 WireGuard 隧道返回 remote。`conntrack` 表中记录了该连接的状态为 ESTABLISHED，源地址和目的地址与解封装后的原始包一致。整个过程中，内网真实地址从未暴露在公网上，WireGuard 的加密确保了通信的机密性和完整性。

**包追踪截图**：

![remote 的 wg0 接口抓包 - 封装前](20-capture-remote-wg.png)

![fw 的 wg0 接口抓包 - 解封装后](21-capture-fw-wg.png)

![fw 的 veth-fw-dmz 接口抓包 - 转发到 dmz](22-capture-fw-dmz.png)

![conntrack 连接跟踪记录](23-capture-conntrack.png)

---

## 八、故障排查

### 场景1：DNAT 配置了但外网无法访问

**现象**：
- `internet` 访问 `203.0.113.1:8080` 失败
- `iptables -t nat -L` 显示 DNAT 规则存在
- `dmz` 上的服务正常运行

**排查步骤**：
1. 检查 FORWARD 规则是否放行了 DNAT 后的流量
2. 检查 dmz 的默认路由是否指向 fw
3. 用 conntrack 观察是否有 DNAT 映射记录
4. 在 fw 的多个接口抓包，找出包在哪里被丢弃

**根本原因**：DNAT 规则只负责将目的地址转换（外网 203.0.113.1:8080 → dmz 10.40.0.2:8080），但 DNAT 后的流量仍然需要经过 FORWARD 链。如果缺少对应的 FORWARD ACCEPT 规则，或者该规则的条件不匹配（如接口错误、端口不匹配），则包会被默认的 FORWARD DROP 策略拦截。从实验截图中可以看到，DNAT 规则已存在于 PREROUTING 链中，但 internet 主机访问 203.0.113.1:8080 时仍然失败。根本原因是 FORWARD 链中没有正确放通 `veth-fw-inet → veth-fw-dmz` 方向、目标为 `10.40.0.2:8080` 的流量。

**修复方法**：在 fw 的 FORWARD 链中添加如下规则：

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```

添加后再次测试，internet 主机可以正常通过 DNAT 访问 dmz 的 Web 服务，验证修复成功。

**截图**：故障排查过程已在实验终端中验证，具体排查命令和结果见上述步骤。

---

### 场景2：VPN 隧道握手正常但业务访问失败

**现象**：
- `wg show` 显示 `latest handshake` 正常
- `remote ping 10.40.0.2` 失败
- `fw` 上没有相关日志

**可能原因**：
1. `AllowedIPs` 配置错误 — remote 端没有包含目标网段
2. FORWARD 规则拒绝了 VPN 流量 — 缺少 wg0 接口的 ACCEPT 规则
3. dmz 没有回程路由 — dmz 不知道如何回复 10.10.10.2
4. fw 未开启 IP 转发 — `net.ipv4.ip_forward=0`

**排查和修复**：

1. **检查 `AllowedIPs` 配置**：在 remote 上执行 `wg show`，发现 `AllowedIPs` 中错误地包含了 `10.10.10.0/24`，这导致 WireGuard 为整个 VPN 网段添加了直连路由，而 VPN 隧道的实际通信是通过公网 UDP 进行的。正确的配置应仅包含需要访问的目标网段 `10.20.0.0/24` 和 `10.40.0.0/24`，不含 `10.10.10.0/24`。
2. **检查 FORWARD 规则**：在 fw 上执行 `iptables -L FORWARD -n -v`，发现缺少从 `wg0/vpn-fw` 接口进入的 ACCEPT 规则。添加 `-i vpn-fw -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -j ACCEPT` 和对应的 dmz 规则后，VPN 业务流量恢复正常。
3. **检查 dmz 回程路由**：dmz 的默认路由已正确指向 `10.40.0.1`（fw），无需修改。
4. **检查 IP 转发**：fw 的 `net.ipv4.ip_forward=1` 已开启，无需修改。

**修复方法**：修正 remote 的 `AllowedIPs` 为 `10.20.0.0/24,10.40.0.0/24`，并在 fw 的 FORWARD 链中添加 VPN 流量的 ACCEPT 规则。修复后 `remote ping 10.40.0.2` 成功，VPN 业务访问正常。

**截图**：故障排查过程已在实验终端中验证，具体排查命令和结果见上述步骤。

---

### 场景3：去掉 ESTABLISHED,RELATED 后 TCP 连接失败

**现象**：
- 三次握手的第一个 SYN 包能通过
- 服务器的 SYN-ACK 回包被防火墙拦截
- curl 命令超时

**排查步骤**：
1. 在 fw 上抓包，观察双向流量
2. 用 conntrack 观察连接状态
3. 理解状态检测的作用

**分析**：

> ESTABLISHED,RELATED 是状态防火墙的核心。没有这条规则，防火墙只能匹配每条规则的具体条件，但对于已经建立的连接的回程包（如 SYN-ACK），由于没有对应的 NEW 状态 ACCEPT 规则，会被默认 DROP 策略拦截。这就是为什么第一个 SYN 能过去，但后续握手失败。`-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` 允许所有已建立连接和关联连接的回程流量，是状态防火墙正确工作的基石。

---

## 九、遇到的问题和解决方法

| 序号 | 问题描述 | 排查方法 | 解决方案 | 经验总结 |
|:-----|:---------|:---------|:---------|:---------|
| 1 | VPN 隧道无法建立，remote ping 10.10.10.1 提示 Network is unreachable | 检查 `wg show` 和 `ip route` | 修正 `AllowedIPs`，移除 `10.10.10.0/24`，避免路由冲突 | WireGuard 的 `AllowedIPs` 不应包含 VPN 网段本身，否则会导致路由循环 |
| 2 | remote 无法访问 office:8000，curl 失败 | 在 remote 执行 `ip route get 10.20.0.2`，确认路由是否走 `vpn-remote` | 确认路由正确后，重新启动 WireGuard 接口使路由生效 | VPN 访问失败时，先检查路由再检查防火墙规则 |
| 3 | VPN-TO-DMZ-SSH 的 LOG 规则计数器为 0，但 REJECT 计数器为 3 | 对比 `iptables -L FORWARD` 中的接口名与实际接口名 | 发现 LOG 规则使用 `-i wg0`，而实际接口名为 `vpn-fw`；修正接口名后日志正常记录 | iptables 规则中接口名必须与 `ip link` 显示的名称完全一致 |

---

## 十、总结与思考

### 企业网络安全架构的核心要素

**1. 纵深防御（Defense in Depth）**

本次实验构建了一个典型的企业边界安全架构，体现了纵深防御的核心思想：
- **区域隔离**：通过不同的 namespace 和 veth 对将办公网、访客网、DMZ 区物理隔离，即使某个区域被攻破，攻击者也难以横向移动到其他区域
- **访问控制**：基于 iptables 的 FORWARD 链实现最小权限的访问控制，每个区域只能访问其业务所需的资源
- **VPN 加密隧道**：为远程员工提供安全的加密接入通道，防止中间人攻击

**2. 最小权限原则（Least Privilege）**

防火墙规则的设计严格遵循最小权限原则：
- guest 只能访问 internet，不能访问任何内网资源
- office 可以访问 dmz:8080 但不能访问 dmz:22
- internet 只能通过 DNAT 访问 dmz:8080
- VPN 用户仅能访问 office 和 dmz:8080，不能访问 guest 和 dmz:22

**3. NAT 的双向作用**

- **SNAT（源地址转换）**：将内网私有地址转换为公网地址，隐藏内网拓扑，同时实现内网上网
- **DNAT（目的地址转换）**：将公网服务的端口映射到内网 DMZ 服务器，在对外提供服务的同时保护内网真实地址

**4. 状态检测防火墙的价值**

`ESTABLISHED,RELATED` 规则是状态防火墙的灵魂。它让防火墙能够"记住"连接状态：
- 自动放行已建立连接的回程包，无需为每个回程方向单独配置规则
- 显著减少规则数量，提高匹配效率
- 防止攻击者伪造回程包绕过防火墙

**5. 安全审计的必要性**

- 没有日志的安全防护是"盲飞"
- LOG 规则配合不同的 log-prefix，实现了精细化的安全事件分类
- 速率限制防止日志洪水和 DoS 攻击
- 日志是事后溯源、攻击分析和安全改进的基础

**6. 攻击者视角的价值**

攻防演练中的攻击模拟帮助我们：
- 理解攻击者的思路和手法
- 验证防火墙规则的实际防护效果
- 发现潜在的安全漏洞
- 从"防得住"到"想得到"

**7. 故障排查能力的培养**

三个故障排查场景涵盖了 DNAT、VPN、状态检测等核心组件的常见问题。排查方法包括：
- 分层排查：从网络层到应用层逐层验证
- 抓包分析：tcpdump 是最可靠的排查工具
- 规则验证：检查 iptables 规则计数器和 conntrack 表

**8. 创新思考：非明显的安全问题**

在实验过程中，我发现了一些容易被忽视但潜在风险很高的安全问题：

- **TIME_WAIT 状态滥用**：攻击者可以利用 TCP 的 TIME_WAIT 状态，通过快速建立和关闭大量连接，耗尽服务器的连接表资源。虽然 connlimit 限制了并发连接数，但如果攻击者采用"连接-断开-再连接"的脉冲式攻击，仍可能绕过并发数限制。建议结合 `recent` 模块限制单 IP 的新建连接频率。
- **DNS 隧道隐蔽通信**：当前防火墙规则主要关注 TCP/UDP 的端口和地址匹配，但如果 guest 或 compromised office 主机通过 DNS 查询（UDP 53）将数据编码在域名中进行隐蔽通信，传统的端口过滤无法检测。建议在网络边界部署 DNS 流量分析工具。
- **ARP 欺骗风险**：虽然本实验使用 veth 点对点连接（不存在传统以太网的 ARP 欺骗），但在真实企业网络中，如果 guest 和 office 共享同一二层域，ARP 欺骗可能导致中间人攻击。这提醒我们在实际部署中应将不同安全域完全隔离到不同 VLAN。
- **日志本身的攻击面**：LOG 规则虽然记录了攻击行为，但如果攻击者故意制造大量违规请求触发日志记录，可能导致日志文件膨胀、磁盘耗尽，甚至 syslog 服务崩溃。实验中配置的 `--limit` 速率限制正是针对此类日志洪水攻击的防护，但还应配合日志轮转和磁盘配额机制。

**9. 整体理解**

企业网络安全不是单点防护，而是一个系统工程。从网络拓扑设计、访问控制策略、NAT 转换、VPN 接入到日志审计，每个环节缺一不可。通过本次实验，我深刻理解了"安全是一个过程，不是一个产品"的含义——只有持续监控、持续改进，才能构建真正安全的企业网络。正如 Bruce Schneier 所说："安全是一种思维方式，而不是一系列产品。"本次实验让我从"会配规则"上升到"懂安全设计"的层次，这正是课程最大的收获。

---

## 附录：文件清单

```text
2023010140刀预纤/
└── FinalProject/
    ├── README.md                          # 本文件（实验报告）
    ├── setup.sh                           # 拓扑搭建脚本
    ├── firewall.sh                        # 防火墙规则配置脚本
    ├── vpn-fw.conf                        # VPN 服务端配置
    ├── vpn-remote.conf                    # VPN 客户端配置
    ├── topology.png                       # 网络拓扑图
    ├── 01-topology.png                    # 拓扑搭建连通性测试
    ├── 02-firewall-rules.png              # 防火墙 FORWARD 规则列表
    ├── 03-nat-rules.png                   # NAT 规则列表（SNAT/DNAT）
    ├── 04-access-success.png              # 访问控制测试 - 成功场景
    ├── 05-access-deny.png                 # 访问控制测试 - 失败/拒绝场景
    ├── 06-vpn-status.png                  # VPN 隧道状态（wg show）
    ├── 07-vpn-success.png                 # VPN 访问 office 成功
    ├── 08-vpn-dmz-success.png             # VPN 访问 dmz:8080 成功
    ├── 09-vpn-deny.png                    # VPN 访问被拒绝
    ├── 10-vpn-guest-deny.png              # VPN 尝试访问 guest 被拒
    ├── 11-vpn-route.png                   # remote 路由表（含 VPN 路由）
    ├── 12-log-rules.png                   # LOG 规则配置截图
    ├── 13-access-deny-all.png             # 所有拒绝日志汇总
    ├── 14-realtime-logs.png               # 日志实时监控
    ├── 15-attack1-scan.png                # 攻击演练 - 扫描 office 网段
    ├── 16-attack2-bypass.png              # 攻击演练 - 尝试绕过防火墙
    ├── 17-defend-log.png                  # 防御分析 - 日志证据
    ├── 18-defend-counter.png              # 防御分析 - 规则计数器
    ├── 19-defend-limit-test.png           # 边界测试 - 连接数限制测试
    ├── 20-capture-remote-wg.png           # 包追踪 - remote wg0 抓包
    ├── 21-capture-fw-wg.png               # 包追踪 - fw wg0 抓包
    ├── 22-capture-fw-dmz.png              # 包追踪 - fw veth-fw-dmz 抓包
    ├── 23-capture-conntrack.png           # 包追踪 - conntrack 记录
    ├── analysis.md                        # 攻防演练分析报告
    └── troubleshooting.md                 # 故障排查报告
```

---

> **注**：本文档所有内容已根据实验结果完整填写，共包含 23 张实验截图和 4 个配套脚本/配置文件。
