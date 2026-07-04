# 期末大作业：企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：VMware Workstation 虚拟机 Kali Linux 2025.2 (amd64)
- WireGuard版本：wireguard-tools v1.0.20210914
- iptables版本：iptables v1.8.13 (nf_tables)

---


## 二、拓扑图和地址规划
## 网络拓扑
![](topology.png)

## 地址规划表：

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |


---

## 三、第一部分：网络规划与基础搭建

 ### 1.拓扑搭建步骤说明
1.1清理旧环境
删除可能存在的同名网络命名空间（fw, office, guest, dmz, internet, remote），避免重复运行冲突。

1.2创建六个网络命名空间
使用 ip netns add 创建防火墙（fw）、办公区（office）、访客区（guest）、DMZ区（dmz）、互联网（internet）和远程区（remote，此部分当前未连接，保留备用）。
``` bash
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
```

1.3配置 veth 对
为每个内部网络（office、guest、dmz）和外网（internet）分别创建 veth 对，将一端移入 fw 命名空间，另一端移入对应的主机命名空间。
以office连接为例：
```bash
# office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

# 配置IP地址
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

```

1.4分配 IP 地址并启用接口
在 fw 端和对端分别设置静态 IP（见地址规划表），并激活所有接口（ip link set up）。


1.5设置默认路由
在每个主机命名空间（office、guest、dmz、internet）中添加默认网关，指向 fw 对应接口的 IP 地址（例如 office 的默认网关为 10.20.0.1）。
``` bash
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
```

1.6开启 IP 转发
在 fw 命名空间中启用 net.ipv4.ip_forward=1，使防火墙具备路由转发能力（为后续策略路由和 NAT 做准备）。
``` bash
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```
### 2.连通性测试结果
在完成拓扑搭建后，分别从 office、guest、dmz 和 internet 命名空间 ping 防火墙对应接口的 IP，验证直连链路可达性。
``` bash
# office应该能ping通fw
sudo ip netns exec office ping -c 2 10.20.0.1

# guest应该能ping通fw
sudo ip netns exec guest ping -c 2 10.30.0.1

# dmz应该能ping通fw
sudo ip netns exec dmz ping -c 2 10.40.0.1

# internet应该能ping通fw
sudo ip netns exec internet ping -c 2 203.0.113.1
``` 
##### 连通性测试结果：
``` bash
# office -> fw
64 bytes from 10.20.0.1: icmp_seq=1 ttl=64 time=0.056 ms
2 packets transmitted, 2 received, 0% packet loss

# guest -> fw
64 bytes from 10.30.0.1: icmp_seq=1 ttl=64 time=0.058 ms
2 packets transmitted, 2 received, 0% packet loss

# dmz -> fw
64 bytes from 10.40.0.1: icmp_seq=1 ttl=64 time=0.042 ms
2 packets transmitted, 2 received, 0% packet loss

# internet -> fw
64 bytes from 203.0.113.1: icmp_seq=1 ttl=64 time=0.038 ms
2 packets transmitted, 2 received, 0% packet loss
``` 

![alt text](01-topology.png)

### 3. setup.sh 脚本
``` bash
#!/bin/bash
# setup.sh - 企业网络安全架构拓扑搭建脚本
# 可重复运行，包含错误处理

set -e

echo "=== 清理现有namespace ==="
sudo ip netns exec fw wg-quick down wg0 2>/dev/null || true
sudo ip netns exec remote wg-quick down wg0 2>/dev/null || true
sudo pkill -f "python3 -m http.server" 2>/dev/null || true

for ns in fw office guest dmz internet remote; do
    sudo ip netns del $ns 2>/dev/null || true
done
sleep 1

echo "=== 创建6个namespace ==="
for ns in fw office guest dmz internet remote; do
    sudo ip netns add $ns
done

echo "=== 创建veth对并配置 ==="
# office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest连接
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# dmz连接
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# internet连接
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# fw-remote veth对（用于VPN跨命名空间通信）
sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote
sudo ip netns exec fw ip addr add 10.100.0.1/24 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
sudo ip netns exec remote ip addr add 10.100.0.2/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

echo "=== 配置路由和IP转发 ==="
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add 10.10.10.1/32 via 10.100.0.1
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "=== 验证连通性 ==="
echo "Testing office -> fw..."
sudo ip netns exec office ping -c 2 10.20.0.1 || echo "office ping failed"
echo "Testing guest -> fw..."
sudo ip netns exec guest ping -c 2 10.30.0.1 || echo "guest ping failed"
echo "Testing dmz -> fw..."
sudo ip netns exec dmz ping -c 2 10.40.0.1 || echo "dmz ping failed"
echo "Testing internet -> fw..."
sudo ip netns exec internet ping -c 2 203.0.113.1 || echo "internet ping failed"

echo "=== 拓扑搭建完成 ==="
```


