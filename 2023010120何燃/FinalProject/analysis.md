# 第五部分：攻防演练与故障排查

## 5.1 攻击方演练（从 guest 发起）

### 攻击 1：扫描办公网段

**目标**：探测办公网内存活主机，观察防火墙拦截效果。

**命令**：
```bash
for i in 1 2 3 4 5; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i alive"
done
```

**结果**：
- `10.20.0.1`：ping 通（返回 `64 bytes from 10.20.0.1: icmp_seq=1 ttl=64 time=0.244 ms`）
- `10.20.0.2~5`：全部返回 `From 10.30.0.1 icmp_seq=1 Destination Port Unreachable`，100% 丢包。

**分析**：
`10.20.0.1` 是防火墙 `fw` 在 office 侧的接口地址，该接口属于 `fw` 本身，由其 INPUT 链默认策略 ACCEPT 处理，所以能响应 ICMP 请求。
`10.20.0.2` 是办公网主机，访问该地址的 ICMP 包需经过 FORWARD 链转发。防火墙存在显式 REJECT 规则（规则 9：`REJECT all -- veth-fw-guest veth-fw-office`），主动返回 `icmp-port-unreachable` 错误，导致立即失败。
攻击者通过扫描只能发现防火墙的接口地址，无法探知办公网内部主机的存活状态，即使主机存在，也因防火墙的 REJECT 而显示不可达。相比 DROP，REJECT 虽然暴露了防火墙的存在，但让内部用户快速感知连接被拒，生产环境中可根据区域风险评估选择使用。

### 攻击 2：尝试绕过防火墙访问 dmz:22

**目标**：通过改变源端口，伪装成常见服务流量，试图突破对 dmz:22 的访问限制。

**命令**：
```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**结果**：两条命令均在 0 ms 内返回 `curl: (7) Failed to connect to 10.40.0.2 port 22 after 0 ms: Could not connect to server`。

**分析**：
防火墙对 dmz:22 的 REJECT 规则仅检查目的端口（22）和入口接口（`veth-fw-guest`），与源端口无关。即使攻击者将源端口改为 80、443 等常见服务端口，数据包依然匹配到 `REJECT tcp -- veth-fw-guest veth-fw-dmz ... dpt:22` 规则，被立即拒绝。
此攻击失败说明基于目的端口的访问控制足够健壮，简单更改源端口无法绕过防火墙。

### 攻击 3：伪造 VPN 源地址

**目标**：在 guest 上添加一个 VPN 地址（10.10.10.100），并强制使用 lo 接口发出请求，尝试冒充 VPN 用户访问办公网。

**命令**：
```bash
sudo ip netns exec guest ip addr add 10.10.10.100/32 dev lo
sudo ip netns exec guest curl --max-time 2 --interface lo http://10.20.0.2:8000/
```

**结果**：`curl: (28) Connection timed out after 2001 milliseconds`。

**分析**：
攻击失败分为两个层面：
1. **本地路由层面**：使用 `--interface lo` 强制数据包从回环接口发送，但回环接口仅用于本机通信，无法将包路由到外部网络，SYN 包在 guest 内部就被内核丢弃，导致超时。
2. **防火墙层面**：即使数据包能通过正常接口发出（如 `veth-guest`），防火墙的 VPN 专属规则不仅检查源 IP，还严格限定入口接口必须是 `wg0`（即 WireGuard 虚拟接口）。因此即使源地址被伪造为 10.10.10.2，只要不是从 wg0 接口进入，同样会被后续的 REJECT 规则（比如 VPN-DENY）拦截。

该攻击充分验证了防火墙基于**接口+地址**的双重验证机制，单纯伪造 IP 无法突破网络隔离。

---

## 5.2 防御方分析

### 任务 1：从日志识别攻击

**日志证据（规则计数器截图）**
执行命令：
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "LOG|NFLOG"
```
输出显示各条 LOG/NFLOG 规则均有命中（pkts > 0），其中 `GUEST-TO-OFFICE` 计数为 6，`GUEST-TO-DMZ` 为 3，`INET-TO-OFFICE` 为 1 等，记录了所有违规访问。

**问题回答**：
1. **从日志的哪些字段可以判断这是来自 guest 的攻击？**
   - 规则描述中 `IN=veth-fw-guest` 明确指出了入口接口是连接 guest 的 veth 对端。
   - 日志前缀 `GUEST-TO-OFFICE` 或 `GUEST-TO-DMZ` 直接标明了来源区域。

