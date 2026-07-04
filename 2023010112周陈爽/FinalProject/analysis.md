# 攻防演练分析报告

## 一、攻击方分析

### 攻击1：Ping扫描office网段

**攻击命令：**
```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```
结果如截图所示：
![](screenshots/11-attack-scan.png)
**攻击结果：** 所有ping请求均超时，未探测到任何存活主机。

**失败原因分析：**
防火墙FORWARD链的默认策略为DROP，guest网段访问office网段未配置任何ACCEPT规则。因此从guest发出的ICMP数据包进入防火墙后，遍历FORWARD链所有规则均未匹配ACCEPT，被默认DROP策略静默丢弃。攻击者无法收到任何ICMP echo reply响应，扫描彻底失败。

**防御机制分析：**
- 根本防御策略：**区域隔离**。guest网段与office网段之间无任何业务通信需求，防火墙通过配置拒绝规则（LOG+REJECT）实现完全隔离。
- 关键设计点：规则仅限定了入接口（`-i veth-fw-guest`）和出接口（`-o veth-fw-office`），无论攻击者使用ICMP、TCP还是UDP协议，所有从guest到office的流量均被匹配拦截。
- 局限性：当前使用REJECT策略会向攻击者返回ICMP端口不可达报文（`icmp-port-unreachable`），暴露了防火墙的存在。如果改为DROP策略，攻击者的ping命令会长时间等待超时，无法区分"目标不存在"和"防火墙拦截"，安全性更高（但排查难度增加）。

---

### 攻击2：修改源端口绕过防火墙

**攻击命令：**
```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```
结果如截图所示：
![](screenshots/12-attack-bypass.png)
**攻击结果：** 所有请求均被拒绝，无论源端口如何变化，均无法绕过防火墙。

**失败原因分析：**
防火墙的ACL规则基于**五元组**（源IP、目的IP、源端口、目的端口、协议）进行匹配，但本次规则设计中拦截策略的匹配依据是**入网卡（in interface）、出网卡（out interface）、源网段、目的网段和目的端口**，**不包含源端口**。即使攻击者将源端口修改为80（HTTP）或443（HTTPS），数据包仍从guest网卡（`veth-fw-guest`）流入、目标为dmz的22端口，匹配GUEST-DENY-DMZ拒绝规则，直接被拦截。

**防御机制分析：**
- iptables规则中的源端口匹配需要显式使用`--sport`参数。本实验中所有拒绝规则均未指定源端口，因此无论攻击者使用哪个源端口发起连接，都会被规则匹配拦截。
- 这种设计体现了**最小匹配原则**：仅使用必要的匹配条件判断流量是否违规，避免因匹配条件过多导致绕过漏洞。

---

### 攻击3：伪造VPN源IP地址

**攻击命令：**
```bash
sudo ip netns exec guest iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -j SNAT --to-source 10.10.10.2
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/
```
结果如截图所示：
![](screenshots/12-attack-bypass.png)
**攻击结果：** 攻击失败，数据包被防火墙拦截。

**失败原因分析：**
防火墙在匹配FORWARD规则时，不仅检查数据包的源IP地址，还会校验数据包的**入网卡（in interface）**。VPN流量的合法入网卡为`wg0`，但本次伪造流量是从`veth-fw-guest`网卡流入的。即使源IP被SNAT修改为VPN地址`10.10.10.2`，防火墙仍然可以判定该流量来自guest网段而非VPN网卡，因此不会匹配VPN流量的ACCEPT规则（该规则限定`-i wg0`），最终被默认DROP策略丢弃。

**防御机制分析：**
- 核心防御策略：**入网卡绑定**。VPN合法流量的FORWARD规则严格限定入接口为`wg0`，攻击者无法通过修改源IP来欺骗防火墙。
- 安全隐患：如果防火墙规则未限制入接口（例如使用`-s 10.10.10.2`而不限定`-i wg0`），本攻击就有可能成功。本实验的规则设计避免了此漏洞。
- 深层思考：iptables的入网卡校验发生在路由决策之后、FORWARD链检查之前。即使攻击者使用SNAT修改了源IP，路由层仍然会记录数据包的原始入网卡信息，这是无法伪造的。

