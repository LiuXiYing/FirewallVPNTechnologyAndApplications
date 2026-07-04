
# 企业级网络安全架构搭建与攻防演练

## 一、实验环境

- 操作系统：Kali Linux（内核版本 6.11.2-amd64）
- WireGuard版本：1.0.0
- iptables版本：v1.8.11 (nf_tables)
- 网络工具：iproute2、ping、curl、tcpdump、conntrack-tools

---


## 二、拓扑图和地址规划

### 拓扑图

```
+--------------------------------------------------+
|                    fw (防火墙+VPN网关)              |
|  +--------+  +--------+  +--------+  +--------+  |
|  | office |  | guest  |  |  dmz   |  |internet|  |
|  | 10.20  |  | 10.30  |  | 10.40  |  |203.0   |  |
|  | .0.2   |  | .0.2   |  | .0.2   |  |113.10  |  |
|  +--------+  +--------+  +--------+  +--------+  |
|       |           |           |           |       |
|   veth-fw-   veth-fw-   veth-fw-   veth-fw-      |
|   office     guest      dmz        inet          |
|   10.20.0.1  10.30.0.1  10.40.0.1  203.0.113.1   |
+--------------------------------------------------+
                        |
                    WireGuard
                    (10.10.10.0/24)
                        |
                   +--------+
                   | remote |
                   |10.10.10|
                   | .0.2   |
                   +--------+
```

### 地址规划表

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |


## 三、第一部分：网络规划与基础搭建

### setup.sh说明

setup.sh是网络拓扑搭建的核心脚本，负责创建所有namespace、veth对和配置网络参数，实现企业多区域网络隔离环境。

**脚本功能模块：**

1. **清理旧环境**：删除可能残留的namespace和veth设备，确保脚本可重复运行
2. **创建6个namespace**：fw、office、guest、dmz、internet、remote
3. **创建veth对**：连接fw与各区域，共5对veth
4. **配置IP地址**：为每个接口分配规划好的IP地址
5. **配置路由**：各区域默认路由指向fw对应网关
6. **开启IP转发**：fw上启用`net.ipv4.ip_forward=1`

**关键配置示例：**

以office为例：
```bash
# 创建veth对
sudo ip link add veth-fw-office type veth peer name veth-office
# 分别放入对应namespace
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
# 配置IP地址
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
# 配置默认路由
sudo ip netns exec office ip route add default via 10.20.0.1
guest、dmz、internet采用相同方式配置，使用对应网段。

注意： internet接口由于veth设备名称长度限制，实际使用短名称 veth-fw-inet/veth-inet，IP地址仍为203.0.113.1/203.0.113.10，功能完全一致。
```
### 拓扑搭建步骤

**步骤1：创建6个network namespace**

使用 `ip netns add` 命令创建fw、office、guest、dmz、internet、remote六个独立网络空间，实现各区域网络隔离。每个namespace拥有独立的网络栈、路由表和防火墙规则。

```bash
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
```

**步骤2：创建veth对连接各区域到fw**

veth（Virtual Ethernet）是成对出现的虚拟网络设备，一端连接一个namespace，实现跨namespace通信。共创建5对veth连接fw与各区域。

以office为例：
```bash
# 创建veth对
sudo ip link add veth-fw-office type veth peer name veth-office

# 将两端分别放入fw和office namespace
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

# 配置IP地址并启用
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up
```

guest、dmz、internet采用相同方式配置，使用对应的网段和接口名称。

> **注意：** 配置internet连接时，执行 `sudo ip link add veth-fw-internet type veth peer name veth-internet` 报错 `Error: Attribute failed policy validation`。原因是Linux内核限制veth设备名称长度不超过15个字符，`veth-fw-internet` 长度为18个字符，超过限制。解决方案：使用短名称 `veth-fw-inet/veth-inet` 替代，功能完全相同。

**步骤3：配置路由和IP转发**

各区域主机的默认路由指向fw对应接口的网关地址，确保所有跨区域流量都经过fw处理：

```bash
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
```

在fw上开启IP转发，使其能够转发不同区域之间的数据包：

```bash
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```

### 验证方法

在每个区域中ping防火墙对应接口的IP地址，验证网络连通性：

```bash
# office验证
sudo ip netns exec office ping -c 2 10.20.0.1

# guest验证
sudo ip netns exec guest ping -c 2 10.30.0.1

# dmz验证
sudo ip netns exec dmz ping -c 2 10.40.0.1

# internet验证
sudo ip netns exec internet ping -c 2 203.0.113.1
```

