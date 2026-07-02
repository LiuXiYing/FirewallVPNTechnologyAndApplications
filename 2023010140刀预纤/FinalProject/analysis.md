# 攻防演练分析报告

## 攻击方演练

### 攻击1：扫描 office 网段

**攻击方法**：从 guest 命名空间对 office 网段（10.20.0.0/24）发起 ping 扫描：
```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**结果**：仅 10.20.0.1（fw 的 office 侧网关地址）能 ping 通，10.20.0.2~10.20.0.10 全部 100% 丢包。

**失败原因分析**：防火墙的 FORWARD 链中配置了 `GUEST-TO-OFFICE` 拒绝规则，该规则匹配所有从 veth-fw-guest 接口进入、发往 veth-fw-office 接口的流量。guest 发起的任何 ICMP、TCP 包都会被该 REJECT 规则拦截并返回 icmp-port-unreachable。10.20.0.1 能 ping 通是因为 fw 本机（ping 目标在 fw 内部），不走 FORWARD 链，因此不受限制。攻击者无法通过 ping 扫描发现内网存活主机。

**iptables 规则计数器证据**：GUEST-TO-OFFICE LOG 规则计数器显示 38 个包（3048 字节）被记录，证实扫描行为触发了日志记录机制。

![攻击1 - 扫描 office 网段](15-attack1-scan.png)

---

### 攻击2：尝试绕过防火墙访问 dmz:22

**攻击方法**：改变 curl 的源端口从默认随机端口到 80 和 443：
```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**结果**：两次请求均超时失败（Connection timed out）。

**失败原因分析**：防火墙的 FORWARD 规则基于以下条件判断：①入口接口（veth-fw-guest）；②出口接口（veth-fw-dmz）；③目标端口（22）。源端口的改变不会影响这些匹配条件。无论是源端口 80、443 还是随机端口，只要满足"从 guest 来、到 dmz 去、目标端口 22"的条件，都会被 GUEST-TO-DMZ 规则拦截。

**结论**：单纯改变源端口无法绕过基于目标端口的防火墙策略。

![攻击2 - 尝试绕过防火墙](16-attack2-bypass.png)

---

### 攻击3：尝试伪造 VPN 流量

**分析**：攻击者无法通过伪造源地址 10.10.10.2 来访问内网。WireGuard 协议的安全性建立在以下几个层面：

1. **密钥认证**：WireGuard 使用 Noise 协议框架进行密钥交换，每个 peer 必须拥有对应的私钥才能完成握手。攻击者即使伪造源 IP 地址，也因缺少正确的私钥而无法完成 WireGuard 握手。
2. **加密隧道**：所有 VPN 流量在物理链路上以 UDP 方式传输，payload 已经被加密。即使攻击者截获 UDP 包，也无法解密或伪造有效的 WireGuard 数据包。
3. **网络隔离**：remote 位于独立的 namespace 中，攻击者从外部网络无法直接访问 fw 的 WireGuard 监听端口（需要先穿越 NAT 和防火墙 INPUT 规则）。
4. **AllowedIPs 限制**：fw 端配置 `AllowedIPs = 10.10.10.2/32`，仅接受该地址的流量，其他源地址的包会被直接丢弃。

**结论**：伪造 VPN 流量的攻击在 WireGuard 的密码学保护下完全不可行。

---

### 回答：攻击者能否从 REJECT 和 DROP 的不同表现判断目标是否存在？

REJECT 会立即向攻击者返回 ICMP Port Unreachable 或 TCP RST 包，攻击者可以根据响应时间和包类型判断"目标主机存在但端口被过滤"这一信息。这虽然对正常用户更友好（快速告知连接失败），但同时也向攻击者泄露了网络拓扑信息。

DROP 则完全静默丢弃数据包，不产生任何响应。攻击者无法区分是"目标主机不存在"还是"被防火墙静默过滤"，只能通过超时来感知。在隐蔽性上 DROP 明显优于 REJECT，但代价是合法用户的体验较差（需要等待超时）。

