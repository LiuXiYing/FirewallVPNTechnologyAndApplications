# 攻防演练分析报告

## 一、攻击方视角分析

### 攻击1：guest扫描office网段

**攻击手法**：从guest namespace对10.20.0.0/24网段进行ping扫描，尝试发现office区域存活主机。

**攻击结果**：所有ping请求均被防火墙REJECT，guest收到"Destination Port Unreachable"或"Administratively prohibited"的ICMP响应。

**失败原因分析**：防火墙配置了`-i veth-fw-guest -o veth-fw-office -j REJECT`规则，任何从guest接口进入、目的地为office的数据包都会被直接拒绝。攻击者收到的ICMP错误消息由防火墙生成，而非目标主机，因此无法区分哪些IP有主机存活、哪些没有。防火墙在边界统一拦截，实现了有效的网络隔离。

**REJECT与DROP的差异分析**：攻击者可以从REJECT和DROP的不同表现判断目标是否存在吗？从REJECT来看，防火墙对所有被拦截的请求都返回相同的ICMP响应，无论目标IP是否有主机，响应时间几乎一致，攻击者无法区分。但DROP会静默丢弃，攻击者需要等待超时，这反而暴露了"这里有一个防火墙在过滤"的信息（超时说明有设备但不响应）。因此，REJECT在本次实验中不仅方便测试，安全性也不比DROP差。

### 攻击2：尝试绕过防火墙访问dmz:22

**攻击手法**：使用不同的源端口（80、443、8080）尝试从guest访问dmz:22，试图绕过防火墙规则。

**攻击结果**：所有尝试均被拒绝，防火墙不关心源端口。

**失败原因分析**：防火墙的guest→dmz隔离规则匹配的是入口接口（`-i veth-fw-guest`）和出口接口（`-o veth-fw-dmz`），与源端口无关。无论攻击者使用什么源端口，只要数据包从guest接口进入、目标地址属于dmz区域，就会匹配拒绝规则。改变源端口无法绕过基于接口方向和目的地址的访问控制策略。这是正确的防火墙设计——基于网络拓扑的访问控制，而非基于端口特征。

### 攻击3：思考伪造VPN流量

**问题**：攻击者能否伪造源地址为10.10.10.2的包来访问内网？

**结论**：不能。

**详细分析**：
1. **接口匹配机制**：VPN访问控制规则使用`-i wg0`匹配从WireGuard隧道接口进入的流量。伪造的IP包不会从wg0接口进入fw，因此不会匹配VPN放行规则。
2. **WireGuard加密认证**：WireGuard使用Curve25519进行密钥交换和身份认证，数据包经过加密和MAC验证。没有合法私钥的攻击者无法构造被fw接受的WireGuard数据包。
3. **路由可达性**：即使攻击者伪造源地址发送了SYN包，服务器的SYN-ACK回包会路由到VPN隧道地址10.10.10.2，而不是攻击者的真实地址，攻击者收不到响应。
4. **状态检测保护**：防火墙的状态检测规则（ESTABLISHED,RELATED）确保只有合法建立的连接才能收到返回流量。

## 二、防御方视角分析

### 从日志识别攻击

**问题1：从日志的哪些字段可以判断这是来自guest的攻击？**

通过以下字段综合判断：
- `IN=veth-fw-guest`：入口接口为guest侧接口，表明数据包来自guest区域
- `SRC=10.30.0.2`：源IP为guest主机的地址
- `OUT=veth-fw-office`：目标接口为office侧，表明攻击目标是办公网
- `log-prefix "GUEST-TO-OFFICE:"`：自定义日志前缀明确标识了事件类型

**问题2：如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？**

这说明有数据包从guest网络进入防火墙，并且试图从office网络接口出去。具体含义：
- guest区域有设备正在尝试访问office区域
- 这可能是一次网络扫描、未授权访问尝试或恶意软件活动
- 需要进一步检查SRC、DST、DPT等字段确定具体行为

**问题3：为什么看到大量相同来源的日志应该引起警惕？**

大量相同来源的日志通常意味着：
- **端口扫描**：攻击者在探测目标主机开放的端口和服务
- **暴力破解**：如SSH密码爆破，每个失败尝试都会触发日志
- **DoS/DDoS攻击**：攻击者试图耗尽目标资源
- **蠕虫传播**：恶意软件自动扫描并尝试感染其他主机
- 高频日志本身也是一种资源消耗（日志洪水），所以需要速率限制

### 规则防御效果分析

**问题1：哪条规则拦截了guest访问office？**

在`iptables -L FORWARD -n -v --line-numbers`输出中，可以看到带有`REJECT`动作、且pkts计数器>0的规则中，入口为`veth-fw-guest`、出口为`veth-fw-office`的那条规则。

**问题2：如果guest→office的规则计数很高，说明了什么？**

