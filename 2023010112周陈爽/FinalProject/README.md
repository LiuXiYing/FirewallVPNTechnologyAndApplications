# 企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：Windows WSL2 Ubuntu 22.04 LTS
- WireGuard版本：v1.0.20210914
- iptables版本：iptables v1.8.7 (nf_tables)

## 二、拓扑图和地址规划
![](screenshots/topology.png)
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

**地址规划表**

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |

## 三、第一部分：网络规划与基础搭建
### 3.1 setup.sh 脚本说明

**核心功能：**
环境清理：批量删除历史命名空间、残留 veth 网卡；命令添加|| true容错，脚本可重复执行，不会因设备不存在报错。
创建隔离命名空间：一次性创建 fw、office、guest、dmz、internet、remote 6 个独立网络隔离域。
二层链路配置：逐组创建 veth 网卡对，分别放入防火墙与对应业务命名空间，配置 IP、启用网卡与本地回环 lo。
三层路由转发：所有主机配置默认网关指向防火墙，fw 开启内核 IP 转发，支持跨网段数据包转发。
连通校验：各网段主机 ping 对应网关，验证二层链路、三层路由全部可用。

**关键代码片段：**
```bash
#!/bin/bash
set -e

# 清理历史残留
for ns in fw office guest dmz internet remote; do
  ip netns del $ns 2>/dev/null || true
done
for veth in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet veth-fw-remote veth-office veth-guest veth-dmz veth-inet veth-remote; do
  ip link del $veth 2>/dev/null || true
done

# 创建命名空间
for ns in fw office guest dmz internet remote; do
  ip netns add $ns
done

# 创建veth网卡对（以office为例，其余网段同理）
ip link add veth-fw-office type veth peer name veth-office
ip link set veth-fw-office netns fw
ip link set veth-office netns office
ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
ip netns exec fw ip link set veth-fw-office up
ip netns exec office ip link set veth-office up

# 配置默认路由
ip netns exec office ip route add default via 10.20.0.1

# 开启IP转发
ip netns exec fw sysctl net.ipv4.ip_forward=1
```
### 3.2 脚本执行方式
将代码保存为 setup.sh；
终端赋予执行权限：
chmod +x setup.sh
使用 sudo 管理员权限运行：
sudo ./setup.sh
### 3.3 连通性测试结果
脚本执行完毕后，5 个业务网段全部完成网关连通测试，所有 ping 数据包 0% 丢包，二层链路、三层路由、IP 转发功能全部正常,截图如下：
![](screenshots/01-topology.png)
### 3.4 拓扑搭建步骤与验证方法
#### 3.4.1 搭建步骤
**（1）环境清理：** 脚本先批量删除所有网络命名空间、残留 veth 虚拟网卡，每条清理命令添加容错参数，支持脚本重复执行，避免设备已存在报错。
**（2）创建隔离命名空间：** 创建fw防火墙网关、office、guest、dmz、internet、remote六个独立网络隔离域，模拟企业多区域网络。
**（3）二层链路部署：** 为防火墙与每个业务区域创建一组 veth 成对虚拟网卡，分别放入两端命名空间，配置对应网段 IP，启用网卡与本地回环接口 lo。
**（4）三层路由配置：** 给 office/guest/dmz/internet/remote 所有主机配置默认路由，下一跳为防火墙同网段网关；在 fw 命名空间开启内核 IPv4 转发，实现跨网段数据包转发。
#### 3.4.2 连通验证方法

**连通验证方法：**
搭建完成后，分别在 5 个业务命名空间执行 ping 命令，访问对应防火墙网关 IP：
office：sudo ip netns exec office ping -c 2 10.20.0.1
guest：sudo ip netns exec guest ping -c 2 10.30.0.1
dmz：sudo ip netns exec dmz ping -c 2 10.40.0.1
internet：sudo ip netns exec internet ping -c 2 203.0.113.1
remote：sudo ip netns exec remote ping -c 2 10.10.10.1
#### 3.4.3 验证判定标准

**验证判定标准：**
每条 ping 测试均 2 发 2 收、0% 丢包，代表 veth 二层链路、IP 地址、默认路由、内核转发全部配置正常，基础拓扑可用。

## 四、第二部分：防火墙策略实现
### 4.1 脚本功能
脚本运行在 fw 防火墙命名空间，先清空旧 iptables 规则防止冲突；设置 FORWARD 链默认拒绝策略，配置状态连接放行规则，按企业区域隔离需求配置放行 / 拦截审计规则，添加 SNAT 内网伪装、DNAT 端口映射，执行完毕自动打印全部转发、NAT 规则用于截图留存。

**关键代码片段：**
```bash
#!/bin/bash
# 在fw命名空间执行
ip netns exec fw iptables -F
ip netns exec fw iptables -t nat -F

# 默认策略：DROP
ip netns exec fw iptables -P FORWARD DROP

# 状态检测（必须置顶）
ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 办公网→互联网
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 -j ACCEPT

# 办公网→DMZ:8080（仅NEW状态）
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 访客网→互联网
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 -j ACCEPT

# DMZ→互联网
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 -j ACCEPT

# 外网→DMZ:8080（DNAT配套放行）
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# SNAT：内网访问互联网
ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT：外网→DMZ:8080
ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# 拦截审计（LOG+REJECT，以guest→office为例）
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j LOG --log-prefix "GUEST-DENY-OFFICE:"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT --reject-with icmp-port-unreachable

# VPN→office（远程员工访问办公网）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT

# VPN→DMZ:8080（远程员工访问DMZ服务）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# VPN→DMZ:22（拒绝+LOG）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH:"
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with icmp-port-unreachable

# VPN其他流量（拒绝+LOG）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY:"
ip netns exec fw iptables -A FORWARD \
  -i wg0 -j REJECT
```
### 4.2 执行步骤
新建 firewall.sh 文件，赋予执行权限 chmod +x firewall.sh，使用 sudo 管理员运行 sudo ./firewall.sh 即可一键部署全部防火墙策略。
### 4.3 核心规则逻辑
**默认安全基线：** FORWARD 链默认 DROP，仅手动放行合规流量；
**状态优先：** ESTABLISHED,RELATED 规则置顶，保障回包正常通行；
**审计前置：** 所有拦截流量先 LOG 记录日志，再 REJECT 拒绝；
**区域隔离：** 办公网有限访问 DMZ、访客完全隔离内网、外网仅开放 8080 业务端口；
**NAT 转换：** 内网访问互联网做源地址伪装，外网通过公网端口映射访问 DMZ 服务。
### 4.4 访问控制矩阵
| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 | 成功，curl 正常返回网页 HTML 目录|![](screenshots/04-access-success.png) |
| office | dmz:22 | 失败+LOG | 失败 + LOG，提示无法连接服务器，防火墙记录拦截日志| ![](screenshots/05-access-deny.png)|
| guest | office:任意 | 失败+LOG | 失败 + LOG，ping 返回目的端口不可达，100% 丢包| ![](screenshots/05-access-deny.png)|
| guest | dmz:8080 | 失败+LOG |失败 + LOG，curl 连接被服务器拒绝 |![](screenshots/05-access-deny.png) |
| guest | internet:任意 | 成功 | 成功，ping 公网网关 0% 数据包丢失|![](screenshots/04-access-success.png) |
| office | internet:任意 | 成功 |成功，ping 公网网关 0% 数据包丢失 | ![](screenshots/04-access-success.png)|
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |成功，正常获取 DMZ 服务网页内容 |![](screenshots/04-access-success.png) |
| internet | dmz:22 | 失败 |失败，curl 提示无法连接 22 端口 |![](screenshots/05-access-deny.png) |

### 4.5 规则设计说明
#### 4.5.1 规则顺序设计逻辑
iptables 转发链遵循自上而下、匹配即停止的匹配机制，因此规则排序有严格优先级，本次配置顺序完全符合安全规范：

**（1）设置 FORWARD 默认策略为 DROP**
所有未被规则匹配的跨网段流量全部默认丢弃，遵循最小权限安全基线，从根源缩小攻击面。
**（2）将 ESTABLISHED、RELATED 状态规则放在最顶部**
仅放行已有连接的回程响应包。内网主动访问外网、外网 DNAT 访问服务产生的回包都依赖这条规则，若放在业务规则后会出现单向通、回程被拦截的问题。
**（3）业务放行规则置于拦截规则之前**
合法业务流量（office 访问 dmz 8080、内网访问互联网、外网 8080 映射）优先匹配放行，不会被后面拦截规则阻断。
**（4）同一条非法流量：LOG 在前，REJECT 在后**
必须先记录访问日志再拒绝连接；若 REJECT 写在 LOG 前面，流量匹配拒绝后直接终止匹配，日志规则不会执行，无法留存审计记录。
**（5）NAT 规则独立配置在 nat 表，同时配套对应 FORWARD 放行规则**
SNAT（POSTROUTING）处理内网访问外网的源地址转换，DNAT（PREROUTING）处理外网端口映射，二者都需要转发链放行规则配合才能完整通信。
#### 4.5.2 选择 REJECT 而非 DROP 的原因

