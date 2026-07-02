# 攻防演练与故障排查分析报告

## 5.1 攻击方任务（从 guest 发起）

### 攻击 1：扫描 office 网段

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**结果：** 所有 ping 请求均失败，终端显示 `Destination Port Unreachable`。

**失败原因分析：**
guest 访问 office 网段的 ICMP 请求命中了防火墙 FORWARD 链中的 `GUEST-TO-OFFICE:` LOG 和 REJECT 规则。该规则对从 `veth-fw-guest` 进入、从 `veth-fw-office` 转发的数据包执行 REJECT，返回 ICMP 端口不可达报文。因此扫描者虽然无法获得 ping 通结果，但能收到不可达响应，证明目标网段存在。从日志中可以看到 `SRC=10.30.0.2`、`IN=veth-fw-guest`、`OUT=veth-fw-office` 和 `log-prefix="GUEST-TO-OFFICE:"` 等字段，明确标识攻击来源。

### 攻击 2：尝试绕过防火墙访问 dmz:22

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**结果：** 连接均被拒绝。

**失败原因分析：**
修改本地源端口为 80 或 443 无法改变数据包的方向属性。防火墙对 guest→dmz 的访问控制是基于网络接口方向（从 `veth-fw-guest` 进入、从 `veth-fw-dmz` 转发）和目的地址进行策略匹配，而不是基于 TCP 源端口。因此伪造源端口的 curl 请求仍然命中 `GUEST-TO-DMZ:` REJECT 规则，连接被立即拒绝。这说明防火墙的区域隔离策略不依赖高层端口特征，具有较强的抗绕过能力。

### 攻击 3：尝试伪造 VPN 流量

```bash
# 攻击者能否伪造源地址为 10.10.10.2 的包来访问内网？
```

**结果：** 不会成功。

**失败原因分析：**
虽然将源 IP 伪造为 VPN 地址 `10.10.10.2`，但数据包仍从 guest 接口进入防火墙，防火墙依据接口方向识别其属于 guest 区域，不会按 VPN 策略放行。同时 Linux 内核默认启用反向路径过滤（rp_filter），会丢弃源地址与入接口不符的数据包；即使包到达 dmz，回包也会发往真正的 VPN 接口，无法返回 guest。因此源地址伪造无法绕过基于接口方向的区域隔离。

### 回答：攻击者能否从 REJECT 和 DROP 的不同表现判断目标是否存在？

**答：** 可以。REJECT 会返回 ICMP 错误报文或 TCP RST，攻击者据此能判断目标主机或网络可达；DROP 则直接静默丢弃，攻击者无法区分是目标不存在、防火墙拦截还是路由不可达。因此 REJECT 会暴露目标存在的信息，DROP 的隐蔽性更强。本次实验使用 REJECT 是为了方便演示和验证，生产环境中对敏感资产通常使用 DROP。

---

## 5.2 防御方任务（日志分析与规则分析）

### 任务 1：从日志中识别攻击

```bash
sudo journalctl -k --since "10 minutes ago" --grep "GUEST-|VPN-|INET-" --no-pager
```

#### 问题 1：从日志的哪些字段可以判断这是来自 guest 的攻击？

**答：** 可以从三个字段判断：
- `SRC=10.30.0.2` 属于 guest 网段；
- `IN=veth-fw-guest` 表示数据包从 guest 接口进入防火墙；
- `log-prefix="GUEST-TO-OFFICE:"` 明确标识了这是 guest 访问 office 的违规事件。

这三个字段共同证明攻击来自 guest 区域。

#### 问题 2：如果日志中 `IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？

**答：** 说明数据包的方向是从 guest 区域进入防火墙，并试图转发到 office 区域。这违反了 guest 与 office 之间的隔离策略，属于跨区域未授权访问。防火墙已经拦截并记录该事件，是明显的安全告警。

#### 问题 3：为什么看到大量相同来源的日志应该引起警惕？

**答：** 短时间内出现大量相同 SRC、相同前缀的日志，通常意味着该源正在进行端口扫描、网络探测或暴力破解等攻击行为。这是明显的异常迹象，需要及时触发告警、封禁源 IP 并进一步审计。

### 任务 2：分析规则的防御效果

#### 问题 1：哪条规则拦截了 guest 访问 office？

**答：** 防火墙 FORWARD 链中匹配 `-i veth-fw-guest -o veth-fw-office` 的 REJECT 规则拦截了 guest 访问 office。它紧跟在对应的 LOG 规则之后，先记录后拒绝。可以通过 `sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers` 查看具体行号和计数器。

#### 问题 2：如果 guest→office 的规则计数很高，说明了什么？

**答：** 说明 guest 区域正在频繁尝试访问 office 区域，可能是扫描、探测或暴力破解攻击。高计数是异常行为的重要指标，需要进一步审计源 IP、目的端口和时间分布，必要时采取封禁或告警措施。

#### 问题 3：REJECT 和 DROP 在安全性上有什么区别？

