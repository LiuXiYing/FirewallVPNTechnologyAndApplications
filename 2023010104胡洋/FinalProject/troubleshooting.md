# 故障排查报告

## 场景1：DNAT配置了但外网无法访问DMZ Web

### 1. 故障现象

`internet`访问 `203.0.113.1:8080` 失败，但 `iptables -t nat -L` 能看到DNAT规则，且DMZ上的Web服务 `10.40.0.2:8080` 正常运行。

### 2. 故意重现故障

删除或不配置对应的FORWARD放行规则，只保留DNAT：

```bash
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080
```

测试：

```bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```

### 3. 排查过程

第一步，确认DMZ服务是否正常：

```bash
sudo ip netns exec dmz curl --max-time 2 http://10.40.0.2:8080/
```

第二步，查看NAT表是否发生DNAT：

```bash
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
```

第三步，查看FORWARD链是否有DNAT后的放行规则：

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

第四步，抓包定位包是否到达DMZ接口：

```bash
sudo ip netns exec fw tcpdump -ni veth-fw-inet tcp port 8080
sudo ip netns exec fw tcpdump -ni veth-fw-dmz tcp port 8080
```

### 4. 根本原因

DNAT只修改目标地址，不代表防火墙自动放行转发。PREROUTING完成DNAT后，数据包进入FORWARD链时目的地址已经变成 `10.40.0.2:8080`。如果FORWARD默认策略为DROP且没有对应放行规则，数据包会被丢弃。

### 5. 修复方法

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

修复后再次测试 `internet` 访问 `203.0.113.1:8080`，应能看到DMZ Web目录输出。

## 场景2：VPN握手正常但业务访问失败

### 1. 故障现象

`wg show` 显示 `latest handshake` 正常，但remote访问 `10.40.0.2:8080` 或 `10.20.0.2:8000` 失败，fw上可能没有对应业务日志。

### 2. 可能原因一：AllowedIPs配置错误

故意错误配置：remote端缺少 `10.40.0.0/24`。

```ini
AllowedIPs = 10.20.0.0/24
```

此时remote访问DMZ不会走wg0，而是走默认路由，业务流量不会进入VPN隧道。

排查命令：

```bash
sudo ip netns exec remote ip route
sudo ip netns exec remote ip route get 10.40.0.2
sudo ip netns exec remote tcpdump -ni wg0
```

修复方法：

```ini
AllowedIPs = 10.20.0.0/24, 10.40.0.0/24
```

### 3. 可能原因二：FORWARD规则拒绝VPN业务

如果防火墙中缺少 `wg0 -> veth-fw-dmz` 的放行规则，即使VPN握手正常，业务包进入fw后也会被默认DROP或命中拒绝规则。

排查命令：

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
sudo ip netns exec fw tcpdump -ni wg0 host 10.10.10.2
sudo ip netns exec fw tcpdump -ni veth-fw-dmz host 10.40.0.2
```

修复方法：

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

### 4. 快速定位方法

如果remote的 `ip route get 10.40.0.2` 显示不走wg0，优先检查AllowedIPs；如果remote的wg0能抓到包，但fw的veth-fw-dmz抓不到包，优先检查fw的FORWARD规则；如果包到达DMZ但无回包，检查DMZ默认路由是否指向 `10.40.0.1`；如果各接口都没有转发，检查fw是否开启 `net.ipv4.ip_forward=1`。

## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

### 1. 故障现象

客户端发出的SYN包能够被防火墙放行并到达服务器，但服务器返回的SYN-ACK回包被FORWARD默认DROP拦截，导致curl超时或连接失败。

### 2. 故意重现故障

删除状态检测规则：

```bash
sudo ip netns exec fw iptables -D FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

测试：

```bash
sudo ip netns exec office curl --max-time 3 http://10.40.0.2:8080/
```

### 3. 抓包证明

开两个终端抓包：

```bash
sudo ip netns exec fw tcpdump -ni veth-fw-office tcp port 8080
sudo ip netns exec fw tcpdump -ni veth-fw-dmz tcp port 8080
```

如果只看到office发出的SYN和dmz返回的SYN-ACK，但客户端始终建立不了连接，说明回程方向未被允许。

### 4. conntrack观察

```bash
sudo ip netns exec fw conntrack -L | grep 10.20.0.2
```

可以看到连接状态没有正常进入ESTABLISHED，或者连接反复重试。

### 5. 根本原因

iptables的FORWARD链是双向检查的。只写 `office -> dmz:8080` 放行规则，只允许客户端发起的新连接方向通过；服务器回包方向是 `dmz -> office`，不匹配这条NEW规则。如果没有 `ESTABLISHED,RELATED`，回包会被默认DROP。

### 6. 修复方法

将状态检测规则放在FORWARD链最前面：

```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

修复后再次执行curl，TCP三次握手和后续HTTP响应应正常完成。
