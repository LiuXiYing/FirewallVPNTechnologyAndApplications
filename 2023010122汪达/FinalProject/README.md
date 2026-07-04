# 期末大作业：企业级网络安全架构搭建与攻防演练

## 实验背景

某企业有办公区、访客区、DMZ对外服务区，并需要支持远程员工VPN接入。你需要设计并实现完整的网络安全方案，确保：
- 不同区域之间的访问隔离
- 远程员工通过VPN安全访问内网
- 外部用户可访问DMZ的Web服务
- 所有访问行为留下审计日志

本大作业综合Lab6-Lab13的全部知识点，要求你搭建一个包含多区域隔离、防火墙策略、NAT、VPN接入的完整企业边界网络。

---

## 实验目标

1. 理解企业网络安全架构的整体设计思路
2. 掌握多区域网络的规划和隔离方法
3. 实现基于最小权限原则的防火墙策略
4. 配置SNAT/DNAT实现内网访问外网和外网访问DMZ
5. 实现远程VPN接入并精细控制VPN用户权限
6. 配置全面的日志审计体系
7. 进行攻防演练，理解防御方和攻击方的视角
8. 培养故障排查和问题分析能力

---
## 一、实验环境
- 操作系统：VMware Workstation 虚拟机 Kali Linux 2025.2 (amd64)
- WireGuard版本：wireguard-tools v1.0.20210914
- iptables版本：iptables v1.8.13 (nf_tables)
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


**节点说明：**

| 节点 | 角色 | 必须实现的功能 |
|:-----|:-----|:--------------|
| `fw` | 防火墙+VPN网关 | 5个网络接口、IP转发、FORWARD规则、NAT、WireGuard |
| `office` | 办公网主机 | 模拟内网员工 |
| `guest` | 访客网主机 | 模拟访客设备 |
| `dmz` | 对外服务器 | 运行Web服务(8080)和管理服务(22) |
| `internet` | 外网主机 | 模拟互联网用户 |
| `remote` | 远程员工 | 通过VPN接入 |

---

## 三、第一部分：网络规划与基础搭建（20分）

### 任务清单

**任务1.1：创建6个namespace**
1. 拓扑搭建步骤说明
1.1 清理旧环境
删除可能存在的同名网络命名空间（fw, office, guest, dmz, internet, remote），避免重复运行冲突。同时清理残留的 veth 接口和 iptables 规则。
1.2 创建六个网络命名空间
使用 ip netns add 创建防火墙（fw）、办公区（office）、访客区（guest）、DMZ区（dmz）、互联网（internet）和远程区（remote）。
```bash
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
```
规划IP地址**
填写下表（必须使用不同网段）：
| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |

**任务1.3：创建veth对并配置**

提示：需要创建5对veth连接`fw`和各个区域。
1.3 配置 veth 对
为每个内部网络（office、guest、dmz）和外网（internet）分别创建 veth 对，将一端移入 fw 命名空间，另一端移入对应的主机命名空间。
```bash
# office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

# 配置IP地址（其他区域类似）
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# ... guest、dmz、internet的连接配置（请自行完成）
```

**任务1.4：配置路由和IP转发**
1.4 分配 IP 地址并启用接口
在每个主机命名空间（office、guest、dmz、internet）中添加默认网关，指向 fw 对应接口的 IP 地址。
在 fw 命名空间中启用 net.ipv4.ip_forward=1，使防火墙具备路由转发能力。
```bash
# 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1

# fw开启IP转发
在 fw 命名空间中启用 net.ipv4.ip_forward=1，使防火墙具备路由转发能力。
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```
1.5 基础防火墙策略
应用最小权限原则，设置 INPUT 和 FORWARD 链默认为 DROP，仅放行必要的流量。
# 设置默认策略
sudo ip netns exec fw iptables -P INPUT DROP
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

# 允许回环和已建立连接
sudo ip netns exec fw iptables -A INPUT -i lo -j ACCEPT
sudo ip netns exec fw iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 允许各区域 ping fw
sudo ip netns exec fw iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# 允许办公网 → DMZ 和 VPN → 办公网/DMZ
sudo ip netns exec fw iptables -A FORWARD -s 10.20.0.0/24 -d 10.40.0.0/24 -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -s 10.10.10.0/24 -d 10.20.0.0/24 -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -s 10.10.10.0/24 -d 10.40.0.0/24 -j ACCEPT
**任务1.6：验证基础连通性**

```bash
# office应该能ping通fw
sudo ip netns exec office ping -c 2 10.20.0.1

# guest应该能ping通fw
sudo ip netns exec guest ping -c 2 10.30.0.1

# dmz应该能ping通fw
sudo ip netns exec dmz ping -c 2 10.40.0.1

# internet应该能ping通fw
sudo ip netns exec internet ping -c 2 203.0.113.1
```
setup.sh 脚本说明
一、脚本功能
一键创建包含 6 个网络命名空间（fw、office、guest、dmz、internet、remote）的企业网络拓扑实验环境。
二、地址规划
区域	网段	fw侧地址	主机地址
office	10.20.0.0/24	10.20.0.1	10.20.0.2
guest	10.30.0.0/24	10.30.0.1	10.30.0.2
dmz	10.40.0.0/24	10.40.0.1	10.40.0.2
internet	203.0.113.0/24	203.0.113.1	203.0.113.10
vpn	10.10.10.0/24	10.10.10.1	10.10.10.2
三、执行步骤
清理旧环境：删除旧 namespace、veth 接口、iptables 规则
创建命名空间：fw、office、guest、dmz、internet、remote
创建 veth 对：5 对 veth 连接各区域到 fw
配置路由：各区域默认网关指向 fw
开启转发：net.ipv4.ip_forward=1
基础防火墙：INPUT/FORWARD 默认 DROP
连通性验证：ping 测试各区域到 fw
四、基础防火墙策略
INPUT 默认 DROP，允许回环、已建立连接、ICMP
FORWARD 默认 DROP，允许 office→dmz 和 VPN→office/dmz
OUTPUT 默认 ACCEPT
连通性测试输出：
# office -> fw
PING 10.20.0.1 (10.20.0.1) 56(84) bytes of data.
64 bytes from 10.20.0.1: icmp_seq=1 ttl=64 time=0.044 ms
64 bytes from 10.20.0.1: icmp_seq=2 ttl=64 time=0.037 ms
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.037/0.040/0.044/0.003 ms

# guest -> fw
PING 10.30.0.1 (10.30.0.1) 56(84) bytes of data.
64 bytes from 10.30.0.1: icmp_seq=1 ttl=64 time=0.045 ms
64 bytes from 10.30.0.1: icmp_seq=2 ttl=64 time=0.050 ms
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.045/0.047/0.050/0.002 ms

