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
- 操作系统：
- WireGuard版本：
- iptables版本：

## 二、拓扑图和地址规划
## 网络拓扑
![](topology.png)

# 地址规划表
| 命名空间  | 网卡接口名称    | IP地址/子网     | 网段用途     |
|---------|---------------|----------------|------------|
| fw      | veth-fw-office | 10.20.0.1/24   | 办公网网关   |
| office  | veth-office    | 10.20.0.2/24   | 办公内网主机 |
| fw      | veth-fw-guest  | 10.30.0.1/24   | 访客网网关   |
| guest   | veth-guest     | 10.30.0.2/24   | 访客内网主机 |
| fw      | veth-fw-dmz    | 10.40.0.1/24   | DMZ服务区网关|
| dmz     | veth-dmz       | 10.40.0.2/24   | DMZ业务服务器|
| fw      | veth-fw-inet   | 203.0.113.1/24 | 外网出口网关 |
| internet| veth-inet      | 203.0.113.10/24| 模拟外网主机 |

### 规划说明
1. 内网三段业务网段 10.20.0.0/24、10.30.0.0/24、10.40.0.0/24 相互独立，无IP网段冲突；
2. 公网网段使用保留测试网段 203.0.113.0/24，与内网私网地址完全隔离；
3. 每个网段网关固定为网段第1个可用地址(.1)，业务主机固定为网段第2个地址(.2)，分配规则统一清晰；
4. remote命名空间为VPN预留节点，任务1阶段无需分配IP，第三部分实验配置10.10.10.0/24隧道网段。

## 三、第一部分：网络规划与基础搭建
（包含setup.sh的说明和连通性测试结果）setup.sh
apyy@localhost:~$ # 创建6个网络命名空间
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
[sudo] password for apyy:
apyy@localhost:~$ # office网段veth配置
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip link set lo up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest网段veth配置
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# dmz网段veth配置
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
echo "sudo ip netns exec internet ping -c 2 203.0.113.1".0.113.1-inet
net.ipv4.ip_forward = 1
====拓扑搭建完成====
连通测试命令：
sudo ip netns exec office ping -c 2 10.20.0.1
sudo ip netns exec guest ping -c 2 10.30.0.1
sudo ip netns exec dmz ping -c 2 10.40.0.1
sudo ip netns exec internet ping -c 2 203.0.113.1
apyy@localhost:~$ # 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1

# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
RTNETLINK answers: File exists
RTNETLINK answers: File exists
RTNETLINK answers: File exists
net.ipv4.ip_forward = 1
apyy@localhost:~$ sudo ip netns exec office ping -c 2 10.20.0.1
PING 10.20.0.1 (10.20.0.1) 56(84) bytes of data.
64 bytes from 10.20.0.1: icmp_seq=1 ttl=64 time=0.094 ms
64 bytes from 10.20.0.1: icmp_seq=2 ttl=64 time=0.042 ms

--- 10.20.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1011ms
rtt min/avg/max/mdev = 0.042/0.068/0.094/0.026 ms
apyy@localhost:~$ sudo ip netns exec guest ping -c 2 10.30.0.1
PING 10.30.0.1 (10.30.0.1) 56(84) bytes of data.
64 bytes from 10.30.0.1: icmp_seq=1 ttl=64 time=0.148 ms
64 bytes from 10.30.0.1: icmp_seq=2 ttl=64 time=0.097 ms

--- 10.30.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1028ms
rtt min/avg/max/mdev = 0.097/0.122/0.148/0.025 ms
apyy@localhost:~$ sudo ip netns exec dmz ping -c 2 10.40.0.1
PING 10.40.0.1 (10.40.0.1) 56(84) bytes of data.
64 bytes from 10.40.0.1: icmp_seq=1 ttl=64 time=0.184 ms
64 bytes from 10.40.0.1: icmp_seq=2 ttl=64 time=0.037 ms

--- 10.40.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1016ms
rtt min/avg/max/mdev = 0.037/0.110/0.184/0.073 ms
apyy@localhost:~$ sudo ip netns exec internet ping -c 2 203.0.113.1
PING 203.0.113.1 (203.0.113.1) 56(84) bytes of data.
64 bytes from 203.0.113.1: icmp_seq=1 ttl=64 time=0.106 ms
64 bytes from 203.0.113.1: icmp_seq=2 ttl=64 time=0.042 ms

--- 203.0.113.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1011ms
rtt min/avg/max/mdev = 0.042/0.074/0.106/0.032 ms
apyy@localhost:~$