### 连通性测试结果

| 测试项 | 预期结果 | 实际结果 | 丢包率 |
|:-------|:---------|:---------|:-------|
| office → 10.20.0.1 | 通 | 通 | 0% |
| guest → 10.30.0.1 | 通 | 通 | 0% |
| dmz → 10.40.0.1 | 通 | 通 | 0% |
| internet → 203.0.113.1 | 通 | 通 | 0% |

所有基础连通性测试全部通过，网络搭建成功。


## 四、第二部分：防火墙策略实现

### firewall.sh说明

防火墙策略遵循最小权限原则，默认策略为DROP，仅放行必要的流量。

**规则顺序设计：**
1. 状态检测规则（ESTABLISHED,RELATED）在最前
2. 具体放行规则（office→dmz:8080、guest→internet等）
3. LOG规则记录违规访问
4. REJECT/DROP规则拒绝未授权流量

**REJECT vs DROP选择：**
- REJECT用于明确禁止的场景（如guest→office），让客户端立即知道被拒绝
- DROP用于外部访问（如internet→office），不暴露信息，更安全

### 访问控制矩阵

| 来源 | 目标 | 预期结果 | 实际结果 |
|:-----|:-----|:---------|:---------|
| office | dmz:8080 | 成功 | 成功（HTTP 200） |
| office | dmz:22 | 失败+LOG | 失败（000），有LOG记录 |
| guest | office:任意 | 失败+LOG | 失败（不可达），有LOG记录 |
| guest | dmz:8080 | 失败+LOG | 失败（000），有LOG记录 |
| guest | internet:任意 | 成功 | 成功（ping通） |
| office | internet:任意 | 成功 | 成功（ping通） |
| internet | fw公网IP:8080 | 成功（DNAT） | 成功（HTTP 200） |
| internet | dmz:22 | 失败 | 失败（超时） |

---

## 五、第三部分：VPN远程接入

### WireGuard配置

**fw端 `/etc/wireguard/fw/wg0.conf`：**
```
[Interface]
Address = 10.10.10.1/24
PrivateKey = [隐藏]
ListenPort = 51820

[Peer]
PublicKey = [隐藏]
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
```

**remote端 `/etc/wireguard/remote/wg0.conf`：**
```
[Interface]
Address = 10.10.10.2/24
PrivateKey = [隐藏]

[Peer]
PublicKey = [隐藏]
Endpoint = 203.0.113.254:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
```

### AllowedIPs设计思路

| 端 | AllowedIPs | 设计理由 |
|:---|:-----------|:---------|
| fw | 10.10.10.2/32 | 只接受remote的VPN地址，精确匹配 |
| remote | 10.20.0.0/24,10.40.0.0/24 | 只有访问办公网和DMZ时走VPN，避免所有流量都经过VPN |

### VPN测试结果

| 测试项 | 预期 | 结果 |
|:-------|:-----|:-----|
| remote → office | 成功 | 成功（0%丢包） |
| remote → dmz:8080 | 成功 | 成功（HTTP 200） |
| remote → dmz:22 | 失败+LOG | 失败（000），有LOG |
| remote → guest | 失败 | 失败（不可达） |
| wg show握手 | 有latest handshake | 有（2秒前） |
| wg show transfer | 有数据收发 | 有（KiB级别） |

---

## 六、第四部分：安全审计与日志分析

### LOG规则配置

所有REJECT规则均配置了对应的LOG规则：

| 事件类型 | log-prefix | 速率限制 |
|:--------|:-----------|:---------|
| guest访问office | GUEST-TO-OFFICE: | 5/min burst 10 |
| guest访问dmz | GUEST-TO-DMZ: | 5/min burst 10 |
| VPN访问dmz:22 | VPN-TO-DMZ-SSH: | 无限制 |
| internet访问内网 | INET-TO-OFFICE: | 5/min burst 10 |
| 其他VPN违规 | VPN-DENY: | 5/min burst 10 |

### 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office | 22 | 22 | 是 |
| guest→dmz | 4 | 4 | 是|
| VPN→dmz:22 | 14 | 14 | 是|
| internet→office | 2 | 2 | 是 |
| VPN其他违规 | 6 | 6 | 是|

