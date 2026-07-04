# 故障排查报告

## 场景一：DNAT 配置正确但外网无法访问 dmz 服务

### 现象
- 在 `internet` 命名空间中执行 `curl http://203.0.113.1:8080/` 时报错：`curl: (28) Connection timed out after 3002 milliseconds`
- `dmz` 上的 Python HTTP 服务运行正常（`python3 -m http.server 8080 --bind 10.40.0.2`）
- `iptables -t nat -L PREROUTING -nv` 显示 DNAT 规则已命中（`pkts` 增加）

### 排查过程
1. **检查 NAT 规则**：确认 DNAT 方向正确，目标地址为 `10.40.0.2:8080`，无问题。
2. **检查 FORWARD 规则**：执行 `iptables -L FORWARD -nv --line-numbers`，发现从 `veth-fw-inet` 到 `veth-fw-dmz` 方向**缺少** ACCEPT 规则。数据包在完成 DNAT 后进入 FORWARD 链，但仅有状态检测规则和针对其他区域的规则，最终被默认策略 DROP 丢弃。
3. **抓包验证**：在 `fw` 的 `veth-fw-inet` 接口抓包，能看到来自 `internet` 的 SYN 包；但在 `veth-fw-dmz` 接口无对应包，证明包在防火墙内部被拦截。
4. **检查连接跟踪**：`conntrack -L` 中无任何相关记录，说明包根本没有完成状态建立。

### 根本原因
**防火墙规则过严**：DNAT 只负责修改目的 IP，但数据包仍然需要通过 FORWARD 链的过滤。默认策略为 DROP，必须显式添加 ACCEPT 规则放行已转换的流量。

### 修复方法
在 FORWARD 链添加一条规则：
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

### 启示
- NAT 与防火墙策略是**独立**的：配置 DNAT 时，必须同步考虑 FORWARD 链的放行规则。
- 故障排查时，**数据包路径追踪**是最有效的方法：从入口抓包一直跟到出口，找到丢包点。
- 默认 DROP 策略虽然安全，但容易导致此类“忘记放行”的故障，需要在保证安全的前提下清晰定义访问控制列表。

---

## 场景二：VPN 隧道握手正常但业务访问失败

### 现象
- `wg show` 显示 `latest handshake: X seconds ago` 和 `transfer: X KiB received, Y KiB sent`，握手和保活均正常。
- 从 `remote` 执行 `curl http://10.20.0.2:8000/` 时却报错：`curl: (7) Failed to connect ...`，有时为 `Connection timed out`。
- 查看防火墙 FORWARD 规则计数器，发现精确的 VPN→office 的 ACCEPT 规则 `pkts` 只有 1，而 REJECT 规则并未增加。

### 排查过程
1. **验证路由**：在 `remote` 中执行 `ip route`，确认 `10.20.0.0/24 dev wg0` 已存在，路由层面无误。
2. **入门抓包**：在 `fw` 的 `wg0` 接口上 `tcpdump`，能够捕获来自 `10.10.10.2` 发往 `10.20.0.2` 的 TCP SYN 包，说明包已通过隧道到达防火墙。
3. **出口抓包**：在 `fw` 的 `veth-fw-office` 接口上抓包，却**没有**看到对应的 SYN 包，证明包在 FORWARD 链被丢弃。
4. **分析规则顺序**：
   - 规则 A：`ACCEPT all -- wg0 veth-fw-office 10.10.10.2 10.20.0.0/24 ctstate NEW`
   - 该规则计数器为 1，但后续重试的 SYN 包（多次 curl 或重传）并没有使计数器增加。
   - 排查发现，该规则使用了 `-m conntrack --ctstate NEW`，但某些重传的 SYN 包可能被内核 conntrack 判定为非 NEW 状态（如 UNREPLIED 后的重传可能被归类为 INVALID），导致不匹配，随后被后面的 REJECT 规则拦截。
5. **临时验证**：插入一条通用放行规则 `iptables -I FORWARD 16 -i wg0 -o veth-fw-office -j ACCEPT`，再次测试，curl 立刻成功。证实问题出在精确规则的匹配条件上。

### 根本原因
**iptables 状态匹配的严格性**：在部分内核版本中，TCP 重传的 SYN 包可能不被视为 NEW 状态，导致依赖 `--ctstate NEW` 的规则失效。精确规则中的 `-s`、`-d` 等条件虽然理论上正确，但在特定重传场景下未能匹配。

### 修复方法
1. 保持通用放行规则（基于接口匹配），以保证连通性。
2. 将针对敏感端口（如 22）的 REJECT 规则仍然放在通用放行规则之前，确保安全。
3. 更新后的规则结构：
   ```
   -A FORWARD -i wg0 -o veth-fw-office -j ACCEPT
   -A FORWARD -i wg0 -o veth-fw-dmz -p tcp --dport 22 -j REJECT
   -A FORWARD -i wg0 -o veth-fw-dmz -j ACCEPT
   -A FORWARD -i wg0 -j REJECT (其他 VPN 流量拒绝)
   ```