### 拓扑搭建说明
拓扑搭建步骤
1、环境清理：循环删除 fw、office、guest、dmz、internet、remote 所有旧网络命名空间，避免网卡、IP 冲突；
2、创建隔离域：依次创建 6 个网络命名空间，划分办公区、访客区、DMZ 服务区、外网、防火墙、预留 VPN 客户端区域；
3、虚拟链路搭建：为每个业务网段创建一对 veth 虚拟网线，一端绑定防火墙 fw，一端绑定对应业务主机；
4、IP 与网卡启用：为所有 veth 接口分配规划好的 IP 地址，启用网卡与本地回环 lo；
5、路由配置：所有业务主机配置默认路由，全部流量转发至防火墙对应网关；
6、开启跨网段转发：在 fw 命名空间开启 IPv4 转发，实现不同网段数据包互通。
### 验证方法：
查看命名空间：sudo ip netns list，确认 6 个隔离域全部创建；
查看网卡 IP：sudo ip netns exec fw ip addr，核对所有网关 IP 分配正确；
连通性 ping 测试：4 组主机 ping 对应网关，0% 丢包代表二层链路与路由配置正常；
转发校验：执行sudo ip netns exec fw sysctl net.ipv4.ip_forward，输出 1 代表转发功能开启。

![](01-topology.png)

## 四、第二部分：防火墙策略实现
（包含firewall.sh的说明和访问控制矩阵）
---

#!/bin/bash
# 任务二防火墙脚本，支持重复执行
# 清空旧规则，保证重复运行不叠加
sudo ip netns exec fw iptables -F FORWARD
sudo ip netns exec fw iptables -t nat -F
# 默认转发全部拒绝
sudo ip netns exec fw iptables -P FORWARD DROP
# 放行回程应答流量
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# 允许office访问dmz 8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拦截office访问dmz 22，日志+拒绝
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "OFFICE_BLOCK_SSH:" --log-level info
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with tcp-reset

# 拒绝guest访问office，带日志
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m conntrack --ctstate NEW \
  -j REJECT

# 拒绝guest访问dmz，带日志
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "GUEST-TO-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m conntrack --ctstate NEW \
  -j REJECT

# 内网SNAT上网
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# 外网DNAT映射8080到dmz
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

echo "防火墙规则加载完成，可重复运行"

## 规则设计说明
一、整体设计思路
以 fw 网络命名空间作为网段边界防火墙，采用默认拒绝、按需放行的安全策略。脚本启动时自动清空原有过滤与 NAT 规则，保证可重复运行；优先放行连接回程流量保障访问正常应答；按业务需求配置网段访问控制，所有拦截流量同步记录审计日志；通过 SNAT 实现内网共享公网上网，DNAT 实现外网端口映射内网业务服务；FORWARD 链默认策略设为 DROP，未匹配放行规则的跨网段流量全部阻断，遵循最小权限安全原则。
二、filter 表 FORWARD 过滤规则设计
回程连接放行规则
匹配 ESTABLISHED、RELATED 状态数据包并放行，仅允许已建立连接的应答流量回传，是所有访问规则的基础前置规则，避免单向请求无法接收返回数据。
office 访问 dmz 8080 放行规则
限定源网段 10.20.0.0/24、目标网段 10.40.0.0/24，仅放行 tcp 8080 端口新建连接，满足办公网段访问 DMZ 业务网页服务的业务需求。
office 访问 dmz 22 拦截规则
分为两条连续规则，第一条 LOG 规则匹配流量并写入内核日志，日志前缀为 OFFICE_BLOCK_SSH，用于安全审计追溯；第二条 REJECT 规则发送 tcp-reset 主动断开连接，禁止办公网段访问 DMZ 的 SSH 管理端口。
guest 访问 office 全量拦截规则
匹配入网卡 veth-fw-guest、出网卡 veth-fw-office 的新建连接，先通过 LOG 记录访客访问办公区行为，再使用 REJECT 拒绝连接，隔离访客网络与内网办公主机。
guest 访问 dmz 全量拦截规则
匹配入网卡 veth-fw-guest、出网卡 veth-fw-dmz 的新建连接，LOG 记录访问行为后 REJECT 阻断，禁止访客网段访问业务服务器区域。
DNAT 配套外网转发放行规则
匹配外网网卡流入、目标为 dmz 主机 10.40.0.2 的 tcp 8080 新建连接，配合 DNAT 端口映射规则，允许外网流量转发至内网 Web 服务。
FORWARD 默认策略
设置 FORWARD 链默认策略为 DROP，所有未匹配放行规则的跨网段流量直接丢弃，收紧网络访问边界。
三、nat 表地址转换规则设计
SNAT 内网共享上网规则
分别为 office (10.20.0.0/24)、guest (10.30.0.0/24)、dmz (10.40.0.0/24) 三个内网网段配置 MASQUERADE 源地址伪装，内网私有 IP 访问外网时自动转换为防火墙公网 IP，实现所有内网主机正常访问外网。
DNAT 外网端口映射规则
对外网网卡 veth-fw-inet 的 tcp 8080 端口流量做目的地址转换，转发至 dmz 服务器 10.40.0.2:8080，对外暴露业务网页；未配置 22 端口映射，外网无法访问 dmz 的 SSH 服务。
四、日志审计规则设计
全部拦截流量均配置独立 LOG 规则，每条规则设置专属日志前缀：OFFICE_BLOCK_SSH、GUEST-TO-OFFICE、GUEST-TO-DMZ。拦截行为会写入系统内核日志，可通过 dmesg 命令抓取日志记录，实现非法访问行为溯源与安全审计。
五、脚本可重复运行设计
脚本开头执行清空命令，分别清空 filter 表 FORWARD 链、nat 表全部规则，每次运行都会清除上一次加载的规则后重新完整配置，多次执行不会产生重复叠加规则，满足实验可重复运行要求。

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

