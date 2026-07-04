# 攻防演练分析报告

## 一、攻击场景一：Guest扫描Office网段

### 攻击命令

```bash
for i in {1..10}; do
    sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i
done
```

### 实验结果

所有扫描请求均未成功，无法发现Office主机。

### 原因分析

Guest网络到Office网络的流量经过防火墙FORWARD链。防火墙中配置了LOG和REJECT规则，对来自Guest网段访问Office网段的所有数据包进行记录并拒绝，因此扫描请求无法到达目标主机。同时iptables状态检测机制保证只有已建立连接的数据包能够返回，从而有效阻止了Guest对Office网络的探测行为。

---

## 二、攻击场景二：尝试绕过防火墙访问DMZ SSH

### 攻击命令

```bash
sudo ip netns exec guest curl --local-port 80 http://10.40.0.2:22
sudo ip netns exec guest curl --local-port 443 http://10.40.0.2:22
```

### 实验结果

两次连接均失败。

```
curl: (7) Failed to connect to 10.40.0.2 port 22
```

### 原因分析

防火墙匹配规则依据的是目标IP、目标端口、协议及数据包进入和离开的接口，而不是客户端源端口。因此即使攻击者修改源端口为80或443，目标仍然是TCP 22端口，最终仍会命中LOG规则和REJECT规则，被防火墙拒绝访问。

---

## 三、攻击场景三：伪造VPN地址

### 是否能够成功

不能。

### 原因分析

VPN规则限定进入接口必须为wg0，同时源地址必须为172.16.100.2。普通Guest主机的数据包来自veth-fw-guest接口，不可能从WireGuard接口进入，因此即使伪造源IP地址，也无法匹配VPN访问规则。此外，WireGuard使用公私钥认证机制，未建立合法VPN隧道的数据包不会被接受，因此无法绕过身份认证。

---

## 四、REJECT与DROP的区别

REJECT会主动向客户端返回拒绝信息，例如ICMP Port Unreachable或TCP Reset，因此客户端能够立即知道访问被拒绝，连接失败速度较快。

DROP则直接丢弃数据包，不返回任何响应。客户端通常会等待超时后才认为连接失败，因此攻击者无法快速判断目标是否存在，但合法用户排查网络故障也更加困难。

本实验采用REJECT方式，能够提高实验可观察性，同时配合LOG规则能够方便分析访问行为。