---

## 四、 第二部分：防火墙策略实现

### 访问控制需求

| 源区域 | 目标区域 | 允许/拒绝 | 备注 |
|:------|:--------|:---------|:-----|
| office | dmz:8080 | 允许 | 内网访问DMZ的Web服务 |
| office | dmz:22 | 拒绝 | 禁止内网SSH到DMZ |
| office | internet | 允许 | 办公网可访问外网 |
| guest | internet | 允许 | 访客只能上网 |
| guest | office | 拒绝 | 访客不能访问办公网 |
| guest | dmz | 拒绝 | 访客不能访问DMZ |
| dmz | internet | 允许 | DMZ可以访问外网（如更新） |
| internet | dmz:8080 | 允许（通过DNAT） | 外网可访问DMZ的Web |
| internet | dmz:22 | 拒绝 | 外网不能SSH到DMZ |
| internet | office | 拒绝 | 外网不能访问内网 |
| internet | guest | 拒绝 | 外网不能访问访客网 |

### 1.访问测试矩阵：

| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 |成功（规则允许，假设服务运行） | 如图1|
| office | dmz:22 | 失败+LOG |失败（连接拒绝） | 如图2|
| guest | office:任意 | 失败+LOG |失败，返回 Destination Host Prohibited | 如图2|
| guest | dmz:8080 | 失败+LOG |失败，连接超时（Could not connect） |如图2 |
| guest | internet:任意 | 成功 |成功（SNAT + FORWARD 允许，假设外网可达） | 如图1|
| office | internet:任意 | 成功 |成功 | 如图1|
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |成功，返回 dmz 主机上的目录列表（HTTP 服务） |如图1 |
| internet | dmz:22 | 失败 | 失败，连接超时（Could not connect to server）| 如图2|



**图1（访问测试成功截图）**
![alt text](04-access-success.png)
**图2（访问测试失败截图）**
![alt text](05-access-deny.png)
### 2.规则列表截图：iptables -L FORWARD和iptables -t nat -L
![alt text](02-firewall-rules.png)

![alt text](03-nat-rules.png)


### 3. 防火墙脚本 firewall.sh
``` bash

#!/bin/bash
# firewall.sh - 防火墙规则配置脚本

echo "=== 配置防火墙规则 ==="

# 清除现有规则
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -t nat -X

# 默认策略DROP
sudo ip netns exec fw iptables -P FORWARD DROP

# 状态检测规则（必须放在最前面）
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 1. office -> dmz:8080 (允许)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 2. office -> internet (允许)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-inet -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# 3. office -> dmz:22 (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# 4. guest -> internet (允许)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# 5. guest -> office (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -s 10.30.0.0/24 -d 10.20.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -s 10.30.0.0/24 -d 10.20.0.0/24 -j REJECT

# 6. guest -> dmz (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -s 10.30.0.0/24 -d 10.40.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -s 10.30.0.0/24 -d 10.40.0.0/24 -j REJECT

# 7. dmz -> internet (允许)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# 8. internet -> dmz:8080 (DNAT放行)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 9. internet -> office (拒绝)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -d 10.20.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -d 10.20.0.0/24 -j REJECT

# 10. internet -> guest (拒绝)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -d 10.30.0.0/24 -j REJECT

# 11. internet -> dmz:22 (拒绝)
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# SNAT配置
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT配置
sudo ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080

# 查看完整规则
echo "=== FORWARD规则 ==="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers

echo "=== NAT规则 ==="
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers

echo "=== 防火墙规则配置完成 ==="
```

### 4. 规则设计说明
4.1 规则顺序（关键）
iptables 按规则顺序匹配，一旦匹配即终止（除非有 CONTINUE 等特殊动作）。本脚本的设计顺序遵循 “先放行已建立连接，再放行明确允许的新连接，最后拒绝其余” 的原则：
首条规则：放行 ESTABLISHED,RELATED 状态的连接，保证响应流量能返回，避免阻断正常通信。
具体允许规则：逐个添加放行规则（如 office→dmz:8080，内网→外网等），这些规则限定源、目的、端口和状态 NEW，确保只允许首次连接。
拒绝与日志规则：在允许之后，添加拒绝规则并附带日志（带 limit 防止日志泛滥）。例如 office→dmz:22 的拒绝、guest 访问任何内部网段的拒绝等。
默认策略：FORWARD 链默认策略设为 DROP，用于拦截所有未明确允许的流量，符合“白名单”安全模型。
这种顺序确保了 “先允许安全的，再明确拒绝危险的，最后丢弃未知的”，既保证了可用性，又加强了安全性。