---

### 问题回答：REJECT与DROP的区别

**问：攻击者能否从REJECT和DROP的不同表现判断目标是否存在？**

**答：可以。**

REJECT策略会向攻击者返回ICMP端口不可达（`icmp-port-unreachable`）或TCP重置（`tcp-reset`）报文。攻击者能立即收到返回的拒绝报文，从而做出以下判断：
- 目标IP地址是真实存在的（否则数据包会在路由层丢失，不会有任何响应）
- 目标端口受到防火墙策略限制（而不是服务未运行）
- 可以推断出防火墙的存在和类型（基于返回报文特征）

DROP策略则静默丢弃数据包，不返回任何响应。攻击者只能观测到：
- 连接超时（TCP SYN重传直到超时）
- 无法区分"目标不存在"、"路由不可达"、"防火墙拦截"三种情况
- 无法判断目标IP是否存活，内网拓扑被有效隐藏

**安全建议：** 在外网边界推荐使用DROP策略，隐藏内网资产信息，增加攻击者信息收集难度；在内网环境中可使用REJECT策略，便于运维人员快速定位故障。

---

## 二、防御方分析

### 2.1 从日志中识别攻击

**防御命令：**
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "LOG|REJECT"
sudo ip netns exec fw tcpdump -ni any "icmp[icmptype] == 3" -c 10
```
如截图所示：
![](screenshots/13-defense-logs.png)

**日志分析要点：**

**Q1: 从日志的哪些字段可以判断这是来自guest的攻击？**

通过三类核心字段可以溯源攻击来源：

1. **log-prefix前缀字段**：自定义的日志前缀`GUEST-DENY-OFFICE`、`GUEST-DENY-DMZ`专门标记guest网段产生的违规流量，通过`grep "GUEST-"`可快速筛选。
2. **入网卡字段IN**：`IN=veth-fw-guest`表明数据包从guest专属网卡流入，该网卡只有guest网段的主机能到达，流量来源可精准定位到guest命名空间。
3. **源IP字段SRC**：源地址属于`10.30.0.0/24`网段，进一步确认攻击者来自guest区域。

此外，`tcpdump`抓包中出现大量ICMP端口不可达（Type 3）报文，说明防火墙正在对违规流量执行REJECT操作，这是网段扫描攻击的典型特征。

**Q2: 如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？**

这说明数据包从guest网卡流入防火墙，试图通过office网卡转发至办公内网，属于**跨安全域非法越界访问**。这种流量模式表明：
- guest网段存在恶意攻击者，正在主动探测办公内网
- 攻击目标是office网段的主机和端口
- 流量未匹配任何放行规则，命中GUEST-DENY-OFFICE审计规则后被REJECT拦截
- 一旦扫描成功，攻击者可能实施漏洞入侵、横向渗透，威胁办公业务数据安全

**Q3: 为什么看到大量相同来源的日志应该引起警惕？**

同一IP或网段产生海量重复拦截日志表明该地址正在持续发起高频探测，大概率属于：
- **端口扫描**：遍历目标网段的TCP/UDP端口，发现开放服务
- **暴力破解**：对SSH、RDP等管理端口进行密码猜测
- **DDoS攻击**：大量无效连接耗尽服务器资源

大量重复日志的副作用：
- 日志洪水攻击：高频产生的审计日志会大量占用磁盘I/O和CPU资源
- 超出限速阈值：预设的`5/min burst 10`限速被突破后，后续日志不再记录，审计功能失效
- 安全事件无法追溯：重要攻击行为因日志丢失而无法分析取证

**应对措施：** 运维人员应第一时间封禁攻击源IP，加固网段访问权限，增加更严格的连接频率限制（如connlimit + recent模块）。

---

### 2.2 分析规则的防御效果

```bash
# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
如截图所示：
![](screenshots/14-defense-counters.png)

**Q1: 哪条规则拦截了guest访问office？**

