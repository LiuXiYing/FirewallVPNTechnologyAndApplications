# 企业级网络安全架构故障排查报告

## 一、故障场景一：DNAT配置正常但无法访问DMZ

### 故障现象

Internet访问：

```bash
curl http://203.0.113.1:8080
```

连接失败。

DMZ中的HTTP服务正常运行，DNAT规则存在。

---

### 排查过程

#### （1）检查DNAT规则

```bash
iptables -t nat -L -n -v
```

确认DNAT规则正常。

#### （2）检查DMZ默认路由

```bash
ip route
```

确认默认网关正确。

#### （3）检查FORWARD规则

```bash
iptables -L FORWARD -n -v
```

发现没有允许Internet访问DMZ的FORWARD规则。

#### （4）抓包分析

```bash
tcpdump -ni veth-fw-inet
```

能够看到Internet数据包进入防火墙。

继续抓包：

```bash
tcpdump -ni veth-fw-dmz
```

没有数据包。

说明数据包已经完成DNAT，但没有继续转发。

---

### 根本原因

DNAT只修改目标地址，不负责放行数据。

由于FORWARD链没有对应规则，数据包被默认DROP。

---

### 修复方法

增加FORWARD规则：

```bash
iptables -A FORWARD \
-i veth-fw-inet \
-o veth-fw-dmz \
-p tcp --dport 8080 \
-j ACCEPT
```

再次访问恢复正常。

---

# 二、故障场景二：VPN握手成功但业务失败

### 故障现象

执行：

```bash
wg show
```

Handshake正常。

但是：

```bash
ping 10.40.0.2
```

无法访问。

---

### 原因一

AllowedIPs配置错误。

Remote端没有包含：

```text
10.40.0.0/24
```

导致DMZ流量没有进入VPN。

---

### 原因二

FORWARD规则缺失。

删除VPN访问DMZ规则后：

```bash
curl http://10.40.0.2:8080
```

连接超时。

日志显示：

```text
VPN-DENY
```

说明数据包已经进入FW，但是被iptables拒绝。

---

### 修复方法

恢复AllowedIPs：

```text
AllowedIPs=10.20.0.0/24,10.40.0.0/24
```

恢复FORWARD规则：

```bash
iptables -A FORWARD \
-i wg0 \
-o veth-fw-dmz \
-j ACCEPT
```

重新启动WireGuard后恢复正常。

---

# 三、故障场景三：删除ESTABLISHED,RELATED导致TCP连接失败

## 故障重现

删除状态检测规则：

```bash
iptables -D FORWARD \
-m conntrack \
--ctstate ESTABLISHED,RELATED \
-j ACCEPT
```

执行：

```bash
curl http://10.40.0.2:8080
```

连接超时。

---

## tcpdump抓包分析

在FW抓包：

```bash
tcpdump -ni any tcp port 8080
```

抓包结果：

```text
10.20.0.2 > 10.40.0.2 Flags [S]

10.40.0.2 > 10.20.0.2 Flags [S.]
```

能够看到：

- SYN正常发送；
- SYN-ACK已经返回；

但没有出现：

```text
ACK
```

说明SYN-ACK没有返回客户端。

证明服务器返回的数据包已经被防火墙拦截。

---

## conntrack分析

查看：

```bash
conntrack -L
```

连接状态一直停留：

```text
NEW

或

UNREPLIED
```

没有进入ESTABLISHED状态。

---

## 原因分析

客户端发出的SYN属于NEW连接，可以通过放行规则。

服务器返回SYN-ACK属于ESTABLISHED状态。

由于删除了：

```bash
-m conntrack --ctstate ESTABLISHED,RELATED
```

服务器返回的数据包没有任何允许规则，因此被FORWARD默认DROP。

最终导致TCP三次握手失败。

---

## 修复方法

恢复状态检测规则：

```bash
iptables -I FORWARD 1 \
-m conntrack \
--ctstate ESTABLISHED,RELATED \
-j ACCEPT
```

再次执行：

```bash
curl http://10.40.0.2:8080
```

网页恢复正常。

---

# 四、故障排查总结

本实验分别分析了DNAT访问失败、VPN握手成功但业务失败以及状态检测规则缺失导致TCP连接失败三种典型故障。

排查过程中主要使用了以下工具：

- iptables（检查防火墙规则）
- wg show（检查VPN状态）
- ip route（检查路由）
- tcpdump（抓包分析）
- conntrack（查看连接状态）
- journalctl（查看日志）

通过这些工具可以快速定位故障位置，分析数据包在网络中的转发过程，并准确找到问题根源。

本次实验不仅提高了Linux网络配置能力，也进一步理解了企业网络安全架构中路由、NAT、防火墙、VPN及状态检测之间的协同工作机制，为今后的网络安全实践积累了丰富经验。