4.2 选择 REJECT 而非 DROP 的原因
快速故障排查：REJECT 会向发送端返回明确的错误消息（如 icmp-host-prohibited 或 tcp-reset），客户端能立即得知连接被拒绝，而不是长时间等待超时，便于开发和管理员定位问题。
减少资源浪费：DROP 会静默丢弃包，可能导致客户端重传多次，增加网络和系统负担；REJECT 则立即终结连接，降低负载。
符合规范：在企业边界防火墙中，对于明确禁止的访问（如 guest 访问内部办公网），使用 REJECT 配合日志，既能记录攻击企图，又能快速响应。
在本脚本中：
对 ICMP 流量使用 icmp-host-prohibited（符合 RFC 规范）；
对 SSH（TCP）使用 tcp-reset，模拟端口未开放，更贴近真实服务拒绝。

4.3 日志策略
所有拒绝规则前都添加了 LOG 目标（配合 limit 限制速率），用于记录违规访问尝试。日志前缀区分了不同场景（如 OFFICE-TO-DMZ-SSH、GUEST-TO-OFFICE 等），便于后续安全审计和入侵检测。

4.4 NAT 设计
SNAT（MASQUERADE）：让内网（office/guest/dmz）访问外网时源地址转换为防火墙公网 IP，实现单向访问互联网。
DNAT（端口映射）：将外网对公网 IP:8080 的请求转发至 DMZ 主机的 8080 端口，使外网用户能够访问 DMZ 提供的 Web 服务，同时保持 DMZ 其他端口（如 22）对外不可达，有效隔离内外网。



## 五、第三部分：VPN远程接入
### 1.WireGuard配置文件：fw端和remote端的wg0.conf
**fw端的wg0.conf:**

``` bash
[Interface]
Address = 10.10.10.1/24
PrivateKey = KAn4UqSqMMZJysJYnJ6El1EMv9J3bex43wAMX78MGUI=
ListenPort = 51820

[Peer]
PublicKey = /zF30dEbe0XyxvJkZJ+eaZ0Z5fu1BcwNF0imfk/CxUM=
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
```
 **remote 端的wg0.conf**

 ``` bash 
[Interface]
Address = 10.10.10.2/24
PrivateKey = 4CYfb4A2G7rWBA8fTLSF60UaUeOlbgwGwFa/yuB261M=

[Peer]
PublicKey = QcKjDU4BUGdAdl9Bo1nFgUonrtYsqAwi3I+2Y3WCMkA=
Endpoint = 10.100.0.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
```
### 2.wg show截图：显示握手成功、transfer计数
``` bash
# VPN隧道状态
sudo ip netns exec fw wg show
sudo ip netns exec remote wg show
```
![alt text](06-vpn-status.png)


### 3.VPN访问测试截图：成功和失败场景各3个
 **VPN测试成功**
 ``` bash
# 测试VPN访问office
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8080/

# 测试VPN访问dmz:8080
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
```
![alt text](07-vpn-success.png)
成功判定标准
fw wg show：出现 peer，同时有 received /sent 流量；
remote wg show：显示对端公钥、endpoint:203.0.113.1:51820；
tcpdump：抓到 remote 发往 fw 的 UDP 加密数据包。

 **VPN测试失败**
 ``` bash
# VPN访问dmz:22（应该失败）
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:22/

# VPN访问guest（应该失败）
sudo ip netns exec remote ping -c 2 10.30.0.2
```
![alt text](08-vpn-deny.png)
失败判定标准
ping 100% 丢包；
curl 输出 Connection timed out；
关闭 fw 隧道后，fw wg show 无任何输出。

### 4.路由表截图：remote的ip route，能看到VPN相关路由
 **路由表截图**
![alt text](image.png)

### 5.VPN配置说明：说明AllowedIPs的设计思路

5.1最小权限原则：远程员工只需访问办公区（10.20.0.0/24）和 DMZ 的 Web 服务（10.40.0.0/24），故只将这两个网段纳入 VPN 路由，避免所有流量（包括互联网流量）绕经公司网关，减少带宽消耗和延迟。

5.2安全性：不将 0.0.0.0/0 设为 AllowedIPs，防止员工通过公司网络访问互联网，也避免内部网络暴露给不必要的流量（例如 guest 网段 10.30.0.0/24 不在其中，即使 VPN 连接也无法访问访客区，符合隔离要求）。

