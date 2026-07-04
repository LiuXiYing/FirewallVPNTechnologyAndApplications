# 攻防演练分析报告

**实验名称**：企业级网络安全架构搭建与攻防演练  
**实验人**：2023010108 尚富斌  
**实验日期**：2026年6月29日


## 一、攻击方演练

### 1.1 攻击1：扫描office网段

**攻击命令**：

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```
攻击结果：
| 目标IP | 响应状态 |
|--------|----------|
| 10.20.0.1 | ✅ 可达（网关） |
| 10.20.0.2 | ❌ Destination Port Unreachable |
| 10.20.0.3 | ❌ Destination Port Unreachable |
| 10.20.0.4 | ❌ Destination Port Unreachable |
| 10.20.0.5 | ❌ Destination Port Unreachable |
| 10.20.0.6 | ❌ Destination Port Unreachable |
| 10.20.0.7 | ❌ Destination Port Unreachable |
| 10.20.0.8 | ❌ 超时 |
| 10.20.0.9 | ❌ Destination Port Unreachable |
| 10.20.0.10 | ❌ 超时 |

**测试截图**：
![攻击扫描](screenshots/11-attack-scan.png)
### 失败原因分析：

guest 发出的 ICMP 请求到达 fw 后，进入 veth-fw-guest 接口。防火墙 FORWARD 链中存在 guest → office 的 REJECT 规则（规则编号 9），该规则匹配所有从 guest 区域发往 office 区域的流量，并返回 ICMP Port Unreachable。因此，除了网关 10.20.0.1 外，office 网段内的其他主机均无法被扫描到。pkts=32 的计数器值也印证了多次扫描尝试被记录。

### 1.2 攻击2：尝试绕过防火墙访问dmz:22（改变源端口）
攻击命令：
```bash
sudo ip netns exec guest curl --local-port 80 -m 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 -m 2 http://10.40.0.2:22/
```
攻击结果：
```bash
curl: (7) Failed to connect to 10.40.0.2 port 22 after 0 ms: Could not connect to server
curl: (7) Failed to connect to 10.40.0.2 port 22 after 0 ms: Could not connect to server
```
**测试截图**：
![攻击源端口绕过](screenshots/12-attack-bypass.png)
### 失败原因分析：

iptables 规则基于五元组（协议、源IP、目的IP、目的端口）进行匹配，源端口不在匹配条件中。防火墙已经配置了 guest → dmz 的全拒绝规则（规则 10、11），无论攻击者使用源端口 80、443 还是其他随机端口，数据包都会因匹配相同的规则而被 REJECT。改变源端口无法绕过基于目的端口和服务类型的访问控制。

### 1.3 攻击3：尝试伪造VPN流量
攻击命令：
```bash
sudo ip netns exec guest socat - TCP:10.40.0.2:8080,bind=10.10.10.2,sourceport=12345
```
攻击结果：
```bash
2026/06/27 10:18:01 socat[64105] W bind(5, [AF=2 10.10.10.2:12345], 16): Cannot assign requested address
```
### 失败原因分析：

本次攻击失败有三层原因。第一，guest 命名空间仅拥有 IP 10.30.0.2，操作系统不允许绑定不存在的 IP 地址。第二，即使通过原始套接字伪造源 IP，fw 的 rp_filter（反向路径过滤）会检查数据包源 IP 是否与路由表匹配，来自 veth-fw-guest 接口的包若源 IP 不是 10.30.0.0/24 网段，会被直接丢弃。第三，WireGuard 隧道本身使用加密和身份认证，伪造的包无法通过密钥验证。

### 攻击者能否从REJECT和DROP判断目标存在？

能。REJECT返回明确错误，攻击者可推断端口关闭；DROP静默丢弃，攻击者需超时，无法区分原因。

## 二、防御方任务
### 2.1 从日志/计数器中识别攻击
通过查看 fw 的 FORWARD 链计数器，可识别以下攻击行为：
### 攻击结果

| 规则编号 | 规则描述 | pkts | 分析结论 |
| 1 | internet → dmz:22 REJECT | 1 | 外部扫描尝试 |
| 9 | guest → office REJECT | 32 | 访客区频繁扫描办公网 |
| 11 | guest → dmz REJECT | 30 | 访客试图访问DMZ |
| 18 | VPN → dmz:22 REJECT | 26 | VPN用户违规访问SSH端口 |
**测试截图**：
![防御日志证据](screenshots/13-defense-logs.png)
![	防御规则计数器](screenshots/14-defense-counters.png)

#### 问题1：从日志的哪些字段可以判断这是来自 guest 的攻击？

从 iptables -L FORWARD -v -n 的输出中，IN=veth-fw-guest 字段表明数据包从 guest 接口进入防火墙，OUT=veth-fw-office 或 veth-fw-dmz 表明目标区域。综合 IN 接口和源网段，可以准确判断攻击来自 guest 区域。

#### 问题2：如果日志中 IN=veth-fw-guest OUT=veth-fw-office，说明了什么？

说明有一个数据包从 guest 区域进入防火墙，试图穿越到 office 区域，但被 REJECT 规则拦截。这违反了“访客不能访问办公网”的安全策略。

#### 问题3：为什么看到大量相同来源的日志应该引起警惕？

规则 9（guest→office）的 pkts=32 是五条违规中最高的，说明该访问尝试最频繁，可能为端口扫描或暴力破解的前兆，应触发安全告警。

### 2.2 分析规则的防御效果
#### 问题1：哪条规则拦截了 guest 访问 office？

规则编号 9（REJECT all -- veth-fw-guest veth-fw-office）拦截了 guest 访问 office 的流量，pkts=32。

#### 问题2：如果 guest→office 的规则计数很高，说明了什么？

说明 guest 区域存在大量违规访问尝试，可能为攻击行为，应触发告警并及时处置。

#### 问题3：REJECT 和 DROP 在安全性上有什么区别？

REJECT返回明确错误，攻击者可感知；DROP静默丢弃，攻击者需超时等待，DROP在外部防御中更隐蔽。

## 三、边界测试与改进方案
### 3.1 问题识别与风险分析（200字）
选择的问题：dmz:8080对外开放，可能被DDoS攻击耗尽连接资源

当前防火墙允许外部用户通过 DNAT 访问 dmz:8080 的 Web 服务，但没有对并发连接数做任何限制。攻击者可以利用大量僵尸主机或单个主机发起大量并发 TCP 连接，耗尽 DMZ 服务器的连接资源（如文件描述符、内存），导致正常用户无法访问。这种资源耗尽型攻击不需要很高的带宽，仅需少量并发请求即可造成服务不可用。因此，限制单个 IP 的并发连接数是必要的安全加固措施。

### 3.2 改进方案实现代码
使用 connlimit 模块限制单个源 IP 对 dmz:8080 的最大并发连接数为 10：
```bash
sudo ip netns exec fw iptables -I FORWARD 1 -p tcp --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
```
### 规则解释：

-m connlimit：使用连接数限制模块

--connlimit-above 10：当连接数超过 10 时触发

--connlimit-mask 32：按单个 IP 计算

--reject-with tcp-reset：返回 TCP RST

### 3.3 测试效果
使用 ab 工具发送 30 个并发请求（并发数 15）：
```bash
sudo ip netns exec internet ab -n 30 -c 15 http://203.0.113.1:8080/
```
测试结果：connlimit 规则 pkts=6，证明拦截生效。
**测试截图**：
![边界测试改进方案](screenshots/15-improvement.png)
## 四、总结
| 攻击类型 | 防御机制 | 结果 |
| --- | --- | --- |
| 网段扫描 | REJECT规则拦截 | ✅ 成功防御 |
| 源端口绕过 | 基于五元组匹配 | ✅ 成功防御 |
| IP伪造 | rp_filter + WireGuard加密 | ✅ 成功防御 |

### 关键经验：

防火墙策略应明确允许少量必要访问，其余全部拒绝

计数器是发现攻击的重要手段，应定期分析异常流量

connlimit 等模块可极大提升系统韧性

内部常用 REJECT，外部常用 DROP