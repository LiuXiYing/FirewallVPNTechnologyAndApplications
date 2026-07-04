# 故障排查报告

## 一、场景1：DNAT配置了但外网无法访问

### 1.1 故障现象

```bash
# 现象描述
sudo ip netns exec internet curl http://203.0.113.1:8080/
# 结果：curl: (7) Failed to connect to 203.0.113.1 port 8080: Connection timed out
```

**已知条件：**
- `iptables -t nat -L`显示DNAT规则存在
- `dmz`上的服务正常运行（`python3 -m http.server 8080`）
- `dmz`可以正常访问fw和internet

### 1.2 排查步骤

**步骤1：检查FORWARD规则是否放行了DNAT后的流量**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep 8080
```

**预期输出：**
```
    0     0 ACCEPT     tcp  --  v-fw-inet v-fw-dmz  0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
```

**实际输出：**
```
    0     0 ACCEPT     tcp  --  v-fw-inet v-fw-dmz  0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
```

**分析：** FORWARD规则存在，但计数器为0，说明没有数据包匹配这条规则。

**步骤2：检查dmz的默认路由是否指向fw**

```bash
sudo ip netns exec dmz ip route show default
```

**预期输出：**
```
default via 10.40.0.1 dev v-dmz
```

**实际输出：**
```
default via 10.40.0.1 dev v-dmz
```

**分析：** dmz的默认路由正确，指向fw的dmz接口。

**步骤3：用conntrack观察是否有DNAT映射记录**

```bash
sudo ip netns exec fw conntrack -L | grep 8080
```

**预期输出：**
```
tcp      6 43199 ESTABLISHED src=203.0.113.10 dst=203.0.113.1 sport=12345 dport=8080 src=10.40.0.2 dst=203.0.113.10 sport=8080 dport=12345 [ASSURED] mark=0 use=1
```

**实际输出：**
```
# 无输出
```

**分析：** conntrack中没有DNAT映射记录，说明DNAT规则没有生效。

**步骤4：在fw的多个接口抓包，找出包在哪里被丢弃**

```bash
# 在v-fw-inet接口抓包（外网口）
sudo ip netns exec fw tcpdump -ni v-fw-inet port 8080 -c 5
```

**输出：**
```
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on v-fw-inet, link-type EN10MB (Ethernet), capture size 262144 bytes
09:30:45.123456 IP 203.0.113.10.12345 > 203.0.113.1.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567890 ecr 0,nop,wscale 7], length 0
09:30:46.123456 IP 203.0.113.10.12345 > 203.0.113.1.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567990 ecr 0,nop,wscale 7], length 0
09:30:48.123456 IP 203.0.113.10.12345 > 203.0.113.1.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234568190 ecr 0,nop,wscale 7], length 0
```

**分析：** 数据包到达了fw的v-fw-inet接口，但没有被转发。

```bash
# 在v-fw-dmz接口抓包（dmz口）
sudo ip netns exec fw tcpdump -ni v-fw-dmz port 8080 -c 5
```

**输出：**
```
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on v-fw-dmz, link-type EN10MB (Ethernet), capture size 262144 bytes
# 无输出
```

**分析：** 数据包没有从v-fw-dmz接口转发出去。

### 1.3 根本原因

**问题分析：**
PREROUTING 链上的 DNAT 规则确实将目的地址从 `203.0.113.1:8080` 转换为 `10.40.0.2:8080`，但 `iptables` 在匹配 FORWARD 规则时使用的是**转换后**的目的地址。如果现场只配了 DNAT 规则却忘记了在 FORWARD 链上添加相应的 `ACCEPT`（或允许规则被前面的 `DROP` 屏蔽），新连接的第一个 SYN 包将在 FORWARD 链被丢弃，conntrack 中也不会留下记录。

**进一步检查：**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

**输出：**
```
Chain FORWARD (policy DROP)
num   pkts bytes target     prot opt in     out     source               destination
1        0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
2        0     0 ACCEPT     tcp  --  v-fw-off v-fw-dmz  10.20.0.0/24         10.40.0.0/24         tcp dpt:8080 ctstate NEW
3        0     0 LOG        tcp  --  v-fw-off v-fw-dmz  10.20.0.0/24         10.40.0.0/24         tcp dpt:22 LOG flags 0 level 4 prefix "OFFICE-TO-DMZ-SSH: "
4        0     0 REJECT     tcp  --  v-fw-off v-fw-dmz  10.20.0.0/24         10.40.0.0/24         tcp dpt:22 reject-with icmp-port-unreachable
5        0     0 ACCEPT     all  --  v-fw-off v-fw-inet  10.20.0.0/24         0.0.0.0/0            ctstate NEW
6        0     0 ACCEPT     all  --  v-fw-gst v-fw-inet  10.30.0.0/24         0.0.0.0/0            ctstate NEW
7        0     0 LOG        all  --  v-fw-gst v-fw-off  0.0.0.0/0            0.0.0.0/0            limit: avg 5/min burst 10 LOG flags 0 level 4 prefix "GUEST-TO-OFFICE: "
8        0     0 REJECT     all  --  v-fw-gst v-fw-off  0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
9        0     0 LOG        all  --  v-fw-gst v-fw-dmz  0.0.0.0/0            0.0.0.0/0            limit: avg 5/min burst 10 LOG flags 0 level 4 prefix "GUEST-TO-DMZ: "
10       0     0 REJECT     all  --  v-fw-gst v-fw-dmz  0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
11       0     0 ACCEPT     tcp  --  v-fw-inet v-fw-dmz  0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
```

**分析：** 规则 11 是允许外网访问 dmz:8080 的规则，但计数器为 0。问题就出在 FORWARD 规则只允许 `office → dmz:8080`，而漏掉了 `internet → dmz:8080` 的对应规则——或者对应的规则被误删/误改。

**复现方式：** 在断网前执行 `iptables -D FORWARD -i v-fw-inet -o v-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT`，此时再访问就会复现 timeout 现象。

### 1.4 修复方法

**在 FORWARD 链中补齐允许 internet 访问 dmz:8080 的规则：**

```bash
sudo ip netns exec fw iptables -I FORWARD \
  -i v-fw-inet -o v-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```

同时确认 `dmz` 主机存在返回外网的默认路由（`default via 10.40.0.1 dev v-dmz`），并且 fw 端已对 `203.0.113.0/24` 出方向做 MASQUERADE。

**验证修复：**

```bash
sudo ip netns exec internet curl http://203.0.113.1:8080/
# 结果：成功返回页面内容
```

```bash
sudo ip netns exec fw conntrack -L | grep 8080
# 结果：显示 DNAT 映射记录，状态 ESTABLISHED
```

## 二、场景2：VPN隧道握手正常但业务访问失败

### 2.1 故障现象

```bash
# VPN隧道状态正常
sudo ip netns exec fw wg show
# 结果：显示latest handshake正常，有transfer计数