5.3精确控制：服务端仅允许 VPN 客户端的隧道 IP（10.10.10.2/32），拒绝任何其他来源伪造的 VPN 地址，防止地址欺骗。

5.4易于扩展：若未来需要增加可访问的内网网段，只需在客户端 AllowedIPs 中添加相应条目，并在 fw 上增加 FORWARD 规则即可，无需更改路由表或其他配置。

### 6. VPN跨命名空间通信问题及解决方案

问题：remote和fw位于不同的网络命名空间，remote无法直接访问fw的VPN端点10.10.10.1:51820。

解决方案：创建veth对连接fw和remote命名空间，配置新网段10.100.0.0/24，将remote的Endpoint改为10.100.0.1:51820，并在remote添加路由。
```bash
# 创建veth对
sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote

# 配置IP
sudo ip netns exec fw ip addr add 10.100.0.1/24 dev veth-fw-remote
sudo ip netns exec remote ip addr add 10.100.0.2/24 dev veth-remote

# 添加路由
sudo ip netns exec remote ip route add 10.10.10.1/32 via 10.100.0.1
```
---

## 六、第四部分：安全审计与日志分析

### 1. LOG规则配置截图：显示所有LOG规则的行号和参数
   LOG规则说明：本次防火墙所有阻断流量均采用LOG 在前、REJECT 在后的双条规则结构，LOG为非终止目标，仅写入内核日志；REJECT为终止目标，匹配后丢弃数据包、终止规则匹配流程，若 LOG 写在 REJECT 后则永远无法记录违规流量。
  全部违规流量配置差异化log-prefix区分攻击场景，高并发扫描类流量增加-m limit限速模块，防止日志洪水挤占系统磁盘、CPU 资源。

 **LOG规则配置截图**
![alt text](image-1.png)

### 2. 5种违规场景截图：触发命令和失败结果
 **日志实时监控**
 5 条违规访问
```bash
# 场景1：guest尝试访问office
sudo ip netns exec guest curl --max-time 2 http://10.20.0.2:8080/

# 场景2：guest尝试访问dmz
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/

# 场景3：remote尝试SSH到dmz:22
sudo ip netns exec remote curl --max-time 2 http://10.40.0.2:22/

# 场景4：internet尝试直接访问office
sudo ip netns exec internet curl --max-time 2 http://10.20.0.2:8080/

# 场景5：internet尝试访问dmz的未映射端口
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:3306/
```

 ![alt text](09-logs-realtime.png)

### 3. journalctl日志截图：至少5条，包含完整字段（IN、OUT、SRC、DST、DPT）
``` bash
# 统计各类事件频次
sudo journalctl -k --grep "GUEST-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager | wc -l
sudo journalctl -k --grep "VPN-TO-DMZ-SSH" --no-pager | wc -l
sudo journalctl -k --grep "INET-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "VPN-DENY" --no-pager | wc -l
```

![alt text](10-logs-stats.png)


### 4. 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office |6 |6 |是 |
| guest→dmz |4 | 4| 是|
| VPN→dmz:22 | 10| 10| 是|
| internet→office |1| 1| 是|
| VPN其他违规 |1 |1 |是 |


### 5. 日志分析报告：
   - 从日志中能获取哪些安全信息？
从防火墙日志中可提取完整流量取证信息：入 / 出接口区分流量所属区域、源目 IP 定位攻击主体与受害资产、目标端口识别攻击服务类型，运维人员可快速区分访客越权、外网扫描、VPN 违规访问三类安全事件，为应急处置提供证据支撑。

   - LOG规则为什么要放在REJECT之前？
LOG 规则必须放置在 REJECT 之前，核心原因是 LOG 仅做日志记录，不会终止数据包匹配流程；若 REJECT 前置，数据包会直接丢弃，日志规则无法匹配，造成安全行为无审计记录，形成安全盲区。
   - 速率限制如何防止日志洪水攻击？
实验中针对普通越权流量配置 limit 限速规则，依靠漏桶算法限制日志生成速率，当攻击者发起高频扫描、洪水探测时，不会瞬间生成数万条日志填满磁盘，避免日志洪水攻击导致系统日志服务崩溃，保障审计功能持续可用。
   - 不同log-prefix的作用是什么？
差异化log-prefix是日志分类的核心手段，不同违规场景使用独立标识，配合journalctl --grep可快速筛选、统计对应攻击频次，直观展示各区域安全风险等级。整体日志体系遵循最小权限审计思路，仅记录拒绝流量，不记录正常业务流量，减少日志存储开销，同时完整覆盖企业边界全部隔离策略，实现全网访问行为可追溯、可审计、可统计，满足企业网络安全合规要求。