说明guest区域存在持续的、大量的对office区域的访问尝试。可能是：
- 访客网络中有设备被恶意软件感染，在自动扫描内网
- 有攻击者连接到了访客WiFi，正在尝试渗透办公网络
- 需要立即调查guest区域的设备，检查日志中的SRC IP定位具体设备

**问题3：REJECT和DROP在安全性上有什么区别？**

| 特性 | REJECT | DROP |
|:-----|:------|:-----|
| 响应方式 | 立即返回ICMP错误/TCP RST | 静默丢弃，无响应 |
| 客户端感知 | 快速知道连接被拒绝 | 等待超时 |
| 信息泄露 | 确认防火墙存在 | 模拟"主机不存在" |
| 扫描速度 | 攻击者扫描更快 | 攻击者扫描极慢 |
| 运维便利 | 方便排查网络问题 | 问题难以定位 |
| 安全建议 | 对内网使用 | 对公网敏感端口使用 |

## 三、边界测试与改进方案

### 选择的问题：dmz:8080对外开放

**风险分析**：

dmz的Web服务（8080端口）通过DNAT对外开放，面临以下安全风险：

1. **DDoS攻击**：攻击者可以发起大量HTTP请求，消耗dmz服务器的CPU、内存和带宽资源，导致合法用户无法访问。特别是SYN flood攻击可以快速耗尽服务器的连接表。

2. **Web应用漏洞利用**：如果Web服务存在SQL注入、XSS跨站脚本、文件包含等漏洞，攻击者可能获取服务器权限、窃取数据或篡改网站内容。

3. **连接耗尽攻击**：攻击者建立大量TCP连接但不发送数据（slowloris攻击），占用服务器连接资源直到达到上限。

4. **信息泄露**：HTTP响应头可能泄露服务器版本、框架信息，帮助攻击者选择针对性攻击手法。

5. **暴力破解**：如果Web服务有登录功能，攻击者可能尝试暴力破解管理员密码。

### 改进方案实现

```bash
# 方案1：限制单IP最大并发连接数为10
sudo ip netns exec fw iptables -I FORWARD 1 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset

# 方案2：限制新连接速率（每秒最多5个新连接）
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m limit --limit 5/sec --limit-burst 10 \
  -j ACCEPT

# 超过速率限制的丢弃
sudo ip netns exec fw iptables -I FORWARD 3 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -j DROP

# 方案3：限制最大并发连接总数
sudo ip netns exec fw iptables -I FORWARD 4 \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 50 --connlimit-mask 24 \
  -j REJECT --reject-with tcp-reset
```

### 测试效果

```bash
# 使用ab（Apache Bench）进行压力测试
sudo ip netns exec internet apt install -y apache2-utils
sudo ip netns exec internet ab -n 100 -c 20 http://203.0.113.1:8080/

# 观察结果：当并发超过10时，部分请求被拒绝
# 查看规则计数器确认限流规则生效
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5
```

## 四、高级任务：包追踪分析

### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 | 10.10.10.2 | 10.40.0.2 | TCP/HTTP | 封装前，原始请求 |
| 2 | fw wg0 | 10.10.10.2 | 10.40.0.2 | TCP/HTTP | 解封装后，fw收到 |
| 3 | fw veth-fw-dmz | 10.10.10.2 | 10.40.0.2 | TCP/HTTP | 转发到dmz |
| 4 | conntrack | 10.10.10.2→10.40.0.2 | - | TCP | 连接跟踪记录 |

### 分析报告

当remote用户通过VPN访问dmz:8080时，数据包经历了以下完整处理过程：

**第1阶段 - VPN封装**：remote上的curl发起HTTP请求，目标地址10.40.0.2:8080。根据remote的路由表（由WireGuard的AllowedIPs配置生成），访问10.40.0.0/24的流量被路由到wg0接口。WireGuard将原始IP包加密并封装在新的UDP包中，源地址为remote的外网地址192.0.2.10，目的地址为fw的internet地址203.0.113.1:51820。

**第2阶段 - VPN解封装**：fw的wg0接口收到加密的WireGuard数据包后，使用remote的公钥验证数据包完整性，使用fw的私钥解密，还原出原始IP包（SRC=10.10.10.2, DST=10.40.0.2:8080）。fw检查AllowedIPs确认10.10.10.2是授权的peer。

**第3阶段 - 防火墙转发**：解封装后的数据包进入fw的FORWARD链。首先匹配ESTABLISHED,RELATED规则（如果已有连接）或VPN放行规则（`-i wg0 -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080`）。通过后，数据包从veth-fw-dmz接口转发到dmz。

**第4阶段 - 连接跟踪**：fw的conntrack模块记录此连接：`tcp 6 ... src=10.10.10.2 dst=10.40.0.2 sport=xxx dport=8080 [ASSURED]`。后续的返回流量（dmz→remote）会自动匹配ESTABLISHED规则放行，并通过WireGuard加密回传。