# dmz -> fw
PING 10.40.0.1 (10.40.0.1) 56(84) bytes of data.
64 bytes from 10.40.0.1: icmp_seq=1 ttl=64 time=0.046 ms
64 bytes from 10.40.0.1: icmp_seq=2 ttl=64 time=0.069 ms
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.046/0.057/0.069/0.011 ms

# internet -> fw
PING 203.0.113.1 (203.0.113.1) 56(84) bytes of data.
64 bytes from 203.0.113.1: icmp_seq=1 ttl=64 time=0.042 ms
64 bytes from 203.0.113.1: icmp_seq=2 ttl=64 time=0.064 ms
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.042/0.053/0.064/0.011 ms
连通性测试结果
在完成拓扑搭建后，分别从 office、guest、dmz、internet 和 remote 命名空间 ping 防火墙对应接口的 IP，验证直连链路可达性
来源	目标	命令	结果	截图
office	10.20.0.1 (fw)	sudo ip netns exec office ping -c 2 10.20.0.1	✅ 成功，0% packet loss	
guest	10.30.0.1 (fw)	sudo ip netns exec guest ping -c 2 10.30.0.1	✅ 成功，0% packet loss	
dmz	10.40.0.1 (fw)	sudo ip netns exec dmz ping -c 2 10.40.0.1	✅ 成功，0% packet loss	
internet	203.0.113.1 (fw)	sudo ip netns exec internet ping -c 2 203.0.113.1	✅ 成功，0% packet loss
![alt text](01-topology.png)
### 提交内容

1. **setup.sh脚本**：包含完整的拓扑搭建命令（可重复运行）
2. **地址规划表**：markdown格式，列出所有接口的IP地址
3. **连通性测试截图**：至少4组ping测试结果
4. **拓扑搭建说明**：简要说明你的拓扑搭建步骤和验证方法

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 脚本完整性 | 5分 | 能创建所有namespace、veth对、配置IP、路由 |
| 脚本可运行性 | 5分 | 可重复运行，无错误 |
| 地址规划合理性 | 5分 | 网段无冲突，地址分配清晰 |
| 连通性验证 | 5分 | 所有基础连通性测试通过 |

---

## 四、第二部分：防火墙策略实现（30分）

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

### 任务清单
firewall.sh 脚本说明
firewall.sh 脚本执行以下步骤：
清理旧规则：清空 filter 表和 nat 表的所有规则。
配置 FORWARD 链默认策略：设置为 DROP，遵循最小权限原则。
配置状态检测规则：放行 ESTABLISHED,RELATED 状态的连接，提高性能并保证 TCP 连接正常工作。
配置区域间访问控制：根据访问控制需求配置各区域间的 ACCEPT/REJECT/LOG 规则。
配置 SNAT：实现内网（office、guest、dmz）访问外网。
配置 DNAT：实现外网访问 DMZ 的 Web 服务。
 
**任务2.1：配置FORWARD链默认策略**

```bash
sudo ip netns exec fw iptables -P FORWARD DROP
```

**任务2.2：配置状态检测规则**

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

**任务2.3：配置office访问dmz规则**

```bash
# 允许office访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz:22（请自行添加LOG和REJECT规则）
```

**任务2.4：配置guest隔离规则**

```bash
# 拒绝guest访问office（带LOG）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# 拒绝guest访问dmz（请自行完成）
```

**任务2.5：配置SNAT让内网访问外网**

```bash
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
```

**任务2.6：配置DNAT让外网访问dmz:8080**

```bash
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# 对应的FORWARD规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**任务2.7：查看完整规则**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
```
规则列表截图：iptables -L FORWARD和iptables -t nat -L
![alt text](02-firewall-rules.png)

![alt text](03-nat-rules.png)
### 测试要求

在`dmz`上启动两个服务：

```bash
# 终端A
sudo ip netns exec dmz python3 -m http.server 8080

# 终端B
sudo ip netns exec dmz python3 -m http.server 22
```
填写访问测试矩阵：

| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 |成功 | 图1|
| office | dmz:22 | 失败+LOG | 失败（Host name lookup failure）|图2 |
| guest | office:任意 | 失败+LOG |失败（100% packet loss）| 图2|
| guest | dmz:8080 | 失败+LOG |失败（HTTP状态: 000） | 图2|
| guest | internet:任意 | 成功 | 成功（SNAT + FORWARD 允许，假设外网可达）| 图1|
| office | internet:任意 | 成功 | 成功（0% packet loss）|图1 |
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |成功（HTTP状态: 200） |图1 |
| internet | dmz:22 | 失败 | 失败（Host name lookup failure）|图2 |
**图1（访问测试成功截图）**
![alt text](04-access-success.png)
**图2（访问测试失败截图）**
![alt text](05-access-deny.png)
规则顺序说明
防火墙规则按照"先放行、后拒绝、日志记录在拒绝前"的顺序排列：
规则顺序	   规则类型	       说明
第1条	状态检测 (RELATED,ESTABLISHED)	最高优先级，保证已有连接的回包通过
第2条	office→dmz:8080 ACCEPT	具体放行规则
第3条	office→dmz:22 LOG	日志记录必须在REJECT之前
第4条	office→dmz:22 REJECT	具体拒绝规则
第5-10条	其他 ACCEPT/LOG/REJECT	按区域顺序排列
第11-17条	internet→各区域 REJECT	外网访问内网的拒绝规则（最后）
顺序合理性分析：
状态检测放在最前面，避免每个包都被后续规则处理，提高性能
具体的 ACCEPT 规则放在 REJECT 之前，确保合法流量先被放行
LOG 规则紧贴在对应的 REJECT 规则之前，确保违规访问被记录
从最具体的规则到最通用的规则，避免误匹配
为什么用 REJECT 而不是 DROP？
考量因素	REJECT	DROP	本实验选择
用户体验	快速返回错误，用户立刻知道连接被拒绝	无响应，用户需等待超时	✅ REJECT（便于调试）
信息泄露	暴露防火墙存在和端口状态	完全静默，不泄露信息	⚠️ 需权衡
日志清晰度	配合LOG可明确记录拒绝事件	配合LOG也可记录	✅ REJECT（日志更完整）
攻击防护	攻击者可通过响应判断端口状态	攻击者难以判断端口是否存在	❌ DROP更安全
本实验选择 REJECT 的原因：
便于调试和测试：在实验环境中使用 REJECT 可以快速确认规则是否生效，收到 icmp-port-unreachable 或 TCP RST 表示规则已匹配。
配合 LOG 规则：所有 REJECT 规则前都有对应的 LOG 规则，日志前缀（如 GUEST-TO-OFFICE:）能清晰标识违规类型。
速率限制保护：guest→office 和 guest→dmz 的日志规则使用了 limit 模块（5/min burst 10），避免日志洪水攻击。
教育目的：本实验是网络安全课程的一部分，使用 REJECT 可以让学生直观地看到防火墙的拒绝行为。
实际生产环境建议：在真实生产环境中，DMZ 对外服务建议使用 DROP 以减少信息泄露，内部网络可使用 REJECT 便于运维。
规则设计亮点
最小权限原则：所有区域默认无法互访，只有明确放行的流量才能通过。
状态检测优化：RELATED,ESTABLISHED 规则放行回包，提高性能。
分层日志策略：不同违规类型使用不同的 log-prefix，便于日志分析和告警。
速率限制保护：防止日志洪水攻击，保护系统资源。
明确的区域隔离：guest 完全隔离（只能上网），office 可访问 DMZ Web 服务，internet 只能通过 DNAT 访问 DMZ:8080。