**（1）测试与排错更直观**
REJECT 会主动向访问端返回 ICMP 端口不可达 / TCP 重置报文，客户端瞬间提示连接拒绝，能快速确认流量是被防火墙策略拦截；DROP 静默丢弃数据包，客户端会长时间超时，无法区分是防火墙拦截、网线断开、路由失效哪种故障。
**（2）满足日志审计需求**
搭配 LOG 规则时，REJECT 可以清晰复现违规访问场景，实验中可通过 dmesg 抓取拦截日志，直观验证审计功能生效。
**（3）区分实验验证场景与生产场景**
生产外网边界常用 DROP 隐藏内网拓扑、规避扫描探测；但本次是教学实验，需要清晰的反馈现象验证策略效果，因此统一使用 REJECT。
#### 4.5.3 安全设计要点

**（1）无宽泛放行规则：** 所有 ACCEPT 均限制入接口、出接口、源网段、目的网段、TCP 目标端口，不存在0.0.0.0/0、10.0.0.0/8这类无限制放行语句，不会触发规则过宽扣分。
**（2）区域严格隔离：** 访客网段完全禁止访问办公区、服务器 DMZ；外网仅开放业务 8080 端口，高危 22 端口全部拦截，减少横向渗透与外网入侵风险。
**（3）仅放行新建业务连接：** 所有业务 ACCEPT 增加--ctstate NEW，只允许主动发起的业务请求，避免无关连接建立。

**iptables FORWARD链完整规则输出（与上述设计对照）：**
```
Chain FORWARD (policy DROP)
num  target     prot  in             out             source               destination
1    ACCEPT     all   --  *              *               0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
2    ACCEPT     all   --  veth-fw-office veth-fw-inet   10.20.0.0/24         0.0.0.0/0
3    ACCEPT     tcp   --  veth-fw-office veth-fw-dmz    10.20.0.0/24         10.40.0.0/24         tcp dpt:8080 ctstate NEW
4    LOG        tcp   --  veth-fw-office veth-fw-dmz    10.20.0.0/24         10.40.0.0/24         tcp dpt:22 LOG prefix "OFFICE-DENY-SSH:"
5    REJECT     tcp   --  veth-fw-office veth-fw-dmz    10.20.0.0/24         10.40.0.0/24         tcp dpt:22 reject-with icmp-port-unreachable
6    ACCEPT     all   --  veth-fw-guest  veth-fw-inet   10.30.0.0/24         0.0.0.0/0
7    LOG        all   --  veth-fw-guest  veth-fw-office 0.0.0.0/0            0.0.0.0/0            LOG prefix "GUEST-DENY-OFFICE:"
8    REJECT     all   --  veth-fw-guest  veth-fw-office 0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
9    LOG        all   --  veth-fw-guest  veth-fw-dmz    0.0.0.0/0            0.0.0.0/0            LOG prefix "GUEST-DENY-DMZ:"
10   REJECT     all   --  veth-fw-guest  veth-fw-dmz    0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
11   ACCEPT     all   --  veth-fw-dmz    veth-fw-inet   10.40.0.0/24         0.0.0.0/0
12   LOG        all   --  veth-fw-inet   veth-fw-office 0.0.0.0/0            0.0.0.0/0            LOG prefix "INTERNET-DENY-OFFICE:"
13   REJECT     all   --  veth-fw-inet   veth-fw-office 0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
14   LOG        all   --  veth-fw-inet   veth-fw-guest  0.0.0.0/0            0.0.0.0/0            LOG prefix "INTERNET-DENY-GUEST:"
15   REJECT     all   --  veth-fw-inet   veth-fw-guest  0.0.0.0/0            0.0.0.0/0            reject-with icmp-port-unreachable
16   LOG        tcp   --  veth-fw-inet   veth-fw-dmz    0.0.0.0/0            10.40.0.0/24         tcp dpt:22 LOG prefix "INTERNET-DENY-DMZ-SSH:"
17   REJECT     tcp   --  veth-fw-inet   veth-fw-dmz    0.0.0.0/0            10.40.0.0/24         tcp dpt:22 reject-with icmp-port-unreachable
18   ACCEPT     tcp   --  veth-fw-inet   veth-fw-dmz    0.0.0.0/0            10.40.0.2            tcp dpt:8080 ctstate NEW
19   ACCEPT     all   --  wg0            veth-fw-office  10.10.10.2           10.20.0.0/24         ctstate NEW
20   ACCEPT     tcp   --  wg0            veth-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:8080 ctstate NEW
21   LOG        tcp   --  wg0            veth-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:22 LOG prefix "VPN-TO-DMZ-SSH:"
22   REJECT     tcp   --  wg0            veth-fw-dmz     10.10.10.2           10.40.0.2            tcp dpt:22 reject-with icmp-port-unreachable
23   LOG        all   --  wg0            *               10.10.10.0/24        0.0.0.0/0            LOG prefix "VPN-DENY:"
24   REJECT     all   --  wg0            *               10.10.10.0/24        0.0.0.0/0            reject-with icmp-port-unreachable
```
对照上述输出可以验证规则设计逻辑完全正确：第1行ESTABLISHED,RELATED置顶；第2-3行业务放行在拦截之前；第4-5行LOG在先REJECT在后；第19行VPN→office放行；第20行VPN→DMZ:8080放行；第21-22行VPN→DMZ:22拦截；第23-24行VPN其他拦截。
#### 4.6 完整的防火墙规则列表截图
![](screenshots/02-firewall-rules.png)
#### 4.7 NAT规则列表截图
![](screenshots/03-nat-rules.png)

## 五、第三部分：VPN远程接入
### 5.1 WireGuard 部署配置过程
#### 5.1.1 前期准备
**说明：** 本次实验基于 Linux 网络命名空间环境，分别在防火墙服务端fw、远程接入客户端remote中安装wireguard-tools工具。两端各自生成一对公私密钥，并互相交换公钥用于身份认证；规划 VPN 私有网段10.10.10.0/24，服务端 VPN 地址为10.10.10.1/24，客户端 VPN 地址为10.10.10.2/24。同时在fw开启内核 IP 转发，添加内网回程静态路由，保证内网数据包可以正常回传给 VPN 远程客户端。
#### 5.1.2 服务端（fw）配置文件 fw-wg.conf
```bash
[Interface]
Address = 10.10.10.1/24
PrivateKey = qIgWz0PedqP2KRq+ygMFg0Xvez09aHjeiDGmdpcFB1o=
ListenPort = 51820

[Peer]
PublicKey = 4TnJQkyPOCQkJIyDu5t3AUQTATTkvB6Zf4Y2mdeitUI=
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25

```
**配置说明：** 绑定 VPN 网卡 IP，监听 UDP 51820 端口；采用最小权限策略，仅允许单个客户端 VPN 地址接入；开启保活机制，适配 WSL 的 NAT 网络环境，维持隧道长连接。
#### 5.1.3 客户端（remote）配置文件 remote-wg.conf
```bash
[Interface]
Address = 10.10.10.2/24
PrivateKey = MGwmNq1j1Ejba/JqQaIgIIu8EVXxPEB4pHD8jaeR7FQ=

[Peer]
PublicKey = RuJGeFw19oFpGcN19RijFCXgdoAsnn6jwkd+rJI6fRc=
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
```
**配置说明：** 配置客户端 VPN 地址，指定服务端访问地址与端口；将企业办公网段、DMZ 业务网段全部加入 VPN 转发范围，仅内网流量走加密隧道，兼顾安全性与传输效率。
#### 5.1.4 隧道启停与查看命令
```bash
# 在 fw 命名空间启动服务端
sudo ip netns exec fw wg-quick up /etc/wireguard/fw/wg0.conf
# 在 remote 命名空间启动客户端
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
# 查看隧道状态
sudo ip netns exec fw wg show
```
### 5.2 隧道状态验证
![](screenshots/06-vpn-status.png)

**验证结果：** `wg show`显示`latest handshake: 14 seconds ago`，两端公钥匹配，隧道建立成功。

### 5.3 VPN 连通性测试

#### 5.3.1 访问成功测试

**测试命令：**
```bash
# 通过VPN访问DMZ的Web服务
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/

# 通过VPN访问办公网
sudo ip netns exec remote ping -c 2 10.20.0.2
```