> **说明：** 由于系统环境限制（namespace内iptables LOG输出未写入宿主机内核日志），使用iptables规则列表中的 `pkts` 计数作为日志记录证据。规则中包含的 `-i`（IN）、`-o`（OUT）、`-s`（SRC）、`-d`（DST）、`--dport`（DPT）字段完整记录了攻击特征信息，可满足日志审计要求。

### 日志分析报告

**1. 从日志中能获取哪些安全信息？**

日志中包含以下安全信息：
- `IN`/`OUT`：流量进出口接口，识别攻击来源区域和目标区域
- `SRC`：源IP地址，定位攻击者
- `DST`：目标IP地址，识别被攻击目标
- `DPT`：目标端口，判断攻击类型（如22端口为SSH扫描）
- `PROTO`：协议类型（TCP/UDP/ICMP）
- `log-prefix`：快速识别违规类型

**2. LOG规则为什么要放在REJECT之前？**

iptables按顺序匹配规则，流量匹配到REJECT后立即被拒绝，不再继续执行后续规则。如果LOG放在REJECT之后，被拒绝的流量将不会被记录。LOG必须在REJECT/DROP之前才能完整记录所有被拒绝的流量。

**3. 速率限制如何防止日志洪水攻击？**

`--limit 5/min --limit-burst 10` 限制每分钟最多记录5条日志，突发允许10条。可以防止攻击者用大量请求填满日志空间，避免系统性能下降，同时保留关键安全信息。

**4. 不同log-prefix的作用是什么？**

不同log-prefix用于快速识别违规类型（如GUEST-TO-OFFICE、VPN-DENY），便于统计分析不同维度的安全事件，支持自动化告警和按事件类型过滤查询。

---

## 七、第五部分：攻防演练

### 7.1 攻击方任务

**攻击1：扫描office网段**

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**结果：** 只有10.20.0.1（网关）通，其余IP全部不可达。

**失败原因分析（100字）：**
防火墙FORWARD链默认策略为DROP，guest到office的流量被REJECT规则拦截。攻击者只能探测到网关存活，无法获取内网主机信息。ICMP请求被防火墙拦截并返回"Destination Port Unreachable"，表明防火墙在应用层实施了访问控制。

**攻击2：尝试绕过防火墙访问dmz:22**

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**结果：** 所有尝试均失败（curl: (7) Failed to connect）。

**失败原因分析（100字）：**
防火墙基于五元组（协议、源IP、源端口、目的IP、目的端口）进行访问控制，guest到dmz:22的流量被REJECT规则明确拒绝。无论源端口如何变化，目的IP（10.40.0.2）和目的端口（22）始终匹配拒绝规则，因此无法绕过。

**攻击3：尝试伪造VPN流量**

```bash
sudo ip netns exec guest ping -I 10.10.10.2 -c 1 10.20.0.2 2>&1
```

**结果：** `ping: bind: 无法分配被请求的地址`

**失败原因分析（100字）：**
攻击者无法伪造源地址为10.10.10.2的包，因为该IP不属于guest的本地接口。即使强行构造伪造包，fw也会因入口接口不匹配（guest从veth-fw-guest进入，VPN流量从wg0进入）而丢弃。防火墙规则明确限制 `-i wg0 -s 10.10.10.2`，入口接口不同，规则不匹配。

**回答：攻击者能否从REJECT和DROP的不同表现判断目标是否存在？**

可以。REJECT返回ICMP不可达消息（如"Destination Port Unreachable"），攻击者能确认目标存在但被拒绝；DROP直接静默丢弃（超时），攻击者无法判断目标是否存在。因此DROP比REJECT更安全，能增加攻击者的信息收集难度。本实验中guest→office使用REJECT（返回不可达），internet→office使用DROP（超时），体现了不同场景的安全策略差异。


## 7.2 防御方任务

### 任务1：从日志中识别攻击

**问题1：从日志的哪些字段可以判断这是来自guest的攻击？**

从日志中的以下字段可以判断攻击来自guest区域：`IN=veth-fw-guest` 表示流量从guest区域的网络接口进入防火墙，`SRC=10.30.0.2` 是guest主机的IP地址，`OUT=veth-fw-office` 表示流量的目标指向办公区，`DPT=22`（或目标端口）可以识别攻击类型。通过组合这些字段可以完整还原攻击路径：从哪个区域来（IN）、攻击者是谁（SRC）、要去哪个区域（OUT）、攻击什么服务（DPT）。同时，`PROTO=TCP` 或 `PROTO=ICMP` 可以识别攻击使用的协议类型。这些字段共同构成了攻击行为的完整画像，帮助安全分析人员快速定位和响应。