### 提交内容

1. **firewall.sh脚本**：包含所有防火墙规则
2. **规则列表截图**：`iptables -L FORWARD`和`iptables -t nat -L`
3. **访问测试矩阵**：填写完整的测试结果
4. **规则设计说明**：说明规则顺序、为什么用REJECT而不是DROP等

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 规则完整性 | 10分 | 覆盖所有访问需求 |
| 访问控制正确性 | 10分 | 所有测试符合预期 |
| NAT配置 | 5分 | SNAT和DNAT正确 |
| 规则顺序合理性 | 5分 | 状态检测在前、具体规则在后、LOG在REJECT前 |

**扣分项：**
- 规则过宽导致安全漏洞（如无条件放行10.0.0.0/8）：每处-5分
- 规则顺序错误导致无法生效：每处-3分

## 第三部分：VPN远程接入（20分）

### 任务清单

**任务3.1：生成WireGuard密钥对**

```bash
umask 077
wg genkey | tee fw.key | wg pubkey > fw.pub
wg genkey | tee remote.key | wg pubkey > remote.pub
```

**任务3.2：配置fw的WireGuard**

```bash
sudo mkdir -p /etc/wireguard/fw
FW_PRIVATE_KEY=$(cat fw.key)
REMOTE_PUBLIC_KEY=$(cat remote.pub)

sudo tee /etc/wireguard/fw/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.1/24
PrivateKey = ${FW_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${REMOTE_PUBLIC_KEY}
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
EOF

sudo chmod 600 /etc/wireguard/fw/wg0.conf
```

**任务3.3：配置remote的WireGuard**

```bash
sudo mkdir -p /etc/wireguard/remote
REMOTE_PRIVATE_KEY=$(cat remote.key)
FW_PUBLIC_KEY=$(cat fw.pub)

sudo tee /etc/wireguard/remote/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = ${REMOTE_PRIVATE_KEY}

[Peer]
PublicKey = ${FW_PUBLIC_KEY}
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 /etc/wireguard/remote/wg0.conf
```

**重要说明：**
- `fw`的`AllowedIPs = 10.10.10.2/32`：只接受remote的VPN地址
- `remote`的`AllowedIPs = 10.20.0.0/24,10.40.0.0/24`：只有访问这些地址时走VPN

**任务3.4：启动WireGuard隧道**

```bash
# 在fw上
sudo ip netns exec fw wg-quick up /etc/wireguard/fw/wg0.conf

# 在remote上
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

**任务3.5：配置VPN流量的FORWARD规则**

```bash
# VPN用户可以访问office
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN用户可以访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN用户不能访问dmz:22（拒绝+LOG）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: "

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
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
![alt text](06-vpn-status.png)
**任务3.6：验证VPN访问**

```bash
# VPN隧道状态
sudo ip netns exec fw wg show
sudo ip netns exec remote wg show

# 测试VPN访问（应该成功）
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/

# 测试VPN访问（应该失败+LOG）
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:22/
sudo ip netns exec remote ping -c 2 10.30.0.2
```
![alt text](07-vpn-success.png)
![alt text](08-vpn-deny.png)
VPN 配置说明
AllowedIPs 设计思路
端	AllowedIPs	设计理由
fw 端	10.10.10.2/32	严格限制对端 VPN IP，防止 IP 伪造或未经授权的对端接入
remote 端	10.20.0.0/24, 10.40.0.0/24	精确路由控制：只将企业内网（office + dmz）流量通过 VPN，避免所有流量走 VPN（如 0.0.0.0/0），优化路由效率，减少隧道负载
### 提交内容

1. **WireGuard配置文件**：fw端和remote端的`wg0.conf`
2. **wg show截图**：显示握手成功、transfer计数
3. **VPN访问测试截图**：成功和失败场景各3个
4. **路由表截图**：`remote`的`ip route`，能看到VPN相关路由
5. **VPN配置说明**：说明`AllowedIPs`的设计思路

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 隧道建立 | 8分 | wg show显示握手成功、有transfer |
| AllowedIPs配置 | 6分 | remote端只让指定网段走VPN |
| 访问控制 | 6分 | VPN用户只能访问授权服务 |

**扣分项：**
- `remote`的`AllowedIPs = 0.0.0.0/0`导致所有流量走VPN：-5分
- VPN用户能访问未授权服务：每处-3分

---

## 六、第四部分：安全审计与日志分析（15分）

### 任务清单

**任务4.1：配置LOG规则**

为所有REJECT规则配置对应的LOG规则，使用不同的`log-prefix`区分：

| 事件类型 | log-prefix | 速率限制 |
|:--------|:-----------|:---------|
| guest访问office | `GUEST-TO-OFFICE:` | 5/min burst 10 |
| guest访问dmz | `GUEST-TO-DMZ:` | 5/min burst 10 |
| VPN访问dmz:22 | `VPN-TO-DMZ-SSH:` | 无限制 |
| internet访问内网 | `INET-TO-OFFICE:` | 5/min burst 10 |
| 其他VPN违规 | `VPN-DENY:` | 5/min burst 10 |

```bash
# 示例：带速率限制的LOG规则
sudo ip netns exec fw iptables -I FORWARD [行号] \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
```

**任务4.2：模拟5种违规访问场景**

```bash
# 场景1：guest尝试访问office
sudo ip netns exec guest curl --max-time 2 http://10.20.0.2:8000/

# 场景2：guest尝试访问dmz
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/

# 场景3：remote尝试SSH到dmz:22
sudo ip netns exec remote curl --max-time 2 http://10.40.0.2:22/

# 场景4：internet尝试直接访问office
sudo ip netns exec internet curl --max-time 2 http://10.20.0.2:8000/

# 场景5：internet尝试访问dmz的未映射端口
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:3306/
```
![alt text](09-logs-realtime.png)
**任务4.3：提取和分析日志**

```bash
# 实时监控日志
sudo journalctl -k -f

# 统计各类事件频次
sudo journalctl -k --grep "GUEST-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager | wc -l
sudo journalctl -k --grep "VPN-TO-DMZ-SSH" --no-pager | wc -l
sudo journalctl -k --grep "INET-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "VPN-DENY" --no-pager | wc -l
![alt text](10-logs-stats.png)
# 查看最近10条日志
sudo journalctl -k --grep "GUEST-TO-OFFICE|GUEST-TO-DMZ|VPN-" --no-pager | tail -10
```