访问控制矩阵
| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 |访问正常，返回网页 HTML |04-access-success.png |
| office | dmz:22 | 失败+LOG |连接被重置，dmesg 可捕获 OFFICE_BLOCK_SSH 日志 |05-access-deny.png |
| guest | office:任意 | 失败+LOG |连接被拒绝，生成 GUEST-TO-OFFICE 日志 |05-access-deny.png |
| guest | dmz:8080 | 失败+LOG |连接被拒绝，生成 GUEST-TO-DMZ 日志 |05-access-deny.png |
| guest | internet:任意 | 成功 |可正常访问外网，SNAT 地址转换生效 |04-access-success.png |
| office | internet:任意 | 成功 |可正常访问外网，SNAT 地址转换生效 |04-access-success.png |
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |外网访问 203.0.113.1:8080 跳转至 10.40.0.2:8080 |04-access-success.png |
| internet | dmz:22 | 失败 |无 DNAT 映射，外网无法访问 dmz 22 端口 |05-access-deny.png |

![](02-firewall-rules.png)

![]( 03-nat-rules.png)
## 五、第三部分：VPN远程接入
（包含WireGuard配置说明和测试结果）
![](04-access-success.png)
![](05-access-deny.png)
![](06-vpn-status.png)
![](07-vpn-success.png)
![](08-vpn-deny.png)

VPN配置说明
一、AllowedIPs 核心作用
AllowedIPs 同时承担路由分发与访问权限控制两项核心功能：
路由功能：系统自动生成静态路由，匹配该网段的流量全部转发至 wg0 隧道网卡，走 VPN 加密通道传输；
安全校验功能：仅接收对端 AllowedIPs 字段内网段发来的加密数据包，不属于列表内的报文直接丢弃，实现访问白名单隔离。
二、服务端 fw 配置：AllowedIPs = 10.10.10.2/32
设计思路：
精准限定客户端 VPN 虚拟地址，使用 32 位掩码仅放行单一客户端 IP 10.10.10.2，杜绝其他未知 VPN 地址接入内网；
最小安全隔离，服务端仅处理来自该客户端单地址的隧道流量，缩小内网攻击面；
配合防火墙转发规则，仅转发该客户端发起的、去往 10.20.0.0/24、10.40.0.0/24 业务网段的访问流量。
三、客户端 remote 配置：AllowedIPs = 10.20.0.0/24,10.40.0.0/24
设计思路：
限定客户端可访问的内网业务网段，仅办公网段与服务器网段加入允许列表；系统自动生成两条隧道路由，访问这两个网段自动走 VPN 隧道；
遵循最小权限原则，不配置 0.0.0.0/0 全局转发，外网流量不走 VPN，减轻服务端负载；同时屏蔽 10.30.0.0/24 等无关网段，客户端无法通过 VPN 访问该网段；
访问控制约束：客户端发起 10.30.0.0/24 网段请求时，无对应隧道路由，系统提示网络不可达，验证 AllowedIPs 对访问范围的管控能力。
四、整体设计原则
最小权限：两端仅填写业务必需网段 / 地址，不开放多余网段权限；
双向校验：两端 AllowedIPs 互相约束，双向过滤非法流量；
路由绑定：依靠该字段自动生成 VPN 专用路由，无需手动添加静态路由，简化组网配置。