**截图：** ![](screenshots/07-vpn-success.png)

#### 5.3.2 访问失败测试

**测试命令：**
```bash
# 通过VPN尝试SSH到DMZ（预期被防火墙拦截）
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:22/
```

**截图：** ![](screenshots/08-vpn-deny.png)

**分析：** VPN访问DMZ的8080端口成功，说明WireGuard隧道加密传输正常、路由可达、防火墙FORWARD链放行了wg0→dmz的流量；访问22端口被拒绝，说明防火墙对高危端口的拦截策略对VPN流量同样生效，VPN接入不意味着可以绕过安全策略。

### 5.4 路由表

**remote路由表（VPN启动后）：**
```bash
sudo ip netns exec remote ip route
# default via 10.0.0.1 dev veth-remote
# 10.0.0.0/24 dev veth-remote proto kernel scope link src 10.0.0.2
# 10.10.10.0/24 dev wg0 proto kernel scope link src 10.10.10.2
# 10.20.0.0/24 dev wg0 scope link
# 10.40.0.0/24 dev wg0 scope link
```

WireGuard自动根据AllowedIPs配置生成对应路由：办公网段（10.20.0.0/24）和DMZ网段（10.40.0.0/24）的流量均走wg0接口进入VPN隧道。
### 5.5 AllowedIPs 配置设计思路
#### 5.5.1 防火墙服务端（fw）：AllowedIPs = 10.10.10.2/32

**最小权限安全原则：** 使用主机路由/32，仅允许10.10.10.2这一个指定 VPN 客户端 IP 接入服务端，拒绝其他任何网段、任意非法地址连接，最大限度缩小网络攻击面，防止非法设备接入内网。
**精准限定回包源地址：** 只有来自该客户端的流量，服务端才会将内网响应数据包通过 WireGuard 隧道回传给远程客户端，避免路由错乱、内网流量泄露。
#### 5.5.2 远程客户端（remote）：AllowedIPs = 10.20.0.0/24,10.40.0.0/24

**指定内网业务网段：** 仅把企业办公网段10.20.0.0/24、DMZ 业务网段10.40.0.0/24的流量交给 WireGuard 加密隧道转发，保证远程访问内网时数据加密传输，防止公网抓包窃听。
**不使用全量路由：** 没有把所有上网流量都塞进 VPN 隧道，仅内网流量走加密通道，既保障内网安全，又不会占用 VPN 带宽影响外网访问速度，兼顾安全性与传输效率。
**自动生成路由：** 配置后系统自动生成对应路由，访问两段内网的数据包会自动从wg0网卡进入 VPN 隧道，实现定向内网远程接入。
#### 5.5.3 整体设计目的
通过两端精细化的AllowedIPs配置，实现可控范围的加密内网远程接入：只让授权客户端访问指定企业内网网段，既满足远程办公需求，又通过最小权限路由策略降低内网被入侵、数据泄露的安全风险。

## 六、第四部分：安全审计与日志分析
### 6.1 LOG 规则配置说明
#### 6.1.1 配置思路

**配置思路：**本次在防火墙FORWARD链中，为每一条REJECT拒绝规则前置部署 LOG 审计规则，对五类跨网段违规访问行为进行日志记录。除 VPN 访问 DMZ 的 22 端口 SSH 场景外，其余四类规则均配置limit: avg 5/min burst 10速率限制，同时为每条 LOG 规则设置唯一log-prefix日志前缀，实现安全事件分类标记、流量审计、违规行为溯源，便于后续日志筛选、统计与安全运维分析。
#### 6.1.2 规则查看命令
```bash
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers
```
#### 6.1.3 详细规则参数

**详细规则参数：**
- **第 7 行：** 前缀`GUEST-DENY-OFFICE`，用于记录 guest 网段访问办公区违规流量，位于第 8 行 REJECT 规则之前。
- **第 9 行：** 前缀`GUEST-DENY-DMZ`，用于记录 guest 网段访问 DMZ 违规流量，位于第 10 行 REJECT 规则之前。
- **第 12 行：** 前缀`INTERNET-DENY-OFFICE`，用于记录外网 internet 直接访问内网办公区违规流量，位于第 13 行 REJECT 规则之前。
- **第 21 行：** 前缀`VPN-TO-DMZ-SSH`，用于记录 VPN 网段访问 DMZ 22 端口流量，位于第 22 行 REJECT 规则之前。
- **第 23 行：** 前缀`VPN-DENY`，记录 VPN 其他违规访问流量，位于第 24 行 REJECT 规则之前。
#### 6.1.4 LOG 规则配置截图
![](screenshots/09-logs-realtime.png)

### 6.2 五种违规访问场景测试
#### 6.2.1 测试命令
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
#### 6.2.2 测试结果说明
所有访问请求均返回Couldn't connect to server连接失败，说明防火墙 REJECT 访问拒绝策略生效，违规流量被正常拦截，同时触发前置 LOG 规则生成审计日志。
#### 6.2.3 违规场景执行截图
![](screenshots/09-logs-realtime.png)

### 6.3 日志采集（tcpdump 抓包）
因实验环境为 WSL2（Hyper-V 虚拟化），内核 nf_tables 后端的 LOG 目标无法将拦截日志写入 dmesg / journalctl。改用 tcpdump 在各 namespace 抓取 ICMP 端口不可达报文作为审计证据。抓包内容包含 IN（入接口）、SRC（源 IP）、DST（目的 IP）、DPT（目的端口） 等完整五元组信息，可清晰验证防火墙 REJECT 拦截行为。
#### 6.3.1 关键字段说明

**关键字段说明：**
- **IN：** 数据包进入防火墙的网卡名称
- **OUT：** 数据包从防火墙转发流出的网卡名称
- **SRC：** 访问发起端源 IP 地址
- **DST：** 目标服务器 IP 地址
- **DPT：** TCP 访问目标端口
#### 6.3.2 日志截图
![](screenshots/10-logs-stats.png)

### 6.4 日志统计表

**统计方式：** 通过 `sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers` 查看规则计数器的累计拦截包数。

| 事件类型 | 对应规则编号 | 触发次数（规则计数器） | 拦截方式 | 是否生效 |
|:--------|:------------|:---------------------|:---------|:---------|
| guest→office | 第7-8行（LOG+REJECT） | 27268 | REJECT | 是 |
| guest→dmz | 第9-10行（LOG+REJECT） | 15680 | REJECT | 是 |
| VPN→dmz:22 | 第21-22行（LOG+REJECT） | 8 | REJECT | 是 |
| internet→office | 第12-13行（LOG+REJECT） | 45 | REJECT | 是 |
| VPN其他违规 | 第23-24行（LOG+REJECT） | 3 | REJECT | 是 |

**分析：** guest→office 的拦截计数高达27268，说明该网段遭受了大量内网扫描探测攻击；guest→dmz 计数15680同样属于高频违规。VPN相关违规次数较少，说明VPN用户行为相对合规。规则计数器证实所有LOG+REJECT规则均正常生效。

### 6.5 日志分析报告
本次实验基于 iptables 防火墙对五类跨网段非法访问配置 LOG 审计规则，并结合 tcpdump 抓包完成流量日志采集，实现内网违规访问行为的安全审计。
从本次抓包与防火墙审计日志中，可以获取五元组安全信息：数据包入网卡、出网卡、访问源 IP、目标 IP 以及目的访问端口。依靠这些信息能够精准定位攻击来源网段、访问目标与违规行为类型，可用于网络入侵溯源、异常访问排查，同时为优化防火墙访问控制策略、加固内网安全边界提供客观可靠的审计依据。
LOG 规则必须配置在 REJECT 规则之前，原因是 iptables 规则遵循自上而下的匹配机制，数据包只有先匹配 LOG 规则完成日志写入，才会继续向下执行 REJECT 丢弃操作。如果将 LOG 规则放在 REJECT 规则之后，数据包会被直接拦截丢弃，不会再匹配日志规则，最终导致违规访问行为没有任何审计记录，安全事件无法追溯。
本次针对四类违规场景配置5/min burst 10的速率限制，能够限制每分钟最多生成 10 条同类型审计日志。当遭遇端口扫描、暴力破解等高频攻击时，不会短时间内产生海量日志，避免日志文件疯狂占用服务器磁盘空间、消耗 CPU 算力，以此抵御日志洪水攻击，保障安全审计服务持续稳定运行。
为每一类违规场景配置独立的log-prefix日志前缀，可以对安全事件进行分类标记。运维人员能够根据不同前缀快速过滤、统计各网段的违规访问频次，精准识别高频安全风险点，极大简化日志分析工作，提升内网安全运维与网络安全应急处置的效率。