**任务4.4：填写日志统计表**

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office |336 | 4| 是|
| guest→dmz | 120|2 |是 |
| VPN→dmz:22 | 10|10 | 是|
| internet→office | 0| 0| 是|
| VPN其他违规 |0 |0 | 是|
日志分析报告
一、从日志中能获取哪些安全信息？
从防火墙日志中可以获取以下关键安全信息：
1. 攻击来源识别：通过日志中的 IN= 字段可以识别攻击流量从哪个网络接口进入防火墙（如 veth-fw-guest 表示来自访客网络），通过 SRC= 字段可以获取攻击者的具体 IP 地址。
2. 攻击目标识别：通过 OUT= 字段可以识别攻击流量要转发到哪个网络接口（如 veth-fw-office 表示目标为办公网），通过 DST= 字段可以获取被攻击目标的 IP 地址。
3. 攻击类型识别：通过 PROTO= 字段可识别攻击使用的协议（TCP/UDP/ICMP），通过 DPT= 字段可识别攻击的目标端口（如 22 表示 SSH、8080 表示 Web），从而判断攻击性质（端口扫描、暴力破解等）。
4. 攻击时间识别：日志中的时间戳记录了攻击发生的精确时间，便于进行攻击时序分析和溯源。
5. 规则匹配识别：通过 log-prefix（如 GUEST-TO-OFFICE:）可快速识别被匹配的防火墙规则，了解攻击触发了哪种安全策略。
二、LOG规则为什么要放在REJECT之前？
LOG 规则必须放在 REJECT 之前的原因是 iptables 规则按顺序依次匹配执行。当数据包匹配到某条规则后，会立即执行该规则指定的动作，后续规则不再被执行。
如果将 LOG 规则放在 REJECT 之后，当数据包匹配到前面的 REJECT 规则时，包会被立即丢弃并返回 ICMP 错误消息，后续的 LOG 规则永远不会被执行，导致违规访问无法被记录。
正确的做法是将 LOG 规则紧贴在对应的 REJECT 规则之前，确保每次违规访问在被拒绝之前都被完整记录。这为安全审计、攻击溯源、事后分析和取证提供了完整的日志证据，是安全运维中必须遵循的规则设计原则。
三、速率限制如何防止日志洪水攻击？
速率限制通过 -m limit 模块实现对日志记录频率的控制。例如 --limit 5/min --limit-burst 10 表示：前 10 个数据包全部记录，之后每分钟最多只记录 5 个数据包。
当攻击者使用自动化工具高速扫描时，每秒可能发送数百上千个违规请求。如果没有速率限制，防火墙会对每个请求都生成日志，导致：一是磁盘空间迅速被海量日志填满；二是系统 CPU 和 I/O 资源大量消耗在日志处理上，影响正常业务；三是大量重复日志淹没了真正有价值的告警信息。
启用速率限制后，即使在遭受高强度扫描攻击时，每分钟也仅记录少量日志。这既能保留攻击特征供分析，又能防止日志洪水攻击导致的资源耗尽，同时满足了安全合规对日志留存的要求。
四、不同log-prefix的作用是什么？
不同 log-prefix 的核心作用是在日志中快速标识违规访问的类型和来源，实现日志的快速分类和过滤。
具体而言，GUEST-TO-OFFICE: 标识访客试图访问办公网，GUEST-TO-DMZ: 标识访客试图访问 DMZ，VPN-TO-DMZ-SSH: 标识 VPN 用户试图 SSH 访问 DMZ，OFFICE-TO-DMZ-SSH: 标识办公网主机试图 SSH 访问 DMZ，INET-TO-OFFICE: 标识外网试图访问办公网，VPN-DENY: 标识 VPN 用户的其他违规行为。
通过不同的 log-prefix，运维人员可以在 journalctl 或 dmesg 中通过 grep 快速筛选特定类型的安全事件，例如 grep "GUEST-TO-OFFICE" 即可查看所有访客访问办公网的违规记录。这大大提高了日志分析的效率，便于建立自动化告警规则，实现不同事件不同级别的响应。

### 提交内容

1. **LOG规则配置截图**：显示所有LOG规则的行号和参数
2. **5种违规场景截图**：触发命令和失败结果
3. **journalctl日志截图**：至少5条，包含完整字段（IN、OUT、SRC、DST、DPT）
4. **日志统计表**：填写完整
5. **日志分析报告**（300-500字）：
   - 从日志中能获取哪些安全信息？
   - LOG规则为什么要放在REJECT之前？
   - 速率限制如何防止日志洪水攻击？
   - 不同log-prefix的作用是什么？

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| LOG规则完整 | 4分 | 所有REJECT都有对应LOG |
| 日志提取 | 4分 | 能正确使用journalctl提取和统计 |
| 日志分析报告 | 7分 | 分析深入、理解透彻 |

## 七、第五部分：攻防演练与故障排查（15分）

### 5.1 攻击方任务（从guest发起）（5分）

**攻击1：扫描office网段**

尝试扫描`10.20.0.0/24`网段，观察防火墙是否拦截：

```bash
# 尝试ping扫描
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```
结果： 只有网关可达，office主机不可达
失败原因分析：
防火墙FORWARD链配置了guest→office的REJECT规则，所有从veth-fw-guest进入、目标为office网络的ICMP包被拒绝并返回icmp-port-unreachable。防火墙明确告知客户端目标不可达，网关10.20.0.1可达是因为INPUT链允许ICMP。日志记录显示"GUEST-TO-OFFICE"规则匹配并记录了每次扫描尝试，扫描完全失效。
![alt text](11-attack-scan.png)
**攻击2：尝试绕过防火墙访问dmz:22**

尝试改变源端口、使用不同协议等方法：

```bash
# 尝试用不同源端口
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```
结果： 所有连接被拒绝
失败原因分析：
防火墙配置了区域间访问控制，明确拒绝guest访问dmz的SSH服务。iptables匹配完整五元组（源IP、目的IP、协议、源端口、目的端口），改变源端口不影响规则匹配。从日志看到"GUEST-TO-DMZ"规则触发REJECT，返回icmp-port-unreachable。防火墙基于区域策略过滤，所有绕过尝试均失败。
![alt text](12-attack-bypass.png)
**攻击3：尝试伪造VPN流量**

思考：攻击者能否伪造源地址为`10.10.10.2`的包来访问内网？