FORWARD链第7-8行负责拦截：
- **第7行（LOG）**：`LOG all -- veth-fw-guest veth-fw-office 0.0.0.0/0 0.0.0.0/0 LOG prefix "GUEST-DENY-OFFICE:"`
- **第8行（REJECT）**：`REJECT all -- veth-fw-guest veth-fw-office 0.0.0.0/0 0.0.0.0/0 reject-with icmp-port-unreachable`

数据包匹配流程：guest→office的流量进入FORWARD链，前面1-6行未匹配（不满足接口/IP条件），第7行匹配并记录日志，第8行匹配并返回ICMP端口不可达。

**Q2: 如果guest→office的规则计数很高，说明了什么？**

规则计数值反映了该规则的命中次数。如果guest→office相关的REJECT规则计数值偏高（例如数千至数万），说明：

1. **攻击强度大**：guest网段正在遭受或发起大规模内网扫描攻击，攻击者使用批量ping、端口遍历等方式探测office网段资产。
2. **隔离策略有效**：高拦截计数证明当前网段隔离规则正常工作，成功阻止了越界访问尝试。
3. **需要进一步加固**：虽然策略有效抵御了攻击，但仍需：
   - 定位并封禁高频访问的源IP
   - 细化网段间最小访问权限，必要时配置白名单
   - 新增连接数限流规则（connlimit），防止持续扫描引发资源耗尽

**Q3: REJECT和DROP在安全性上有什么区别？**

| 特性 | REJECT | DROP |
|:-----|:-------|:-----|
| 返回响应 | 返回ICMP端口不可达/TCP RST | 无任何响应 |
| 攻击者感知 | 立即拒绝，可判断目标存活 | 连接超时，无法判断目标状态 |
| 信息泄露 | 暴露防火墙存在和类型 | 隐藏内网拓扑 |
| 排错便利性 | 高，客户端能快速确认拦截 | 低，客户端长时间等待超时 |
| 适用场景 | 内网环境（方便运维排查） | 外网边界（隐藏资产） |
| 资源消耗 | 稍高（需生成响应报文） | 较低（仅丢弃数据包） |

**结论：** REJECT和DROP各有适用场景。本实验作为教学实验选择REJECT，目的是让测试结果反馈更加直观清晰（客户端立即报错而非长时间等待超时）。生产环境的外网边界应使用DROP策略来隐藏内网资产信息。

---

## 三、边界测试与改进方案分析

### 3.1 风险发现

实验中发现DMZ区域的8080端口通过DNAT对外开放，存在以下安全风险：
- **DDoS攻击**：攻击者可利用多线程脚本快速建立大量TCP连接，耗尽服务器端口资源
- **CC攻击**：大量HTTP请求消耗Web服务CPU/内存资源
- **Web漏洞利用**：暴露的服务可能被扫描器探测到SQL注入、文件上传等漏洞
- **资源耗尽**：防火墙的连接跟踪表（conntrack）可能被填满，导致合法连接被丢弃

### 3.2 改进方案实现

使用connlimit模块限制单IP对dmz:8080的最大并发连接数为10：