---

## 七、第五部分：攻防演练与故障排查
### 1.攻防演练

**攻击1：扫描office网段**


```bash
for i in {1..5}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up" || echo "10.20.0.$i is down"
done
```
结果：仅10.20.0.1（fw）可ping通，10.20.0.2被拦截

失败原因分析：防火墙FORWARD链默认策略为DROP，且单独配置规则拦截访客流向办公网的全部流量。访客网段与办公网完全隔离，无论ICMP、TCP、UDP全部阻断。扫描数据包到达防火墙后直接丢弃，无法抵达办公主机
**攻击演练场景1截图：**
![alt text](11-attack-scan.png)



**攻击2：尝试绕过防火墙访问dmz:22**

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```


结果：两次尝试均失败（Connection refused）

失败原因分析：防火墙拦截规则匹配入接口、出接口，不区分客户端源端口，仅限制目标网段与目标服务。无论客户端使用80、443或任意随机源端口，只要流量从访客网卡流向DMZ网卡，就会匹配拦截规则。修改源端口无法绕过域间隔离策略
**攻击演练场景2截图：**
![alt text](12-attack-bypass.png)

**攻击3：尝试伪造VPN流量**



思考：攻击者能否伪造源地址为`10.10.10.2`的包来访问内网？
```bash
# 这个攻击会成功吗？为什么？
```
不会成功。原因有三：
1.WireGuard隧道流量全部加密并携带公私钥身份校验，普通Guest主机无法生成合法VPN封装数据包
2.fw防火墙规则匹配入接口wg0才放行VPN权限流量，伪造流量从veth-fw-guest网卡进入，不会匹配VPN放行规则
3.内核反向路由校验会过滤非法源IP数据包

- 回答：攻击者能否从REJECT和DROP的不同表现判断目标是否存在？
 答：REJECT：防火墙返回ICMP禁止报文，客户端立刻收到拒绝提示，能确定目标IP存在
DROP：数据包静默丢弃，无任何回应，攻击者无法判断主机是否存活

### 2. 防御分析

**任务1：从日志中识别攻击**

```bash
sudo journalctl -k --since "10 minutes ago" --grep "GUEST-|VPN-|INET-" --no-pager
```
**防御分析-日志证据截图：**
![alt text](14-defense-counters.png)

回答问题：
1. 从日志的哪些字段可以判断这是来自guest的攻击？
答：日志中IN=veth-fw-guest入网卡字段是核心标识，代表数据包从访客网络 veth 接口流入防火墙；同时日志前缀GUEST-TO-OFFICE/GUEST-TO-DMZ人工标记访客违规流量。SRC 源 IP 属于 10.30.0.0/24 访客网段，三者结合可 100% 判定攻击源为访客区主机。五元组（入接口、源网段、出接口、目的网段、端口）完整溯源，无需额外抓包即可定位攻击区域，满足企业安全审计溯源要求。
2. 如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？
答：代表数据包从访客网络接口进入防火墙，目标转发至办公内网接口，属于跨安全域越权访问行为，是典型内网横向渗透风险。企业架构中访客区为不可信区域，办公区为核心可信区域，二者严格隔离。该日志证明访客设备尝试横向移动入侵办公内网窃取业务数据，属于高危安全事件，运维人员需立刻核查访客主机是否被恶意程序控制，及时处置入侵风险。

3. 为什么看到大量相同来源的日志应该引起警惕？
答：相同来源的日志说明攻击者使用了暴力破解、端口扫描等攻击手段，尝试探测网段存活设备，属于高危安全事件，运维人员需立刻核查攻击者是否为合法用户，及时阻断攻击流量。

**任务2：分析规则的防御效果**

```bash
# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
**防御分析-规则计数器截图：**
![alt text](13-defense-logs-1.png)

回答问题：
1. 哪条规则拦截了guest访问office？
答：两条成对规则：第一条 LOG 规则（前缀 GUEST-TO-OFFICE），第二条 REJECT 终止规则。两条规则匹配入接口 veth-fw-guest、出接口 veth-fw-office，无协议、端口限制，拦截访客到办公网所有流量。使用iptables -L FORWARD -n -v --line-numbers可查看规则流量计数器，每次访问都会递增数据包计数，直观验证拦截生效。