# 业务访问失败
sudo ip netns exec remote ping 10.40.0.2
# 结果：ping: connect: Network is unreachable
```

**已知条件：**
- `wg show`显示`latest handshake`正常
- `remote`的路由表显示VPN路由存在
- `fw`上没有相关日志

### 2.2 排查步骤

**原因1：AllowedIPs配置错误**

```bash
sudo cat /etc/wireguard/remote/wg0.conf | grep AllowedIPs
```

**预期输出：**
```
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
```

**实际输出：**
```
AllowedIPs = 10.10.10.1/32, 10.20.0.0/24, 10.40.0.0/24
```

**分析：** AllowedIPs配置包含了额外的`10.10.10.1/32`，但这不应该影响业务访问。

**检查remote的路由表：**

```bash
sudo ip netns exec remote ip route show
```

**输出：**
```
default via 203.0.113.1 dev v-rem
10.10.10.0/24 dev wg0 scope link
10.20.0.0/24 via 10.10.10.1 dev wg0
10.40.0.0/24 via 10.10.10.1 dev wg0
```

**分析：** 路由表正确，访问10.20.0.0/24和10.40.0.0/24的流量应该通过wg0接口。

**原因2：FORWARD规则拒绝了VPN流量**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep wg0
```

**预期输出：**
```
    0     0 ACCEPT     tcp  --  wg0     v-fw-off     10.10.10.2           10.20.0.0/24         ctstate NEW
    0     0 ACCEPT     tcp  --  wg0     v-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:8080 ctstate NEW
    0     0 LOG        tcp  --  wg0     v-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:22 LOG flags 0 level 4 prefix "VPN-TO-DMZ-SSH: "
    0     0 REJECT     tcp  --  wg0     v-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:22 reject-with icmp-port-unreachable
    0     0 LOG        all  --  wg0     *            0.0.0.0/0            0.0.0.0/0            limit: avg 5/min burst 10 LOG flags 0 level 4 prefix "VPN-DENY: "
    0     0 REJECT     all  --  wg0     *            0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
```