## 六、第四部分：安全审计与日志分析
（包含LOG规则说明和日志分析报告）

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

# 查看最近10条日志
sudo journalctl -k --grep "GUEST-TO-OFFICE|GUEST-TO-DMZ|VPN-" --no-pager | tail -10
```


![](09-logs-realtime.png)
![](10-logs-stats.png)
**日志统计表**

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office |1 |1 |是 |
| guest→dmz |1 |1 |是 |
| VPN→dmz:22 |1 |1 |是 |
| internet→office |1 |1 |是 |
| VPN其他违规 |1 |1 |是 |

**日志分析报告**
本次基于 iptables 防火墙 LOG 审计日志开展安全分析，日志可提取多类关键安全信息，每条记录包含数据包五元组、访问方向、阻断原因、时间戳与自定义标记前缀，能够定位违规访问行为、识别内网区域越权访问、捕获端口扫描探测流量，同时区分合法业务访问与恶意尝试，为安全事件溯源、访问控制策略有效性校验、异常行为告警提供原始依据。LOG 规则必须放置在 REJECT 动作之前，因为 iptables 规则匹配一旦命中执行动作便会终止匹配流程，若先执行 REJECT 丢弃数据包，LOG 规则不会触发，流量行为无法留存审计记录，前置 LOG 可保证所有被拒绝流量先完成日志写入再执行阻断。针对大量扫描引发的日志洪水攻击，可通过 limit 速率限制模块约束日志生成频率，限定单位时间内相同类型日志输出条数，避免海量记录占满系统磁盘、挤占系统 IO 资源，防止日志服务崩溃掩盖真实安全事件。配置差异化 log-prefix 是日志分类检索的核心手段，如 OFFICE_BLOCK_SSH、GUEST-TO-OFFICE 等专属标记，可快速区分不同区域、不同违规场景的日志，无需逐条解析五元组即可筛选办公区 SSH 拦截、访客跨区访问等不同类型告警，大幅提升日志排查、安全审计与故障定位效率，整体日志体系兼顾流量审计、行为溯源与运维便捷性，完善多区域网络安全监控能力。

## 七、第五部分：攻防演练
（包含攻击演练、防御分析、边界测试）
![](11-attack-scan.png)
![](12-attack-bypass.png)
![](13-defense-logs.png)
![](14-defense-counters.png)
![](15-improvement.png)

### 5.1 攻击方任务（从guest发起）（5分）

**攻击1：扫描office网段**

尝试扫描`10.20.0.0/24`网段，观察防火墙是否拦截：

```bash
# 尝试ping扫描
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**攻击2：尝试绕过防火墙访问dmz:22**

尝试改变源端口、使用不同协议等方法：

```bash
# 尝试用不同源端口
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**攻击3：尝试伪造VPN流量**
攻击 3：多类型报文绕过尝试（混合 ICMP/TCP 绕过防火墙）
```bash
for i in {2..10}; do sudo ip netns exec guest hping3 -c 1 --icmp -a 10.10.10.2 10.20.0.$i; done
```

思考：攻击者能否伪造源地址为`10.10.10.2`的包来访问内网？
攻击者无法依靠伪造源地址 10.10.10.2 成功访问内网，存在两层防护阻断

攻击者能否从REJECT和DROP的不同表现判断目标是否存在？
可以区分判断。REJECT 会主动返回 ICMP 端口 / 主机不可达应答，攻击者收到回复即可确定该 IP 真实存在，仅端口 / 访问权限被防火墙拦截；DROP 直接静默丢弃数据包，无任何响应，攻击者无法区分目标 IP 不存在、防火墙拦截、链路中断三种场景，无法确认主机存活状态。因此 REJECT 会泄露内网网段资产存活信息，生产环境更推荐使用 DROP 做静默阻断提升隐蔽性

### 5.2 防御方任务

**任务1：从日志中识别攻击**

```bash
# 查看最近的所有拒绝日志
sudo journalctl -k --since "10 minutes ago" --grep "GUEST-|VPN-|INET-" --no-pager
```

回答问题：
1. 从日志的哪些字段可以判断这是来自guest的攻击？
自定义日志前缀字段：日志开头 GUEST-TO-XXX，是 iptables LOG 规则配置的专属标记，直接标识流量来自 guest 网段；
入接口字段 IN=：IN=veth-fw-guest，veth-fw-guest 是防火墙连接 guest 区域的网卡，入接口匹配即可判定流量源头为 guest；
源 IP 字段 SRC=：源地址属于10.10.0.0/24 guest 网段，可佐证攻击来源。

2. 如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？
数据包入接口是连接 guest 区域的网卡，流量发起端为 guest 网段；
数据包出接口是连接 office 内网业务区的网卡，访问目标是 office 内网主机；
该流量匹配guest→office拦截 LOG 规则，防火墙识别为跨区域非法访问，记录日志后执行 REJECT 丢弃，属于来自 guest 对内网 office 的扫描 / 渗透攻击行为

3. 为什么看到大量相同来源的日志应该引起警惕？
大量同源高频报文代表攻击者正在进行端口扫描、网段存活扫描、暴力探测，属于主动攻击行为；
持续大量拦截日志说明攻击者未放弃探测，后续可能更换端口、伪造源 IP 等方式尝试绕过防火墙；
高频访问会消耗防火墙、内网主机资源，存在 DOS 风险；
海量拦截日志可作为入侵行为取证依据，需要及时阻断对应攻击源 IP，加固访问控制策略
**任务2：分析规则的防御效果**

```bash
# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