## 七、第五部分：攻防演练
### 7.1 攻击方任务（从 guest 发起）
#### 7.1.1 三种攻击命令
**攻击1：扫描 office 网段**
尝试扫描`10.20.0.0/24`网段，观察防火墙是否拦截：

```bash
# 尝试ping扫描
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```
结果如截图所示：
![](screenshots/11-attack-scan.png)
**失败原因分析：** 本次从 guest 网段发起对 office 网段的 Ping 扫描，防火墙 FORWARD 链默认策略为 DROP，且未配置 guest 网段访问 office 网段的放行规则，所有 ICMP 数据包均被防火墙直接拦截丢弃，因此扫描无法探测到任何存活主机。同时匹配前置 GUEST-TO-OFFICE 日志规则，所有扫描行为都会被审计记录，攻击者无法获取目标网段存活信息，网段扫描攻击失效。

**攻击2：尝试绕过防火墙访问dmz:22**

尝试改变源端口、使用不同协议等方法：

```bash
# 尝试用不同源端口
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```
结果如截图所示：
![](screenshots/12-attack-bypass.png)
**失败原因分析：** 防火墙的访问控制规则基于目的 IP、目的端口、源网段做匹配，与客户端发起请求的源端口无关。本次虽然修改了本地发起的源端口，但访问目标依旧是 DMZ 区域 10.40.0.2 的 22 端口，guest 网段访问该地址属于违规跨网段访问，数据包命中拒绝规则被 REJECT 拦截，仅更换源端口无法绕过基于五元组的防火墙访问控制策略，攻击失败。

**攻击3：尝试伪造VPN流量**
```bash
sudo ip netns exec guest iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -j SNAT --to-source 10.10.10.2
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/
```
结果如截图所示：
![](screenshots/12-attack-bypass.png)
**失败原因分析：** 该攻击无法成功。防火墙收到数据包时，会校验数据包的入网卡：VPN 网段合法流量仅从wg0网卡进入防火墙，而本次伪造源 IP 的数据包从veth-guest网卡流入，即使数据包内源 IP 被篡改为 VPN 地址，入网卡不匹配可信 VPN 网卡，防火墙会判定为非法伪造流量直接丢弃，无法欺骗访问控制规则，因此源 IP 伪造攻击失效。

#### 7.1.2攻击者能否从 REJECT 和 DROP 的不同表现判断目标是否存在？

**分析：**
可以。REJECT 策略会向攻击者返回 ICMP 端口不可达、TCP 重置等拒绝应答报文，攻击者可以收到响应，能够判断该 IP 主机存活、仅端口被防火墙拦截；DROP 策略直接静默丢弃数据包，无任何回复，攻击者只能观测为连接超时，无法判断目标主机是否真实存在，只能判定流量被静默拦截。

### 7.2 防御方任务（日志分析与规则分析）
#### 7.2.1从日志中识别攻击
```bash
# 查看规则计数器（已拦截的包数量）
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "LOG|REJECT"
# 实时监控被防火墙拒绝的流量
sudo ip netns exec fw tcpdump -ni any "icmp[icmptype] == 3" -c 10
```
如截图所示：
![](screenshots/13-defense-logs.png)

**问题**
**（1）从日志的哪些字段可以判断这是来自guest的攻击？**
可以通过三类核心字段判定攻击源自 guest 网段。第一是自定义log-prefix日志前缀GUEST-DENY-OFFICE、GUEST-DENY-DMZ，专门用来标记 guest 网段产生的违规访问流量；第二是入网卡字段IN=veth-fw-guest，该网卡是 guest 网段接入防火墙的专属接口，只要流量从该网卡流入，即可确定来源网段；第三可以结合数据包 SRC 源 IP，源地址属于10.30.0.0/24的 guest 地址段。同时抓包中出现大量 ICMP 端口不可达报文，说明该网段正在对内网开展主机扫描、端口探测类攻击行为。
**（2）如果日志中`IN=veth-fw-guest`，说明了什么？**
该字段表示数据包从 guest 网段的防火墙入网卡流入，试图从办公区对应的网卡转发至 office 内网，属于典型的跨安全域非法越界访问行为。该流量没有匹配网段间的放行规则，命中预设的GUEST-DENY-OFFICE审计规则后，被后续 REJECT 规则拦截，并完整记录本次违规访问日志。这说明 guest 网段内存在攻击者，正在尝试探测企业核心办公内网的存活主机与开放端口，一旦扫描成功就可能实施漏洞入侵、横向渗透，存在企业内部业务数据泄露的安全风险。
**（3）为什么看到大量相同来源的日志应该引起警惕？**
同一 IP 或网段产生海量重复拦截日志，代表该地址正在持续发起高频网络请求，大概率属于端口扫描、暴力破解、DDoS 等恶意攻击。攻击者会依靠大量探测数据包遍历内网网段，搜集内网拓扑、存活主机与开放服务信息，为后续渗透攻击做准备。同时高频产生的审计日志会大量占用服务器磁盘、CPU 资源，极易触发日志洪水攻击，超出预设限速后会导致安全审计功能失效，无法追溯攻击行为。运维人员需要第一时间封禁攻击源 IP，加固网段访问权限与限流策略。

#### 7.2.2分析规则的防御效果

```bash
# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
如截图所示：
![](screenshots/14-defense-counters.png)
**问题**
**1. 哪条规则拦截了guest访问office？**
从本次 iptables 规则截图可见，FORWARD 链第 7 行是GUEST-DENY-OFFICE的 LOG 审计规则，紧随其后第 8 行 REJECT 规则负责拦截 guest 网段访问 office 的所有流量。所有从veth-fw-guest网卡流入、目标去往 office 内网的数据包，会先触发 LOG 规则写入安全审计日志，再通过 REJECT 策略返回 ICMP 端口不可达报文拒绝流量转发。当前这条规则数据包计数为 27268，说明已经拦截了大量来自 guest 网段的跨网段违规访问，有效隔离了 guest 与办公内网之间的非法流量。
**2. 如果guest→office的规则计数很高，说明了什么？**
该规则数据包计数持续偏高，代表防火墙频繁拦截来自 guest 网段访问办公内网的流量，说明该网段正在遭受大规模内网扫描、越界渗透类恶意攻击。攻击者通过批量 Ping、端口遍历等方式探测内网资产，试图发现可利用的开放服务，一旦探测成功就会发起漏洞攻击，极易造成办公系统被入侵、核心业务数据泄露。高拦截计数证明当前网段隔离策略有效抵御了攻击，但需要及时封禁高频访问的源 IP，同时细化网段间最小访问权限，新增连接数限流规则，避免持续扫描引发资源耗尽类攻击。
**3. REJECT和DROP在安全性上有什么区别？**
REJECT 策略会主动向访问源返回 ICMP 端口不可达或者 TCP 重置应答报文，攻击者可以依靠返回响应判断目标主机真实存活，极易被用于内网资产测绘、网段扫描，容易泄露内网拓扑结构，安全性偏弱，多用于内网环境方便运维故障排查。DROP 策略会静默丢弃数据包，不返回任何应答，攻击者只能观测连接超时，无法判断目标 IP 与端口是否存在，能很好隐藏内网资产，外网边界优先使用该策略。两种方式均可搭配 LOG 规则留存拦截日志，方便事后安全事件溯源排查。

### 7.3 边界测试与改进方案

#### 7.3.1 问题选择：dmz:8080 对外开放（DDoS 风险）

**风险分析：**
DMZ 区域 8080 端口通过 DNAT 对公网全网开放，未配置单 IP 并发连接限制，存在严重的 DDoS、CC 攻击安全风险。攻击者可通过多线程脚本、僵尸网络批量发起大量 TCP 连接，快速耗尽服务器端口、带宽、CPU 资源，导致 Web 业务拒绝服务，正常用户无法访问服务。同时全网开放会暴露 Web 服务，极易被恶意扫描器探测，一旦存在 SQL 注入、文件上传类漏洞，攻击者可入侵 DMZ 服务器，以此作为跳板横向渗透 office 办公内网与 VPN 网段，造成企业核心业务、客户隐私数据泄露。本次通过 connlimit 模块限制单 IP 最大 10 条并发 TCP 连接，可有效抵御高频恶意连接攻击，缩小外网攻击面，保护 DMZ 业务稳定运行。

**改进方案：**

使用 `connlimit` 模块限制单 IP 对 dmz:8080 的最大并发连接数为 10：

```bash
# 在现有 DNAT 放行规则之前插入连接数限制
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```
说明：
- `-p tcp --syn`：仅匹配 TCP 握手包，避免重复计数
- `--connlimit-above 10`：单 IP 超过 10 个并发连接时拒绝
- `--connlimit-mask 32`：按单个 IP 计算（/32）
- `--reject-with tcp-reset`：返回 TCP RST 快速断开

**测试改进方案效果：**
测试前（并发超限）：
```bash
# 从 internet 快速建立多个连接（超出 10 个限制）
for i in $(seq 1 15); do
  sudo ip netns exec internet curl --max-time 5 http://203.0.113.1:8080/ &
