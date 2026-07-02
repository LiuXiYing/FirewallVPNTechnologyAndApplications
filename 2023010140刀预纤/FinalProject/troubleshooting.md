# 故障排查报告

## 场景1：DNAT 配置了但外网无法访问

### 现象重现

- `internet` 命名空间中的主机访问 `203.0.113.1:8080` 失败，curl 超时。
- `iptables -t nat -L` 显示 DNAT 规则已存在。
- `dmz` 上的 `python3 -m http.server 8080` 服务正常运行，本地可访问。

### 故障重现命令

```bash
# 1. 故意删除 FORWARD 规则（模拟故障）
sudo ip netns exec fw iptables -D FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# 2. 测试：外网访问失败
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
# 结果：Connection timed out
```

### 排查过程

| 步骤 | 命令 | 观察 | 结论 |
|:-----|:-----|:-----|:-----|
| 1 | `sudo ip netns exec fw iptables -t nat -L -n -v` | DNAT 规则存在，计数器有匹配 | DNAT 规则本身正常工作 |
| 2 | `sudo ip netns exec fw iptables -L FORWARD -n -v` | 缺少 veth-fw-inet→veth-fw-dmz 的 ACCEPT 规则 | FORWARD 链未放行 DNAT 后的流量 |
| 3 | `sudo ip netns exec dmz ip route show` | default via 10.40.0.1 | dmz 回程路由正确 |
| 4 | `sudo ip netns exec fw tcpdump -ni any -c 5` | SYN 包到达 fw 但不转发到 dmz | FORWARD 链 DROP 导致 |

### 根本原因

DNAT 规则仅负责在 PREROUTING 链中将目的地址从 203.0.113.1 转换为 10.40.0.2，但转换后的流量仍需经过 FORWARD 链进行转发判断。由于 FORWARD 链的默认策略是 DROP，且缺少从 internet 侧接口到 dmz 侧接口的明确 ACCEPT 规则，DNAT 转换后的流量被丢弃。

### 修复方法

```bash
# 添加 FORWARD ACCEPT 规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# 验证修复
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
# 结果：HTTP 200 OK
```

### 经验教训

1. **DNAT + FORWARD 缺一不可**：DNAT 规则仅完成地址转换，FORWARD 规则决定转换后的流量能否通过。两者必须同时配置，且接口方向要匹配。
2. **分层排查法**：NAT 层（PREROUTING/POSTROUTING）→ FORWARD 层 → 路由层 → 应用层。每一层都要用计数器验证规则是否命中。
3. **举一反三**：此故障模式同样适用于 SNAT 场景。如果内网主机通过 SNAT 访问外网失败，除了检查 POSTROUTING 的 SNAT 规则，还必须确认 FORWARD 链是否允许内网→外网的流量。很多初学者只配了 SNAT 却忘了 FORWARD，导致"能 ping 通网关但上不了网"的经典故障。

**相关截图**：

![NAT 规则列表](03-nat-rules.png)

---

## 场景2：VPN 隧道握手正常但业务访问失败

### 现象重现

- `wg show` 显示 `latest handshake` 时间新鲜（数秒内），传输计数器有递增。
- `sudo ip netns exec remote ping -c 2 10.40.0.2` 100% 丢包。
- `fw` 上的 `iptables -L FORWARD -n -v` 中相关规则计数器为 0。
- `journalctl -k` 中无 VPN 相关拒绝日志。

### 故障原因1：AllowedIPs 配置错误

**重现方法**：
```bash
# 错误配置：AllowedIPs 中包含了 VPN 网段自身
sudo tee /etc/wireguard/remote/wg0.conf <<'EOF'
[Interface]
Address = 10.10.10.2/24
PrivateKey = <remote-private-key>

[Peer]
PublicKey = <fw-public-key>
Endpoint = 192.168.99.1:51820
AllowedIPs = 10.10.10.0/24,10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
EOF
```

**排查方法**：
1. 检查 remote 的路由表：`sudo ip netns exec remote ip route`，发现存在 10.10.10.0/24 dev vpn-remote 的路由，干扰了对端通信。
2. 检查 `wg show` 输出：WireGuard 提示 "Warning: AllowedIP has nonzero host part: 10.10.10.1/24"。

**修复**：从 AllowedIPs 中移除 10.10.10.0/24。

### 故障原因2：FORWARD 规则拒绝了 VPN 流量

**重现方法**：
```bash
# 删除 VPN 的 FORWARD ACCEPT 规则
sudo ip netns exec fw iptables -D FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT
```

**排查方法**：
1. 检查规则计数器：`sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers`，VPN 相关 ACCEPT 计数器为 0。
2. 在 fw 上抓包：`sudo ip netns exec fw tcpdump -ni wg0`，看到 VPN 流量到达但未转发。

**修复**：重新添加 VPN 的 FORWARD ACCEPT 规则。

### 故障原因3：dmz 没有回程路由

**排查方法**：
```bash
sudo ip netns exec dmz ip route show
# 预期：default via 10.40.0.1
# 若缺少到 10.10.10.0/24 的路由，dmz 无法回复 remote
```

**修复**：
```bash
sudo ip netns exec dmz ip route add 10.10.10.0/24 via 10.40.0.1
```

### 排查步骤表