回答问题：
1. 哪条规则拦截了guest访问office？
匹配截图 iptables 输出，序号 3、4 两条规则完成拦截，序号 3 为 LOG 审计规则、序号 4 为 REJECT 阻断规则，入接口 veth-fw-guest、出接口 veth-fw-office，专门匹配访客网段去往办公区的新建流量。数据包先经过 LOG 规则写入带 GUEST-TO-OFFICE 前缀的内核审计日志，记录五元组与访问时间，随后进入 REJECT 规则发送 TCP 重置或 ICMP 不可达报文断开连接，两条规则组合完整实现访客跨办公区访问的拦截与安全日志留存，是防御 guest 横向渗透的核心控制策略
2. 如果guest→office的规则计数很高，说明了什么？
规则数据包、字节计数持续走高，代表 guest 网段存在大量主动访问 office 内网的流量，大概率发生内网横向扫描、越权探测等攻击行为。攻击者通过 ping、hping3 遍历办公区 IP 与业务端口，尝试发现存活主机、开放服务以扩大攻击面；计数暴涨是内网安全告警信号，需立刻调取对应 GUEST-TO-OFFICE 日志定位攻击源，核查访客终端是否失陷，同时可补充速率限制、黑名单加固规则，抑制持续扫描行为，防范内网横向渗透风险扩散
3. REJECT和DROP在安全性上有什么区别？
REJECT 会主动返回 ICMP/TCP 拒绝应答，攻击者收到回复即可确认目标 IP 真实存在，泄露内网资产存活信息，容易用于网段测绘；DROP 静默丢弃数据包，无任何回程响应，攻击者无法区分主机不存在、防火墙拦截、链路中断，隐蔽性更强。但 REJECT 可直观反馈阻断行为，便于日常故障排查；DROP 更适合生产安全防御，避免泄露内网拓扑。二者审计逻辑一致，均可前置 LOG 记录流量，仅报文回程行为差异带来资产暴露层面的安全等级区分


### 5.3 边界测试与改进方案

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

**选择：限制单IP对dmz:8080的连接数**
本次选择原防火墙无单 IP 并发连接限制的安全缺陷进行优化，原有策略仅依靠网段、端口做访问放行，未管控 TCP 并发数量，存在 CC、连接耗尽攻击风险。攻击者可通过多进程批量发送 SYN 报文，持续向 DMZ 10.40.0.2:8080 建立海量连接，占用服务器套接字、CPU 与内存资源，导致正常用户无法接入，业务服务瘫痪。该风险不会被基础网段阻断规则拦截，仅靠访问控制矩阵无法抵御流量层攻击，属于边界防御短板。通过 connlimit 模块限制单 IP 最大并发连接，可约束异常海量请求，缓解洪水攻击带来的服务不可用风险，补齐流量管控层面防御缺口
```bash
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```
配套日志规则
sudo ip netns exec fw iptables -I FORWARD 1 \
-p tcp --syn --dport 8080 -d 10.40.0.2 \
-m connlimit --connlimit-above 10 \
-j LOG --log-prefix "CC_LIMIT_BLOCK:"