```bash
# 这个攻击会成功吗？为什么？
```
不能成功
失败原因分析：
三重防护确保VPN流量无法伪造：1) rp_filter反向路径过滤检测到非对称路由，丢弃伪造包；2) WireGuard使用加密隧道和公钥认证，伪造包无法通过加密验证；3) 防火墙基于入接口判断，guest接口进入的包即使src=10.10.10.2也不会被当作VPN流量转发（VPN流量必须从wg0接口进入）。攻击者无法绕过这三层防护。
- 回答：攻击者能否从REJECT和DROP的不同表现判断目标是否存在？
理论上可以通过差异判断：REJECT返回明确错误消息（ICMP unreachable或TCP RST），DROP完全无响应。但现代防火墙混合使用两种策略来迷惑攻击者，不能完全依赖。本实验中guest→office使用REJECT（返回icmp-port-unreachable），而某些场景使用DROP。如果扫描时部分端口REJECT、部分无响应，可能说明防火墙策略差异，但也可能是目标主机不存在导致的超时，需综合判断。
### 5.2 防御方任务（日志分析与规则分析）（5分）

**任务1：从日志中识别攻击**

```bash
# 查看最近的所有拒绝日志
sudo journalctl -k --since "10 minutes ago" --grep "GUEST-|VPN-|INET-" --no-pager
```
![alt text](14-defense-counters.png)
回答问题：
1. 从日志的哪些字段可以判断这是来自guest的攻击？
从以下字段判断攻击来自guest：IN=veth-fw-guest（入接口为guest网卡，表明包从guest网络进入）、SRC=10.30.0.x（源地址在guest子网，确认来源区域）、OUT=veth-fw-office（目标指向office网络，说明是跨区域访问行为）、PROTO=ICMP（ping扫描是典型侦察行为）。日志前缀"GUEST-TO-OFFICE"明确标识被匹配的防火墙链。这些字段组合确定攻击来自guest区域，意图访问受保护的office网络，属于违规访问行为。
2. 如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？
说明包从guest网络进入防火墙，经路由决策后转发到office网络，属于南北向跨区域转发。该组合触发了GUEST→OFFICE的访问控制规则，防火墙在FORWARD链上处理此包。表明防火墙成功识别了流量的源区域和目的区域，并进行了策略匹配，是区域隔离机制生效的标志。同时说明包不是本地回环或同一区域内的通信，而是跨区域访问尝试，需要被防火墙规则处理。
3. 为什么看到大量相同来源的日志应该引起警惕？
表明单一主机正在主动扫描或攻击内网，可能使用自动化工具（如nmap、masscan）批量探测。流量模式异常，正常业务不会产生大量重复日志。可能预示暴力破解、DDoS攻击前兆，或该主机已被入侵作为跳板攻击内网其他系统。管理员应立即调查源IP，检查该主机的进程和网络连接，必要时临时封禁该IP，并部署IDS/IPS进行深度包检测和告警。
**任务2：分析规则的防御效果**

```bash
# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
![alt text](14-defense-counters.png)
回答问题：
1. 哪条规则拦截了guest访问office？
拦截guest访问office的是FORWARD链中IN=veth-fw-guest OUT=veth-fw-office的REJECT规则，匹配source=10.30.0.0/24 destination=10.20.0.0/24，target为REJECT。规则计数器pkts=125显示已被拦截125个包。该规则前还配置了limit模块（avg 5/min burst 10）的LOG规则，控制日志速率避免洪水攻击。规则顺序合理：LOG在前REJECT在后。
2. 如果guest→office的规则计数很高，说明了什么？
说明guest网络存在异常扫描或攻击行为，可能被入侵或感染恶意软件（如挖矿病毒、DDoS木马）。违反安全策略的访问尝试频繁发生，防火墙有效工作持续拦截违规流量。计数器数值越高，表明攻击越持续或越猛烈。管理员应立即调查guest网络的异常主机，检查是否有未授权服务运行，可能需要加强guest网络的访问控制或隔离措施，甚至考虑将该主机从网络中隔离。
3. REJECT和DROP在安全性上有什么区别？
REJECT返回错误消息（ICMP unreachable或TCP RST），快速失败但暴露防火墙存在，便于攻击者进行端口扫描和服务识别。DROP静默丢弃无响应，隐藏服务存在增加攻击难度，但客户端需等待超时可能影响用户体验。安全性上DROP更优，不提供任何反馈信息；REJECT更友好但信息泄露较多。生产环境常在信任区域使用REJECT便于调试，在非信任区域使用DROP减少信息泄露。
**提交内容：**
- 日志截图（含攻击特征）
- 规则计数器截图
- 3个问题的回答（各150字）

### 5.3 边界测试与改进方案（5分）

**找出潜在的安全问题：**

1. **office无限制访问internet**
   - 风险：员工可能访问恶意网站、下载病毒
   - 改进方案：配置白名单、使用Web过滤、限制可访问端口

2. **dmz:8080对外开放**
   - 风险：可能被DDoS攻击、Web漏洞利用
   - 改进方案：配置connlimit限制连接数、使用反向代理、WAF

3. **VPN没有限制连接频率**
   - 风险：可能被暴力破解、端口扫描
   - 改进方案：使用recent模块限制连接频率、fail2ban

**任务要求：**
1. 从上述3个问题中选择1个实现改进方案（或提出自己发现的其他问题）
选择的问题：dmz:8080对外开放
风险分析
DMZ 的 8080 端口对公网完全开放，仅依靠基础防火墙放行，无并发连接限制，存在三大安全风险。
第一，易遭受 CC/DoS 攻击。攻击者可利用大量肉鸡或代理IP，向 Web 服务发起海量并发请求，短时间内新建数以万计的 TCP 连接，耗尽服务器的端口资源和防火墙的连接跟踪表（conntrack table），导致正常用户无法访问，Web 服务完全瘫痪。
第二，开放端口易被漏洞扫描器探测。攻击者使用自动化工具对 8080 端口进行高频扫描，探测 Web 应用类型、版本及潜在漏洞。若 Web 程序存在 SQL 注入、文件上传、反序列化等代码漏洞，攻击者可利用漏洞入侵 DMZ 服务器，进一步横向渗透内网办公区和数据库服务器。
第三，慢速攻击风险。攻击者建立连接后不发送完整请求，以极低速率发送数据，长时间占用连接池，消耗 Web 服务器线程资源，导致合法请求排队等待超时。
现有策略仅做访问放行，无流量管控、无并发限制、无速率控制，边界防护薄弱，不符合企业纵深防御安全标准。需增加连接并发限制和新建连接速率限制加固边界，提升 Web 服务的可用性和安全性。
2. 写出具体的iptables规则或配置方法
限制单 IP 对 dmz:8080 的最大并发连接数（connlimit）
#!/bin/bash
# dmz-web-protection.sh - DMZ Web服务连接数限制

echo "=== 配置DMZ Web服务防护规则 ==="

# 1. 清除可能存在的旧规则（避免重复）
sudo ip netns exec fw iptables -D FORWARD -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT 2>/dev/null
sudo ip netns exec fw iptables -D FORWARD -p tcp --syn --dport 8080 -d 10.40.0.2 -m limit --limit 5/second --limit-burst 10 -j ACCEPT 2>/dev/null

# 2. connlimit规则（限制单IP并发连接数不超过10个）
sudo ip netns exec fw iptables -I FORWARD 2 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j LOG --log-prefix "DMZ-WEB-CONNLIMIT: " --log-level 4

sudo ip netns exec fw iptables -I FORWARD 3 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset

# 3. limit规则（限制新建连接速率：每秒最多5个，burst 10）
sudo ip netns exec fw iptables -I FORWARD 4 -p tcp --syn --dport 8080 -d 10.40.0.2 -m limit --limit 5/second --limit-burst 10 -j ACCEPT

sudo ip netns exec fw iptables -I FORWARD 5 -p tcp --syn --dport 8080 -d 10.40.0.2 -j LOG --log-prefix "DMZ-WEB-RATELIMIT: " --log-level 4

sudo ip netns exec fw iptables -I FORWARD 6 -p tcp --syn --dport 8080 -d 10.40.0.2 -j DROP

# 4. 验证规则
echo ""
echo "=== 当前FORWARD链规则（前20条） ==="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -20

echo ""
echo "=== connlimit规则验证 ==="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "connlimit|limit"

echo ""
echo "✅ DMZ Web服务防护规则配置完成"
```bash
![alt text](15-improvement.png)
**提交内容：**
- 选择的问题及风险分析（200字）
- 改进方案的实现代码
- 测试效果截图