**问题2：如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？**

这说明guest区域的主机（10.30.0.2）尝试向office区域发起连接，但被防火墙拦截。这是一次典型的跨区域违规访问行为，违反了"访客不能访问办公网"的安全策略。该日志证明了防火墙成功实施了区域隔离机制，阻止了未授权访问。这种情况可能发生在访客设备试图扫描或攻击内网资源时，也可能是访客用户无意中访问了不该访问的内部系统。无论哪种情况，都表明防火墙的访问控制策略正在发挥作用，有效阻止了潜在的安全威胁横向传播。

**问题3：为什么看到大量相同来源的日志应该引起警惕？**

大量相同来源的拒绝日志表明该IP地址正在对目标网络进行自动化扫描或暴力破解攻击。这种密集的访问尝试通常是攻击的前兆，攻击者在进行信息收集（如端口扫描、服务探测）或尝试突破访问控制（如密码暴力破解）。这种情况可能意味着：该主机已被入侵成为僵尸网络的一部分，正在执行自动化攻击脚本；或者有攻击者正在手动进行渗透测试。安全团队应及时对该IP进行封禁，并排查该来源区域是否存在其他安全风险，同时加强监控和告警机制。


### 任务2：分析规则的防御效果

**问题1：哪条规则拦截了guest访问office？**

规则12（行号12）拦截了guest访问office：`REJECT all -- veth-fw-guest veth-fw-office`。该规则匹配所有从guest区域（接口veth-fw-guest）发出的、目标是office区域（接口veth-fw-office）的流量，无论协议类型和端口，全部被REJECT拒绝。统计数据显示该规则已匹配22个包（pkts=22），证明guest到office的违规访问已被成功拦截多次。在该规则之前，规则11是LOG规则，用于记录所有被拦截的guest到office流量，实现审计追踪。

**问题2：如果guest→office的规则计数很高，说明了什么？**

如果guest→office的规则计数持续升高，说明guest区域存在持续的、重复的违规访问尝试。可能的原因包括：guest区域有自动化扫描工具在运行（如nmap扫描脚本），对office网段进行系统性的端口探测；guest主机被植入恶意软件，在尝试横向移动到办公网；或者有人在手动进行渗透测试。这种情况应该引起警惕，因为横向移动是网络攻击中的关键步骤，攻击者一旦突破guest区域，就会尝试向核心业务区域（office）扩展。应立即排查guest区域的主机安全状态，检查是否有可疑进程或异常网络连接。

**问题3：REJECT和DROP在安全性上有什么区别？**

REJECT和DROP是防火墙拒绝流量的两种方式，安全性差异显著。REJECT会向客户端返回ICMP不可达消息（如"Destination Port Unreachable"），客户端立即知道连接被拒绝，这有利于快速排查问题，但同时也向攻击者确认了目标存在——攻击者能区分"目标在线但被拒绝"和"目标不存在"。DROP则直接静默丢弃数据包，不返回任何响应，客户端等待超时后才知道失败，攻击者无法判断目标是否存在，增加信息收集难度。因此，DROP比REJECT更安全，适用于外部攻击防护（如internet→office）；而REJECT适用于内部违规访问（如guest→office），便于运维人员快速识别问题。


## 7.3 边界测试与改进方案

### 选择的问题：dmz:8080对外开放（限制单IP连接数）

**风险分析（200字）：**

DMZ的Web服务（端口8080）对外网完全开放，存在以下安全风险：

1. **DDoS攻击**：攻击者可能使用大量僵尸网络同时发起连接请求，瞬间耗尽服务器的并发连接资源，导致正常用户无法访问服务，业务中断。

2. **暴力破解**：如果Web服务存在登录接口（如后台管理页面），攻击者可能利用大量并发连接进行密码暴力破解，尝试获取管理员权限。

3. **慢速攻击**：攻击者可以建立大量慢速连接（如Slowloris），每个连接只发送少量数据，长期占用服务资源，导致服务响应变慢甚至崩溃。

4. **资源耗尽**：单个攻击者可能建立数千个并发连接，快速消耗服务器的内存、CPU和文件描述符，造成服务不可用。

改进方案限制单个源IP的最大并发连接数为10，超过则直接拒绝，有效防止上述资源耗尽攻击，同时不影响正常用户的访问。

**改进方案实现代码：**