### 启示
- 防火墙规则设计应遵循**“先通后精”**原则：先用宽松条件验证网络可达，再逐步收紧。
- 抓包和规则计数器是定位防火墙问题的黄金组合。
- 状态防火墙中的 `NEW` 状态并非绝对可靠，对于重传等边缘情况需谨慎使用。

---

## 场景三：移除 ESTABLISHED,RELATED 规则导致 TCP 连接失败

### 现象
- 从 `office` 访问 `dmz:8080`，`curl` 命令长时间等待后超时。
- `office` 和 `dmz` 上的服务均正常，路由也正确。
- 防火墙规则中已存在 `office→dmz:8080` 的 ACCEPT 规则（针对 NEW 状态）。

### 排查过程
1. **观察三次握手**：在 `fw` 上同时抓取 `veth-fw-office` 和 `veth-fw-dmz` 接口：
   - `veth-fw-office`：收到来自 `10.20.0.2` 的 SYN 包。
   - `veth-fw-dmz`：看到转发的 SYN 包发出，并且 dmz 回复了 SYN-ACK。
   - `veth-fw-office`：始终**没有**看到 SYN-ACK 回包。 
2. **检查 FORWARD 规则**：发现整个链中第 1 条规则原本应有的 `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` 被意外删除（或因脚本重置丢失）。
3. **分析原因**：回程的 SYN-ACK 包属于 `ESTABLISHED` 状态，但没有规则放行，最终被默认 DROP 策略丢弃。

### 根本原因
**状态检测规则缺失**：`ESTABLISHED,RELATED` 规则是双向通信的基石。当缺省时，任何非 NEW 状态的包（如 TCP 握手第二次、第三次握手、数据传输等）都会被拒绝，导致连接无法建立。

### 修复方法
重新插入该规则，且**必须**位于 FORWARD 链的最前面：
```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

### 启示
- `ESTABLISHED,RELATED` 规则是**任何有状态防火墙的必备第一条**，不可遗漏。
- 当遇到“SYN 包能通过，但连接无法建立”的问题时，首要怀疑的就是回程流量被拦截。
- 写脚本时务必确保该规则在任何清空操作后被重新添加，我们后续的 `firewall.sh` 已固定该步骤。

---

## 场景四：WireGuard 握手失败（路由冲突与回程缺失）

### 现象
- `remote` 端持续发送握手包（`transfer` 中的 send 增加），但 `fw` 端 `wg show` 没有 `handshake`，也无 `transfer` 接收。
- 用 `tcpdump` 在 `fw` 的 Internet 接口抓包，看不到来自 `remote` 的 UDP 51820 包。
- `remote` 可以 ping 通 `internet` 侧接口（203.0.113.10），但 ping 不通 `fw` 公网地址 203.0.113.1。

### 排查过程
1. **检查底层网络**：发现 `remote` 和 `internet` 最初被错误地配置在**同一个子网**（203.0.113.0/24）中，且 `internet` 本身是一个命名空间，不具备路由器的功能，导致了路由歧义。
2. **检查 fw 路由**：`fw` 仅有去往 203.0.113.0/24（直连）的路由，没有去往 `remote` 新子网（后来修改的 203.0.114.0/24）的路由。即使包被 `internet` 转发到 `fw`，`fw` 也不知道如何送回 `remote`。
3. **抓包证明**：在 `internet` 的 `veth-inet-rmt` 接口抓包，能看到 `remote` 发来的 UDP 包，但在 `fw` 的 `veth-fw-inet` 上收不到，说明 `internet` 命名空间虽然有开启 IP 转发，但可能因为子网重叠导致未正确转发。

### 根本原因
1. **子网重叠**：`internet` 连接 `fw` 的接口和连接 `remote` 的接口使用了相同网段，导致 `internet` 协议栈混淆，不能正确转发数据包。
2. **缺少回程路由**：即使子网隔离后，`fw` 没有去往 `remote` 新网段的路由，导致握手应答无法返回。

### 修复方法
1. 将 `remote` 和 `internet` 之间的链路改为独立子网（例如 `203.0.114.0/24`）。
2. 在 `fw` 上添加静态路由：`ip route add 203.0.114.0/24 via 203.0.113.10`。
3. 确保 `internet` 命名空间的 IP 转发开启且 FORWARD 策略宽松。

### 启示
- 复杂的虚拟网络环境中，IP 地址规划必须严谨，避免子网重叠。
- 命名空间之间的路由是**单向**的，务必考虑回程路径。
- `tcpdump` 在每一跳进行抓包，可快速定位包丢失的位置。

---

## 通用排查技巧总结

1. **分层排查**：从底层链路、路由、防火墙规则到应用服务，逐层确认。
2. **计数器和抓包**：`iptables -nvL` 和 `tcpdump` 是定位防火墙、路由问题的核心工具。
3. **简化测试**：遇到复杂规则失效时，临时用 `-I` 插入一条全通规则，快速判断是规则问题还是网络问题。
4. **善用 conntrack**：`conntrack -E` 或 `cat /proc/net/nf_conntrack` 可实时观察连接状态，有助于分析状态防火墙行为。
5. **脚本可重复性**：所有配置必须脚本化，且脚本应包含清理步骤，避免上一次实验的残留状态干扰本次实验。

---

**报告完毕**。