```bash
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**参数说明：**
- `-p tcp --syn`：仅匹配TCP握手包，避免同一连接的后续数据包重复计数
- `--connlimit-above 10`：单IP超过10个并发连接时拒绝
- `--connlimit-mask 32`：按单个IP计算（/32），若改为/24则按C类网段统计
- `--reject-with tcp-reset`：返回TCP RST报文，客户端立即断开连接

### 3.3 测试结果分析

用15个并发curl请求测试，结果分为两类：
- **前10个连接**：成功返回DMZ的HTML目录列表，说明未超过阈值的正常请求不受影响
- **后5个连接**：立即返回连接失败，被connlimit规则直接REJECT

iptables规则计数器验证第2行connlimit规则累计拦截5个包，与预期一致。

**改进效果评估：**
- 单IP连接数从无限制降为10个，有效抑制了DDoS/CC攻击
- connlimit规则放在第2行（紧随ESTABLISHED,RELATED之后），确保在业务放行规则之前进行限流
- 返回TCP RST而非静默DROP，客户端能快速释放连接资源，减少服务器负担

**改进效果截图：**
![](screenshots/15-improvement.png)

---

## 四、包追踪分析

### 4.1 抓包位置与观察结果

| 位置 | 观察内容 | 关键发现 |
|:-----|:---------|:---------|
| remote wg0 | 封装前原始TCP包 | 源10.10.10.2 → 目标10.40.0.2:8080，内网地址 |
| remote veth-remote | 加密后的UDP包 | 外层10.0.0.2→10.0.0.1:51820，包大小约148B |
| fw wg0 | 解密后TCP包 | 还原为原始内网报文，源地址保持不变 |
| fw veth-fw-dmz | FORWARD放行后 | 包成功转发到dmz服务器 |
| conntrack | 连接跟踪记录 | 显示[ASSURED]状态的双向五元组 |

**抓包结果：**
remote抓包截图：
![](screenshots/16-tcpdump-remote.png)
fw抓包截图：
![](screenshots/17-tcpdump-fw.png)
conntrack抓包截图：
![](screenshots/18-conntrack.png)

### 4.2 包大小变化分析
```
原始TCP包（60B） → WireGuard加密（+88B开销） → UDP包（148B）
```

WireGuard加密引入了约88B的额外开销，包括：
- 20B IP头部
- 8B UDP头部
- ~32B WireGuard消息头部
- ~28B 认证标签（Poly1305 MAC）

### 4.3 数据流全景

整个数据流展示了VPN远程访问的完整安全路径：

1. **应用层**：remote主机的curl生成HTTP请求，TCP封装为SYN包
2. **加密传输**：WireGuard在wg0接口拦截内网流量，加密后封装为UDP，通过veth-remote物理网卡发送
3. **解密还原**：防火墙wg0接口接收UDP包，完成解密认证，还原原始TCP报文
4. **路由转发**：查询路由表确定目标为dmz网段，走veth-fw-dmz接口
5. **安全策略**：提交FORWARD链检查，第20行ACCEPT规则匹配（`-i wg0 -o veth-fw-dmz`）
6. **连接跟踪**：conntrack记录TCP五元组，回包通过ESTABLISHED规则直接放行

三个安全环节协同工作：**加密隧道确保传输安全 → 防火墙策略控制访问权限 → 连接跟踪优化回包效率**。

---

## 五、总体安全评估

### 5.1 防御纵深

本实验构建了多层防御体系：

| 防御层 | 实现方式 | 防御效果 |
|:-------|:---------|:---------|
| 网络隔离层 | 6个独立网络命名空间 | 区域间物理隔离，攻击者无法直接访问 |
| 路由控制层 | 默认路由指向防火墙 | 所有跨网段流量必须经过防火墙 |
| 防火墙策略层 | FORWARD链 DROP + 精细化ACL | 只放行合规流量，拦截违规访问 |
| VPN认证层 | WireGuard公钥加密 | 只有持有私钥的授权用户可以接入 |
| 审计告警层 | LOG规则 + log-prefix | 所有违规行为留下审计记录 |
| 连接限流层 | connlimit模块 | 限制单IP并发连接数（改进方案） |

### 5.2 存在的不足

1. **REJECT策略泄露信息**：内网使用REJECT会向攻击者暴露防火墙存在，生产环境外网边界应全部使用DROP
2. **无入侵检测系统**：当前仅依靠日志审计被动防御，缺少IDS/IPS实时告警机制
3. **单点故障风险**：所有区域流量集中经过fw防火墙，没有高可用冗余方案
4. **VPN无多因子认证**：WireGuard仅依赖私钥认证，缺少用户级身份验证

### 5.3 进一步改进方向

- 在外部边界使用DROP策略并增加recent模块限制单IP连接频率
- 配置fail2ban自动封禁高频扫描IP
- 增加应用层WAF防御Web攻击
- 部署流量镜像到IDS系统进行深度包检测
- 实现防火墙主备高可用方案