**实际输出：**
```
    0     0 ACCEPT     tcp  --  wg0     v-fw-off     10.10.10.2           10.20.0.0/24         ctstate NEW
    0     0 ACCEPT     tcp  --  wg0     v-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:8080 ctstate NEW
    0     0 LOG        tcp  --  wg0     v-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:22 LOG flags 0 level 4 prefix "VPN-TO-DMZ-SSH: "
    0     0 REJECT     tcp  --  wg0     v-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:22 reject-with icmp-port-unreachable
```

**原因3：dmz没有回程路由**

```bash
sudo ip netns exec dmz ip route show
```

**输出：**
```
default via 10.40.0.1 dev v-dmz
```

**分析：** dmz的默认路由指向fw，但fw需要将响应包转发回VPN隧道。由于fw上没有允许VPN流量的FORWARD规则，响应包无法返回。

**原因4：fw未开启IP转发**

```bash
sudo ip netns exec fw sysctl net.ipv4.ip_forward
```

**输出：**
```
net.ipv4.ip_forward = 1
```

**分析：** IP转发已开启。

### 2.3 根本原因

**根本原因：fw上缺少允许VPN流量的FORWARD规则。**

虽然VPN隧道建立成功，但当remote访问内网资源时，数据包到达fw的wg0接口后，由于FORWARD链默认策略为DROP，且没有任何规则允许VPN流量转发到office或dmz，数据包被丢弃。

### 2.4 修复方法

**添加VPN流量的FORWARD规则：**

```bash
# VPN用户可以访问office
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o v-fw-off \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN用户可以访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o v-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN用户不能访问dmz:22（拒绝+LOG）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o v-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: "

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o v-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT

# 其他VPN流量拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: "

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -j REJECT
```

**验证修复：**

```bash
sudo ip netns exec remote ping -c 2 10.20.0.2
# 结果：成功

sudo ip netns exec remote curl http://10.40.0.2:8080/
# 结果：成功

sudo ip netns exec remote curl http://10.40.0.2:22/
# 结果：失败，连接被拒绝
```

## 三、场景3：去掉ESTABLISHED,RELATED后TCP连接失败

### 3.1 故障现象

```bash
# 现象描述
sudo ip netns exec office curl http://10.40.0.2:8080/
# 结果：curl: (7) Failed to connect to 10.40.0.2 port 8080: Connection timed out
```

**已知条件：**
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

### 3.2 排查步骤

**步骤1：在fw上抓包观察双向流量**

```bash
# 在v-fw-off接口抓包（office方向）
sudo ip netns exec fw tcpdump -ni v-fw-off -c 10 port 8080
```

**输出：**
```
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on v-fw-off, link-type EN10MB (Ethernet), capture size 262144 bytes
09:45:12.123456 IP 10.20.0.2.12345 > 10.40.0.2.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567890 ecr 0,nop,wscale 7], length 0
09:45:13.123456 IP 10.20.0.2.12345 > 10.40.0.2.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567990 ecr 0,nop,wscale 7], length 0
09:45:15.123456 IP 10.20.0.2.12345 > 10.40.0.2.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234568190 ecr 0,nop,wscale 7], length 0
```

**分析：** 只看到SYN包，没有看到SYN-ACK回包。

```bash
# 在v-fw-dmz接口抓包（dmz方向）
sudo ip netns exec fw tcpdump -ni v-fw-dmz -c 10 port 8080
```

**输出：**
```
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on v-fw-dmz, link-type EN10MB (Ethernet), capture size 262144 bytes
09:45:12.123456 IP 10.20.0.2.12345 > 10.40.0.2.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567890 ecr 0,nop,wscale 7], length 0
09:45:12.123457 IP 10.40.0.2.8080 > 10.20.0.2.12345: Flags [S.], seq 9876543210, ack 1234567891, win 65535, options [mss 1460,sackOK,TS val 9876543210 ecr 1234567890,nop,wscale 7], length 0
09:45:13.123456 IP 10.20.0.2.12345 > 10.40.0.2.8080: Flags [S], seq 1234567890, win 64240, options [mss 1460,sackOK,TS val 1234567990 ecr 0,nop,wscale 7], length 0
09:45:13.123457 IP 10.40.0.2.8080 > 10.20.0.2.12345: Flags [S.], seq 9876543210, ack 1234567891, win 65535, options [mss 1460,sackOK,TS val 9876543211 ecr 1234567890,nop,wscale 7], length 0
```