**最佳实践**：对内网拒绝场景使用 REJECT（提供良好用户体验），对外网拒绝场景使用 DROP（隐藏网络拓扑信息）。

---

## 防御方分析

### 问题1：从日志的哪些字段可以判断这是来自 guest 的攻击？

以下日志字段组合可以精准判断攻击来源是 guest：

1. **IN=veth-fw-guest**：入口接口标识，明确数据包从 guest 网段的 veth 接口进入防火墙。
2. **SRC=10.30.0.2**：源 IP 地址，guest 主机在 10.30.0.0/24 网段，10.30.0.2 正是 guest 主机的地址。
3. **OUT=veth-fw-office**：出口接口，显示攻击目标方向。
4. **DST=10.20.0.2**：目标地址，office 段的主机。
5. **PROTO=TCP DPT=8000**：协议和目标端口，揭示了攻击手法。

通过这五个字段的组合分析，可以完整还原出："guest 网段的主机 10.30.0.2 正在尝试通过 HTTP 协议访问 office 网段主机 10.20.0.2 的 8000 端口"这一完整的攻击画像。

---

### 问题2：如果日志中 IN=veth-fw-guest OUT=veth-fw-office，说明了什么？

这组字段组合说明：

1. **访问方向**：数据包从 guest 区域的接口（veth-fw-guest）进入防火墙，目标出口是 office 区域的接口（veth-fw-office），形成了一条 guest→office 的跨区域访问路径。
2. **违规行为**：根据防火墙策略，guest 区域被明确禁止访问 office 区域。这条跨区域访问是明显的安全策略违反。
3. **防御响应**：防火墙已识别该违规访问并执行了拦截动作（REJECT），同时触发了日志记录。
4. **安全意义**：这条日志是 guest 隔离策略生效的直接证据，也是安全审计中需要重点关注的事件类型。如果此类日志频繁出现，可能表明 guest 区域已被恶意控制或内网存在异常行为。

---

### 问题3：为什么看到大量相同来源的日志应该引起警惕？

大量来自相同源 IP 或相同接口的拒绝日志频繁出现时，应当引起高度警惕：

1. **自动化攻击特征**：单个用户的手动误操作通常只会产生少量日志，大量重复的拒绝记录表明可能是自动化扫描工具或攻击脚本在工作，攻击者可能在尝试发现内网存活主机或开放端口。
2. **持续性渗透尝试**：如果攻击者持续尝试不同目标或不同端口，说明其可能在执行横向移动（从 guest 渗透到 office 或 dmz），这是 APT 攻击的典型特征。
3. **资源消耗风险**：高频请求不仅可能通过日志系统消耗分析资源，如果防火墙使用 REJECT 而非 DROP，ICMP 不可达回复也会消耗网络带宽。
4. **暴力破解可能**：如果是针对特定服务的重复请求（如 dmz:22），可能是 SSH 暴力破解尝试。

**应对措施**：通过 iptables recent 模块或 fail2ban 对异常 IP 进行临时封禁，配合速率限制防止日志洪水，同时通知安全团队进行深度排查。

**防御分析截图**：

![防御分析 - 日志证据](17-defend-log.png)

![防御分析 - 规则计数器](18-defend-counter.png)

---

## 边界测试与改进方案

### 选择的问题：dmz:8080 对外开放 — DDoS/连接耗尽风险

### 风险分析

dmz:8080 是对外提供 Web 服务的主要入口，通过 DNAT 将公网 IP（203.0.113.1:8080）的访问映射到内部 DMZ 服务器（10.40.0.2:8080）。该服务直接暴露在互联网上，面临以下安全威胁：

1. **DDoS 攻击**：攻击者可发起大量 SYN 请求，耗尽服务器的 TCP 连接表资源，导致正常用户无法访问。
2. **Slowloris 攻击**：建立连接后缓慢发送 HTTP 请求，长期占用连接资源。
3. **暴力扫描**：攻击者可能通过 Web 服务进行目录扫描、漏洞探测。
4. **无连接频率限制**：当前防火墙规则未对单 IP 的连接速率或并发数进行任何限制，攻击者可能轻易发起大规模攻击。

