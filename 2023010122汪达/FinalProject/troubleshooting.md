# 故障排查报告

## 场景1：DNAT配置了但外网无法访问

### 故障重现

**操作**：删除 FORWARD 链中 DNAT 对应的放行规则

```bash
sudo ip netns exec fw iptables -D FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null
验证故障：

bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
返回 curl: (28) Connection timed out，访问失败。

排查过程
1. 检查 DNAT 规则是否存在

bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v | grep 8080
输出：DNAT 规则仍在（tcp dpt:8080 to:10.40.0.2:8080）。

2. 检查 FORWARD 链是否有对应放行规则

bash
sudo ip netns exec fw iptables -L FORWARD -n | grep "10.40.0.2"
无输出，说明放行规则缺失。

3. 查看 conntrack 表

bash
sudo ip netns exec fw conntrack -L -p tcp --dport 8080
无记录，说明包未到达 DNAT 阶段或被丢弃。

4. 在 veth-fw-inet 抓包

bash
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5 port 8080
看到 SYN 包到达，但无转发流量。

根本原因
DNAT 规则正确将目的地址转换为 10.40.0.2:8080，但 FORWARD 链缺少对应的 ACCEPT 规则，导致 DNAT 后的包被默认 DROP。

修复方法
添加 FORWARD 放行规则：

bash
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
验证
bash
sudo ip netns exec internet curl -s -o /dev/null -w "HTTP状态: %{http_code}\n" --max-time 3 http://203.0.113.1:8080/
成功返回 HTTP状态: 200。

如何快速定位
步骤	命令	判断
1. 查 NAT 表	iptables -t nat -L PREROUTING	确认 DNAT 存在
2. 查 FORWARD 表	iptables -L FORWARD	确认放行规则缺失
3. 查 conntrack	conntrack -L	确认无映射记录
4. 抓包	tcpdump -i veth-fw-inet	确认包在哪层丢弃
场景2：VPN隧道握手正常但业务访问失败
故障重现（原因1：FORWARD 规则缺失）
操作：删除 VPN→dmz 的 FORWARD 放行规则

bash
sudo ip netns exec fw iptables -D FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null
验证故障：

bash
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
返回 curl: (28) Connection timed out，访问失败。

故障重现（原因2：AllowedIPs 配置错误）
操作：修改 remote 的 WireGuard 配置，删除 10.40.0.0/24

bash
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24
验证故障：

bash
sudo ip netns exec remote ping -c 2 10.40.0.2
输出：100% packet loss。

排查过程
1. 检查 VPN 握手状态（确认隧道正常）

bash
sudo ip netns exec remote wg show
显示 latest handshake: 26 seconds ago，传输统计正常。

2. 检查 remote 路由表（排除路由问题）

bash
sudo ip netns exec remote ip route | grep 10.40
原因1：路由存在（10.40.0.0/24 dev wg0 scope link）

原因2：路由缺失（无输出）

3. 检查 FORWARD 规则

bash
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers | grep -E "wg0|10.40.0"
无输出，说明 FORWARD 放行规则缺失。

4. 检查防火墙日志

bash
sudo dmesg | grep "VPN-DENY" | tail -3
显示 VPN 流量被 DENY 规则拦截。

根本原因
原因1：FORWARD 规则缺失，VPN 接口（wg0）收到的包无法转发至 veth-fw-dmz。

原因2：AllowedIPs 配置错误，remote 端未将 10.40.0.0/24 加入 VPN 路由。

修复方法
修复原因1：

bash
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
修复原因2：

bash
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24,10.40.0.0/24
验证
bash
sudo ip netns exec remote curl -s -o /dev/null -w "HTTP状态: %{http_code}\n" http://10.40.0.2:8080/
成功返回 HTTP状态: 200。

两种原因快速定位对比
故障原因	特征	排查命令	快速定位
AllowedIPs 配置错误	wg show 正常，路由缺失	ip route | grep 10.40	路由表中无目标网段
FORWARD 规则缺失	wg show 正常，路由正常	iptables -L FORWARD	无匹配的 ACCEPT 规则
场景3：去掉ESTABLISHED,RELATED后TCP连接失败
故障重现
操作：删除状态检测规则（FORWARD 第一条）

bash
sudo ip netns exec fw iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
验证故障：

bash
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/
返回 curl: (28) Connection timed out，连接失败。

排查过程
1. 在 wg0 接口抓包（观察请求）

bash
sudo ip netns exec fw tcpdump -ni wg0 -c 10 port 8080
看到 SYN 包发出，但无 SYN-ACK 返回。

2. 在 veth-fw-dmz 接口抓包（观察转发）

bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 port 8080
看到 SYN 包到达 dmz，且 dmz 回复 SYN-ACK。

3. 查看 conntrack 表

bash
sudo ip netns exec fw conntrack -L -p tcp --dport 8080
无连接状态记录。

用 tcpdump 证明 SYN-ACK 被拦截
抓包位置	结果	证明
wg0 接口（请求方向）	只看到 SYN 包	请求成功发出
veth-fw-dmz 接口	看到 SYN + SYN-ACK	dmz 服务器已正常回复
wg0 接口（回程方向）	未看到 SYN-ACK	回包在 fw 处被拦截
根本原因
三次握手的第一个 SYN 包是 NEW 状态，能够被放行规则匹配并转发。

服务器回应的 SYN-ACK 包既不是 NEW（它是第二个包），也不是 ESTABLISHED（连接尚未完全建立），需要状态检测才能放行。

缺少状态检测规则后，SYN-ACK 被默认 DROP，导致连接失败。

修复方法
bash
sudo ip netns exec fw iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
验证
bash
sudo ip netns exec remote curl -s -o /dev/null -w "HTTP状态: %{http_code}\n" http://10.40.0.2:8080/
成功返回 HTTP状态: 200。

必要性说明
ESTABLISHED,RELATED 规则允许已建立连接的回程流量通过，是实现"允许内部主动访问、限制外部主动连接"策略的基础。没有它，TCP 三次握手的后续数据包无法返回，所有需要回包的通信都将中断。同时，它也减少了显式放行规则的数量，简化了防火墙策略管理，提升了转发性能。

故障场景快速定位方法总结
场景	根本原因	快速定位方法
DNAT 不生效	FORWARD 放行规则缺失	查 NAT 表 → 查 FORWARD 表 → 查 conntrack → 抓包
VPN 业务不通（原因1）	FORWARD 规则缺失	查 wg show → 查 iptables → 查日志
VPN 业务不通（原因2）	AllowedIPs 配置错误	查 wg show → 查 ip route → 查配置
TCP 连接失败	缺少 ESTABLISHED,RELATED 状态检测	抓包对比请求/回包 → 查 conntrack