| 步骤 | 命令 | 观察 | 结论 |
|:-----|:-----|:-----|:-----|
| 1 | `sudo ip netns exec remote ip route get 10.40.0.2` | 确认路由是否走 `vpn-remote` 接口 | 判断路由是否正确指向 VPN 隧道 |
| 2 | `sudo ip netns exec remote wg show` | 检查 AllowedIPs 和握手状态 | 确认 AllowedIPs 是否包含目标网段 |
| 3 | `sudo ip netns exec fw iptables -L FORWARD -n -v` | 检查 VPN 相关 ACCEPT 规则计数器 | 判断 FORWARD 规则是否匹配到流量 |
| 4 | `sudo ip netns exec dmz ip route show` | 检查是否有到 10.10.10.0/24 的回程路由 | 判断回程路由是否完整 |
| 5 | `sudo ip netns exec fw sysctl net.ipv4.ip_forward` | 检查值是否为 1 | 确认 fw 是否开启 IP 转发 |

### 快速定位口诀

1. **先查路由**：在 remote 上 `ip route get 10.40.0.2`，确认路由走向。
2. **再查防火墙**：在 fw 上 `iptables -L FORWARD -n -v`，确认规则和计数器。
3. **最后查回程**：在目标（如 dmz）上检查回程路由。

**相关截图**：

![VPN 隧道状态](06-vpn-status.png)

![remote 路由表](11-vpn-route.png)

---

## 场景3：去掉 ESTABLISHED,RELATED 后 TCP 连接失败

### 现象重现

```bash
# 删除 ESTABLISHED,RELATED 规则
sudo ip netns exec fw iptables -D FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 测试：office 访问 dmz:8080
sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080/
# 结果：Connection timed out（超时）
```

### 排查过程

| 步骤 | 命令 | 观察 | 结论 |
|:-----|:-----|:-----|:-----|
| 1 | `sudo ip netns exec fw tcpdump -ni veth-fw-office -nn` | 看到 SYN (10.20.0.2 → 10.40.0.2:8080) | SYN 包到达 fw 的 office 侧接口 |
| 2 | `sudo ip netns exec fw tcpdump -ni veth-fw-dmz -nn` | 看到 SYN 到达 dmz，SYN-ACK 从 dmz 发出，但 SYN-ACK 未回到 office | SYN-ACK 回程被拦截 |
| 3 | `sudo ip netns exec fw conntrack -L \| grep 10.40.0.2` | 连接状态为 SYN_SENT | 三次握手未完成，fw 记录了半开连接 |
| 4 | `sudo ip netns exec fw iptables -L FORWARD -n -v` | 第一条 ESTABLISHED,RELATED 规则已不存在 | 确认规则被删除，回程无匹配规则 |

**包流向分析**：
```
SYN (office→fw→dmz)       ✅ 被 "office→dmz:8080 NEW" ACCEPT 规则放行
SYN-ACK (dmz→fw→office)   ❌ 被默认 DROP 策略拦截（无 ESTABLISHED 规则匹配）
ACK (office→fw→dmz)       ❌ 同样被 DROP（重传也失败）
```

### 根本原因

FORWARD 链中只有针对 `NEW` 状态（第一个 SYN）的具体 ACCEPT 规则。删除 `ESTABLISHED,RELATED` 规则后，回程的 SYN-ACK 包没有对应的 ACCEPT 规则（它的状态是 `ESTABLISHED`），因此被 FORWARD 链默认的 `DROP` 策略丢弃，导致 TCP 三次握手无法完成。

### 分析

`ESTABLISHED,RELATED` 是状态检测防火墙的核心。它让防火墙可以"记住"每个连接的状态，自动放行属于已建立连接的回程流量。没有这条规则：

- **第一个 SYN 包**：通过（有具体的 ACCEPT 规则匹配 `NEW` 状态）
- **回程 SYN-ACK**：被 DROP（没有对应的 ACCEPT 规则匹配 `ESTABLISHED` 状态）
- **后续数据包**：全部被 DROP

这就像一道只有入口没有出口的门——可以进去，但出不来。

### 修复

```bash
# 恢复 ESTABLISHED,RELATED 规则（放在第一条）
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### 经验教训

1. **ESTABLISHED,RELATED 是状态防火墙的基石**：不能删除。它使得只需要为每个连接方向的首包配置 ACCEPT 规则，所有后续回程流量自动放行。
2. **安全意义**：这条规则只允许属于已建立连接的回程包，攻击者无法伪造全新的回程包来绕过防火墙。
3. **举一反三**：此原理同样适用于 UDP 通信。UDP 虽然没有"连接"概念，但 conntrack 通过源/目的地址和端口的配对来追踪"伪连接"。如果删除 ESTABLISHED,RELATED，UDP 的请求能发出，但回复包也会被 DROP。
4. **生产环境警示**：在实际运维中，如果误删了 ESTABLISHED,RELATED 规则，会导致所有已有连接中断，但新连接仍然可以建立（因为首包有 NEW 规则匹配）。这种"间歇性故障"最难排查——看似能连上，但数据传输不稳定。排查时应优先检查 conntrack 状态和规则顺序。

**相关截图**：

![防火墙 FORWARD 规则列表](02-firewall-rules.png)