### 改进方案

采用 iptables 的 connlimit 模块限制单 IP 对 dmz:8080 的最大并发连接数：

```bash
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**规则说明**：
- `--syn`：仅匹配 TCP 三次握手的第一包，不影响已建立的连接。
- `--dport 8080`：限制目标端口为 8080 的连接。
- `-d 10.40.0.2`：限制目标为 dmz 服务器。
- `--connlimit-above 10 --connlimit-mask 32`：单 IP（/32 掩码）的最大并发连接数超过 10 时触发。
- `-j REJECT --reject-with tcp-reset`：用 TCP RST 拒绝超额连接，让客户端立即感知。

### 测试验证

使用 for 循环从 internet 命名空间发起 20 次高频 curl 请求：
```bash
for i in {1..20}; do
  sudo ip netns exec internet curl --max-time 1 http://203.0.113.1:8080/
done
```

**测试结果**：前约 10 个请求建立成功（返回 HTTP 200），后续请求被 connlimit 规则以 TCP RST 拒绝，dmz 服务器未因连接数过多而崩溃。测试验证了 connlimit 限制的有效性。

![边界测试 - 连接数限制测试](19-defend-limit-test.png)

### 进一步改进建议

1. **结合 recent 模块限制连接频率**：在 connlimit 限制并发数的基础上，增加 recent 模块限制单 IP 每分钟的新建连接数不超过 30 个，防御脉冲式攻击。
2. **部署 WAF（Web 应用防火墙）**：在 dmz 前部署 ModSecurity 或商业 WAF，过滤 SQL 注入、XSS、目录遍历等 Web 攻击。
3. **应用层限流**：使用反向代理 Nginx 的 `limit_conn` 和 `limit_req` 模块，在 HTTP 层面对请求速率和连接数进行更精细的控制。
4. **自动封禁机制**：部署 fail2ban 自动监控 iptables 日志，当某 IP 在短时间内触发多次拒绝规则时，自动添加到黑名单。
5. **CDN + DDoS 清洗**：将 dmz:8080 接入 CDN 服务，利用 CDN 的边缘节点分散流量，同时启用 DDoS 清洗服务吸收攻击流量。
6. **连接状态监控**：定期使用 `conntrack -L | wc -l` 监控连接表使用率，设置阈值告警，及时发现异常连接增长。
7. **SYN Cookie 启用**：在 fw 上启用 `net.ipv4.tcp_syncookies=1`，防御 SYN Flood 攻击，避免连接表被半开连接耗尽。

### 创新发现：非明显的安全问题

在本次攻防演练中，除了上述直接的攻击尝试，我还发现了几个容易被忽视但风险极高的安全隐患：

1. **DNS 隧道隐蔽通信风险**：当前防火墙允许所有区域访问 internet 的 UDP 53 端口（DNS）。如果 guest 或 compromised office 主机将数据编码在 DNS 查询的域名中（如 `data.attacker.com`），可以绕过传统的端口/地址过滤实现隐蔽的数据外泄。这种攻击不需要建立 TCP 连接，connlimit 和常规防火墙规则都无法检测。建议在网络边界部署专门的 DNS 流量分析工具（如 DNS Twist、Pi-hole），监控异常域名查询模式。

2. **ICMP 隧道风险**：虽然本实验中的 REJECT 规则会返回 ICMP 不可达消息，但如果防火墙配置不当，ICMP Echo（ping）和 ICMP Echo Reply 可能被滥用为隐蔽通信通道（如 icmpsh、ptunnel）。建议在对外接口上严格限制 ICMP 类型，仅允许必要的 Echo 请求，并监控 ICMP 包的大小和频率。

3. **侧信道信息泄露**：REJECT 和 DROP 的不同响应时间可能泄露防火墙规则信息。攻击者可以通过测量不同端口的响应时间差异，推断哪些端口被显式拒绝、哪些被静默丢弃，从而绘制出防火墙规则的部分轮廓。建议在对外规则中统一使用 DROP 策略，消除这种侧信道信息泄露。
