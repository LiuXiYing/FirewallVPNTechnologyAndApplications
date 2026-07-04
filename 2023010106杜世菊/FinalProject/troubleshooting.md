# 故障排查报告

本次实验针对企业级网络安全架构中三类典型故障场景进行了完整的排查与修复。故障覆盖 **DNAT 端口映射失效**、**VPN 隧道业务不通** 和 **状态检测规则缺失**，分别对应外网访问、远程接入、基础转发三个关键环节。通过系统化的排查思路（确认规则 → 抓包定位 → 检查状态 → 验证服务）和组合工具（iptables、tcpdump、conntrack、ss、路由表），我们能够快速定位根因并修复。

## 故障 1：DNAT 配置了但外网无法访问

### 故障现象
- 外网主机（internet，IP `203.0.113.10`）通过防火墙公网 IP `203.0.113.1:8080` 访问 DMZ 的 Web 服务，连接超时。
- 预期行为：DNAT 应将流量转发至 `10.40.0.2:8080`，并正常返回 HTTP 页面。

### 重现步骤（故意配置错误）
```bash
# 删除 FORWARD 链中原本放行外网访问 DMZ:8080 的规则（行号10），模拟故障
sudo ip netns exec fw iptables -D FORWARD 10
```
```bash
# 从 internet 命名空间测试访问，预期超时
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:8080/
```
```text
curl: (28) Connection timed out after 2002 milliseconds
```

### 排查过程

#### ① 确认 DNAT 规则存在且生效
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers | grep 8080
```
```text
1       18  1080 DNAT  tcp  --  veth-fw-inet *  0.0.0.0/0  0.0.0.0/0  tcp dpt:8080 to:10.40.0.2:8080
```
- `pkts=18` 说明 DNAT 已被命中，地址转换环节正常，问题在后端转发。

#### ② 检查 FORWARD 链放行规则
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "10.40.0.2.*8080" | grep ACCEPT
```
无输出 → 缺少放行规则，包可能被默认策略拦截。

#### ③ 抓包定位丢包位置
- **入口抓包（防火墙 internet 侧）**
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5 host 203.0.113.10 and port 8080
```
可见 SYN 包到达，说明包已抵达防火墙。
- **出口抓包（防火墙 DMZ 侧）**
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5 host 10.40.0.2 and port 8080
```
首次抓包无任何包 → 包未从 DMZ 接口发出，确认在 FORWARD 链被丢弃。

#### ④ 查看 conntrack 表
```bash
sudo ip netns exec fw conntrack -L | grep 8080
```
无输出 → 连接未能建立（因包被丢弃）。

#### ⑤ 确认 FORWARD 默认策略
```bash
sudo ip netns exec fw iptables -L FORWARD -n | grep "Chain FORWARD"
```
```text
Chain FORWARD (policy DROP)
```
默认 DROP，未匹配的包被丢弃，证实缺少放行规则。

#### ⑥ 检查 DMZ 服务是否监听
```bash
sudo ip netns exec dmz ss -tlnp | grep 8080
```
无输出 → 服务未启动，即使 FORWARD 放行也会被目标 RST。

### 根本原因
- **主要原因**：FORWARD 链缺少从 `veth-fw-inet` 到 `veth-fw-dmz`、目标 `10.40.0.2:8080` 的 ACCEPT 规则，导致 DNAT 后的数据包被默认 DROP。
- **次要原因**：DMZ 主机上 8080 端口无服务监听，即使放行也会返回 RST。

### 修复与验证
1. **添加 FORWARD 放行规则**
```bash
sudo ip netns exec fw iptables -I FORWARD 5 \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```
2. **启动 DMZ Web 服务**
```bash
sudo ip netns exec dmz python3 -m http.server 8080 &
```
3. **验证访问成功**
```bash
sudo ip netns exec internet curl -v http://203.0.113.1:8080/
```
返回 HTTP 200。

4. **检查 conntrack 及计数器**
- `conntrack -L | grep 8080` 显示 ESTABLISHED 记录。
- `iptables -L FORWARD -n -v` 中新增规则 pkts > 0，确认转发生效。

### 举一反三
- **DNAT 排查三板斧**：① 检查 PREROUTING 命中计数；② 检查 FORWARD 放行；③ 检查后端服务监听。任何一环缺失都会导致访问失败。
- **抓包策略**：入口抓包确认到达，出口抓包确认转发，对比即可定位丢包发生在 FORWARD 还是后端。
- **生产建议**：FORWARD 规则应细化到 `-i/-o` 接口，避免开放所有路径；同时务必确保后端服务存活，否则会出现“转发成功但连接拒绝”的迷惑现象。

---

## 故障 2：VPN 隧道握手正常但业务访问失败