**答：** REJECT 会返回 ICMP 错误报文或 TCP RST，攻击者能据此判断目标可达，只是被策略拒绝；DROP 则静默丢弃数据包，不返回任何信息，攻击者无法区分目标不存在、网络不可达还是被防火墙拦截。因此 DROP 的隐蔽性更好，但 REJECT 对合法用户更友好（不会等待超时）。

---

## 5.3 边界测试与改进方案

### 选择的问题：dmz:8080 对外开放，存在被 DDoS 攻击和 Web 漏洞利用的风险

### 风险分析（200 字）

dmz 的 8080 端口通过 DNAT 映射到防火墙公网口 `203.0.113.1:8080`，面向 internet 开放。虽然业务需要外网访问，但当前规则没有限制连接频率和并发连接数。攻击者可能对该端口发起 SYN Flood、HTTP Slowloris 或暴力扫描，导致服务不可用或泄露 Web 应用漏洞。一旦 dmz 的 Web 服务被攻破，攻击者可能进一步向内网横向移动。因此需要在防火墙上增加连接数限制和速率限制，降低 DDoS 和扫描风险。

### 改进方案实现代码

```bash
# 限制单 IP 对 dmz:8080 的并发连接数
sudo ip netns exec fw iptables -I FORWARD 1 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m conntrack --ctstate NEW \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset

# 限制单 IP 对 dmz:8080 的新建连接速率
sudo ip netns exec fw iptables -I FORWARD 1 \
  -p tcp --dport 8080 \
  -d 10.40.0.2 \
  -m conntrack --ctstate NEW \
  -m limit --limit 30/min --limit-burst 50 \
  -j ACCEPT

# 日志记录被限流的连接
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --dport 8080 \
  -d 10.40.0.2 \
  -m conntrack --ctstate NEW \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "DMZ-8080-RATE-LIMIT: "
```

### 测试效果

```bash
# 在 internet 命名空间发起大量并发连接
sudo ip netns exec internet bash -c 'for i in {1..20}; do curl -s http://203.0.113.1:8080/ & done; wait'

# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers

# 查看日志
sudo dmesg -T | grep DMZ-8080-RATE-LIMIT
```

预期效果：前 10 个并发连接正常，超出部分被 REJECT；新建连接速率超过 30/min 时也会被限制。

---

## 5.4 高级任务：追踪包的完整变化过程

### 任务：追踪一次 remote 通过 VPN 访问 dmz:8080 的完整过程

### 抓包命令

```bash
# 终端 1：remote 的 wg0 接口（看到封装前的包）
sudo ip netns exec remote tcpdump -ni wg0 -c 5

# 终端 2：fw 的 wg0 接口（看到解封装后的包）
sudo ip netns exec fw tcpdump -ni wg0 -c 5

# 终端 3：fw 的 veth-fw-dmz 接口（看到转发到 dmz 的包）
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5

# 终端 4：fw 的 conntrack 表
watch -n 1 'sudo ip netns exec fw conntrack -L | grep 10.10.10.2'

# 终端 5：触发访问
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 | 203.0.113.2:33666|203.0.113.1:51820 |UDP | 封装前 |
| 2 | fw wg0 |	10.10.10.2:34066 |10.40.0.2:8080 | TCP| 解封装后 |
| 3 | fw veth-fw-dmz |10.10.10.2:34066 |10.40.0.2:8080 |TCP | 转发到dmz |
| 4 | conntrack | 10.10.10.2:49012| 10.40.0.2:8080| TCP| 连接跟踪记录 |


### 分析报告（300 字）

当 remote 主机访问 dmz:8080 时，数据包首先经过 WireGuard 隧道封装。在 remote 的 wg0 接口上观察到的是 UDP 报文，源地址为 remote 公网 IP `203.0.113.20`，目的地址为防火墙公网 IP `203.0.113.1`，目的端口 `51820`，这正是 WireGuard 隧道的外层封装。
当数据包到达防火墙的 wg0 接口时，WireGuard 解封装后露出内层 TCP 报文。此时源地址变为 VPN 内网地址 `10.10.10.2`，目的地址为 dmz 主机 `10.40.0.2`，目的端口 `8080`。由于防火墙已开启 IP 转发，且 FORWARD 链允许 VPN 到 dmz 的流量，报文被转发至 `veth-fw-dmz` 接口。
在 fw 的 `veth-fw-dmz` 接口上，报文保持源地址 `10.10.10.2` 不变，直接发往 dmz 主机。这说明 VPN 访问没有再做 SNAT，dmz 看到的是真实的 VPN 内网地址。最后通过 conntrack 可以看到连接跟踪记录：`src=10.10.10.2 dst=10.40.0.2 sport=xxx dport=8080`，状态从 `SYN_SENT` 到 `ESTABLISHED` 再到 `TIME_WAIT`，表明 TCP 连接被正确记录和维护。整个过程验证了 VPN 隧道封装、解封装、策略转发和状态跟踪的协同工作。