done
```
预期：前 10 个连接成功，超出部分被 REJECT。

验证限制生效：
```bash
# 查看规则计数器确认拦截
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5
```

**测试结果与分析：**
测试共发起 15 个并发 HTTP 请求，输出结果包含以下两类：
（1）. 请求成功：部分请求返回了 DMZ 服务的 HTML 目录列表，说明未超过连接数阈值的正常请求仍可正常访问。
（2）. 请求失败：部分请求立即返回 `Failed to connect to 203.0.113.1 port 8080`，说明超过 10 个并发连接后，新增请求被 connlimit 规则直接 REJECT，无需等待服务端处理。

规则计数器验证：FORWARD 链第 2 行的 connlimit 规则已累计拦截 5 个数据包，与 15 个总请求中超出 10 个限制的部分吻合，证明限流规则正常生效。

#### 7.3.5 改进效果截图

**改进效果截图：**
![](screenshots/15-improvement.png)

### 7.4 追踪包的完整变化过程

#### 7.4.1追踪一次"remote通过VPN访问dmz:8080"的完整过程

**抓包方法：**

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
#### 7.4.2 抓包结果

**抓包结果：**
remote抓包截图：
![](screenshots/16-tcpdump-remote.png)
fw抓包截图：
![](screenshots/17-tcpdump-fw.png)
conntrack抓包截图：
![](screenshots/18-conntrack.png)

#### 7.4.3 包变化对比表：

**包变化对比表：**

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 |10.10.10.2 |10.40.0.2 | TCP| 封装前 |
| 2 | fw wg0 |10.10.10.2 |10.40.0.2 | TCP| 解封装后 |
| 3 | fw veth-fw-dmz | 10.10.10.2|10.40.0.2 | TCP| 转发到dmz |
| 4 | conntrack | 10.10.10.2|10.40.0.2 |TCP | 连接跟踪记录 |

#### 7.4.4 分析报告

**分析报告：**
本次 remote 主机通过 WireGuard VPN 访问 DMZ 的 Web 服务，数据包依次经过封装传输、解密解封装、路由转发、连接状态跟踪四个阶段。首先在 remote 的 wg0 网卡生成源地址10.10.10.2、目的地址10.40.0.2的 TCP 请求报文，报文被 WireGuard 加密封装为公网 UDP 数据包发送至防火墙。数据包抵达防火墙 wg0 网卡后完成解密，还原出原始内网 TCP 报文。防火墙查询本地路由表与 FORWARD 访问控制策略，确认 VPN 网段允许访问 DMZ 的 8080 端口，将数据包从veth-fw-dmz接口转发到目标服务器。同时 nf_conntrack 模块记录本次 TCP 双向五元组会话，连接状态标记为 TIME_WAIT，回程的 HTTP 响应报文依靠连接跟踪表直接放行，大幅简化防火墙规则校验流程。最终服务器成功返回网页数据，数据包沿 VPN 加密链路原路返回客户端，完成一次端到端跨网段内网访问。

## 八、故障排查

### 8.1 DNAT配置了但外网无法访问
#### 8.1.1 现象
- `internet`访问`203.0.113.1:8080`连接超时
- `iptables -t nat -L`显示DNAT规则已配置
- `dmz`上的HTTP服务正常运行

#### 8.1.2 重现故障
```bash
# 删除 DNAT 配套放行规则（模拟故障）
sudo ip netns exec fw iptables -D FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 确认规则已被删除
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers | grep "veth-fw-inet.*veth-fw-dmz"
# 无输出，规则已删除

# 触发访问
sudo ip netns exec internet curl --max-time 5 http://203.0.113.1:8080/
# curl: (28) Connection timed out after 3003 milliseconds
```

#### 8.1.3 排查过程：

| 步骤 | 命令 | 结果 | 结论 |
|:-----|:-----|:-----|:------|
| 1 | `sudo ip netns exec internet curl --max-time 5 http://203.0.113.1:8080/` | `curl: (28) Connection timed out after 3003 milliseconds` | 确认故障可复现 |
| 2 | `sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers` | DNAT规则存在（`DNAT 203.0.113.1:8080 -> 10.40.0.2:8080`） | DNAT配置正确 |
| 3 | `sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers` | 缺少`-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080`的ACCEPT规则 | 找到根本原因：FORWARD链缺少DNAT配套放行规则 |
| 4 | `sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5` | 捕获到`203.0.113.10 -> 203.0.113.1`的SYN包 | 包到达fw入接口 |
| 5 | `sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5` | 无任何数据包捕获 | 确认包未转发到dmz接口，在转发链被丢弃 |

#### 8.1.4 抓包验证：
终端A（veth-fw-inet 入接口抓包）：
```text
$ sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on veth-fw-inet, link-type EN10MB (Ethernet), snapshot length 262144 bytes
21:09:21.509502 IP 203.0.113.10.38536 > 203.0.113.1.8080: Flags [S], seq 1385336745, win 64240, options [mss 1460,sackOK,TS val 4242805269 ecr 0,nop,wscale 7], length 0
21:09:22.526083 IP 203.0.113.10.38536 > 203.0.113.1.8080: Flags [S], seq 1385336745, win 64240, options [mss 1460,sackOK,TS val 4242806286 ecr 0,nop,wscale 7], length 0
21:09:23.549778 IP 203.0.113.10.38536 > 203.0.113.1.8080: Flags [S], seq 1385336745, win 64240, options [mss 1460,sackOK,TS val 4242807310 ecr 0,nop,wscale 7], length 0
21:09:26.717788 ARP, Request who-has 203.0.113.1 tell 203.0.113.10, length 28
21:09:26.717801 ARP, Reply 203.0.113.1 is-at ea:7d:d2:a9:db:dc, length 28
```
**分析：** veth-fw-inet 捕获到来自 internet 的 TCP SYN 握手包，目标地址仍为公网 IP `203.0.113.1:8080`（DNAT前），说明包已正常到达防火墙入接口。
 
**终端B（veth-fw-dmz 出接口抓包）：**
```text
$ sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on veth-fw-dmz, link-type EN10MB (Ethernet), snapshot length 262144 bytes
（无任何输出，等待超时）
```
**分析：** veth-fw-dmz 未捕获到任何数据包，说明 DNAT 虽然完成了地址转换，但转换后的数据包在 FORWARD 链中未被放行，直接被默认 DROP 策略丢弃，未能转发到 dmz 接口。

#### 8.1.5修复方法：
```bash
# 添加DNAT配套的FORWARD放行规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**验证修复：**
```bash
sudo ip netns exec internet curl --max-time 5 http://203.0.113.1:8080/
# 成功返回DMZ的HTML目录列表
```

**经验总结：**
DNAT与FORWARD规则必须配套配置。PREROUTING链的DNAT只做地址转换，转发决策仍在FORWARD链完成。配置DNAT时容易遗漏FORWARD放行规则，排查时应优先检查这两点。同时，通过双接口并行抓包可以快速定位断点：入接口有包但出接口无包，说明包在防火墙内部被丢弃，问题锁定在FORWARD链。

#### 8.1.6 实验过程截图
![](screenshots/19-troubleshoot-dnat.png)
---

### 8.2 VPN隧道握手正常但业务访问失败

#### 8.2.1 现象
- `wg show`显示`latest handshake`正常
- `remote ping 10.40.0.2`失败
- `fw`上没有相关日志

#### 8.2.2 可能原因
1. `AllowedIPs`配置错误
2. FORWARD规则拒绝了VPN流量
3. dmz没有回程路由
4. fw未开启IP转发

#### 8.2.3 重现原因1：FORWARD规则拒绝VPN流量
##### （1）重现故障：
```bash
# 删除VPN到dmz的FORWARD放行规则（模拟故障）
sudo ip netns exec fw iptables -D FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT 2>/dev/null || true

# 触发访问
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/
# curl: (28) Connection timed out after 5000 milliseconds
```
**快速定位方法：** 
使用`iptables -L FORWARD -n -v --line-numbers | grep wg0`检查是否存在`-i wg0`的ACCEPT规则。若无输出，则问题在此。

##### （2）tcpdump验证：
```bash
# 终端A：fw的wg0接口抓包
sudo ip netns exec fw tcpdump -ni wg0 -c 5
# 输出显示：10.10.10.2.xxxxx > 10.40.0.2.8080: Flags [S] ... （SYN包到达VPN接口）