2. 如果guest→office的规则计数很高，说明了什么？
答：计数持续上涨说明访客网段存在主机持续扫描、尝试访问办公内网，存在横向渗透风险。可能是访客设备接入恶意 WiFi、运行扫描脚本、感染木马病毒，持续探测内网资产。运维人员需根据日志 SRC 定位恶意访客主机，隔离终端并查杀病毒；同时优化边界防护，增加 connlimit 连接限制模块，阻断高频扫描行为，降低内网暴露风险。

3. REJECT和DROP在安全性上有什么区别？
答：REJECT 会返回 ICMP 错误报文，攻击者可快速判断目标网段存在，泄露内网资产信息，适合企业内部测试环境；DROP 静默丢弃数据包，无任何响应，攻击者无法判断主机存活，隐藏内网拓扑，生产环境高安全区域推荐使用。同时 REJECT 产生的 ICMP 报文可能被攻击者利用 DoS 扫描，DROP 可减少对外暴露信息，缩小攻击面，纵深防御效果更强。


### 3. 边界测试与改进方案

选定风险：DMZ 对外开放 8080 Web 服务
3.1 风险分析：
DMZ 的 8080 端口对公网完全开放，仅依靠基础防火墙放行，无并发连接限制，存在两大安全风险。第一，易遭受 CC/DoS 攻击，攻击者大量新建 TCP 连接耗尽服务器端口与防火墙资源，导致 Web 服务瘫痪；第二，开放端口易被漏洞扫描器探测，若 Web 程序存在代码漏洞，攻击者可利用漏洞入侵 DMZ 服务器，进一步横向渗透内网。现有策略仅做访问放行，无流量管控、并发限制，边界防护薄弱，不符合企业纵深防御安全标准，需增加连接并发限制加固边界。

3.2 改进方案 iptables 规则（connlimit 限制单 IP 最大并发）
``` bash
# 限制单IP对dmz:8080的连接数（connlimit）
echo "=== 边界测试：connlimit限制 ==="
sudo ip netns exec fw iptables -I FORWARD 2 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset

# 查看规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -15
```

边界测试改进方案截图
![alt text](15-improvement.png)

### 4. 高级任务：追踪包的完整变化过程


要求在4个位置同时抓包：
```bash
# 在4个位置同时抓包
echo "=== 高级任务：包追踪 ==="

# 终端1：remote的wg0接口
sudo ip netns exec remote tcpdump -ni wg0 -c 5 -v &
T1=$!

# 终端2：fw的wg0接口
sudo ip netns exec fw tcpdump -ni wg0 -c 5 -v &
T2=$!

# 终端3：fw的veth-fw-dmz接口
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5 -v &
T3=$!

# 触发访问
sleep 2
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/ 2>&1 | head -5

# 停止抓包
sleep 2
sudo kill $T1 $T2 $T3 2>/dev/null
```

**包变化对比表：**

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 |10.10.10.2| 10.40.0.2|TCP | 封装前 |
| 2 | fw wg0 |10.10.10.2 |10.40.0.2 | TCP| 解封装后 |
| 3 | fw veth-fw-dmz |10.10.10.2 |10.40.0.2 |TCP | 转发到dmz |
| 4 | conntrack | 10.10.10.2|10.40.0.2 | TCP| 连接跟踪记录 |

**抓包截图**
![alt text](16-tcpdump-remote.png)
![alt text](17-tcpdump-fw.png)
**conntrack记录截图**
![alt text](18-conntrack.png)


**分析报告**
本次实验通过在 remote、fw 两个网络命名空间分别抓取 wg0 隧道接口、dmz 转发网卡流量，结合 conntrack 连接跟踪表完整验证 WireGuard 隧道封装 / 解封装全过程与防火墙转发逻辑。
远程 remote 主机 wg0 抓包可见原始内网 TCP SYN 报文，源地址为 VPN 内网 10.10.10.2，目标 DMZ 服务器 10.40.0.2，该报文会被 WireGuard 加密封装为公网 UDP 流量传输至防火墙 fw。fw 的 wg0 接口是隧道解密入口，抓包结果与 remote 端内网报文完全一致，证明 fw 完成解封装，剥离外层公网头部，还原原始内网 IP 数据包。
解封装后的流量匹配 fw FORWARD 链 VPN 放行规则，转发至 veth-fw-dmz 网卡，该网卡抓包保留相同五元组信息，无 NAT 地址转换，实现 VPN 内网地址端到端透传。同时 conntrack 连接跟踪实时记录该 TCP 连接状态为 SYN_SENT，持续维护五元组会话，当服务器返回应答报文时，依靠 ESTABLISHED 状态规则自动放行回程流量，无需新增独立放行规则。
整套架构依靠 WireGuard 加密隧道实现远程安全接入，配合 iptables 访问控制与连接跟踪机制，实现流量加密、权限管控、会话自动放行三层防护，所有违规访问同步生成内核审计日志，满足企业远程办公边界安全审计要求。