### 5.4 高级任务：追踪包的完整变化过程（加分5分）

**任务：追踪一次"remote通过VPN访问dmz:8080"的完整过程**

要求在4个位置同时抓包：

```bash
# 终端1：remote的wg0接口（看到封装前的包）
sudo ip netns exec remote tcpdump -ni wg0 -c 5

# 终端2：fw的wg0接口（看到解封装后的包）
sudo ip netns exec fw tcpdump -ni wg0 -c 5

# 终端3：fw的veth-fw-dmz接口（看到转发到dmz的包）
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5

# 终端4：fw的conntrack表
watch -n 1 'sudo ip netns exec fw conntrack -L | grep 10.10.10.2'

# 终端5：触发访问
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

**填写包变化对比表：**

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
分析报告：
本次实验追踪了 remote 通过 VPN 访问 dmz:8080 的完整包处理过程，从三个位置抓包分析。
第一阶段，包在 remote 命名空间生成，源地址为 VPN 客户端 10.10.10.2，目的地址为 DMZ 服务器 10.40.0.2:8080，包含完整的 HTTP GET 请求，ttl=64。此时包未经加密，是原始应用层数据。
第二阶段，包通过 WireGuard 隧道到达防火墙，fw 的 wg0 接口接收并解密。源地址和目的地址保持不变，ttl 减为63。防火墙识别到包来自 VPN 客户端，源地址为 10.10.10.2，入接口为 wg0，开始路由决策。
第三阶段，防火墙检查路由表，发现 10.40.0.0/24 通过 veth-fw-dmz 接口可达。FORWARD 链规则匹配成功，允许 VPN→DMZ 的新建连接，包被转发到 DMZ 区域。包结构不变，ttl 保持63。
第四阶段，conntrack 模块记录连接状态，从 NEW 变为 ESTABLISHED。由于 VPN 到 DMZ 是直连，无 NAT 转换，地址在整个路径中保持一致。DMZ 服务器处理 HTTP 请求并返回响应，通过已建立的连接原路返回。
整个过程中，WireGuard 提供加密隧道保证传输安全，防火墙基于状态检测和区域策略实现访问控制，conntrack 记录连接状态确保回包快速匹配。src/dst 全程保持不变（10.10.10.2 → 10.40.0.2），无 NAT 转换，ttl 从64递减至63。
**提交内容：**
- 4个位置的抓包截图
- 包变化对比表
- conntrack记录截图
- 分析报告（300字）：说明包是如何一步步被处理的

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 攻击方演练 | 5分 | 3种攻击完整、分析合理 |
| 防御方分析 | 5分 | 日志分析准确、规则理解透彻 |
| 边界测试与改进 | 5分 | 问题识别准确、方案可行、有测试 |
| 高级任务（加分） | 5分 | 抓包完整、分析深入 |

---

## 八、故障排查专题（体现Plan1的开放性）
场景1：DNAT配置了但外网无法访问
1.1 重现故障
步骤1：删除 DNAT 对应的 FORWARD 放行规则
bash
echo "=== 场景1：DNAT故障重现 ==="
sudo ip netns exec fw iptables -D FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "10.40.0.2"
步骤2：确认故障现象
bash
echo "--- 测试外网访问（预期失败） ---"
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/ 2>&1
1.2 排查过程
bash
echo "=== 排查1：检查DNAT规则 ==="
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers | grep -E "DNAT|8080"
echo "=== 排查2：检查FORWARD放行规则 ==="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "10.40.0.2.*8080"
echo "=== 排查3：检查dmz默认路由 ==="
sudo ip netns exec dmz ip route
echo "=== 排查4：检查conntrack记录 ==="
sudo ip netns exec fw conntrack -L | grep -E "203.0.113|10.40.0.2"
1.3 根本原因
DNAT 规则成功将目的地址转换为 10.40.0.2:8080，但 FORWARD 链缺少对应的放行规则。由于 FORWARD 默认策略为 DROP，转换后的包在 FORWARD 链被丢弃，无法到达 DMZ 服务器。
1.4 修复并验证
bash
echo "=== 修复DNAT故障 ==="
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
echo "--- 验证修复（预期成功） ---"
sudo ip netns exec internet curl -s -o /dev/null -w "HTTP状态: %{http_code}\n" --max-time 3 http://203.0.113.1:8080/
![alt text](19-troubleshoot-dnat.png)
### 场景2：VPN隧道握手正常但业务访问失败
2.1 重现故障（原因1：AllowedIPs 配置错误）
bash
echo "=== 场景2：VPN故障 - 原因1：AllowedIPs配置错误 ==="
sudo ip netns exec remote wg show
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24
echo "--- 测试VPN访问dmz（预期失败） ---"
sudo ip netns exec remote ping -c 2 10.40.0.2
2.2 排查过程（原因1）
bash
echo "=== 排查1：检查路由表 ==="
sudo ip netns exec remote ip route | grep -E "wg0|10.40.0"
echo "=== 排查2：检查wg状态 ==="
sudo ip netns exec remote wg show
2.3 修复方法（原因1）
bash
echo "=== 修复：恢复正确的AllowedIPs ==="
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24,10.40.0.0/24
sudo ip netns exec remote ping -c 2 10.40.0.2
2.4 重现故障（原因2：FORWARD 规则缺失）
bash
echo "=== 场景2：VPN故障 - 原因2：FORWARD规则缺失 ==="
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24,10.40.0.0/24
sudo ip netns exec fw iptables -D FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null
echo "--- 测试VPN访问dmz:8080（预期失败） ---"
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/ 2>&1
2.5 排查过程（原因2）
bash
echo "=== 排查1：检查wg状态 ==="
sudo ip netns exec remote wg show
echo "=== 排查2：检查路由表 ==="
sudo ip netns exec remote ip route | grep 10.40.0
echo "=== 排查3：检查FORWARD规则 ==="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "wg0|10.40.0"
echo "=== 排查4：检查防火墙日志 ==="
sudo dmesg | grep "VPN-DENY" | tail -3
2.6 修复方法（原因2）
bash
echo "=== 修复：恢复VPN→dmz的FORWARD规则 ==="
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
sudo ip netns exec remote curl -s -o /dev/null -w "HTTP状态: %{http_code}\n" http://10.40.0.2:8080/
![alt text](20-troubleshoot-vpn.png)

### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败
3.1 重现故障
bash
echo "=== 场景3：去掉ESTABLISHED,RELATED状态检测 ==="

sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "RELATED,ESTABLISHED"

sudo ip netns exec fw iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "--- 测试VPN访问dmz:8080（预期超时） ---"
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/ 2>&1
3.2 抓包证明 SYN-ACK 被拦截
bash
echo "=== 抓包分析：证明SYN-ACK被拦截 ==="
# 终端1：抓取 fw 的 wg0 接口（VPN侧）
sudo ip netns exec fw tcpdump -ni wg0 -c 10 host 10.10.10.2 &
# 终端2：抓取 fw 的 veth-fw-dmz 接口（DMZ侧）
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 host 10.40.0.2 &
# 终端3：触发访问
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/
抓包结果分析：
bash
# wg0 接口可以看到 SYN 包发出，但看不到 SYN-ACK 返回
# veth-fw-dmz 接口可以看到 SYN 包到达，SYN-ACK 发出后被拦截
# 正常流程：
# 1. SYN 包：防火墙允许通过（匹配 NEW 规则）
# 2. SYN-ACK 回包：没有 ESTABLISHED 规则放行，被默认 DROP 丢弃
# 3. TCP 三次握手无法完成，curl 超时
3.3 根本原因分析
bash
echo "=== 根本原因分析 ==="
sudo ip netns exec fw conntrack -L | grep 10.40.0.2
3.4 修复验证
bash
echo "=== 恢复ESTABLISHED,RELATED规则 ==="
sudo ip netns exec fw iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
echo "--- 验证修复（预期成功） ---"
sudo ip netns exec remote curl -s -o /dev/null -w "HTTP状态: %{http_code}\n" http://10.40.0.2:8080/

---
## 九、遇到的问题和解决方法
问题1：veth对创建后无法通信
现象： ping 不同区域的地址时无响应，100% packet loss。
原因： 未开启 IP 转发功能，fw 无法在不同网络接口之间路由数据包。
解决方法：
bash
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.ip_forward=1   # 宿主机兜底
问题2：WireGuard 隧道无法握手
现象： wg show 显示无握手信息（latest handshake 为空），transfer 计数为 0。
原因： 防火墙 INPUT 链默认 DROP，阻止了 UDP 51820 端口的 WireGuard 握手包。
解决方法：
bash
# 放行 WireGuard 端口
sudo ip netns exec fw iptables -A INPUT -i wg0 -p udp --dport 51820 -j ACCEPT
# 或使用更精确的规则
sudo ip netns exec fw iptables -A INPUT -p udp --dport 51820 -j ACCEPT
问题3：日志速率限制导致部分日志丢失
现象： 触发违规访问的次数多于实际记录日志数。
原因： limit 模块限制了日志记录速率（如 --limit 5/min --limit-burst 10），超过速率限制的日志不再记录。
解决方法：
bash
# 方法1：调整 limit 参数
-m limit --limit 10/min --limit-burst 20
# 方法2：移除速率限制（不推荐用于生产环境）
# 直接移除 -m limit 参数
问题4：rp_filter 导致伪造 IP 失败
现象： 伪造源 IP 的包被丢弃，无法到达目标。
原因： rp_filter（反向路径过滤）检测到非对称路由，丢弃伪造源地址的包。这是 Linux 内核的安全特性。
解决方法：
bash
# 查看当前状态
sudo sysctl net.ipv4.conf.all.rp_filter
# 临时禁用（不推荐，会降低安全性）
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.veth-fw-guest.rp_filter=0
# 保持启用（推荐）
# 这是安全特性，不应禁用
问题5：VPN AllowedIPs 配置错误导致业务不通
现象： wg show 显示握手正常，但 remote 无法访问内网服务。
原因： remote 端的 AllowedIPs 未包含目标网段，导致该网段流量不走 VPN 隧道。
解决方法：
bash
# 查看当前路由表
sudo ip netns exec remote ip route
# 修复：添加正确的 AllowedIPs
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24,10.40.0.0/24
## 十、总结与思考
通过本次企业级网络安全架构搭建与攻防演练实验，我深入理解了多层防护体系的设计理念和实现方法。整个项目涵盖了网络命名空间隔离、防火墙策略设计、VPN远程接入、安全审计日志以及攻防演练等多个关键领域，让我对企业网络安全架构有了系统性的认识。
核心收获：
第一，最小权限原则是安全设计的基石。防火墙规则必须遵循最小权限原则，只放行必要的服务访问。本实验中office只能访问dmz:8080而不能访问dmz:22，guest只能上网不能访问内网，VPN用户只能访问授权的office和dmz:8080。这种精细化的访问控制有效降低了攻击面，即使某个区域被攻破，攻击者也无法横向移动到其他区域，实现了真正的区域隔离。
第二，状态检测是防火墙性能优化的关键。-m conntrack --ctstate ESTABLISHED,RELATED规则让防火墙只检查新连接，后续包直接放行，大幅提升性能。在场景3故障排查中，去掉该规则后TCP连接立即失败，因为SYN-ACK回包无法通过。这让我深刻理解了状态检测的必要性——没有它，防火墙将无法正常工作。
第三，日志审计是安全运维的眼睛。通过LOG规则和journalctl可以实时监控安全事件。不同log-prefix（如GUEST-TO-OFFICE、VPN-TO-DMZ-SSH）帮助快速识别攻击类型，速率限制（limit模块）防止日志洪水攻击，保护系统资源。日志中记录的IN、OUT、SRC、DST、DPT等字段为安全事件溯源提供了完整证据链。
第四，VPN安全配置需要精细化控制。AllowedIPs的设计直接影响VPN路由。remote端只将10.20.0.0/24和10.40.0.0/24指向VPN，避免所有流量走VPN（如0.0.0.0/0），既保证内网访问又优化了路由效率。VPN加连接频率限制可有效防御暴力破解和资源耗尽攻击。
第五，攻防视角转换让我深刻理解了REJECT vs DROP的策略选择。REJECT快速失败但暴露信息，DROP静默丢弃更安全但影响用户体验。本实验guest→office使用REJECT（返回icmp-port-unreachable），便于实验调试；实际生产环境中，DMZ对外服务建议使用DROP以减少信息泄露。
第六，WireGuard协议的安全特性。WireGuard使用UDP 51820端口，采用公钥认证和加密隧道。伪造源IP的攻击因rp_filter、加密验证、入接口判断三重防护而无法成功，体现了纵深防御的有效性。
改进方向与未来展望：
考虑使用nfqueue将可疑流量交给用户态程序进行深度分析
部署Suricata/Snort进行IDS/IPS深度包检测
使用fail2ban实现自动封禁恶意IP
配置更详细的审计日志并集中存储到ELK或Syslog服务器
增加VPN双因素认证（如TOTP）
定期进行安全评估和渗透测试
本次实验让我认识到企业网络安全不是单一技术问题，而是需要多层面、多角度的综合防护。从网络隔离、访问控制、加密传输到安全审计，每个环节都不可或缺。同时要站在攻击者视角思考弱点，持续改进安全策略，才能构建真正安全的企业网络架构。网络安全没有终点，只有不断完善和进化的过程。
## 提交要求

### 文件结构

```text
学号姓名/
└── FinalProject/
    ├── README.md           # 实验报告主文档
    ├── setup.sh            # 拓扑搭建脚本
    ├── firewall.sh         # 防火墙规则配置脚本
    ├── vpn-fw.conf         # VPN服务端配置
    ├── vpn-remote.conf     # VPN客户端配置
    ├── screenshots/        # 所有截图（至少20张）
    │   ├── 01-topology.png
    │   ├── 02-firewall-rules.png
    │   ├── 03-access-matrix.png
    │   ├── 04-vpn-status.png
    │   ├── 05-logs.png
    │   ├── 06-attack-*.png
    │   ├── 07-tcpdump-*.png
    │   └── ...
    ├── analysis.md         # 攻防演练分析报告
    └── troubleshooting.md  # 故障排查报告