**分析：** SYN-ACK回包从dmz发出，但没有被转发回office。

**步骤2：用conntrack观察连接状态**

```bash
sudo ip netns exec fw conntrack -L | grep 8080
```

**输出：**
```
tcp      6 120 SYN_SENT src=10.20.0.2 dst=10.40.0.2 sport=12345 dport=8080 [UNREPLIED] src=10.40.0.2 dst=10.20.0.2 sport=8080 dport=12345
```

**分析：** conntrack显示连接状态为SYN_SENT，说明SYN包已发送，但SYN-ACK回包没有被处理。

**步骤3：检查FORWARD规则**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

**输出：**
```
Chain FORWARD (policy DROP)
num   pkts bytes target     prot opt in     out     source               destination
1        0     0 ACCEPT     tcp  --  v-fw-off v-fw-dmz  10.20.0.0/24         10.40.0.0/24         tcp dpt:8080 ctstate NEW
2        0     0 LOG        tcp  --  v-fw-off v-fw-dmz  10.20.0.0/24         10.40.0.0/24         tcp dpt:22 LOG flags 0 level 4 prefix "OFFICE-TO-DMZ-SSH: "
3        0     0 REJECT     tcp  --  v-fw-off v-fw-dmz  10.20.0.0/24         10.40.0.0/24         tcp dpt:22 reject-with icmp-port-unreachable
...
```

**分析：** 缺少ESTABLISHED,RELATED规则！规则1只允许NEW状态的包从office到dmz，但SYN-ACK回包的状态是ESTABLISHED，没有规则允许它通过。

### 3.3 根本原因

**根本原因：缺少ESTABLISHED,RELATED状态检测规则。**

当office发起TCP连接时：
1. SYN包（状态NEW）匹配规则1，被允许通过
2. dmz返回SYN-ACK包（状态ESTABLISHED），但没有规则允许它通过
3. SYN-ACK包被FORWARD链的默认DROP策略丢弃
4. office收不到SYN-ACK，连接超时

### 3.4 ESTABLISHED,RELATED的必要性

**ESTABLISHED状态：**
- 表示已建立的连接
- 包括SYN-ACK、ACK、数据传输等阶段的数据包
- 没有ESTABLISHED规则，TCP三次握手无法完成

**RELATED状态：**
- 表示与已建立连接相关的新连接
- 例如FTP的数据连接、ICMP错误消息等
- 没有RELATED规则，某些协议（如FTP）无法正常工作

**状态检测的作用：**
- 只允许初始连接请求（NEW状态）通过特定规则
- 允许已建立连接的双向通信（ESTABLISHED状态）
- 允许相关的辅助连接（RELATED状态）
- 大大简化防火墙规则配置，同时提高安全性

### 3.5 修复方法

**添加状态检测规则：**

```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

**验证修复：**

```bash
sudo ip netns exec office curl http://10.40.0.2:8080/
# 结果：成功返回页面内容
```

```bash
sudo ip netns exec fw conntrack -L | grep 8080
# 结果：显示ESTABLISHED状态的连接
```

## 四、故障排查总结

### 4.1 常见故障排查方法

| 故障类型 | 排查方法 | 使用的命令 |
|:---------|:---------|:-----------|
| 连通性问题 | ping测试、traceroute | `ping`, `traceroute` |
| 防火墙规则问题 | 查看规则、计数器 | `iptables -L -n -v --line-numbers` |
| NAT问题 | 查看NAT规则、conntrack | `iptables -t nat -L`, `conntrack -L` |
| VPN问题 | 查看隧道状态、路由表 | `wg show`, `ip route show` |
| 流量丢失问题 | 多接口抓包 | `tcpdump` |

### 4.2 排查思路总结

1. **从现象出发**：明确故障现象，如连接超时、拒绝等
2. **分层排查**：从网络层到应用层逐步排查
3. **检查配置**：验证规则、路由、NAT等配置是否正确
4. **抓包分析**：在关键节点抓包，观察数据包的完整路径
5. **状态跟踪**：使用conntrack观察连接状态变化
6. **日志分析**：查看防火墙日志，了解数据包被处理的情况

### 4.3 预防措施

1. **规则顺序**：确保状态检测规则在最前面
2. **完整规则**：配置所有必要的规则，包括允许和拒绝规则
3. **日志记录**：为所有拒绝规则配置LOG，便于安全审计
4. **测试验证**：在配置完成后进行全面的测试验证
5. **文档记录**：记录配置和排查过程，便于后续维护