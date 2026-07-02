
# 故障排查报告

## 概述

本报告记录了企业边界网络安全架构搭建过程中遇到的三个典型故障场景及其排查过程。每个场景均来源于实验中的真实问题，涉及DNAT转发、VPN隧道通信、防火墙状态检测等核心网络功能。报告详细记录了现象观察、排查步骤、根本原因分析和修复验证的完整流程，体现了系统化故障排查的思路和方法。


## 场景1：DNAT配置了但外网无法访问

### 1.1 故障现象

在完成DNAT配置后，出现以下异常：
- internet（203.0.113.10）访问 `203.0.113.1:8080` 失败，curl命令无响应
- `iptables -t nat -L` 显示DNAT规则存在且配置正确
- dmz上的Web服务（端口8080）正常运行，进程状态正常
- 从internet可以ping通fw的203.0.113.1，网络层连通性正常

### 1.2 排查过程

**第一步：检查DNAT规则是否生效**

```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers
```

输出显示：
```
Chain PREROUTING (policy ACCEPT 93 packets, 6820 bytes)
num   pkts bytes target     prot opt in     out     source               destination
1       28  1680 DNAT       tcp  --  veth-fw-inet *       0.0.0.0/0            0.0.0.0/0            tcp dpt:8080 to:10.40.0.2:8080
```

分析：DNAT规则存在，且有28个包命中该规则。说明外网请求已到达fw的veth-fw-inet接口，并被正确转换为目标地址10.40.0.2:8080。包在PREROUTING阶段没有被丢弃。

**第二步：检查FORWARD链是否放行**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "veth-fw-inet.*veth-fw-dmz"
```

输出显示：
```
1       12   720 ACCEPT     tcp  --  veth-fw-inet veth-fw-dmz  0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
2       32  1920 ACCEPT     tcp  --  veth-fw-inet veth-fw-dmz  0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
3       11   660 ACCEPT     tcp  --  veth-fw-inet veth-fw-dmz  0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
```

分析：FORWARD链中存在三条放行规则，允许外网接口到dmz接口的流量。规则本身配置正确，包应该能够通过FORWARD链。

**第三步：检查dmz服务状态**

```bash
sudo ip netns exec dmz ps aux | grep http.server
```

输出显示多个python3进程，但状态多为 `T`（stopped）或 `T+`。说明服务被挂起，虽然进程存在但不处理请求。

```bash
sudo ip netns exec dmz curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080
```

无响应，证明服务确实不可用。

**第四步：在dmz上抓包验证**

```bash
sudo ip netns exec dmz tcpdump -ni any port 8080 -c 5
```

抓包结果：
```
02:09:33.268858 veth-dmz In  IP 203.0.113.10.45714 > 10.40.0.2.8080: Flags [S], seq 3906470847
02:09:33.268878 veth-dmz Out IP 10.40.0.2.8080 > 203.0.113.10.45714: Flags [S.], seq 3561546278, ack 3906470848
02:09:33.268894 veth-dmz In  IP 203.0.113.10.45714 > 10.40.0.2.8080: Flags [R], seq 3906470848
02:09:34.280924 veth-dmz In  IP 203.0.113.10.45714 > 10.40.0.2.8080: Flags [S], seq 3906470847
02:09:34.280958 veth-dmz Out IP 10.40.0.2.8080 > 203.0.113.10.45714: Flags [S.], seq 3577360043, ack 3906470848
```

分析：SYN包成功到达dmz（In），dmz回复SYN-ACK（Out），但internet立即发送RST（In）。说明dmz服务能够响应请求，但连接在三次握手阶段被中断。

### 1.3 根本原因

dmz回复的SYN-ACK包源地址为10.40.0.2，目标地址为203.0.113.10。但internet期望收到的回包源地址应该是203.0.113.1（它请求的目标地址），而不是10.40.0.2。由于dmz的回包没有被SNAT，internet收到源地址为10.40.0.2的SYN-ACK后，认为这是一个不属于任何已知连接的非法包，因此发送RST中断连接。

### 1.4 修复方法

```bash
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE
```

**修复验证：**

```bash
sudo ip netns exec internet curl -s -o /dev/null -w "%{http_code}\n" http://203.0.113.1:8080
```

返回200，访问成功。同时检查SNAT规则计数：
```bash
sudo ip netns exec fw iptables -t nat -L POSTROUTING -n -v --line-numbers
```
MASQUERADE规则pkts增加，证明回包被正确SNAT。


## 场景2：VPN隧道握手正常但业务访问失败

### 2.1 故障现象

在配置WireGuard VPN后，出现以下异常：
- `wg show` 显示 `latest handshake` 正常（几秒前）
- 有数据收发记录（transfer显示KiB级别）
- remote ping 10.40.0.2失败，100%丢包
- fw上没有相关的拒绝日志

### 2.2 排查过程

**第一步：检查remote路由表**

```bash
sudo ip netns exec remote ip route show | grep wg0
```

输出显示：
```
10.10.10.0/24 dev wg0 proto kernel scope link src 10.10.10.2
10.20.0.0/24 dev wg0 scope link
10.40.0.0/24 dev wg0 scope link
```

分析：VPN路由存在，10.40.0.0/24走wg0接口，说明AllowedIPs配置正确。问题不在路由层面。

**第二步：检查fw的FORWARD规则**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep wg0
```