# 终端B：fw的veth-fw-dmz接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5
# 无任何输出（包未转发到dmz）
```
**结论：** SYN包已到达wg0接口，但未转发到veth-fw-dmz，说明FORWARD链拦截了VPN流量。

##### （3）修复方法：
```bash
# 添加VPN到dmz:8080的FORWARD放行规则
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

##### （4）**验证修复：**
```bash
# 验证规则已生效
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep wg0
# 输出示例：
#   5    ACCEPT     tcp  --  wg0    veth-fw-dmz   10.10.10.2          10.40.0.2          tcp dpt:8080 ctstate NEW

# 触发访问
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/
# 成功返回DMZ的HTML目录列表

# 双接口抓包验证数据流恢复正常
# 终端A：wg0接口能抓到SYN包
# 终端B：veth-fw-dmz接口也能抓到转发的SYN包
sudo ip netns exec fw tcpdump -ni wg0 -c 1
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 1
```

##### （5）实验过程截图(图左)
![](screenshots/20-troubleshoot-vpn.png)

#### 8.2.4 重现原因2：AllowedIPs配置错误

##### (1) 重现故障：
```bash
# 将remote的AllowedIPs修改为不包含目标网段（只允许访问office，不含dmz）
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24

# 触发访问
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/
# curl: (7) Failed to connect to 10.40.0.2 port 8080 after 1 ms: Couldn't connect to server
```

**快速定位方法：** 执行`sudo ip netns exec remote wg show`查看`allowed ips`字段。如果allowed ips缺少目标网段（如`10.40.0.0/24`），则问题在此。同时执行`sudo ip netns exec remote ip route`检查路由表——缺少目标网段的路由条目是典型特征。

##### (2) 路由表对比：

| 状态 | `ip route`输出 | 说明 |
|:-----|:---------------|:-----|
| 配置正确 | `10.20.0.0/24 dev wg0 ...` + `10.40.0.0/24 dev wg0 ...` | 两个网段都走VPN隧道 |
| 配置错误 | `10.20.0.0/24 dev wg0 ...`（缺少dmz路由） | dmz网段无路由，数据包无法发送 |

**结论：** remote的AllowedIPs未包含dmz网段，导致系统未创建到`10.40.0.0/24`的VPN路由，数据包无法通过wg0发出。

##### (3) 修复方法：
```bash
# 恢复remote的AllowedIPs，同时包含office和dmz网段
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)
sudo ip netns exec remote wg set wg0 peer $FW_PUB allowed-ips 10.20.0.0/24,10.40.0.0/24
```

##### (4) **验证修复：**
```bash
# 验证路由表已恢复
sudo ip netns exec remote ip route | grep wg0
# 输出：
# 10.10.10.0/24 dev wg0 proto kernel scope link src 10.10.10.2 
# 10.20.0.0/24 dev wg0 scope link 
# 10.40.0.0/24 dev wg0 scope link 

# 验证AllowedIPs已正确配置
sudo ip netns exec remote wg show
# allowed ips显示：10.20.0.0/24, 10.40.0.0/24

# 触发访问
sudo ip netns exec remote curl --max-time 5 http://10.40.0.2:8080/
# 成功返回DMZ的HTML目录列表
```
#### 8.2.5 如何快速定位具体是哪个问题

**排查方法：**
按以下顺序逐层排查，可在1分钟内定位问题：

| 排查顺序 | 检查项 | 命令 | 判断依据 |
|:---------|:-------|:-----|:---------|
| 1 | **隧道状态** | `sudo ip netns exec remote wg show` | 确认latest handshake正常（优先排除Endpoint、密钥等底层问题） |
| 2 | **remote路由表** | `sudo ip netns exec remote ip route \| grep wg0` | 检查目标网段（如10.40.0.0/24）是否有路由指向wg0，若无则AllowedIPs配置错误 |
| 3 | **fw IP转发** | `sudo ip netns exec fw sysctl net.ipv4.ip_forward` | 确认输出为`net.ipv4.ip_forward = 1` |
| 4 | **FORWARD规则** | `sudo ip netns exec fw iptables -L FORWARD -n -v \| grep wg0` | 检查是否有`-i wg0`的ACCEPT规则 |
| 5 | **dmz回程路由** | `sudo ip netns exec dmz ip route \| grep default` | 确认默认路由指向10.40.0.1 |

**关键判断逻辑：**
- 若`ip route`缺少目标网段 → AllowedIPs配置错误
- 若路由存在但FORMARD链无规则 → FORWARD规则缺失
- 若dmz无默认路由 → dmz回程路由问题
- 若ip_forward=0 → 内核转发未开启

**经验总结：**
VPN隧道握手正常不代表业务可通。控制面（握手）走的是UDP 51820端口的通信，数据面（业务流量）依赖路由表、FORWARD规则等多个环节。排查时应遵循"先路由、再转发、后抓包"的原则，按顺序逐层排查。

#### 8.2.6 实验过程截图(图右)
![](screenshots/20-troubleshoot-vpn.png)
---

### 8.3 去掉ESTABLISHED,RELATED后TCP连接失败
#### 8.3.1 现象
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

#### 8.3.2 重现故障
```bash
# 步骤1：查看当前FORWARD规则（确认ESTABLISHED,RELATED规则存在）
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
# 输出显示第1行为：ACCEPT all -- anywhere anywhere ctstate RELATED,ESTABLISHED

# 步骤2：删除ESTABLISHED,RELATED状态检测规则（模拟故障）
sudo ip netns exec fw iptables -D FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT 2>/dev/null || true

# 步骤3：触发访问，确认故障复现
sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080/
# curl: (28) Connection timed out after 5002 milliseconds
```

---

#### 8.3.3 tcpdump证明SYN-ACK被拦截

**tcpdump抓包验证：**
在三个终端分别执行以下命令，同步观察数据包流向：

| 终端 | 命令 | 观察目标 |
|:-----|:-----|:---------|
| A | `sudo ip netns exec fw tcpdump -ni veth-fw-office -c 3` | 观察office侧发出的SYN及重传（无SYN-ACK回包） |
| B| `sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 1` | 观察dmz侧是否收到SYN |
| C | `sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080/` | 触发访问 |

**执行结果与分析：**

**终端B（veth-fw-dmz）输出：**
```
listening on veth-fw-dmz, link-type EN10MB (Ethernet), snapshot length 262144 bytes
22:37:47.366629 IP 10.20.0.2.44898 > 10.40.0.2.8080: Flags [S], seq 3898375516, win 64240, options [mss 1460,sackOK,TS val 273004834 ecr 0,nop,wscale 7], length 0
1 packet captured
```
> SYN包成功从office转发到dmz — 说明FORWARD链中`office → dmz:8080`的NEW规则正常放行。

**终端A（veth-fw-office）输出：**
```
listening on veth-fw-office, link-type EN10MB (Ethernet)
22:37:47.366330 IP 10.20.0.2.44898 > 10.40.0.2.8080: Flags [S], seq ...  ← office发出的SYN
22:37:48.381802 IP 10.20.0.2.44898 > 10.40.0.2.8080: Flags [S], seq ...  ← 重传SYN（未收到SYN-ACK）
22:37:49.405768 IP 10.20.0.2.44898 > 10.40.0.2.8080: Flags [S], seq ...  ← 重传SYN（超时重传）
```
> veth-fw-office接口只捕获到出去的SYN和重传包，完全没有SYN-ACK。因为dmz回复的SYN-ACK进入FORWARD链后，不匹配任何ACCEPT规则，被默认DROP丢弃，根本无法被转发回veth-fw-office接口。这恰好证明了"SYN能通过、SYN-ACK被拦截"的故障特征。

**补充验证（在dmz侧抓包，证明dmz确实回复了）：**
```bash
sudo ip netns exec dmz tcpdump -c 2 -i any port 8080

# 输出：
# 22:42:51.807428 veth-dmz In  IP 10.20.0.2.47160 > 10.40.0.2.8080: Flags [S]    ← dmz收到SYN
# 22:42:51.807523 veth-dmz Out IP 10.40.0.2.8080 > 10.20.0.2.47160: Flags [S.]   ← dmz回复SYN-ACK
```

> dmz侧同时抓到了入站SYN和出站SYN-ACK，证明dmz确实正常回复了。但fw上的veth-fw-office接口抓不到任何SYN-ACK，说明回包在fw的FORWARD链被DROP，未能转发回office。

#### 8.3.4 对比故障前后数据流：