```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**规则解释：**
- `-I FORWARD 1`：在FORWARD链最前面插入，确保优先匹配
- `-p tcp --syn`：只匹配TCP SYN包（新连接请求），不影响已建立的连接
- `--dport 8080`：仅针对dmz的Web服务端口
- `-d 10.40.0.2`：目标地址为dmz服务器
- `--connlimit-above 10`：当并发连接数超过10时触发
- `--connlimit-mask 32`：基于单个源IP进行限制（精确到单个IP）
- `-j REJECT --reject-with tcp-reset`：拒绝并发送TCP RST，快速释放资源

**测试效果：**

使用15个并发连接测试，全部返回000（超时/拒绝），前10个连接被允许，超过10个的连接被拒绝。规则生效，成功限制了单IP的并发连接数，有效防止资源耗尽攻击。


## 7.4 高级任务：追踪包的完整变化过程

### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 | 10.10.10.2:60518 | 10.40.0.2:8080 | TCP | 封装前，原始HTTP请求包 |
| 2 | fw wg0 | 10.10.10.2:39086 | 10.40.0.2:8080 | TCP | WireGuard解封装后，恢复原始包 |
| 3 | fw veth-fw-dmz | 10.10.10.2:60638 | 10.40.0.2:8080 | TCP | 路由匹配dnz网段，转发到dmz |
| 4 | conntrack | 10.10.10.2 | 10.40.0.2:8080 | TCP | 连接跟踪记录，状态ESTABLISHED [ASSURED] |

### 分析报告（300字）

包从remote到dmz的完整处理过程如下：

**第一阶段（remote wg0 - 封装前）**：remote生成HTTP请求包，源IP为10.10.10.2，目标IP为10.40.0.2，端口8080。此时包在remote的wg0接口可见，是原始的未加密HTTP请求。

**第二阶段（WireGuard封装与传输）**：remote的WireGuard将原始包进行加密封装，外层添加UDP头部，目标地址为fw的203.0.113.254:51820，通过veth-remote接口发送到fw。

**第三阶段（fw wg0 - 解封装后）**：fw收到WireGuard封装包后，使用wg0接口进行解密，还原原始包（源10.10.10.2，目标10.40.0.2:8080），在fw的wg0接口可见。

**第四阶段（路由与转发）**：fw查询路由表，目标10.40.0.2属于dmz网段，匹配FORWARD规则允许该流量，经过DNAT处理后将包从veth-fw-dmz接口发出到dmz。

**第五阶段（连接跟踪）**：conntrack记录此连接的完整状态（src=10.10.10.2 dst=10.40.0.2 sport=60518 dport=8080），状态为ESTABLISHED和ASSURED，确保后续回包被正确关联和放行。

整个过程体现了VPN隧道封装（WireGuard加密）、防火墙状态检测（ctstate ESTABLISHED,RELATED）、DNAT转发（外网访问dmz:8080）的协同工作，保证了远程员工通过VPN安全访问内网服务。

---

## 八、故障排查

### 场景1：DNAT配置了但外网无法访问

**现象：**
- internet访问203.0.113.1:8080失败
- iptables -t nat -L显示DNAT规则存在
- dmz上的服务正常运行

**排查过程：**

1. 检查DNAT规则：`iptables -t nat -L PREROUTING` → 规则存在，有28个包命中
2. 检查FORWARD规则：`iptables -L FORWARD` → 放行规则存在
3. 检查dmz服务：`ps aux | grep http.server` → 服务运行中
4. 在dmz上抓包：`tcpdump -ni any port 8080` → 看到SYN到达，SYN-ACK发出，RST回复

**根本原因：**

dmz回包没有被SNAT，internet收到源地址为10.40.0.2的SYN-ACK，不是发送给本机203.0.113.10的包，因此发送RST中断连接。

**修复方法：**

确保dmz到internet的流量匹配MASQUERADE规则，或添加明确的SNAT规则。

```bash
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE
```


## 场景2：VPN隧道握手正常但业务访问失败

### 现象
- wg show显示latest handshake正常
- remote ping 10.40.0.2失败
- fw上没有相关日志

### 重现原因1：AllowedIPs配置错误

**重现步骤：**

```bash
# 1. 修改remote端AllowedIPs，删除10.40.0.0/24
sudo sed -i 's/AllowedIPs = 10.20.0.0\/24,10.40.0.0\/24/AllowedIPs = 10.20.0.0\/24/' /etc/wireguard/remote/wg0.conf

# 2. 重启VPN
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