测试步骤
在 guest/office/ 外网客户端使用 hping3、多进程 curl 批量发起大量并发 TCP 连接访问10.40.0.2:8080；
防火墙执行iptables -L FORWARD -v查看规则计数器，超限规则 pkts 持续上涨；
服务端抓包观察：单 IP 最多建立 10 条有效连接，第 11 个及以上 SYN 报文被防火墙拦截，无握手完成；
内核日志执行journalctl -k --grep "CC_LIMIT_BLOCK"可抓取大量超限拦截审计日志；
对比改进前：无连接限制时数百条连接可全部建立，服务器负载飙升；改进后严格限制并发，抵御 CC 压力测试，保障 DMZ 业务稳定运行


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
| 1 | remote wg0 |10.10.10.2 |10.40.0.2 |TCP | 封装前 |
| 2 | fw wg0 |10.10.10.2 |10.40.0.2 |TCP | 解封装后 |
| 3 | fw veth-fw-dmz |无有效转发报文 |无有效转发报文 |TCP | 转发到dmz |
| 4 | conntrack | |10.40.0.2 |TCP | 连接跟踪记录 |

本次测试基于限制单 IP 访问 DMZ 8080 并发连接的 iptables 改进规则，完整观测 VPN 远程客户端访问内网业务的数据包全流程。远程 remote 命名空间 wg0 网卡抓取到源 10.10.10.2、目的 10.40.0.2 的 TCP SYN 握手包，客户端持续发送新建连接请求，数据包经 WireGuard 封装抵达防火墙 fw。防火墙 wg0 解封装后读取原始 TCP 报文，进入 FORWARD 链匹配前置 connlimit 限流规则，规则判定该源 IP 并发连接超出 10 条阈值，触发 REJECT 动作直接重置 TCP 会话。因此防火墙连接 DMZ 的 veth-fw-dmz 网卡无下行转发报文，流量无法抵达内网服务端。实时监控 conntrack 连接跟踪表，检索目标 10.40.0.2 无任何有效流记录，证明握手报文全部被防火墙拦截，无法完成 TCP 三次握手。整体流程体现改进规则生效：合法少量连接可正常转发，超限 CC 攻击流量在防火墙边界直接阻断，不占用内网服务器资源，有效抵御连接耗尽攻击，补齐原有防火墙缺少并发管控的安全短板。

![](16-tcpdump-remote.png)
![](17-tcpdump-fw.png)
![](18-conntrack.png)

## 八、故障排查
（包含至少3个故障场景的排查过程）
## 故障排查专题（体现Plan1的开放性）
### 场景1：DNAT配置了但外网无法访问
步骤一 
1 写入 DNAT 转换规则（fw 命名空间）
```bash
sudo ip netns exec fw iptables -t nat -A PREROUTING \
-d 203.0.113.1 -p tcp --dport 8080 \
-j DNAT --to-destination 10.40.0.2:8080
```
2 清空 FORWARD 链放行规则，制造拦截故障
```bash
# 清空FORWARD链，无任何允许流量规则
sudo ip netns exec fw iptables -F FORWARD
# 设置FORWARD默认策略DROP
sudo ip netns exec fw iptables -P FORWARD DROP
```
3 模拟外网访问，复现访问失败现象
```bash
# 在internet命名空间发起访问
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080
```
步骤二 排查
**排查步骤：**
1. 检查FORWARD规则是否放行了DNAT后的流量
2. 检查dmz的默认路由是否指向fw
3. 用conntrack观察是否有DNAT映射记录
4. 在fw的多个接口抓包，找出包在哪里被丢弃

查看 nat 表，确认 DNAT 规则存在
```bash
sudo ip netns exec fw iptables -t nat -L -n
```
检查 FORWARD 链是否放行流量（核心故障点）
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v
```
查看 conntrack 连接跟踪，无 DNAT 映射记录
```bash
watch -n 1 'sudo ip netns exec fw conntrack -L | grep 8080'
```
多接口同步抓包定位丢包位置
终端 1：fw 公网入口网卡抓包（能抓到入站 SYN）
```bash
sudo ip netns exec fw tcpdump -ni eth0 -c 5
```
终端 2：fw dmz 网卡 veth-fw-dmz 抓包（无任何报文）
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5
```

