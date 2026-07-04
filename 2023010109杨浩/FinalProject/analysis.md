# 企业级网络安全架构搭建与攻防演练分析报告

## 一、实验目的

本实验通过构建企业级网络安全架构，实现办公区（Office）、访客区（Guest）、DMZ区、Internet以及VPN远程接入等多个网络区域之间的安全通信。通过iptables实现访问控制、NAT地址转换、安全审计以及VPN远程接入，并结合攻防演练分析防火墙规则的实际防御效果，加深对企业网络安全架构设计思想的理解。

---

# 二、攻击方演练分析

## 1. Guest扫描Office网段

### 攻击方法

攻击者位于Guest网络，通过Ping扫描Office网段，试图发现内部主机。

```bash
for i in {1..10}; do
sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i
done
```

### 实验结果

所有Ping请求均超时，没有发现任何Office主机。

### 原因分析

防火墙配置了Guest到Office的访问控制策略，FORWARD链默认策略为DROP，同时存在Guest→Office的REJECT规则，因此扫描流量在防火墙即被拦截，无法进入Office网络。

---

## 2. Guest尝试绕过防火墙访问DMZ SSH

### 攻击方法

修改源端口访问22端口：

```bash
curl --local-port 80 http://10.40.0.2:22/
curl --local-port 443 http://10.40.0.2:22/
```

### 实验结果

连接均失败。

### 原因分析

iptables匹配依据主要是目标IP、目标端口和连接状态，而不是客户端源端口，因此修改源端口不能绕过访问控制策略。

---

## 3. 伪造VPN地址攻击

### 攻击思路

攻击者伪造源IP地址为10.10.10.2，尝试访问Office和DMZ。

### 实验结果

攻击失败。

### 原因分析

WireGuard采用公私钥认证机制，只有完成合法认证的数据包才能进入VPN隧道。仅伪造源IP无法通过身份验证，因此数据包会被直接丢弃。

---

# 三、防御方分析

## 日志分析

通过journalctl查看日志：

```bash
journalctl -k --grep "GUEST-|VPN-|INET-"
```

日志能够记录以下信息：

- 数据包来源接口（IN）
- 转发接口（OUT）
- 源IP地址（SRC）
- 目的IP地址（DST）
- 源端口（SPT）
- 目标端口（DPT）
- 使用协议（PROTO）

管理员可以根据这些字段快速判断攻击来源及攻击目标。

---

## 防火墙规则分析

查看规则：

```bash
iptables -L FORWARD -n -v --line-numbers
```

规则计数器能够统计每条规则被匹配次数。

如果Guest→Office规则计数持续增加，说明Guest区域存在持续扫描、暴力破解或恶意访问行为，应及时进行封禁处理。

---

## REJECT与DROP分析

REJECT会主动向客户端返回错误信息，使客户端立即结束等待，提高用户体验，但攻击者能够判断目标主机存在。

DROP直接丢弃数据包，不返回任何响应，攻击者无法判断目标是否存在，因此具有更好的隐蔽性。

企业内部网络通常采用REJECT方便故障定位，而互联网边界一般采用DROP提高安全性。

---

# 四、边界安全分析

本实验发现以下安全风险：

## （1）Office可无限制访问Internet

风险：

- 下载恶意程序
- 访问钓鱼网站
- 数据泄露

改进方案：

- Web白名单
- DNS过滤
- 代理服务器
- HTTPS过滤

---

## （2）DMZ Web服务长期开放

风险：

- Web漏洞利用
- DDoS攻击
- 暴力扫描

改进方案：

- connlimit限制连接数
- Web应用防火墙（WAF）
- Nginx反向代理
- CDN防护

示例规则：

```bash
iptables -I FORWARD \
-p tcp --syn \
--dport 8080 \
-m connlimit --connlimit-above 10 \
-j REJECT
```

---

## （3）VPN连接缺少访问频率限制

风险：

- 暴力破解
- UDP Flood攻击

改进方案：

- recent模块限制连接频率
- fail2ban自动封禁异常IP

---

# 五、实验收获

通过本次实验，进一步理解了企业网络安全架构中网络隔离、防火墙策略、NAT转换、VPN远程接入、安全审计及攻击防御等多个模块之间的协同工作关系。

企业网络安全并不是简单部署防火墙即可实现，而是需要网络分区、访问控制、身份认证、日志审计以及持续监控共同组成完整的安全体系。

同时，本实验让我熟悉了iptables、conntrack、tcpdump、journalctl、WireGuard等常用网络安全工具，提高了网络故障分析和安全防护能力，为今后的网络安全学习和实际工作奠定了基础。