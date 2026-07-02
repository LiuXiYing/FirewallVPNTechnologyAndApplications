# 故障排查报告

## 场景1：DNAT配置了但外网无法访问
### 故障重现
- **操作**：本次模拟真实生产常见故障：DNAT 端口映射规则正常，但缺少配套转发放行策略。
手动删除外网访问 DMZ 8080 服务对应的 FORWARD 放行规则，制造阻断故障：
  ```bash
  sudo ip netns exec fw iptables -D FORWARD 22
  ```
随后在模拟外网 internet 节点发起访问测试：
```bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```
访问超时失败，返回错误：curl: (28) Connection timed out，网页提示解析失败、无法访问服务，外网用户无法通过公网地址访问内网 DMZ 业务。

### 排查过程
1. sudo ip netns exec fw iptables -D FORWARD 22 → 检查 DNAT 规则是否存在：
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v | grep 8080
```
输出：DNAT 规则仍在（tcp dpt:8080 to:10.40.0.2:8080）。
2. `iptables -L FORWARD` → 检查 FORWARD 链是否有对应放行规则：
```bash
sudo ip netns exec fw iptables -L FORWARD -n | grep "10.40.0.2:8080"
```
无输出，说明放行规则缺失。
3. `conntrack -L` → 查看 conntrack 表：
```bash
sudo ip netns exec fw conntrack -L -p tcp --dport 8080
```
看到 SYN 包到达，但无转发流量。

### 根本原因
PREROUTING 链 DNAT 可正常完成目的 IP 转换，将203.0.113.1:8080转为10.40.0.2:8080；但防火墙 FORWARD 链默认策略为 DROP，缺少外网访问 DMZ 8080 的放行规则，地址转换后的数据包直接被丢弃，无法抵达 DMZ 服务器。
### 修复
添加规则：`iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT`
- 验证：`curl` 成功返回页面。

```bash
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```
### 验证：
```bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```
成功返回 DMZ Web 服务页面。

### 如何快速定位
- 先查 NAT 表确认 DNAT 存在。
- 查 FORWARD 表确认放行规则。
- 查 conntrack确认是否有映射。
- 抓包确认包到达哪一层。

---

## 场景2：VPN隧道握手正常但业务访问失败
### 故障重现
- 操作：删除 VPN→office 放行规则（行号 17）：
```bash
sudo ip netns exec fw iptables -D FORWARD 17
```
- 验证故障：
```bash
sudo ip netns exec remote ping -c 2 10.20.0.2
```
输出：100% 丢包（Destination Port Unreachable 或超时）。

### 故障重现（原因2：AllowedIPs 配置错误）
- 操作：修改 remote 的 WireGuard 配置文件，删除 10.20.0.0/24：
```ini
AllowedIPs = 10.40.0.0/24
```

- 重启 WireGuard：
```bash
sudo ip netns exec remote wg-quick down /etc/wireguard/remote.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote.conf
```
- 验证故障：
```bash
sudo ip netns exec remote ping -c 2 10.20.0.2
```
输出：ping: connect: 网络不可达。


### 排查过程
1. 检查 VPN 握手状态（确认隧道正常）：
```bash
sudo ip netns exec remote wg show
```
显示 latest handshake: 26 seconds ago，传输统计正常。

2. 检查 FORWARD 规则：
```bash
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers | grep "10.20.0.0/24"
```
VPN→office 放行规则已缺失。

3. 检查 remote 路由（排除路由问题）：
```bash
sudo ip netns exec remote ip route | grep 10.20
```
输出：10.20.0.0/24 dev remote scope link，路由正常。

4. 在 fw 的 WireGuard 接口抓包：
```bash
sudo ip netns exec fw tcpdump -ni fw -c 5 icmp
```
看到 ICMP request 到达，但无 reply，说明包被 DROP。

### 排查与定位
- 检查 remote 路由表：
```bash
sudo ip netns exec remote ip route | grep 10.20
```
无输出，说明路由未添加。

- 检查 WireGuard 配置：
```bash
sudo cat /etc/wireguard/remote.conf | grep AllowedIPs
```
发现缺少 10.20.0.0/24。
### 修复方法
恢复 AllowedIPs = 10.20.0.0/24, 10.40.0.0/24，重启 WireGuard，路由自动添加，ping 恢复。

### 如何快速定位
- 查 wg show 确认握手正常
- 查 ip route 确认路由 
- 查 iptables -L 确认规则
- 抓包确认包到达哪一层。

### 根本原因
FORWARD 规则缺失，VPN 接口（fw）收到的包无法转发至 veth-fw-office。

### 修复方法
```bash
sudo ip netns exec fw iptables -A FORWARD -i fw -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
```
### 验证
```bash
sudo ip netns exec remote ping -c 2 10.20.0.2
```
成功收到回复。

---

## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败
### 故障重现
- 操作：删除状态检测规则（通常为 FORWARD 第一条）：
```bash
sudo ip netns exec fw iptables -D FORWARD 1
```
- 验证故障：
```bash
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
```
返回 curl: (28) Connection timed out，连接失败。


### 排查过程
- 在 fw 的 WireGuard 接口抓包（观察请求）：
```bash
sudo ip netns exec fw tcpdump -ni fw -c 10 port 8080
```
- 在 veth-fw-dmz 接口抓包（观察转发）：
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 port 8080
```
看到 SYN 包转发至 dmz，且 dmz 回复 SYN-ACK。
- 查看 conntrack 表：
```bash
sudo ip netns exec fw conntrack -L -p tcp --dport 8080
```
无连接状态记录，因为缺少状态检测，连接无法建立。

