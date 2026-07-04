# 攻防演练分析报告

## 一、攻击方任务分析

### 1.1 扫描office网段

**攻击命令：**

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**攻击原理：**
攻击者试图通过ping扫描发现office网段中存活的主机，获取网络拓扑信息，为后续攻击做准备。

**实验结果：**
所有ping请求均被防火墙拦截，未发现任何存活主机。

**失败原因分析：**
防火墙规则明确拒绝guest访问office，并且配置了LOG规则记录此类违规行为。由于FORWARD链默认策略为DROP，且没有任何规则允许guest访问office网段，所有来自guest的ICMP请求包都被静默丢弃或REJECT。攻击者无法获取任何关于office网段的存活主机信息，扫描完全失败。

### 1.2 尝试绕过防火墙访问dmz:22

**攻击命令：**

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**攻击原理：**
攻击者试图通过改变源端口来绕过防火墙规则，假设防火墙规则可能基于源端口进行过滤。

**实验结果：**
所有请求均失败，连接被拒绝。

**失败原因分析：**
防火墙规则基于目的端口进行过滤，与源端口无关。规则`-p tcp --dport 22`只检查目的端口是否为22，不关心源端口。因此，无论攻击者使用何种源端口（80、443或其他），访问dmz:22都会被REJECT规则拦截。同时，LOG规则会记录每一次违规访问尝试。

### 1.3 尝试伪造VPN流量

**攻击原理：**
攻击者试图伪造源地址为10.10.10.2（VPN客户端地址）的数据包，绕过防火墙访问内网资源。

**分析：**
理论上可以伪造IP包的源地址，但WireGuard使用公钥认证机制。即使源IP地址正确，没有对应的私钥也无法通过WireGuard的加密验证。WireGuard会对每个数据包进行加密和认证，只有持有正确私钥的客户端才能生成有效的加密包。此外，WireGuard的AllowedIPs机制会检查数据包的来源是否匹配配置的IP地址范围，进一步防止IP欺骗攻击。

### 1.4 REJECT与DROP的安全区别

**问题：** 攻击者能否从REJECT和DROP的不同表现判断目标是否存在？

**分析：**
- **REJECT**：会返回ICMP不可达消息（如"Connection refused"），攻击者可以据此判断目标主机存在但服务不可达。这泄露了目标主机的存在信息。
- **DROP**：静默丢弃数据包，不返回任何消息。攻击者无法确定目标是否存在，可能是主机不存在、服务未运行、防火墙规则阻止或网络不通。这提供了更高的安全性，但不利于网络诊断。

**建议：** 对于外部边界防火墙，应优先使用DROP；对于内部网络，可以使用REJECT以便于排障。

## 二、防御方任务分析

### 2.1 从日志中识别攻击

**日志分析命令：**

```bash
sudo journalctl -k --since "10 minutes ago" --grep "GUEST-|VPN-|INET-" --no-pager
```

**问题1：从哪些字段可以判断这是来自guest的攻击？**

**回答：**
从日志的以下字段可以判断攻击来自guest：
- `IN=v-fw-gst`：数据包从guest接口（v-fw-gst）进入防火墙
- `SRC=10.30.0.2`：源IP地址属于guest网段（10.30.0.0/24）
- `log-prefix`：防火墙规则配置了`GUEST-TO-OFFICE:`或`GUEST-TO-DMZ:`等特定前缀
- `OUT=v-fw-off`或`OUT=v-fw-dmz`：数据包试图发往office或dmz接口

通过这些字段的组合，可以准确判断攻击来源和攻击目标，为安全响应提供依据。

**问题2：如果日志中`IN=v-fw-gst OUT=v-fw-off`，说明了什么？**

**回答：**
这说明有数据包从guest网试图访问office网。根据安全策略，guest网和office网应该严格隔离，guest不应该访问office。这是违反安全策略的行为，可能是：
1. **恶意攻击**：攻击者从guest网发起对office网的探测或攻击
2. **配置错误**：guest网中的主机配置了错误的路由或网关
3. **用户误操作**：访客设备错误地尝试访问内网资源