### 故障现象
- WireGuard VPN 隧道已建立（`wg show` 显示握手成功），但 remote 客户端无法访问 DMZ 的 Web 服务 `10.40.0.2:8080`。
- 同时 remote 可以访问 office 网段 `10.20.0.0/24`，唯独 DMZ 不通。

### 重现步骤（故意配置错误）
**故障 2a：删除 FORWARD 链中允许所有 NEW 连接的全局规则**
```bash
sudo ip netns exec fw iptables -D FORWARD 11   # 行号 11 为全局 ACCEPT
```
**故障 2b：修改 remote 的 AllowedIPs，仅保留 office 网段**
```bash
sudo ip netns exec remote sed -i 's|^AllowedIPs = .*|AllowedIPs = 10.20.0.0/24|' /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

### 排查过程

#### ① 确认 VPN 隧道状态
```bash
sudo ip netns exec remote wg show
```
输出显示 `latest handshake`、`transfer` 正常 → 隧道物理层 OK。

#### ② 检查 remote 路由表，看目标网段是否走 wg0
```bash
sudo ip netns exec remote ip route show | grep 10.40.0.0
```
无输出 → AllowedIPs 未包含该网段，路由未添加（故障 2b）。

#### ③ 在 fw 的 wg0 接口抓包
```bash
sudo ip netns exec fw tcpdump -ni wg0 -c 5 host 10.10.10.2 and port 8080
```
触发 remote 访问，能抓到 SYN 包 → 说明包确实到达了 fw 的 wg0 接口，即 VPN 封装/解封装正常，路由到 fw 没问题。

#### ④ 检查 fw 的 FORWARD 链是否存在针对 VPN 的放行规则
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "wg0.*veth-fw-dmz.*8080.*ACCEPT"
```
无输出 → 没有匹配规则，包会被默认 DROP（故障 2a）。

#### ⑤ 在 fw 的 dmz 侧抓包
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5 host 10.40.0.2 and port 8080
```
无任何包 → 包未从 DMZ 接口发出，确认在 FORWARD 被丢弃。

#### ⑥ 确认 FORWARD 默认策略为 DROP
```bash
sudo ip netns exec fw iptables -L FORWARD -n | grep "Chain FORWARD"
```
输出 `Chain FORWARD (policy DROP)`。

#### ⑦ 再查 remote 路由（用 `ip route get` 验证）
```bash
sudo ip netns exec remote ip route get 10.40.0.2
```
输出 `10.40.0.2 via 10.10.10.1 dev veth-remote` → 实际走了默认路由（`veth-remote`），而非 `wg0`，确认故障 2b。

#### ⑧ remote wg0 抓包确认无流量
```bash
sudo ip netns exec remote tcpdump -ni wg0 -c 5 host 10.40.0.2 and port 8080
```
无任何包 → 流量未进入 VPN 隧道。

### 根本原因
- **原因一（FW 侧）**：FORWARD 链缺少放行 VPN 客户端（来源 `wg0` 接口）到 DMZ 的规则，导致包被默认 DROP。
- **原因二（客户端侧）**：`AllowedIPs` 未包含 `10.40.0.0/24`，导致该网段路由未添加到 `wg0`，流量走默认路由，无法经 VPN 转发。

### 修复与验证
1. **修复 FW 侧**：重新添加全局允许规则（或精确规则）
```bash
sudo ip netns exec fw iptables -I FORWARD 5 -o veth-fw-inet -m conntrack --ctstate NEW -j ACCEPT
```
（也可添加针对 `-i wg0 -o veth-fw-dmz -d 10.40.0.2` 的精确规则）

2. **修复客户端路由**：更正 AllowedIPs
```bash
sudo ip netns exec remote sed -i 's|^AllowedIPs = .*|AllowedIPs = 10.20.0.0/24,10.40.0.0/24|' /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

3. **启动 DMZ 服务**（如已停止）
```bash
sudo ip netns exec dmz python3 -m http.server 8080 
```

4. **验证**
```bash
sudo ip netns exec remote curl -v http://10.40.0.2:8080/
```
返回 HTTP 200；`ip route get 10.40.0.2` 显示 `dev wg0`；FW 的 FORWARD 计数器有命中。

### 举一反三
- **VPN 业务不通的二元排查**：先查隧道状态（`wg show`）和路由（`ip route`），再查防火墙转发。任何一端出问题都会导致不通。
- **AllowedIPs 的双重作用**：既控制路由（Linux 策略路由），又控制允许的源地址（对端检查）。修改后必须重启隧道生效。
- **抓包顺序**：在客户端 wg0 抓包检查是否进隧道，在服务端 wg0 抓包检查是否收到，在服务端出口抓包检查是否转发 —— 三步定位法能快速区分路由、隧道、防火墙三类故障。
- **生产建议**：Always use `AllowedIPs` 按最小权限列出，避免使用 `0.0.0.0/0`（除特殊需求外）；防火墙针对 VPN 流量单独配置精确规则，而非依赖全局放行。

---