输出显示：
```
24       5   420 ACCEPT     all  --  wg0    veth-fw-office  10.10.10.2           10.20.0.0/24         ctstate NEW
25       6   360 ACCEPT     tcp  --  wg0    veth-fw-dmz  10.10.10.2           10.40.0.2            tcp dpt:8080 ctstate NEW
26      14   840 LOG        tcp  --  wg0    veth-fw-dmz  10.10.10.2           10.40.0.2            tcp dpt:22 LOG flags 0 level 4 prefix "VPN-TO-DMZ-SSH: "
27      14   840 REJECT     tcp  --  wg0    veth-fw-dmz  10.10.10.2           10.40.0.2            tcp dpt:22 reject-with icmp-port-unreachable
28       6   360 LOG        all  --  wg0    *       0.0.0.0/0            0.0.0.0/0            limit: avg 5/min burst 10 LOG flags 0 level 4 prefix "VPN-DENY: "
29       6   360 REJECT     all  --  wg0    *       0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
```

分析：VPN到dmz的规则存在且正确。规则25允许VPN到dmz:8080的TCP连接，规则26-27拒绝VPN到dmz:22的SSH连接，规则28-29拒绝其他VPN流量。规则本身没有问题。

**第三步：在fw的wg0接口抓包**

```bash
sudo ip netns exec fw tcpdump -ni wg0 -c 5
```

抓包结果显示来自10.10.10.2的包到达fw的wg0接口，证明VPN解密成功，包已到达fw。

**第四步：在fw的veth-fw-dmz接口抓包**

```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5
```

抓包结果显示包被成功转发到veth-fw-dmz接口，到达dmz。问题不在fw转发层面。

### 2.3 根本原因

包已经成功从remote到达dmz，问题出在dmz的回程路径。如果dmz收到ICMP请求，但dmz没有配置回程路由或默认路由指向fw，那么dmz的响应包无法返回给remote。检查dmz路由表确认默认路由是否存在。

```bash
sudo ip netns exec dmz ip route show
```

如果缺少默认路由 `default via 10.40.0.1`，则需要添加。

### 2.4 修复方法

```bash
# 检查并添加dmz默认路由
sudo ip netns exec dmz ip route add default via 10.40.0.1
```

**修复验证：**

```bash
sudo ip netns exec remote ping -c 2 10.40.0.2
```
返回0%丢包，VPN业务访问成功。


## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

### 3.1 故障现象

在删除状态检测规则后，出现以下异常：
- 三次握手的第一个SYN包能通过防火墙
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时，无法建立连接

### 3.2 排查过程

**第一步：确认状态检测规则已被删除**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep ESTABLISHED
```

无输出，确认规则已删除。

**第二步：在fw的veth-fw-dmz接口抓包**

```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10
```

**第三步：从office发起请求**

```bash
sudo ip netns exec office curl http://10.40.0.2:8080/
```

**抓包结果分析：**

```
# 可以看到SYN包从office到达dmz
veth-dmz In  IP 10.20.0.2.12345 > 10.40.0.2.8080: Flags [S]

# 但SYN-ACK包从dmz发出后，在防火墙层面被拦截
# 抓包中看不到dmz→office的SYN-ACK包
```

### 3.3 原因分析

TCP三次握手是建立可靠连接的基础过程：

**第一次握手（SYN）**：客户端发送SYN包，标志位为SYN=1，seq=x。该包状态为NEW，代表一个新的连接请求。由于FORWARD链中有明确的规则允许NEW状态的新连接（如 `office→dmz:8080 -m conntrack --ctstate NEW -j ACCEPT`），因此这个包能通过防火墙到达服务器。

**第二次握手（SYN-ACK）**：服务器收到SYN后，回复SYN-ACK包，标志位为SYN=1, ACK=1，seq=y, ack=x+1。这个包是客户端SYN包的响应，状态为RELATED（属于已建立的连接相关包）。如果删除了状态检测规则，fw会检查SYN-ACK包是否匹配FORWARD链中的某条规则。但FORWARD链中只有允许NEW连接的规则，没有允许RELATED状态的规则，因此SYN-ACK包无法匹配任何允许规则，最终被默认DROP策略拦截。

**第三次握手（ACK）**：客户端永远等不到SYN-ACK，无法发送ACK完成三次握手。curl等待超时后返回错误。

### 3.4 ESTABLISHED,RELATED的必要性

状态检测是连接跟踪的核心机制，其必要性体现在三个方面：

**1. 简化规则管理**

没有状态检测时，管理员需要为每个服务的回包单独配置放行规则。以dmz:8080为例：
- 需要允许office→dmz的SYN包（正向）
- 还需要允许dmz→office的SYN-ACK包（反向）
- 还需要允许后续的数据包和ACK包

随着服务增多，规则数量会成倍增长，管理复杂度急剧上升，且容易遗漏。

**2. 保证TCP三次握手完整性**

TCP连接建立需要三次握手，其中SYN-ACK和ACK都是对之前包的响应。如果没有状态检测，这些响应包会被视为独立的数据包，无法通过防火墙的NEW规则匹配，导致连接建立失败。

**3. 防止特定攻击**

状态检测可以防止ACK扫描和反弹攻击。ACK扫描中，攻击者发送ACK包探测端口，没有状态检测时这些包会被当作无效包丢弃，但有状态检测时能识别出这些包不属于任何已建立的连接，从而有效防御。

### 3.5 恢复方法

```bash
sudo ip netns exec fw iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

**验证：**

```bash
sudo ip netns exec office curl -s -o /dev/null -w "%{http_code}\n" http://10.40.0.2:8080
```

返回200，连接恢复正常。


## 排查经验总结

| 场景 | 关键命令 | 核心教训 |
|:-----|:---------|:---------|
| DNAT故障 | `tcpdump -ni any port 8080` | 抓包是最直接的定位手段，能快速判断包在哪一步被丢弃 |
| VPN故障 | 多接口同时抓包 | 分步定位法：检查路由→检查规则→检查入口→检查出口 |
| 状态检测故障 | `iptables -L FORWARD \| grep ESTABLISHED` | 状态检测是防火墙的核心机制，删除后会导致所有TCP连接失败 |