无论原因如何，这种行为都应该被记录和阻止，日志提供了安全审计的证据。

**问题3：为什么看到大量相同来源的日志应该引起警惕？**

**回答：**
大量相同来源的日志可能表明存在自动化攻击或扫描行为：
1. **自动化攻击**：攻击者使用脚本或工具批量发起攻击，导致日志量激增
2. **端口扫描**：攻击者试图扫描目标网络的所有开放端口
3. **暴力破解**：攻击者试图通过暴力破解获取系统访问权限
4. **DDoS攻击**：攻击者试图通过大量请求耗尽系统资源

安全管理员应该密切关注日志频率的异常变化，当发现大量相同来源的日志时，应及时采取措施，如限制该IP的访问频率、阻断该IP或进行深入调查。

### 2.2 分析规则的防御效果

**规则检查命令：**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

**问题1：哪条规则拦截了guest访问office？**

**回答：**
真正执行拦截的是其后紧随的 `REJECT` 规则；LOG 规则仅负责记录审计日志，为后续 REJECT 提供取证依据。具体规则如下：
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i v-fw-gst -o v-fw-off \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i v-fw-gst -o v-fw-off \
  -j REJECT
```
匹配条件是数据包从 `v-fw-gst` 进入、`v-fw-off` 流出，先被 LOG 记录，再被 REJECT 拒绝并向发送方回送 ICMP port-unreachable。

**问题2：如果guest→office的规则计数很高，说明了什么？**

**回答：**
如果guest→office的规则计数很高，说明guest网中有主机持续尝试访问office网。这可能意味着：
1. **恶意攻击**：guest网中的某个主机正在进行持续的扫描或攻击活动
2. **配置错误**：guest网中的主机可能配置了错误的路由或DNS解析，导致流量错误地发往office网
3. **用户行为**：访客可能误操作或有意尝试访问内网资源
4. **感染病毒**：guest网中的设备可能被恶意软件感染，自动发起对内网的攻击

管理员应该查看具体的日志记录，分析源IP地址和访问模式，确定是攻击行为还是配置问题，并采取相应的措施。

**问题3：REJECT和DROP在安全性上有什么区别？**

**回答：**
REJECT和DROP在安全性上有以下区别：
- **REJECT**：返回ICMP不可达消息或TCP RST包，通知发送方连接被拒绝。优点是便于网络诊断和故障排除；缺点是泄露了目标主机的存在信息，攻击者可以据此判断目标是否存活。
- **DROP**：静默丢弃数据包，不返回任何消息。优点是更隐蔽，攻击者无法确定目标是否存在；缺点是不利于网络诊断，可能导致连接超时等待。

在安全策略设计中，通常在外部边界使用DROP以隐藏网络拓扑，在内部网络使用REJECT以便于排障。同时，配合LOG规则记录被拒绝的流量，确保安全审计的完整性。

## 三、边界测试与改进方案

### 3.1 选择的问题及风险分析

**选择的问题：dmz:8080对外开放**

**风险分析：**
dmz:8080服务直接暴露给外网，存在以下安全风险：
1. **DDoS攻击风险**：攻击者可以发起大量请求，耗尽Web服务的资源，导致服务不可用
2. **Web漏洞利用**：如果Web服务存在漏洞（如SQL注入、XSS等），攻击者可以直接利用这些漏洞获取系统权限或敏感数据
3. **连接数耗尽**：无限制的并发连接可能导致服务资源耗尽，影响正常用户访问
4. **流量洪泛**：大量恶意流量可能占用网络带宽，影响其他服务的正常运行

当前的防火墙规则只允许外网访问dmz:8080，但没有任何连接数限制或速率控制，无法应对上述安全威胁。

### 3.2 改进方案的实现

**改进方案：限制单IP对dmz:8080的连接数**

```bash
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**规则说明：**
- `-p tcp --syn`：只匹配TCP连接的SYN包（新连接请求）
- `--dport 8080`：匹配目的端口8080
- `-d 10.40.0.2`：匹配目的地址为dmz主机
- `-m connlimit --connlimit-above 10`：限制单个IP最多10个并发连接
- `--connlimit-mask 32`：基于32位掩码（即单个IP地址）进行限制
- `-j REJECT --reject-with tcp-reset`：超过限制时返回TCP RST包