---

## 八、故障排查专题（体现Plan1的开放性）

### 场景1：DNAT故障

``` bash
# 重现：删除DNAT对应的FORWARD规则
echo "=== 场景1：DNAT故障 ==="
sudo ip netns exec fw iptables -D FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null

# 测试（应该失败）
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/ 2>&1

# 修复
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 重新测试（应该成功）
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/ 2>&1 | head -3
```

![alt text](19-troubleshoot-dnat.png)



### 场景2：VPN故障


``` bash
echo "=== 场景2：VPN故障 ==="
# 删除VPN到dmz的规则
sudo ip netns exec fw iptables -D FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null

# 测试（应该失败）
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/ 2>&1 | head -3

# 修复
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 重新测试（应该成功）
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/ 2>&1 | head -3
```

![alt text](20-troubleshoot-vpn.png)



## 九、遇到的问题和解决方法
| 问题 | 解决方法  |
|:-----|:---------|
|namespace|清理不干净导致重复创建失败	使用2>/dev/null忽略删除错误，确保脚本可重复运行|
|remote和fw跨命名空间无法通信|	创建veth对连接两个命名空间，配置独立网段和路由|
|WireGuard密钥格式错误|	使用tr -d '\n'去除换行符，确保密钥为44个字符|
|journalctl无日志输出|	使用iptables计数器验证LOG规则生效，配合dmesg查看|
|VPN隧道无握手|	使用veth对打通网络，修改Endpoint为10.100.0.1:51820|

## 十、总结与思考
1.实验回顾
本次企业级网络安全架构搭建与攻防演练实验，通过Linux网络命名空间模拟了完整的企业网络环境，包括办公区、访客区、DMZ对外服务区、互联网区和VPN远程接入区。实验涵盖了从网络拓扑搭建、防火墙策略配置、NAT转换、WireGuard VPN接入，到安全审计日志、攻防演练和故障排查的全流程，让我对企业网络安全架构有了系统性的理解和实践。
2.技术收获
（1）网络虚拟化技术的理解
通过使用Linux Network Namespace和veth对，我深刻理解了网络虚拟化的原理。每个命名空间拥有独立的网络栈（网卡、路由表、iptables规则），veth对则像一根虚拟网线连接两个命名空间。这种技术不仅用于容器网络（Docker），也是构建复杂网络拓扑实验的利器。实验中创建了6个命名空间、5对veth连接，构建了一个多区域隔离的企业网络模型，让我对"网络隔离"有了直观认识。
（2）防火墙策略设计原则
iptables规则配置让我理解了企业防火墙的核心设计原则：
最小权限原则：FORWARD链默认策略设为DROP，只放行明确需要的流量。这种"白名单"模式虽然配置繁琐，但能有效防止未知威胁。
规则顺序的重要性：iptables按顺序匹配，一旦匹配即终止。因此必须将状态检测规则（ESTABLISHED,RELATED）放在最前面，然后是具体的允许规则，最后才是拒绝规则。规则顺序错误可能导致安全漏洞或业务中断。
状态检测的必要性：-m conntrack --ctstate ESTABLISHED,RELATED是状态防火墙的核心。它允许回程流量自动放行，同时阻止外部主动发起的连接，实现了"单向访问控制"。实验中删除这条规则后，TCP三次握手的SYN-ACK被拦截，证明了状态检测的不可或缺。
（3）NAT技术的应用
SNAT（源地址转换）：让内网主机访问外网时，源地址转换为防火墙公网IP。实验中使用了MASQUERADE，它会自动使用输出接口的IP，非常适合动态IP场景。
DNAT（目标地址转换）：将外网对公网IP的请求转发到内网服务器。实验中配置了外网访问203.0.113.1:8080 → 10.40.0.2:8080的映射，实现了对外服务发布。
（4）VPN技术实践
WireGuard的配置让我理解了现代VPN的简洁与安全：
AllowedIPs机制：客户端配置AllowedIPs = 10.20.0.0/24,10.40.0.0/24，只有访问这两个网段的流量才走VPN隧道，避免所有流量绕经公司网关。这种"分裂隧道"设计既减少了带宽消耗，也降低了安全风险。
跨命名空间通信：实验中遇到的最大挑战是remote和fw位于不同命名空间，无法直接通信。解决方案是创建veth对连接两个命名空间，配置独立网段10.100.0.0/24，并修改remote的Endpoint指向10.100.0.1:51820。这个问题让我深刻理解了网络命名空间的隔离特性。
（5）安全审计与日志分析
通过配置iptables LOG规则，我学会了如何构建安全审计体系：
LOG+REJECT双规则：LOG在前记录违规行为，REJECT在后阻断连接，确保"先审计后执行"
速率限制：-m limit --limit 5/min --limit-burst 10防止日志洪水攻击
差异化前缀：不同违规场景使用不同log-prefix（如GUEST-TO-OFFICE、VPN-TO-DMZ-SSH），便于快速分类和统计
（6）攻防演练的启示
从攻击者视角看，防火墙的REJECT和DROP响应差异会暴露信息；从防御者视角看，规则计数器和日志是识别攻击的重要依据。这种攻防对抗的体验让我理解了安全不是静态的，需要持续监控和优化。
（7）故障排查方法论
实验中遇到的各类故障让我总结出排查方法论：
分层排查：先确认底层链路（ping），再检查路由（ip route），然后核验防火墙规则（iptables），最后抓包分析（tcpdump）
连接跟踪：conntrack是排查NAT和状态防火墙问题的利器
抓包对比：在多个接口同时抓包，对比流量走向，快速定位丢包位置