2. **如果日志中 `IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？**
   - 表示有一个数据包从访客区（guest）出发，试图穿越防火墙到达办公区（office），这是一次横向越权尝试。防火墙正确识别并拒绝了该流量，防止了安全域之间的非法访问。

3. **为什么看到大量相同来源的日志应该引起警惕？**
   - 大量相同模式的日志可能意味着攻击者正在进行端口扫描、暴力破解或拒绝服务攻击。例如，短时间内出现数百条 `GUEST-TO-OFFICE` 日志，说明 guest 区域可能存在恶意软件或攻击者正在测绘内网拓扑，应立即触发安全告警，并对来源主机进行隔离或封堵。

### 任务 2：分析规则的防御效果

**规则计数器（REJECT 部分）**：
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep REJECT
```
输出显示 `REJECT` 规则均有相应的命中计数，如规则 9（guest→office）命中 6 次，规则 15（internet→office）命中 1 次等。

**问题回答**：
1. **哪条规则拦截了 guest 访问 office？**
   - 规则 9：`REJECT all -- veth-fw-guest veth-fw-office 0.0.0.0/0  reject-with icmp-port-unreachable`

2. **如果 guest→office 的规则计数很高，说明了什么？**
   - 说明 guest 区域存在大量的横向移动尝试，可能已有主机被攻陷，攻击者正试图以此为跳板进入办公网。需要立即审计该区域所有设备，并考虑临时断开其网络连接。

3. **REJECT 和 DROP 在安全性上有什么区别？**
   - `REJECT`：向源端发送一个 ICMP 不可达或 TCP RST 报文，通知连接被拒绝。优点是客户端能快速失败，提升用户体验（尤其在内网）；缺点是告诉攻击者该端口/主机存在且被过滤，可能泄露防火墙存在。
   - `DROP`：静默丢弃数据包，不产生任何回应。优点是隐藏网络内部结构，增加攻击者侦查难度；缺点是可能导致客户端长时间等待超时，在内网可能引起应用异常。
   - 本实验中，内部区域间的拒绝（如 guest→office）使用了 REJECT，以保证内部应用快速返回错误；而外网访问内网默认使用 DROP（未显式 REJECT），仅对特定服务（如 8080）放行，从而隐藏内网拓扑。

---

## 5.3 边界测试与改进方案

### 问题识别：dmz:8080 面向外网暴露，存在连接耗尽风险

**风险分析**：
`dmz` 的 Web 服务通过 DNAT 对外网开放，任何外网 IP 均可发起连接。如果攻击者发起大量并发 TCP 连接（SYN flood）或慢速连接，可能耗尽 dmz 主机的连接资源，导致正常用户无法访问。尽管防火墙已有基础隔离，但缺乏对单 IP 连接数的精细化限制。

### 改进方案：利用 connlimit 模块限制单 IP 并发连接数

**实现命令**：
```bash
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```
该规则插入在状态检测之后，对每个源 IP（掩码 /32）向 dmz 8080 端口发起的新连接（SYN 包）进行并发数限制，超过 10 个并发连接的新 SYN 包将被直接 RST 拒绝，而不会到达后端服务器。

### 效果测试

为验证效果，临时将阈值降低为 2：
```bash
sudo ip netns exec fw iptables -R FORWARD 2 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 2 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
```
在 `internet` 命名空间使用 `curl` 同时发起 5 个后台请求：
```bash
for i in {1..5}; do
  sudo ip netns exec internet curl --max-time 3 -o /dev/null -w "%{http_code}\n" http://203.0.113.1:8080/ &
done
wait
```
观察终端输出：部分请求返回 `000`（被 RST），其余返回 `200`。同时查看 connlimit 规则计数器，`pkts` 值增加，证明超出限制的连接已被拒绝。

测试后恢复为阈值 10。

### 分析总结
通过引入 connlimit 规则，防火墙能够有效防止单 IP 的恶意连接耗尽攻击，提升了 DMZ 服务的可用性。同时，该规则不影响正常用户的 HTTP 短连接访问，兼顾了安全与性能。

---

## 5.4 高级任务：追踪包的完整变化过程（加分项）

**场景**：remote 通过 VPN 访问 dmz:8080。

### 实现步骤
打开 4 个终端，分别执行：
1. remote 端抓包：`sudo ip netns exec remote tcpdump -ni wg0 -v -c 5`
2. fw VPN 接口抓包：`sudo ip netns exec fw tcpdump -ni wg0 -v -c 5`
3. fw DMZ 接口抓包：`sudo ip netns exec fw tcpdump -ni veth-fw-dmz -v -c 5`
4. 连接跟踪监控：`sudo ip netns exec fw conntrack -E | grep 10.40.0.2`

