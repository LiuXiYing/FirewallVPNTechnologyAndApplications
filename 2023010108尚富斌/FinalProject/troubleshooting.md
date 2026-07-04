# 故障排查报告

**实验名称**：企业级网络安全架构搭建与攻防演练  
**实验人**：2023010108 尚富斌  
**实验日期**：2026年6月29日


## 场景1：DNAT配置了但外网无法访问

### 现象

- 从 `internet` 命名空间访问 `http://203.0.113.1:8080/` 返回：

```text
curl: (7) Failed to connect to 203.0.113.1 port 8080 after 0 ms: Could not connect to server
```
dmz 上的 Web 服务正常运行：
```bash
sudo ip netns exec dmz ss -tulpn | grep 8080
# 输出：tcp LISTEN 0 5 0.0.0.0:8080 0.0.0.0:* users:(("python3",pid=31246,fd=3))
```
DNAT 规则在 iptables -t nat -L PREROUTING 中存在，但 pkts=0

### 排查步骤
#### 步骤1：检查 DNAT 规则是否命中
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers
```
输出显示 DNAT 规则存在，但 pkts=0，说明没有数据包匹配该规则。

#### 步骤2：在 veth-fw-inet 接口抓包
``` bash
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5
```
抓包显示来自 internet 的 SYN 包到达 fw，但未进入 FORWARD 链。

#### 步骤3：检查 FORWARD 链规则
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep 8080
```
发现 FORWARD 放行规则存在，但 pkts=0，说明包未到达 FORWARD。

#### 步骤4：检查 DNAT 目标地址
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v
```
发现 DNAT 规则中的目标地址为 10.40.0.1（网关），而非 10.40.0.2（dmz 主机）。

#### 根本原因
DNAT 规则中 --to-destination 参数配置错误，将目标 IP 设为网关地址。

#### 修复方法
```bash
# 删除错误规则
sudo ip netns exec fw iptables -t nat -D PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.1

# 添加正确规则
sudo ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2
```
验证：
```bash
sudo ip netns exec internet curl -s -o /dev/null -w "%{http_code}\n" http://203.0.113.1:8080/
# 输出：200
```
![故障排查-DNAT](screenshots/19-troubleshoot-dnat.png)
#### 排查思路总结
检查规则是否命中（pkts 计数器）

抓包确认包到达哪个环节

检查规则参数是否正确

修复后验证

## 场景2：VPN隧道握手正常但业务访问失败
### 现象
wg show 显示 latest handshake，transfer 有少量数据

remote 无法访问 10.40.0.2:8080，curl 超时：

```text
curl: (7) Failed to connect to 10.40.0.2 port 8080 after 0 ms: Could not connect to server
```
fw 的 FORWARD 规则中存在放行 VPN → dmz:8080 的规则

### 排查步骤
#### 步骤1：检查 remote 路由表
```bash
sudo ip netns exec remote ip route | grep wg0
```
输出只有 10.20.0.0/24 dev wg0，缺少 10.40.0.0/24。

#### 步骤2：检查 remote 的 WireGuard 配置文件
```bash
sudo cat /etc/wireguard/remote/wg0.conf | grep AllowedIPs
```
输出：
```test
AllowedIPs = 10.20.0.0/24
```
确认 10.40.0.0/24 被移除。

#### 步骤3：验证流量走向
```bash
sudo ip netns exec remote traceroute -n 10.40.0.2
```
发现包走默认网关 203.0.113.11（internet），而非 wg0。

#### 步骤4：检查 internet 命名空间的转发策略
```bash
sudo ip netns exec internet iptables -L FORWARD -n -v --line-numbers | grep 10.40
```
输出：
```test
1    1    60 REJECT    all -- *    203.0.113.12    10.40.0.0/24    reject-with icmp-port-unreachable
```
确认之前为测试截图20添加的阻断规则仍然存在。

### 根本原因
#### 直接原因：AllowedIPs 配置错误，缺少 10.40.0.0/24

#### 间接原因：在 internet 上添加的阻断规则进一步加剧了故障

### 修复方法
```bash
# 恢复 AllowedIPs
sudo cp /etc/wireguard/remote/wg0.conf.bak /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

# 删除 internet 上的阻断规则（若有）
sudo ip netns exec internet iptables -D FORWARD -s 203.0.113.12 -d 10.40.0.0/24 -j REJECT
```
验证：
```bash
sudo ip netns exec remote curl -s -o /dev/null -w "%{http_code}\n" http://10.40.0.2:8080/
# 输出：200
```
**测试截图**：
![故障排查-VPN](screenshots/20-troubleshoot-vpn.png)
### 排查思路总结
检查 VPN 隧道状态（wg show）

检查客户端路由表

检查 WireGuard 配置文件（AllowedIPs）

检查中间网络设备的转发策略
## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败
现象
TCP 三次握手的第一个 SYN 包能通过防火墙

服务器回应的 SYN-ACK 包被防火墙拦截

curl 命令最终超时：
```test
curl: (28) Connection timed out after 2002 milliseconds
```
FORWARD 链中存在显式放行 NEW 连接的规则，但无状态检测规则

### 排查步骤
#### 步骤1：在 fw 上抓包
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 10
```
发现客户端 SYN 到达 dmz，但 dmz 的 SYN-ACK 到达 fw 后没有继续转发。

#### 步骤2：检查 conntrack 表
```bash
sudo ip netns exec fw conntrack -L | grep 10.40.0.2
```
连接状态为 NEW，但没有更新为 ESTABLISHED。

#### 步骤3：检查 FORWARD 规则
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
发现规则中缺少：
```test
-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```
导致 SYN-ACK 包（属于 ESTABLISHED 状态）不匹配任何 ACCEPT 规则，最终被默认 DROP 策略丢弃。

### 根本原因
缺少状态检测规则（ESTABLISHED,RELATED），导致已建立连接的回包无法被放行。

### 修复方法
```bash
# 将状态检测规则插入到 FORWARD 链最前面
sudo ip netns exec fw iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```
验证：
```bash
sudo ip netns exec office curl -s -o /dev/null -w "%{http_code}\n" http://10.40.0.2:8080/
# 输出：200
```
ESTABLISHED,RELATED 的必要性
状态检测规则确保已建立连接的回包被放行，是防火墙正确工作的基础。没有它，TCP 三次握手的 SYN-ACK 包会被 DROP，所有 TCP 连接都会失败。

## 总结
通用排查思路
| 步骤 | 操作 | 目的 |
|---|---|---|
| 1    | 确认现象 | 明确故障表现（访问失败、超时、拒绝等） |
| 2    | 查看规则计数器 | iptables -L -v -n 看哪些规则命中，哪些为 o |
| 3    | 抓包分析 | 在关键接口抓包，定位数据包在哪个环节丢失 |
| 4    | 检查路由表 | 确认包的路由走向是否正确 |
| 5    | 检查 conntrack | 查看连接跟踪状态，辅助判断状态检测是否生效 |
| 6    | 逐步修复 | 从原因入手，逐一修复并验证 |
### ss预防措施建议
脚本化配置：将防火墙规则写入脚本，避免手动输入错误

规则备份：修改前备份当前规则，便于快速回滚

灰度验证：修改规则后，先用小流量测试验证

定期审计：定期 review 防火墙规则，确保符合安全策略

监控告警：对关键规则配置计数器监控，异常时触发告警