**附加改进：添加速率限制**

```bash
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --dport 8080 \
  -d 10.40.0.2 \
  -m limit --limit 50/min --limit-burst 100 \
  -j ACCEPT
```

这条规则限制了对dmz:8080的访问速率，每分钟最多50个新连接，突发限制为100个。

### 3.3 测试效果

**测试方法：**

```bash
# 正常访问测试（应该成功）
sudo ip netns exec internet curl http://203.0.113.1:8080/

# 并发连接测试（超过10个应该被拒绝）
for i in {1..15}; do
  sudo ip netns exec internet curl --max-time 1 http://203.0.113.1:8080/ &
done
wait
```

**测试结果：**
- 正常用户访问不受影响
- 当单个IP超过10个并发连接时，新连接被拒绝
- 有效防止单IP发起的DDoS攻击
- 速率限制有效防止流量洪泛

## 四、高级任务：包追踪分析

### 4.1 实验环境

在4个位置同时抓包：
1. remote的wg0接口（看到封装前的包）
2. fw的wg0接口（看到解封装后的包）
3. fw的v-fw-dmz接口（看到转发到dmz的包）
4. fw的conntrack表（观察连接跟踪记录）

### 4.2 抓包命令

```bash
# 终端1：remote的wg0接口
sudo ip netns exec remote tcpdump -ni wg0 -c 5

# 终端2：fw的wg0接口
sudo ip netns exec fw tcpdump -ni wg0 -c 5

# 终端3：fw的v-fw-dmz接口
sudo ip netns exec fw tcpdump -ni v-fw-dmz -c 5

# 终端4：fw的conntrack表
watch -n 1 'sudo ip netns exec fw conntrack -L | grep 10.10.10.2'

# 终端5：触发访问
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

### 4.3 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 端口 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|:-----|
| 1 | remote wg0 | 10.10.10.2 | 10.40.0.2 | TCP | 源端口→8080 | 封装前的原始包 |
| 2 | fw wg0 | 10.10.10.2 | 10.40.0.2 | TCP | 源端口→8080 | 解封装后的包 |
| 3 | fw v-fw-dmz | 10.10.10.2 | 10.40.0.2 | TCP | 源端口→8080 | 转发到dmz的包 |
| 4 | conntrack | 10.10.10.2 | 10.40.0.2 | TCP | 源端口→8080 | 连接跟踪记录，状态为ESTABLISHED |

### 4.4 分析报告

当remote通过VPN访问dmz:8080时，数据包经历了以下处理过程：

**阶段1：remote端封装**
remote主机生成目标为10.40.0.2:8080的TCP SYN包，根据路由表，该目标地址匹配AllowedIPs配置的10.40.0.0/24网段，因此数据包被发送到wg0接口。WireGuard将原始TCP包封装成UDP包，源端口为51820，目的端口为51820，通过公网发送到fw。

**阶段2：fw端解封装**
fw在wg0接口接收到WireGuard加密包，使用私钥进行解密和解封装，恢复原始的TCP SYN包（源IP:10.10.10.2，目的IP:10.40.0.2，目的端口:8080）。

**阶段3：fw端转发**
fw对解封装后的数据包进行路由判断，目标地址10.40.0.2属于dmz网段，因此需要从v-fw-dmz接口转发。同时，fw检查FORWARD规则，确认允许VPN流量访问dmz:8080。

**阶段4：conntrack跟踪**
conntrack模块记录该连接状态，从NEW状态转换为ESTABLISHED状态，确保后续的响应包可以正确返回。响应包沿相反路径返回，经过fw的v-fw-dmz接口，然后在wg0接口被封装成WireGuard加密包，发送到remote。

通过这个过程，WireGuard实现了安全的远程访问，数据包在公网传输时被加密保护，只有两端的WireGuard设备能够解密和处理。