### 修复故障 + 验证连通
1 添加 FORWARD 放行规则
```bash
# 放行DNAT转发到DMZ的入站流量
sudo ip netns exec fw iptables -A FORWARD \
-d 10.40.0.2 -p tcp --dport 8080 -j ACCEPT
# 放行DMZ服务器回包
sudo ip netns exec fw iptables -A FORWARD \
-s 10.40.0.2 -p tcp --sport 8080 -j ACCEPT
```
2 再次测试外网访问
```bash
sudo ip netns exec internet curl http://203.0.113.1:8080
```
3 验证 conntrack DNAT 映射记录
```bash
sudo ip netns exec fw conntrack -L | grep 8080
```


### 场景2：VPN隧道握手正常但业务访问失败

**现象：**
- `wg show`显示`latest handshake`正常
- `remote ping 10.40.0.2`失败
- `fw`上没有相关日志

**可能原因：**
1. `AllowedIPs`配置错误
2. FORWARD规则拒绝了VPN流量
3. dmz没有回程路由
4. fw未开启IP转发

步骤：
1. 确认隧道握手正常
```bash
sudo ip netns exec fw wg show
```
2. 复现访问失败
```bash
# remote命名空间执行
sudo ip netns exec remote ping 10.40.0.2 -c 3
```
故障 1：fw 的 FORWARD 链默认 DROP，拦截 VPN 跨网段流量
```bash
# fw清空转发规则，默认拒绝所有跨接口流量
sudo ip netns exec fw iptables -F FORWARD
sudo ip netns exec fw iptables -P FORWARD DROP
```
此时 remote ping 10.40.0.2 依旧超时


