# 攻防演练分析报告

## 1. 攻击方演练（从guest发起）
### 攻击1：扫描office网段
- 命令：
```bash
  - `for i in {1..10}; do sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"; done`
  ```
- 输出摘要
  - `10.20.0.1` 有回复（因为该 IP 是 fw 的 office 接口，且 INPUT 链放行了 ICMP）。
  - `10.20.0.2` ~ `10.20.0.10` 均返回 `Destination Port Unreachable`（来自网关 10.30.0.1）。

- **原因分析**：攻击者无法通过 ICMP 探测内网存活主机，因为防火墙对 guest→office 流量实施了区域隔离。即使网关可通，也无法进一步扫描，有效保护了内网拓扑信息。

### 攻击2：改变源端口尝试绕过
- 命令
 ```bash
  sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
  sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/ 
  ```
- 输出摘要：
 两次均返回 curl: (7) Failed to connect to 10.40.0.2 port 22（超时）
- **原因分析**：防火墙规则基于目标端口和区域进行过滤，源端口不在匹配条件中。因此，攻击者无法通过改变源端口绕过访问控制，该防御策略有效。

### 攻击3：伪造VPN源地址
- **命令（模拟）**：
  ```bash
  # 假设攻击者在 guest 命名空间尝试伪造
  sudo ip netns exec guest ping -c 1 -I 10.10.10.2 10.20.0.2
  ```
- 输出：无响应（超时或被拒绝）
- **结论**：不能成功。攻击者无法通过伪造 VPN 源地址访问内网。

- **原因**：防火墙的 FORWARD 规则对 VPN 流量做了双重限制：不仅要求源 IP 为 10.10.10.2，还要求入接口必须是 WireGuard 接口（即 fw）。攻击者从 guest 或 internet 发送伪造包时，入接口为 veth-fw-guest 或 veth-fw-inet，与规则不匹配，因此不会触发放行规则。这些包会被默认 DROP 或后续 REJECT 规则拦截。即使有状态检测（ESTABLISHED,RELATED）也无法放行，因为这不是已建立连接的一部分。因此，伪造 VPN 源地址无法绕过基于接口的访问控制。

### REJECT vs DROP 的识别差异
| 行为 | 响应 | 攻击者判断 |
|------|------|------------|
| REJECT | 返回 ICMP 不可达或 TCP RST | 可判断目标端口存在（或防火墙存在），有助于端口扫描 |
| DROP | 静默丢弃，无任何响应 | 难以区分“端口关闭”与“被过滤”，信息隐藏能力更强 |

**结论**：生产环境推荐使用 DROP，以减少信息泄露风险。



## 2. 防御方分析
### 日志分析（虽未持久化，但规则计数器可用）
- 从 `iptables -L -v` 可见：
```bash
guest→office 拒绝规则（REJECT） pkts = 19

guest→dmz 拒绝规则（REJECT） pkts = 5

internet→office 拒绝规则（REJECT） pkts = 1

VPN→dmz:22 拒绝规则（REJECT） pkts = 17

VPN→office 放行规则（ACCEPT） pkts = 5
```

- **结论**：防火墙成功拦截所有违规访问，计数器证明规则生效。

**1. 从日志的哪些字段可以判断这是来自 guest 的攻击？**
通过 `IN=veth-fw-guest`（入口接口）和 `SRC=10.30.0.x`（源 IP）字段，可识别流量来源于 guest 区域。前缀如 `GUEST-TO-OFFICE` 直接标识违规类型。

**2. 如果日志中 `IN=veth-fw-guest OUT=veth-fw-office` 说明了什么？**
说明流量来自 guest 区，企图转发至 office 区，但被防火墙拦截（匹配了 guest→office 的 REJECT 规则）。这代表 guest 正在尝试违规访问内部办公网络。

**3. 为什么看到大量相同来源的日志应该引起警惕？**
大量重复日志说明源 IP 可能正在执行自动化扫描或暴力破解，试图寻找漏洞或突破访问控制，应视为攻击行为，需及时响应（如封禁 IP、增强监控）。

### 规则分析
- guest→office 的高计数（19 个包）表明存在持续的扫描或探测行为，应引起警惕并考虑自动封禁。

- VPN→dmz:22 的 17 个包表示远程用户多次尝试 SSH 连接，被及时阻断。

- internet→office 的 1 个包说明外网也有探测，但被立即拒绝。



## 3. 边界测试改进方案
- **选择问题**：DMZ Web 服务（8080 端口）对外开放，存在被 DDoS 攻击或漏洞利用的风险。
- **改进措施**：使用 connlimit 模块限制每个源 IP 对 10.40.0.2:8080 的最大并发连接数为 10。
- **规则**（已插入FORWARD链首）：
 ```bash
 sudo ip netns exec fw iptables -I FORWARD 1 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
 ```
- **测试**：
  执行并发连接测试（12 个并发 curl）：
```bash
for i in {1..12}; do
  sudo ip netns exec remote curl -s -o /dev/null -w "conn $i: %{http_code}\n" http://10.40.0.2:8080/ &
done
wait
```
预期输出：
```bash
conn 1: 200
conn 2: 200
...
conn 10: 200
conn 11: 000  (被拒绝)
conn 12: 000  (被拒绝)
```
结论：connlimit 规则生效，单 IP 并发连接超过 10 时后续连接被拒绝，有效防止连接资源耗尽。

## 4. 高级任务：包追踪分析

### 包变化对比表
| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 |10.10.10.2:50564 |10.40.0.2:8080 |TCP | 封装前 |
| 2 | fw wg0 |10.10.10.2:50564 |10.40.0.2:8080 |TCP | 解封装后 |
| 3 | fw veth-fw-dmz |10.10.10.2:50564 | 10.40.0.2:8080|TCP | 转发到dmz |
| 4 | conntrack |10.10.10.2:50564 → 10.40.0.2:8080 |10.40.0.2:8080 → 10.10.10.2:50564|TCP | 连接跟踪记录 |

### 分析报告
包从 remote 的 wg0 接口发出时，是原始的 HTTP 请求（源 IP 10.10.10.2，目标 10.40.0.2:8080）。WireGuard 在 IP 层加密后，封装为 UDP 包通过 veth-remote 发送到 fw。fw 的 wg0 接口收到后解密，还原为原始包，进入 FORWARD 链。防火墙匹配 VPN→dmz:8080 放行规则，将包从 veth-fw-dmz 转发至 dmz 主机。dmz 回复的包经同一路径返回，conntrack 表记录了整个会话状态，确保回包被正确关联。整个过程体现了 VPN 隧道封装、防火墙策略匹配和状态跟踪的协同工作。