### 根本原因
- TCP 三次握手属于双向交互过程，防火墙必须依靠状态检测机制完成完整会话放行。外网访问 DMZ 的首个 SYN 数据包为 NEW 新建状态，可以被手动配置的业务放行规则匹配并正常转发至 DMZ 服务器。
- 但 DMZ 服务器回复的 SYN-ACK 响应包不属于新建连接报文，不再匹配 NEW 类型放行规则；且此时三次握手尚未完成，会话未进入完全 ESTABLISHED 状态。在缺少全局 ESTABLISHED,RELATED 状态放行规则的情况下，防火墙无法识别该响应包属于合法会话关联流量，最终被 FORWARD 默认 DROP 策略丢弃。
- 仅单向放行请求流量、阻断回程响应流量，导致 TCP 三次握手无法正常完成，客户端接收不到服务端回应，最终出现连接超时、网页解析失败的故障。这也证明了状态检测规则是 TCP 双向通信的核心前提，仅放行新建流量无法支撑完整网络通信。

### 用 tcpdump 证明 SYN-ACK 被拦截

| 抓包位置 | 结果 | 证明 |
|----------|------|------|
| `fw` 接口（请求方向） | 只看到 SYN 包 | 请求成功发出 |
| `veth-fw-dmz` 接口 | 看到 SYN + SYN-ACK | dmz 服务器已正常回复 |
| `fw` 接口（回程方向） | 未看到 SYN-ACK | 回包在 fw 处被拦截 |

---
### 修复方法
```bash
sudo ip netns exec fw iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```
验证：curl 成功返回页面。
### 必要性说明
ESTABLISHED,RELATED 状态放行规则是整个防火墙状态检测机制的核心基础规则，也是 TCP 双向通信能够正常工作的必要前提。TCP 通信基于三次握手实现，新建连接的首个 SYN 数据包属于 NEW 状态，可以依靠手动配置的业务放行规则匹配转发；但服务器返回的 SYN-ACK、ACK 等后续报文不属于新建连接，无法被业务放行规则匹配，同时连接尚未完全建立，也不属于严格意义上的 ESTABLISHED 状态，必须依靠 RELATED/ESTABLISHED 状态机制识别关联会话流量。
如果缺失该规则，防火墙默认会丢弃所有回应报文，导致三次握手无法完成，最终出现请求能发、回包不通、连接超时的故障。该规则实现了单向主动放行、回程自动放行的安全逻辑，仅允许内网合法主动发起的连接通行，拒绝外部陌生主动连接，完美契合最小权限安全原则。