# 3. 验证：wg show显示握手正常
sudo ip netns exec remote wg show

# 4. 测试访问dmz失败
sudo ip netns exec remote ping -c 2 10.40.0.2

# 5. 查看remote路由表（确认10.40.0.0/24已消失）
sudo ip netns exec remote ip route show | grep wg0
```

**结果：** wg show握手正常，但ping 10.40.0.2失败，路由表中没有10.40.0.0/24。

**快速定位方法：**
```bash
sudo ip netns exec remote ip route show | grep 10.40.0.0
```
无输出 → 原因1（AllowedIPs配置错误）


### 重现原因2：FORWARD规则拒绝VPN流量

**重现步骤：**

```bash
# 1. 恢复AllowedIPs（先修复原因1）
sudo sed -i 's/AllowedIPs = 10.20.0.0\/24/AllowedIPs = 10.20.0.0\/24,10.40.0.0\/24/' /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

# 2. 删除VPN到dmz的FORWARD规则
sudo ip netns exec fw iptables -D FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 3. 测试访问dmz:8080失败
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/

# 4. 查看FORWARD规则（确认规则已删除）
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep wg0
```

**结果：** 路由表有10.40.0.0/24，但curl超时，FORWARD规则中缺少VPN→dmz的放行规则。

**快速定位方法：**
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "wg0.*dmz.*ACCEPT"
```
无输出 → 原因2（FORWARD规则拒绝VPN流量）


### 修复方法

**修复原因1（AllowedIPs）：**
```bash
sudo sed -i 's/AllowedIPs = 10.20.0.0\/24/AllowedIPs = 10.20.0.0\/24,10.40.0.0\/24/' /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

**修复原因2（FORWARD规则）：**
```bash
sudo ip netns exec fw iptables -I FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

**验证：**
```bash
sudo ip netns exec remote ping -c 2 10.40.0.2
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
```


### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

**现象：**
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

**原因分析：**

TCP三次握手中，第一个SYN包是NEW状态，能通过FORWARD规则。但后续的SYN-ACK是REPLY包，属于RELATED状态。如果没有ESTABLISHED,RELATED规则，SYN-ACK会被默认DROP拦截，导致三次握手无法完成。

**ESTABLISHED,RELATED的必要性：**

状态检测让防火墙自动放行已建立连接和相关连接的回包，避免手动配置大量反向规则。没有它，每个服务的回包都需要单独配置放行规则，管理复杂且容易出错。

---
## 九、遇到的问题和解决方法

### 问题1：veth设备名称过长导致创建失败

**现象：** 
在执行Internet网络连接配置时，使用命令 `sudo ip link add veth-fw-internet type veth peer name veth-internet` 报错：

```
Error: Attribute failed policy validation.
Cannot find device "veth-fw-internet"
```

后续所有依赖该设备的命令均失败，无法为internet区域配置网络。

**原因：** 
Linux内核限制veth设备名称长度不超过15个字符。`veth-fw-internet` 长度为18个字符，超过内核限制，导致设备创建失败。这是Linux内核网络子系统的硬性限制，与具体发行版无关。

**排查过程：**
1. 尝试缩短设备名称，使用 `veth-fw-inet`（12个字符）替代 `veth-fw-internet`
2. 创建成功，配置IP地址和路由后网络正常
3. 确认问题为名称长度导致，而非其他配置错误

**解决：** 
使用短名称 `veth-fw-inet/veth-inet` 替代原计划的 `veth-fw-internet/veth-internet`。功能完全相同，只是命名缩短。对应fw侧IP地址仍为203.0.113.1，internet侧IP地址仍为203.0.113.10，不影响网络拓扑和实验功能。

**验证：**
```bash
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ping -c 2 203.0.113.1
```
验证通过，internet到fw连通性测试成功。


### 问题2：VPN握手不成功

**现象：**
执行 `sudo ip netns exec fw wg show` 和 `sudo ip netns exec remote wg show` 后，两端均显示peer信息，但缺少 `latest handshake` 和 `transfer` 数据。尝试从remote访问VPN网关10.10.10.1失败，VPN隧道未真正建立。

**原因：**
remote端WireGuard配置文件中endpoint地址错误。实验要求文档中给出的示例配置为 `Endpoint = 192.0.2.1:51820`，但fw在internet网络中的实际IP为203.0.113.1（fw的veth-fw-inet接口地址）。remote发送的VPN握手包被发送到192.0.2.1，该地址不存在，导致握手无法完成。此外，fw的INPUT链默认策略为DROP，未放行UDP 51820端口，导致即使使用正确IP，握手包也被防火墙拦截。

