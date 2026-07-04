# 故障排查报告

## 场景1：DNAT配置了但外网无法访问
### 故障重现
- **操作**：删除 FORWARD 链中 DNAT 对应的放行规则（行号 22）：
  ```bash
  sudo ip netns exec fw iptables -D FORWARD 22
  ```
验证故障：
```bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```
返回 curl: (28) Connection timed out，访问失败。

### 排查过程
1. `iptables -t nat -L PREROUTING` → 检查 DNAT 规则是否存在：
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
4. `tcpdump -i veth-fw-inet` → 在 veth-fw-inet 抓包：
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5 port 8080
```
看到 SYN 包到达，但无转发流量。

### 根本原因
DNAT 规则正确将目的地址转换为 10.40.0.2:8080，但 FORWARD 链缺少对应的 ACCEPT 规则，导致 DNAT 后的包被默认 DROP。

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
- 三次握手的第一个 SYN 包是 NEW 状态，能够被放行规则匹配并转发。

- 但服务器回应的 SYN-ACK 包既不是 NEW（它不是第一个包），也不是 ESTABLISHED（连接尚未完全建立），需要 RELATED 或 ESTABLISHED 状态检测才能放行。

- 缺少状态检测规则后，SYN-ACK 被默认 DROP，导致连接失败。

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
ESTABLISHED,RELATED规则允许已建立连接的回程流量通过，是实现“允许内部主动访问、限制外部主动连接”策略的基础。没有它，TCP 三次握手的后续数据包无法返回，所有需要回包的通信都将中断。同时，它也减少了显式放行规则的数量，简化了防火墙策略管理。

### 故障场景快速定位方法总结
| 场景 | 根本原因 | 快速定位方法 |
|------|----------|--------------|
| DNAT 不生效 | FORWARD 放行规则缺失 | `查 NAT 表` → `查 FORWARD 表` → `查 conntrack` → `抓包` |
| VPN 业务不通 | FORWARD 规则缺失 或 AllowedIPs 错误 | `查 wg show` → `查 ip route` → `查 iptables` → `抓包` |
| TCP 连接失败 | 缺少 ESTABLISHED,RELATED 状态检测 | `抓包对比请求/回包` → `查 conntrack` |