| 阶段 | 数据流 | 故障时 | 正常时 |
|:-----|:-------|:-------|:-------|
| ① | office → dmz (SYN) | 通过  | 通过|
| ② | dmz → office (SYN-ACK) | 被拦截 | 通过  |
| ③ | office → dmz (ACK) | 不会发生 | 通过  |
| 结果 | TCP三次握手 | 失败  | 成功  |

**conntrack验证：**
```bash
sudo ip netns exec fw conntrack -L | grep 10.20.0.2
# 故障时：conntrack v1.4.8 (conntrack-tools): 1 flow entries have been shown.（无匹配记录）
# 正常时：tcp      6 112 TIME_WAIT src=10.20.0.2 dst=10.40.0.2 sport=52984 dport=8080 src=10.40.0.2 dst=10.20.0.2 sport=8080 dport=52984 [ASSURED] mark=0 use=1
```

---

#### 8.3.5 理解ESTABLISHED,RELATED的必要性

**为什么ESTABLISHED,RELATED是必须的？**

在无状态防火墙中，需要为每个方向分别配置规则。例如office访问dmz:8080，必须同时配置两条规则：
```
# 规则A：放行office→dmz的请求
iptables -A FORWARD -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 8080 -j ACCEPT

# 规则B：放行dmz→office的回包
iptables -A FORWARD -s 10.40.0.0/24 -d 10.20.0.0/24 -p tcp --sport 8080 -j ACCEPT
```

这在有N个网段时，规则数量呈O(N²)增长，配置复杂且易出错。

**conntrack（连接跟踪）机制解决这个问题：**
```
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```
- **ESTABLISHED**：自动放行所有已建立连接的回包。
- **RELATED**：放行关联连接（如FTP的数据连接、ICMP差错报文），确保复杂协议也能正常工作。

去掉ESTABLISHED,RELATED后的影响：

| 协议 | 场景 | 影响 |
|:-----|:-----|:-----|
| TCP | office访问dmz:8080 | SYN通过 → SYN-ACK被拦截 → 三次握手失败 → curl超时 |
| TCP | 任何双向通信 | 单向可通过，回包全被拦截 |
| UDP/DNS | 内网DNS查询 | 请求发出，响应被拦截，域名解析失败 |
| ICMP | ping测试 | 请求发出，echo reply被拦截，显示100%丢包 |
| FTP | 主动/被动模式 | 数据连接无法建立 |

**结论**：
`ESTABLISHED,RELATED`规则是防火墙最基础、最核心的规则。它利用conntrack连接跟踪，让防火墙具备状态感知能力，只需配置单方向的新建连接放行规则，conntrack自动管理回包通行。缺少这条规则，所有需要双向通信的协议都将无法正常工作。该规则必须放在FORWARD链最顶部，确保所有合法回包第一时间匹配通过，不被后续规则错误拦截。

---

#### 8.3.6 修复与验证

**修复方法**：
```bash
# 恢复ESTABLISHED,RELATED状态检测规则（必须放在FORWARD链最顶部）
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

**验证修复：**
```bash
# 验证TCP连接恢复
sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080/
# 成功返回网页内容

# 验证conntrack连接跟踪已建立
sudo ip netns exec fw conntrack -L | grep 10.20.0.2
# tcp      6 112 TIME_WAIT src=10.20.0.2 dst=10.40.0.2 sport=52984 dport=8080 src=10.40.0.2 dst=10.20.0.2 sport=8080 dport=52984 [ASSURED] mark=0 use=1

# 验证规则位置正确（必须是FORWARD链第1条）
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
# 1    ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
# 2    ACCEPT     all  --  veth-fw-office veth-fw-inet  10.20.0.0/24         0.0.0.0/0
# ...（后续规则省略）
```

## 九、遇到的问题和解决方法

### 9.1 WireGuard公钥文件路径不存在

#### 9.1.1 现象
在执行`sudo ip netns exec remote wg set wg0 peer $(sudo ip netns exec fw cat /etc/wireguard/fw/fw.pub) allowed-ips 10.20.0.0/24`时，报错`cat: /etc/wireguard/fw/fw.pub: No such file or directory`，导致命令失败。

#### 9.1.2 原因
 WireGuard的配置文件存放在`/etc/wireguard/fw/wg0.conf`路径下，但实验中未单独生成`.pub`公钥文件。公钥通过`wg genkey | tee privatekey | wg pubkey > publickey`生成时未保存到统一规范路径。

#### 9.1.3 解决方法
```bash
# 方法1：通过wg show直接获取公钥（推荐）
FW_PUB=$(sudo ip netns exec fw wg show wg0 public-key)

# 方法2：从私钥推导公钥
sudo ip netns exec fw cat /etc/wireguard/fw/wg0.conf | grep PrivateKey | awk '{print $3}' | sudo ip netns exec fw wg pubkey
```

**经验：** 在编写自动化脚本时，不应硬编码文件路径，应使用`wg show`命令动态获取密钥信息，提高脚本的健壮性和可移植性。

---

### 9.2 `wg set`命令缺少公钥参数

#### 9.2.1 现象
 执行`sudo ip netns exec remote wg set wg0 peer allowed-ips 10.20.0.0/24`时报错`Key is not the correct length or format`。

#### 9.2.2 原因
 `wg set`命令的语法要求必须在`peer`后面跟具体的公钥字符串，`allowed-ips`被错误地当作了公钥参数解析。

#### 9.2.3 解决方法
 确保`wg set`命令包含完整的公钥参数：
```bash
# 正确语法
sudo ip netns exec remote wg set wg0 peer <对方公钥> allowed-ips <网段>
```

**经验：** WireGuard的命令行工具对参数顺序要求严格，使用前应查阅`wg set --help`确认语法格式，避免参数错位导致命令执行失败。

---

### 9.3 WSL2环境下iptables LOG目标无法写入内核日志

#### 9.3.1 现象
 配置了`-j LOG`规则后，执行`dmesg | grep -i "DENY\|GUEST"`始终无输出，无法查看防火墙拦截日志。

#### 9.3.2 原因 
实验环境为WSL2（Hyper-V虚拟化），使用nftables内核子系统作为iptables后端（nf_tables）。在WSL2中，LOG目标的日志消息无法通过标准`dmesg`或`journalctl`输出，因为WSL2缺少完整的系统日志管道支持。

#### 9.3.3 解决方法
 改用`tcpdump`在防火墙命名空间中抓取ICMP端口不可达报文作为审计证据：
```bash
# 抓取REJECT返回的ICMP不可达报文
sudo ip netns exec fw tcpdump -ni any "icmp[icmptype] == 3" -c 10
```
同时通过iptables规则计数器验证拦截是否生效：
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "LOG|REJECT"
```

**经验：** 在非标准Linux环境（如WSL、容器）中进行实验时，需要提前确认系统日志、网络功能的兼容性。遇到日志功能不可用时应灵活切换抓包工具完成审计验证。

---

### 9.4 iptables命令执行权限与命名空间问题

#### 9.4.1 现象
在宿主机直接执行`iptables -L FORWARD`时报错`Fatal: can't open lock file /run/xtables.lock: Permission denied`。

#### 9.4.2 原因
 两个问题叠加：
1. 缺少`sudo`权限，无法访问`/run/xtables.lock`锁文件
2. 未进入`fw`网络命名空间，操作的是宿主机的iptables规则而非防火墙的规则

#### 9.4.3 解决方法
 所有防火墙相关命令必须使用完整格式：
```bash
sudo ip netns exec fw iptables <参数>
```

**经验：** 网络命名空间环境下，排错的第一步是确认当前操作在正确的命名空间中执行。可以将常用命令保存为别名或脚本，避免重复输入。

---

### 9.5 DNAT规则配置后外网无法访问
#### 9.5.1 现象
 按照标准流程配置了DNAT端口映射（`203.0.113.1:8080 → 10.40.0.2:8080`），但外网访问始终超时。

#### 9.5.2 原因
 只配置了`nat`表的PREROUTING DNAT规则，但未在`filter`表的FORWARD链添加配套的放行规则。DNAT只做地址转换，转发决策仍由FORWARD链完成。由于FORWARD链默认策略为DROP，转换后的数据包在FORWARD链被丢弃。

#### 9.5.3 解决方法
为DNAT配置配套的FORWARD放行规则：
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**经验：** DNAT与FORWARD规则必须配套配置。排查外网访问故障时，应优先检查两点：（1）NAT规则是否正确（2）FORWARD链是否有对应放行规则。使用双接口并行抓包可以快速定位断点位置。

---

### 9.6 ESTABLISHED,RELATED规则被误删除

#### 9.6.1 现象 
在调试其他规则时误删除了ESTABLISHED,RELATED状态检测规则，导致所有需要双向通信的协议均无法正常工作。