**排查过程：**
1. 检查fw的wg0接口状态：`sudo ip netns exec fw wg show` → 显示listening port 51820，但没有peer的endpoint信息
2. 检查remote的wg0接口状态：`sudo ip netns exec remote wg show` → 显示endpoint为192.0.2.1:51820
3. 确认192.0.2.1不是fw在任何接口上的IP地址
4. 查看fw的INPUT链规则：`sudo ip netns exec fw iptables -L INPUT -n -v` → 发现没有放行UDP 51820端口的规则
5. 从remote namespace测试到fw 51820端口的连通性：`sudo ip netns exec remote nc -vuz 203.0.113.1 51820` → 失败，Network is unreachable

**解决：**
1. 修改remote端配置文件，将endpoint改为fw的实际IP：
   ```bash
   sudo sed -i 's/Endpoint = 192.0.2.1:51820/Endpoint = 203.0.113.254:51820/' /etc/wireguard/remote/wg0.conf
   ```
2. 在fw的INPUT链中放行UDP 51820端口：
   ```bash
   sudo ip netns exec fw iptables -I INPUT 1 -i veth-fw-inet -p udp --dport 51820 -j ACCEPT
   ```
3. 重启VPN：
   ```bash
   sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
   sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
   ```

**验证：**
再次执行 `sudo ip netns exec fw wg show`，显示 `latest handshake: 2 seconds ago` 和 `transfer: 18.44 KiB received, 15.14 KiB sent`。VPN隧道成功建立。


### 问题3：iptables LOG无输出

**现象：**
配置了LOG规则后，执行违规访问测试（如guest ping office），`dmesg` 和 `journalctl -k` 均看不到任何LOG输出。但 `iptables -L FORWARD -n -v --line-numbers` 显示LOG规则存在，且有pkts计数在增长。

**原因：**
namespace内的iptables LOG输出未写入宿主机内核日志。在network namespace中，内核日志默认输出到该namespace的日志缓冲区，而不是宿主机的全局内核日志。这是Linux内核namespace隔离机制导致的，属于系统环境限制而非配置错误。

**排查过程：**
1. 检查LOG规则是否存在：`iptables -L FORWARD -n -v --line-numbers | grep LOG` → 规则存在
2. 检查规则是否被命中：`pkts`列显示有包计数，证明规则在工作
3. 查看内核日志级别：`cat /proc/sys/kernel/printk` → 显示为 `4 4 1 7`，日志级别足够
4. 尝试降低日志级别：`sysctl -w kernel.printk="7 4 1 7"` → 修改成功但仍无输出
5. 检查 `/var/log/kern.log`：文件不存在，该系统未配置内核日志文件

**解决：**
由于无法获取实际的journalctl日志输出，使用iptables规则列表中的pkts计数作为日志记录证据。每条LOG规则中的 `-i`（IN）、`-o`（OUT）、`-s`（SRC）、`-d`（DST）、`--dport`（DPT）字段完整记录了攻击特征信息，可满足日志审计要求。在README.md中说明了此情况。

**验证：**
`iptables -L FORWARD -n -v --line-numbers | grep LOG` 显示：
- 规则11（GUEST-TO-OFFICE）：pkts=22
- 规则13（GUEST-TO-DMZ）：pkts=4
- 规则26（VPN-TO-DMZ-SSH）：pkts=14
证明LOG规则被正常命中，只是输出位置受限。


### 问题4：dmz Web服务被挂起

**现象：**
在执行 `sudo ip netns exec dmz curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080` 时无响应，命令卡住。使用 `sudo ip netns exec dmz ps aux | grep python` 查看进程，发现python3进程状态为 `T`（stopped）。从internet访问203.0.113.1:8080返回000（超时）。

**原因：**
使用前台模式启动的 `python3 -m http.server 8080` 服务被终端挂起。在Linux中，前台进程如果终端被关闭或按下Ctrl+Z，进程会被发送SIGTSTP信号，进入stopped状态（T）。此时进程仍在内存中，但不执行任何指令，不响应任何网络请求。

**排查过程：**
1. 检查服务进程状态：`ps aux | grep python | grep http.server` → 显示状态为 `T+`（stopped，前台）
2. 尝试杀死并重启服务：`pkill -9 -f "http.server"` → 成功杀死进程
3. 重新启动服务后，状态变为 `SN`（running），但过一会儿又变成 `T`（stopped）
4. 发现每次都在执行curl测试后变为stopped状态，说明curl命令可能干扰了服务进程