```

### README.md格式要求

```markdown
# 企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：
- WireGuard版本：
- iptables版本：

## 二、拓扑图和地址规划
（手绘或工具绘制的拓扑图）
（地址规划表）

## 三、第一部分：网络规划与基础搭建
（包含setup.sh的说明和连通性测试结果）

## 四、第二部分：防火墙策略实现
（包含firewall.sh的说明和访问控制矩阵）

## 五、第三部分：VPN远程接入
（包含WireGuard配置说明和测试结果）

## 六、第四部分：安全审计与日志分析
（包含LOG规则说明和日志分析报告）

## 七、第五部分：攻防演练
（包含攻击演练、防御分析、边界测试）

## 八、故障排查
（包含至少3个故障场景的排查过程）

## 九、遇到的问题和解决方法
（实验过程中的实际问题和解决思路）

## 十、总结与思考
（至少500字，包含对企业网络安全架构的整体理解）
```

### 截图清单（至少20张）

| 序号 | 内容 | 文件名 |
|:-----|:-----|:-------|
| 1 | 拓扑搭建后的连通性测试 | 01-topology.png |
| 2 | 完整的防火墙规则列表 | 02-firewall-rules.png |
| 3 | NAT规则列表 | 03-nat-rules.png |
| 4 | 访问控制测试矩阵（成功场景） | 04-access-success.png |
| 5 | 访问控制测试矩阵（失败场景） | 05-access-deny.png |
| 6 | VPN隧道状态（wg show） | 06-vpn-status.png |
| 7 | VPN访问测试（成功） | 07-vpn-success.png |
| 8 | VPN访问测试（失败+LOG） | 08-vpn-deny.png |
| 9 | 日志实时监控 | 09-logs-realtime.png |
| 10 | 日志统计结果 | 10-logs-stats.png |
| 11 | 攻击演练场景1 | 11-attack-scan.png |
| 12 | 攻击演练场景2 | 12-attack-bypass.png |
| 13 | 防御分析-日志证据 | 13-defense-logs.png |
| 14 | 防御分析-规则计数器 | 14-defense-counters.png |
| 15 | 边界测试改进方案 | 15-improvement.png |
| 16 | 高级任务-remote抓包 | 16-tcpdump-remote.png |
| 17 | 高级任务-fw抓包 | 17-tcpdump-fw.png |
| 18 | 高级任务-conntrack | 18-conntrack.png |
| 19 | 故障排查场景1 | 19-troubleshoot-dnat.png |
| 20 | 故障排查场景2 | 20-troubleshoot-vpn.png |

---

## 评分标准

### 总分：100分 + 加分5分

| 部分 | 分值 | 评分细则 |
|:----|:-----|:---------|
| 第一部分：网络规划 | 20分 | 拓扑正确10分、脚本可运行5分、连通性验证5分 |
| 第二部分：防火墙策略 | 30分 | 规则完整性10分、访问控制正确性10分、NAT配置5分、规则设计5分 |
| 第三部分：VPN接入 | 20分 | 隧道建立8分、AllowedIPs配置6分、访问控制6分 |
| 第四部分：安全审计 | 15分 | LOG规则4分、日志提取4分、分析报告7分 |
| 第五部分：攻防演练 | 15分 | 攻击演练5分、防御分析5分、边界测试5分 |
| 高级任务（加分） | 5分 | 包追踪完整性3分、分析深度2分 |

### 扣分项

| 扣分原因 | 扣分 |
|:--------|:-----|
| 截图不清晰、缺失关键字段 | 每处-2分 |
| 规则错误导致安全漏洞 | 每处-5分 |
| 脚本无法运行、拓扑无法复现 | -10分 |
| README.md格式混乱、缺少必要说明 | -5分 |
| 故障排查报告敷衍、未深入分析 | -5分 |
| 抄袭或雷同 | 0分 |

### 优秀作业标准（90分以上）

1. 拓扑搭建脚本健壮，可重复运行，有完善的错误处理
2. 防火墙规则遵循最小权限原则，顺序合理，注释清晰
3. 访问控制测试全面，所有场景都有截图证据
4. VPN配置正确，AllowedIPs设计合理
5. 日志审计完整，分析报告深入，能提出改进建议
6. 攻防演练有创新性，能发现非明显的安全问题
7. 故障排查过程详细，思路清晰，能举一反三
8. README.md结构清晰，表达流畅，有个人思考
9. 完成高级任务，包追踪分析透彻

---

## 截止时间

**2026-07-03（18周结束前）**

届时关于期末大作业的PR将不会被合并。

---