快速定位方法（抓包 + iptables 检查）
查看 FORWARD 规则
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v
```
 修复命令（双向放行 VPN 与 DMZ 互访）
```bash
# 允许VPN网段访问DMZ
sudo ip netns exec fw iptables -A FORWARD -s 10.0.0.0/24 -d 10.40.0.0/24 -j ACCEPT
# 允许DMZ回包给VPN客户端
sudo ip netns exec fw iptables -A FORWARD -s 10.40.0.0/24 -d 10.0.0.0/24 -j ACCEPT
```

### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

**现象：**
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

**排查步骤：**
1. 在fw上抓包，观察双向流量
2. 用conntrack观察连接状态
3. 理解状态检测的作用

1. fw 配置故障防火墙规则
```bash
sudo iptables -F
sudo iptables -X
sudo iptables -Z
# 仅放行客户端新建SYN，无RELATED/ESTABLISHED回包放行
sudo iptables -A FORWARD -s 10.10.10.0/24 -d 10.40.0.0/24 -p tcp --syn -j ACCEPT
sudo iptables -P FORWARD DROP
sudo iptables -P INPUT DROP
sudo iptables -P OUTPUT ACCEPT
```
抓包验证
客户端 curl http://10.40.0.2

连接跟踪查看半连接
sudo conntrack -L  仅存在SYN_SENT半连接，无双向 ESTABLISHED 会话

故障原理说明
TCP 是双向有状态连接：
客户端发SYN属于 NEW；
服务器回复SYN-ACK属于RELATED关联响应包；
当前防火墙只放行 NEW SYN，缺少 --ctstate RELATED,ESTABLISHED 放行规则，回包被 DROP，三次握手中断，curl 超时。
RELATED：放行握手响应、ICMP 差错等关联回包；
ESTABLISHED：放行握手完成后的持续双向业务流量；
二者缺一不可，仅单向放行 SYN 无法完成 TCP 通信

修复步骤
添加状态放行规则后重新测试：sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
再次 curl 可正常访问，抓包能看到完整SYN/SYN-ACK/ACK三次握手

![](19-troubleshoot-dnat.png)
![](20-troubleshoot-vpn.png)



## 九、遇到的问题和解决方法
（实验过程中的实际问题和解决思路）
问题一：伪造源 IP 报文可进入防火墙，存在网段绕过风险
实验初期使用 hping3 伪造陌生内网源地址发起访问，数据包能够抵达防火墙 FORWARD 链，有绕过区域访问控制的隐患。解决思路：开启网卡反向路由校验 rp_filter，内核校验报文入接口与源网段路由匹配关系，非法伪造源数据包在二层直接丢弃，无法进入转发规则匹配流程，从底层阻断源地址伪造攻击。
问题二：大量扫描流量触发海量日志，产生日志洪水
guest 网段横向扫描时，每条拦截数据包都会生成内核日志，短时间日志量暴涨，占用磁盘与系统 IO，易掩盖真实告警。解决思路：在 LOG 规则增加 limit 速率限制模块，限定单位时间内同类阻断日志输出条数，兼顾审计留存与系统资源防护，避免日志洪水风险。
问题三：CC 攻击无防护，单 IP 海量连接耗尽服务器套接字
原有防火墙仅基于网段、端口放行流量，未管控 TCP 并发，多进程批量 SYN 报文可建立数百条连接，导致 DMZ 服务卡死。解决思路：新增 connlimit 并发连接限制规则，单 IP 访问 8080 最大允许 10 条并发，超限直接 REJECT 重置握手报文，在边界拦截攻击流量，保护内网业务资源。
问题四：REJECT 返回 ICMP 应答泄露内网存活网段
阻断访问时主动返回不可达报文，攻击者可依靠应答判断内网主机真实存在，测绘网段拓扑。解决思路：将部分对外阻断策略替换为 DROP 静默丢弃，无任何回程响应，攻击者无法区分主机不存在与防火墙拦截，提升内网资产隐蔽性。

## 十、总结与思考
（至少500字，包含对企业网络安全架构的整体理解）
本次 WireGuard VPN 内网远程访问实验，完整完成了网络命名空间隔离、密钥体系生成、VPN 两端配置、防火墙访问控制、流量拦截防护等实操内容，让我对小型企业标准化网络安全架构形成了体系化认知，同时理清了远程接入、边界防护、内网分区三大核心安全模块的联动逻辑。
从企业网络整体架构来看，一套可靠的安全体系分为外网边界层、VPN 远程接入层、核心防火墙层、业务内网分区四层结构，层层隔离、权限可控是设计核心。外网边界负责屏蔽互联网基础攻击，通过端口过滤、地址转换阻挡扫描与恶意连接；VPN 远程接入层是本次实验重点，解决企业员工异地办公访问内网的刚需，传统明文远程工具极易泄露账号与业务数据，而 WireGuard 基于非对称加密实现端到端加密传输，每一台接入终端都持有独立公私密钥，管理员可随时吊销客户端公钥，相比密码登录大幅提升远程访问安全底线，契合企业 “最小权限访问” 安全准则。实验中通过 connlimit 并发限制、connlimit 单 IP 并发拦截功能，模拟企业边界抗攻击能力，防止攻击者利用海量连接耗尽防火墙资源，这也是企业网关必备的防护手段。
核心防火墙是整个内网安全的中枢，对应实验中的 fw 命名空间，承担流量转发、访问控制、日志审计职能。企业内网不会所有设备互通，通常划分为办公区、服务器 DMZ 区、核心业务数据库区，防火墙通过 iptables / 防火墙策略实现分区隔离：办公终端仅能访问通用业务系统，禁止直连数据库；外网、VPN 客户端默认拒绝主动入站流量，仅开放业务必要端口。本次实验配置 VPN 网段仅允许访问内网指定网段，不开放全量内网权限，正是企业内网隔离思路的缩影，即使远程终端存在病毒、入侵风险，攻击范围也被限制，不会横向扩散至核心资产。
实验过程中暴露的问题也映射出企业运维常见安全隐患：一是密钥管理问题，若私钥随意存放、明文存储，VPN 隧道加密形同虚设，企业需建立密钥生命周期管理，定期轮换公私钥，离职员工客户端公钥立即从网关配置中删除；二是边界防护缺失风险，若未对 VPN 接入终端做并发、流量限制，恶意客户端可发起 CC 攻击瘫痪内网服务；三是访问权限粗放，若给远程 VPN 客户端开放 0.0.0.0 全量内网路由，一旦终端沦陷，内网全部资产暴露，企业必须基于岗位划分精细化访问白名单。
结合本次实操延伸思考，现代企业安全架构不会仅依靠单一 VPN 与防火墙，还会叠加零信任、流量审计、入侵检测系统形成纵深防御。零信任架构摒弃 “内网可信、外网不可信” 传统思维，无论内网还是 VPN 远程接入，每次访问业务都需要身份二次校验；流量审计系统记录所有 VPN 进出内网的数据包，出现数据泄露、异常访问时可溯源定位终端；入侵检测系统识别隧道内木马、横向扫描行为，弥补防火墙仅基于端口、地址过滤的短板。
总而言之，企业网络安全架构的核心逻辑是 “隔离、加密、限流、审计”，VPN 解决异地安全接入，防火墙实现内网分区隔离，限流规则抵御网络攻击，日志与密钥管理完成事后追溯。本次实验的轻量化部署模型可直接落地小微企业，大型企业在此基础上扩展多网关集群、统一身份认证平台，最终构建一套既能保障员工高效远程办公，又能全方位防护内网核心数据资产的完整安全体系