3.对网络安全架构的整体理解
通过本次实验，我对企业网络安全架构有了完整的认识：
（1） 分区隔离是安全的基础
企业网络不能是扁平化的，必须划分为不同安全区域：办公区（可信）、DMZ区（半可信）、访客区（不可信）、外网（不可信）。不同区域之间通过防火墙实施严格的访问控制，实现"纵深防御"。
（2） 最小权限是安全的准则
无论是防火墙规则、VPN配置还是服务开放，都应遵循最小权限原则。只开放必要的端口，只允许必要的访问，只暴露必要的服务。本次实验中，办公区只能访问DMZ的8080端口（Web服务），不能访问22端口（SSH管理），就是最小权限的体现。
（3）审计日志是安全的眼睛
没有日志的安全是不可见的。通过配置LOG规则、统计分析日志，才能及时发现异常行为。日志记录了攻击者的IP、目标、时间、类型，是安全事件响应和溯源的关键证据。
（4） VPN接入是远程办公的保障
远程员工通过加密隧道安全访问内网，是企业数字化转型的必备能力。WireGuard作为现代VPN协议，配置简单、性能优异、安全性高，适合企业部署。
（5） 安全不是一劳永逸的
攻防演练揭示了防火墙策略的局限性：REJECT会暴露信息、开放端口可能被DDoS攻击、VPN可能被暴力破解。安全需要持续监控、定期评估、不断优化。

4.改进建议
（1） 生产环境改进
使用DROP替代REJECT：生产环境敏感区域使用DROP，避免暴露信息
增加连接数限制：使用connlimit模块限制单IP并发连接数，防御DDoS
启用fail2ban：自动封禁暴力破解IP
配置更细粒度的访问控制：基于应用层（L7）的访问控制，如URL过滤
（2） 架构优化
冗余设计：部署双防火墙实现高可用
入侵检测：部署IDS/IPS，实时检测攻击行为
日志集中管理：将日志发送到SIEM平台，实现统一分析和告警
（3） 运维建议
规则变更管理：防火墙规则变更前备份，变更后验证
定期审计：定期审查防火墙规则，删除冗余规则
自动化部署：使用Ansible等工具自动化防火墙配置

5.个人收获
本次实验是Linux网络、iptables防火墙、WireGuard VPN、网络命名空间、攻防演练等知识的综合实践。通过动手搭建完整的企业网络安全架构，我不仅掌握了具体技术，更重要的是理解了安全设计的思路和方法：
理论与实践的结合：在实验中验证了理论知识，如状态检测的工作原理、NAT的转换过程、WireGuard的隧道机制。
问题解决能力的提升：遇到问题时，学会使用多种工具（ping、traceroute、tcpdump、conntrack、iptables、wg show）进行排查，培养了系统化的问题解决思维。
安全意识的增强：理解了安全的本质是"信任管理"——明确哪些是可信的、哪些是不可信的，并通过技术手段实施隔离和控制。
6.结语
网络安全是"攻防对抗"的持续过程。作为未来的网络安全从业者，我们既要掌握防御技术，也要理解攻击思路，在攻防对抗中不断提升安全防护能力。本次实验为我打开了一扇门，让我看到了企业网络安全架构的全貌，也明确了继续深入学习的方向。
未来，我将继续深入研究零信任架构、云原生安全、态势感知等前沿方向，为构建更安全的企业网络环境贡献力量。