## 故障 3：去掉 ESTABLISHED,RELATED 后 TCP 连接失败

### 故障现象
- Office 主机访问 DMZ Web 服务（`10.40.0.2:8080`）超时，但此前该访问是正常的。
- 查看 FORWARD 链发现允许 office→dmz 的 NEW 连接规则存在，但请求仍超时。

### 重现步骤（故意配置错误）
删除 FORWARD 链中的状态检测规则（行号 4）：
```bash
sudo ip netns exec fw iptables -D FORWARD 4
```
从 office 测试：
```bash
sudo ip netns exec office curl --max-time 2 http://10.40.0.2:8080/
```
```text
curl: (28) Connection timed out after 2002 milliseconds
```

### 排查过程

#### ① 确认状态检测规则是否还在
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "ctstate RELATED,ESTABLISHED"
```
无输出 → 规则已删除。

#### ② 抓包分析（在 fw 的 dmz 侧抓包）
- 启动 tcpdump 在 `veth-fw-dmz` 捕获 8080 端口。
- 触发 office 访问，观察到三次握手过程：
```text
12:01:01.123456 IP 10.20.0.2.45678 > 10.40.0.2.8080: Flags [S]
12:01:01.123500 IP 10.40.0.2.8080 > 10.20.0.2.45678: Flags [S.]   # SYN-ACK 发出
# 之后无 ACK，因为 fw 丢弃了该 SYN-ACK（但 tcpdump 仍能看到它从 veth-fw-dmz 接口发出）
```
- 说明：SYN 包成功从 office 转发到 dmz，dmz 响应了 SYN-ACK，但该 SYN-ACK 进入 fw 后（属于 ESTABLISHED 状态）因缺少放行规则被默认 DROP，因此 office 侧收不到 SYN-ACK，连接超时。

#### ③ 查看 conntrack 表
```bash
sudo ip netns exec fw conntrack -L | grep 8080
```
无记录 → 连接未建立。

#### ④ 确认 FORWARD 默认策略为 DROP
```bash
sudo ip netns exec fw iptables -L FORWARD -n | grep "Chain FORWARD"
```
输出 `Chain FORWARD (policy DROP)`。

### 根本原因
- FORWARD 链删除了 `ctstate ESTABLISHED,RELATED` 的 ACCEPT 规则，导致属于已建立连接的回程包（SYN-ACK、ACK、数据包）无法被放行。
- 仅放行 NEW 状态的 SYN 包不足以完成 TCP 三次握手，因为后续报文状态不再是 NEW，会被默认 DROP。

### 修复与验证
1. **重新插入状态检测规则**（必须放在规则链最前面）
```bash
sudo ip netns exec fw iptables -I FORWARD 5 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```
2. **验证访问成功**：
```bash
sudo ip netns exec office curl -v http://10.40.0.2:8080/
```
返回 HTTP 200。
3. **检查 conntrack 记录**，存在 ESTABLISHED 条目。
4. **查看计数器**，状态检测规则 pkts > 0，确认回程包被放行。

### 举一反三
- **状态检测规则是防火墙的“通行证”**：缺它则任何需要双向通信的协议（TCP、FTP 数据通道等）均会失败，即使入向规则正确。
- **规则顺序至关重要**：`ESTABLISHED,RELATED` 必须置于最前面（一般在默认策略之后，其他规则之前），否则回程包可能先匹配到其他规则而被丢弃。
- **排错技巧**：若访问超时但抓包看到 SYN-ACK 发出，则大概率是防火墙丢弃了回程包，立刻检查状态检测规则是否存在。
- **生产环境黄金法则**：永远保留 `-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT` 作为 FORWARD 和 INPUT 链的首条规则，除非有极端性能需求（也需谨慎评估）。

---

## 总结

三类故障分别对应 **DNAT 转发**、**VPN 路由与防火墙联动**、**状态跟踪**，涵盖了企业边界防护中最常见的问题点。通过本次排查，总结出以下通用的排查方法论：

| 故障现象 | 优先检查项 | 常用工具 |
|---------|-----------|---------|
| 外网通过 DNAT 访问不通 | DNAT 规则计数、FORWARD 放行规则、后端服务状态 | iptables -t nat -L, iptables -L FORWARD, ss/tcpdump |
| VPN 隧道建立但业务不通 | 隧道状态、客户端路由（AllowedIPs）、服务端 FORWARD 规则 | wg show, ip route, tcpdump at wg0 |
| 单向可达但无法建立连接 | 状态检测规则是否存在、默认策略 | iptables -L FORWARD, conntrack -L, tcpdump 双向抓包 |

最终，所有故障均修复并通过验证，证明排查思路正确。在实际运维中，需保持防火墙规则的有序性、完整性，并定期审计，避免因误删规则导致业务中断。同时，借助 `tcpdump` 和 `conntrack` 可快速定位丢包环节，是排错利器。