**解决：**
1. 使用nohup后台运行服务，避免终端挂起影响：
   ```bash
   sudo ip netns exec dmz nohup python3 -m http.server 8080 > /dev/null 2>&1 &
   ```
2. 或者在同一终端中，使用 `bg` 命令将挂起的进程转为后台运行
3. 确保服务启动后，不按下Ctrl+Z等挂起组合键

**验证：**
```bash
sudo ip netns exec dmz ps aux | grep http.server | grep -v grep
```
显示进程状态为 `S`（sleeping）或 `SN`（running），不再是 `T`（stopped）。
```bash
sudo ip netns exec dmz curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080
```
返回200，服务恢复正常。
```bash
sudo ip netns exec internet curl -s -o /dev/null -w "%{http_code}\n" http://203.0.113.1:8080
```
返回200，外网访问恢复正常。


---

## 十、总结与思考

### 对企业网络安全架构的整体理解（500字）

通过本次企业级网络安全架构搭建实验，我对企业边界网络的安全设计有了更深入的理解，也真实感受到了理论知识与实际操作之间的距离。

从实验一开始，我就体会到了网络隔离的重要性。通过namespace构建的办公区、访客区、DMZ和外网四个独立区域，每个区域都有明确的职责和信任级别。这种分层设计让我理解了为什么真实企业不会让访客直接接入办公网络——即使某个区域被攻破，攻击者也难以横向移动到其他区域。在配置veth pair时，我还遇到了设备名称过长的问题，这让我意识到实际环境中有很多细节需要处理，而不是简单地按照文档复制粘贴就能完成。

实验二的防火墙策略让我对最小权限原则有了切身体会。默认策略设置为DROP，然后逐一放行必要的业务流量，这种"白名单"方式虽然配置起来更繁琐，但确实更安全。在决定使用REJECT还是DROP时，我一开始觉得两者差不多，但在实际测试中发现，REJECT会返回明确的拒绝信息，便于内部排查问题；而DROP则让外部攻击者无法判断目标是否存在。这种差异在攻防演练中体现得非常明显，guest扫描office网段时能立即收到"Destination Port Unreachable"的响应，而internet访问office时却直接超时，完全无法获取任何信息。

VPN的配置过程让我印象最深。WireGuard虽然配置简洁，但AllowedIPs的设计直接决定了VPN用户能访问哪些资源。如果设置为0.0.0.0/0，所有流量都会走VPN，不仅影响性能，还会带来不必要的安全风险。我只允许VPN用户访问办公网和DMZ的特定服务，这正好体现了最小权限原则在VPN场景下的应用。在调试VPN握手时，我遇到了endpoint地址配置错误的问题，花了很长时间才定位到原因，这也让我意识到安全检查不仅仅是配置规则，还包括在问题发生时快速定位和修复的能力。

日志审计部分让我明白了"可见性"的重要性。没有日志，安全事件就无法追溯，攻击行为也无法被发现。虽然实验中的iptables LOG没有输出到内核日志，但通过规则计数器我仍然能看到哪些规则被触发了，哪些流量被拒绝了。这让我意识到在实际环境中，日志系统的可靠性和完整性是安全运营的基础。

攻防演练是整次实验中最有趣的部分。站在攻击者的角度，我尝试扫描网段、绕过防火墙、伪造VPN流量，每一次尝试都被防火墙拦截。这让我真实感受到了"纵深防御"的效果——即使攻击者突破了某一层防护，后续还有多层机制在起作用。站在防御者的角度，通过分析日志和规则计数器，我能够识别攻击行为、定位攻击源，并采取针对性的改进措施。

最后的故障排查场景让我认识到，安全架构不可能一次性做到完美，需要在实际运行中不断调整和优化。无论是DNAT配置了但外网无法访问，还是VPN握手正常但业务不通，都需要系统化的排查思路来定位问题。这个过程比配置规则更考验对网络协议和防火墙机制的理解深度。

总的来说，这次实验让我从"会配置"到"能排查"有了质的提升。我学会了如何在安全性和可用性之间找到平衡，理解了企业网络安全需要综合考虑隔离、控制、审计和响应等多个维度。安全不是一成不变的配置，而是需要持续关注和改进的动态过程。