第 5 个终端触发访问：
```bash
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| ①   | remote wg0（出站） | 10.10.10.2 | 10.40.0.2 | TCP | 原始 HTTP 请求，准备进入隧道 |
| ②   | fw wg0（入站） | 10.10.10.2 | 10.40.0.2 | TCP | WireGuard 解封装后还原的内层包（外层 UDP 已被剥离） |
| ③   | fw veth-fw-dmz（转发） | 10.10.10.2 | 10.40.0.2 | TCP | 经防火墙路由和 FORWARD 规则放行后，从 DMZ 接口发出 |
| ④   | conntrack 事件 | 10.10.10.2 → 10.40.0.2 | (回程) 10.40.0.2 → 10.10.10.2 | TCP | 连接跟踪表记录该连接的状态变迁（SYN_SENT→ESTABLISHED等） |

### 包变化分析
remote 发出的原始 TCP 包被内核 WireGuard 模块加密并封装在 UDP 数据报中，通过 203.0.113.20 发往 203.0.113.1:51820。fw 收到 UDP 包后，WireGuard 模块解密并还原内层 TCP 包，然后根据路由表决定转发给 dmz。整个过程对上层应用透明。抓包中显示的源/目 IP 始终为内层地址，因为 tcpdump 在 WireGuard 接口上捕获的是解密后的明文包。conntrack 则记录了完整的连接状态，保证回程流量能自动匹配 `ESTABLISHED` 规则通过防火墙。

---

## 5.5 故障排查专题

以下三个故障均为实验过程中真实遇到的问题，体现了排查思路。

### 故障 1：DNAT 配置正确但外网无法访问 dmz 服务

**现象**：
`internet` 命名空间执行 `curl http://203.0.113.1:8080/` 超时，但 `dmz` 上服务正常，且 `iptables -t nat -L` 显示 DNAT 规则已存在。

**排查过程**：
1. 查看 FORWARD 规则计数器：`iptables -L FORWARD -nv`，发现 `internet->dmz:8080` 的 ACCEPT 规则 `pkts` 为 0，说明流量没有匹配该规则。
2. 在 fw 的 `veth-fw-inet` 接口抓包，能收到 SYN 包；在 `veth-fw-dmz` 接口无对应包，说明包在 FORWARD 链被丢弃。
3. 检查 FORWARD 默认策略为 DROP，且没有其他显式放行规则，导致 DNAT 后的流量被丢弃。

**根本原因**：DNAT 只转换目的地址，不自动开放防火墙过滤规则。必须同时添加 FORWARD 链的 ACCEPT 规则。

**修复方法**：
```bash
iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -j ACCEPT
```

**启示**：NAT 与防火墙策略独立，实施 DNAT 时务必成对配置 FORWARD 规则，否则形成“可见不可达”的安全假象。

---

### 故障 2：VPN 隧道握手正常但业务访问失败

**现象**：
`wg show` 显示握手成功、有数据传输，但 remote 无法 curl office 的 HTTP 服务（连接超时），fw 上也没有 REJECT 日志。

**排查过程**：
1. 检查 remote 路由表，确保 10.20.0.0/24 指向 wg0，正确。
2. 在 fw 上抓包 wg0 接口，能看到 remote 发来的 TCP SYN 包进入，但未从 veth-fw-office 发出，说明包在 FORWARD 链被拦截。
3. 查看 FORWARD 规则，发现 VPN→office 的 ACCEPT 规则条件较严格（`-s 10.10.10.2 -d 10.20.0.0/24 -i wg0 -o veth-fw-office -m conntrack --ctstate NEW`），但计数器为 1，而后续重试的包未被匹配，可能是连接跟踪状态判定问题。
4. 临时插入通用放行规则 `iptables -I FORWARD 16 -i wg0 -o veth-fw-office -j ACCEPT` 后，通信立即恢复。

**根本原因**：精确规则在内核协议栈处理时可能存在状态匹配差异，导致后续重传的 SYN 包被误判为非 NEW 状态而被拒绝。

**修复方法**：调整为更宽泛的接口匹配规则，并保持特定的拒绝规则（如针对 22 端口）放在宽泛规则之前，以兼顾安全。

**启示**：防火墙规则设计应遵循“先通后精”的原则，在保证基础连通性的前提下逐步收紧条件，遇到问题时通过抓包和临时放行来隔离问题点。

---

### 故障 3：移除 ESTABLISHED,RELATED 规则导致 TCP 连接失败

**现象**：
从 office 访问 dmz:8080，三次握手第一个 SYN 包能通过防火墙，但服务器回应 SYN-ACK 后连接无法建立，curl 最终超时。

**排查过程**：
1. 在 fw 上同时抓取 office 侧和 dmz 侧接口，发现 SYN 包从 office 进入并转发到 dmz，dmz 回复 SYN-ACK 返回 fw，但 SYN-ACK 没有从 veth-fw-office 发出。
2. 检查 FORWARD 规则，发现缺少 `ESTABLISHED,RELATED` 的状态检测规则，导致回程的 SYN-ACK 被默认策略 DROP 丢弃。

**根本原因**：iptables 是无状态过滤器，必须显式允许已建立连接的应答流量。移除状态检测后，只有 NEW 状态的包被放行，响应包被当作新连接处理而拒绝。

**修复方法**：在 FORWARD 链第一条添加 `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`。

**启示**：状态检测是双向通信的基础，无论防火墙策略如何设计，该规则都应作为第一条放行规则，否则任何 TCP 连接都无法完成。