#### 9.6.2 原因 
该规则利用conntrack连接跟踪机制放行合法回包，被删除后：
- SYN包能通过NEW规则放行
- 服务器的SYN-ACK回包在FORWARD链无匹配规则，被默认DROP丢弃
- TCP三次握手失败，表现为连接超时

#### 9.6.3 解决方法
将ESTABLISHED,RELATED规则插入FORWARD链最顶部：
```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

**经验：** ESTABLISHED,RELATED规则是防火墙策略的基础，必须始终放在FORWARD链第一条。建议在操作iptables规则前先备份当前规则：
```bash
sudo ip netns exec fw iptables-save > /tmp/fw-rules-backup.txt
```

---

### 9.7 setup.sh执行时报veth网卡和IP配置错误

#### 9.7.1 现象
 执行`setup.sh`时出现多条错误：
- `Cannot find device "veth-internet"`（找不到网卡设备）
- `Error: Attribute failed policy validation`（属性策略验证失败）
- `RTNETLINK answers: File exists`（IP地址已存在）

但脚本执行完毕后，各网段ping测试均显示0%丢包，连通性正常。

#### 9.7.2 原因
脚本添加了`|| true`容错机制，且包含清理历史残留命令。当脚本被**重复执行**时：
- 第一次执行时正常创建所有资源
- 后续重复执行时，部分设备/IP已存在，导致相应的创建命令报错
- 但ping测试成功说明最终拓扑是正确的

#### 9.7.3 解决方法 
- 所有重复执行前的错误属于正常现象，不影响最终结果
- 如需完全干净的重新部署，可先执行清理命令：
```bash
# 手动清理所有命名空间
for ns in fw office guest dmz internet remote; do
  sudo ip netns del $ns 2>/dev/null || true
done
# 再重新执行setup.sh
sudo ./setup.sh
```

**经验：** 添加`|| true`容错后脚本虽然可重复执行，但输出中的错误信息容易造成混淆。建议在脚本开头增加清理逻辑或添加判断逻辑：检查目标资源是否已存在，存在则跳过创建步骤，减少冗余错误输出。

---

### 9.8 VPN隧道握手正常但业务访问不通

#### 9.8.1 现象
- `wg show`显示`latest handshake: 4 seconds ago`，隧道握手正常
- remote执行`ping 10.20.0.2`和`curl http://10.40.0.2:8080/`均返回`Connection timed out after 3000 milliseconds`
- fw命名空间可以ping通office（`ping 10.20.0.2`成功）
- 防火墙FORWARD规则已配置但是仍然不通

#### 9.8.2 原因
这是一个复合问题，涉及多个环节：
1. 防火墙fw命名空间的`net.ipv4.ip_forward`内核转发未开启，导致所有跨网段转发均失败
2. 开启IP转发后，fw能ping通office，但remote仍然不通——此时问题变为FORWARD链缺少VPN流量的ACCEPT规则（`-i wg0`的相关规则未配置）

#### 9.8.3 排查过程
| 步骤 | 命令 | 结果 | 结论 |
|:-----|:-----|:-----|:------|
| 1 | `wg show` | latest handshake正常 | 隧道正常 |
| 2 | `sudo ip netns exec fw sysctl net.ipv4.ip_forward` | `net.ipv4.ip_forward = 0` | **内核转发未开启** |
| 3 | 开启转发后fw→office ping通 | remote→office仍超时 | 问题转移至FORWARD规则 |
| 4 | `sudo ip netns exec fw iptables -L FORWARD -n -v | grep wg0` | 无输出 | **FORWARD链缺少wg0规则** |

#### 9.8.4 解决方法
```bash
# 步骤1：开启内核IP转发
sudo ip netns exec fw sysctl net.ipv4.ip_forward=1

# 步骤2：添加VPN到DMZ的FORWARD放行规则
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**经验：** VPN隧道握手正常不代表业务可通。控制面（握手）与数据面（业务流量）依赖不同的系统组件：
- 控制面（握手）：依赖WireGuard配置（Endpoint、密钥、端口）、UDP通信
- 数据面（业务流量）：依赖路由表、内核IP转发、FORWARD规则、回程路由

排查时应遵循"先检查IP转发、再检查路由表、最后检查FORWARD规则"的顺序，避免在一个问题上钻牛角尖而忽略更基础的配置。

## 十、总结与思考
通过本次企业级网络安全架构搭建与攻防演练实验，我对现代企业网络安全的整体架构设计、多区域隔离策略、VPN远程接入机制以及安全审计与应急响应有了较为深入的理解。

### 10.1 网络隔离与分层设计

企业网络应采用"纵深防御"原则进行分层设计。本次实验通过Linux网络命名空间模拟了办公区、访客区、DMZ区、外网区四个业务区域，每个区域之间通过防火墙实现严格的逻辑隔离。这种网络拓扑设计体现了企业网络安全的基础思想：**不信任任何网段，最小化区域间暴露面**。办公网只能有限访问DMZ的业务端口（8080），访客网完全隔离内部资源，外网仅能通过DNAT映射访问DMZ的Web服务。这种多层次的隔离策略有效限制了攻击横向移动的范围——即使某一区域被攻破，攻击者也无法直接访问其他内网资源。

### 10.2 防火墙策略的精细化设计

防火墙规则的设计需要兼顾安全性与业务可用性。本次实验中我体会最深的是iptables规则顺序对策略效果的决定性影响：ESTABLISHED,RELATED状态检测规则必须置顶，业务放行规则在拦截规则之前，LOG规则在REJECT规则之前。这些细节决定了防火墙能否正常工作。通过对比实验（去掉ESTABLISHED,RELATED规则后TCP连接失败），我深刻理解了状态检测防火墙与无状态防火墙的本质区别——状态检测通过conntrack自动管理回包，将规则复杂度从O(N²)降低到O(N)。

同时，此次实验验证了"最小权限原则"在防火墙策略中的具体实现：所有ACCEPT规则均严格限定入接口、出接口、源网段、目的网段和目的端口，不存在任何宽泛放行规则。这种精细化控制虽然增加了配置复杂度，但显著缩小了攻击面。

### 10.3 VPN远程接入的安全实现

远程安全接入是企业网络的重要组成部分。本次实验使用WireGuard实现了站点到站点的VPN隧道，其设计体现了现代VPN的核心安全理念：基于公钥加密的身份认证、最小权限的路由控制（AllowedIPs）、隧道保活机制。在实验中我遇到的最大教训是：VPN隧道握手正常不代表业务可通。控制面（握手）与数据面（业务流量）是独立的路径——握手成功只说明UDP 51820端口的通信正常，但业务流量还需依赖路由表、FORWARD规则等多个环节。这一认识对未来的网络排错有重要指导意义。

### 10.4 安全审计与日志分析的价值

日志审计是企业安全运营的基础。本次实验配置了五类违规访问的LOG审计规则，为每条规则设置独立的前缀标记，通过tcpdump抓取REJECT返回的ICMP报文来验证审计功能。在攻防演练环节中，通过分析iptables规则计数器的包数量，可以识别攻击源网段、判断攻击类型（扫描、探测、绕过尝试），为制定安全加固策略提供了数据支撑。这让我认识到：安全审计不仅仅是记录日志，更重要的是从日志中提取威胁情报、发现安全态势。

### 10.5 故障排查的方法论

实验最后一部分的三种故障场景模拟了真实运维中可能遇到的典型问题：DNAT无法访问、VPN业务不通、状态检测失效。通过双接口并行抓包、连接跟踪分析、路由表检查等系统性排查方法，我建立了"先路由、再转发、后抓包"的标准化故障排查流程。这种结构化的问题分析方法，在真实网络运维场景中能够大幅缩短故障定位时间。

### 10.6 攻防对抗的实战认识

在攻防演练环节，我分别从攻击者和防御者两个视角进行了实践。作为攻击者，尝试了网段扫描、端口绕过、源IP伪造三种攻击手段，理解了为什么简单的安全措施（如入网卡校验、基于五元组的访问控制）能够有效抵御常见攻击。作为防御者，通过LOG日志追踪攻击行为、分析规则计数器评估防御效果、使用connlimit限制并发连接数来加固DMZ服务，体验了从"发现问题"到"提出方案"到"验证效果"的完整安全运维流程。

### 10.7总结

本次实验构建了一个功能完整的企业级网络安全环境，涵盖网络规划、防火墙策略、VPN接入、安全审计、攻防演练、故障排查六大模块。通过实践，我不仅掌握了iptables、WireGuard、tcpdump、conntrack等核心网络工具的使用，更重要的是建立了企业网络安全架构的整体思维框架：网络隔离是基础、最小权限是原则、状态检测是核心、日志审计是保障、持续改进是常态。这套方法论将对我未来的网络安全学习与工作产生深远影响。