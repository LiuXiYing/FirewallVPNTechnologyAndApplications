# 故障排查报告

## 场景 1：DNAT 配置了但外网无法访问

### 故障现象

- internet 访问 `203.0.113.1:8080` 失败
- `iptables -t nat -L` 显示 DNAT 规则存在
- dmz 上的 8080 服务正常运行

### 故障重现

故意删除 DNAT 对应的 FORWARD 允许规则，只保留 DNAT 映射：

```bash
# 正常环境
sudo bash setup.sh
sudo bash firewall.sh

# 制造故障：删除 DNAT 对应的 FORWARD 规则
sudo ip netns exec fw iptables -D FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```

### 排查步骤

```bash
# 1. 确认 DNAT 规则存在
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers

# 2. 确认 FORWARD 规则是否放行 DNAT 后的流量
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers

# 3. 查看 conntrack 是否有 DNAT 映射记录
sudo ip netns exec fw conntrack -L -p tcp --dport 8080

# 4. 在 fw 多个接口抓包，找出包在哪里被丢弃
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 10 port 8080
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 port 8080
```

### 根本原因

DNAT 只修改了数据包的目的地址，但修改后的数据包仍然需要经过 FORWARD 链转发。如果 FORWARD 链中没有放行 `-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 --dport 8080` 的规则，数据包会被默认 DROP 策略丢弃。

### 修复方法

重新添加 DNAT 对应的 FORWARD 允许规则：

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

### 验证

```bash
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:8080/
```

---

## 场景 2：VPN 隧道握手正常但业务访问失败

### 故障现象

- `wg show` 显示 `latest handshake` 正常
- `remote ping 10.40.0.2` 失败
- fw 上没有相关日志（说明未命中 VPN 允许规则，直接走了默认 DROP）

### 可能原因

1. `AllowedIPs` 配置错误，remote 没有把 `10.40.0.0/24` 加入 VPN 路由
2. FORWARD 规则拒绝了 VPN 流量（缺少 VPN→dmz 规则）
3. dmz 没有回程路由
4. fw 未开启 IP 转发

### 故障重现 1：AllowedIPs 配置错误

```bash
# 正常环境
sudo bash setup.sh
sudo bash firewall.sh

# 制造故障：修改 remote 的 AllowedIPs，只保留 office 网段
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo sed -i 's/AllowedIPs = 10.20.0.0\/24,10.40.0.0\/24/AllowedIPs = 10.20.0.0\/24/' /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

### 故障重现 2：FORWARD 规则缺失

```bash
# 制造故障：删除 VPN→dmz 的 FORWARD 允许规则
sudo ip netns exec fw iptables -D FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```

### 快速定位方法

```bash
# 1. 检查 remote 路由表，确认是否有 10.40.0.0/24 路由
sudo ip netns exec remote ip route

# 2. 检查 fw 的 FORWARD 规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers

# 3. 在 fw 的 wg0 和 veth-fw-dmz 接口抓包
sudo ip netns exec fw tcpdump -ni wg0 -c 10 host 10.40.0.2
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 host 10.40.0.2

# 4. 检查 fw 是否开启 IP 转发
sudo ip netns exec fw sysctl net.ipv4.ip_forward

# 5. 检查 dmz 默认路由
sudo ip netns exec dmz ip route
```

### 修复方法

**针对原因 1（AllowedIPs 错误）：**

```bash
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo sed -i 's/AllowedIPs = 10.20.0.0\/24/AllowedIPs = 10.20.0.0\/24,10.40.0.0\/24/' /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

**针对原因 2（FORWARD 规则缺失）：**

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**针对原因 4（未开启 IP 转发）：**

```bash
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```

### 验证

```bash
sudo ip netns exec remote ping -c 2 10.40.0.2
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
```

---

## 场景 3：去掉 ESTABLISHED,RELATED 后 TCP 连接失败

### 故障现象

- 三次握手的第一个 SYN 包能通过
- 服务器的 SYN-ACK 回包被防火墙拦截
- `curl` 命令卡住直到超时

### 故障重现

删除 FORWARD 链最前面的状态检测规则：

```bash
# 正常环境
sudo bash setup.sh
sudo bash firewall.sh

# 制造故障：删除 ESTABLISHED,RELATED 规则
sudo ip netns exec fw iptables -D FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### 排查步骤

```bash
# 1. 在 fw 上观察双向流量
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 10 host 10.40.0.2 and port 8080
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 host 10.20.0.2 and port 8080

# 2. 用 conntrack 观察连接状态
sudo ip netns exec fw conntrack -L -p tcp --dport 8080

# 3. 触发连接
sudo ip netns exec office curl --max-time 3 http://10.40.0.2:8080/
```

### 抓包观察

在 `veth-fw-office` 上可以观察到：
- `office → dmz` 的 SYN 包正常发出
- `dmz → office` 的 SYN-ACK 包没有返回，或被防火墙丢弃

在 `veth-fw-dmz` 上可以观察到：
- SYN 包到达 dmz
- dmz 回复 SYN-ACK，但 SYN-ACK 无法通过 fw 返回 office

### 根本原因

当 FORWARD 链中没有 `ESTABLISHED,RELATED -j ACCEPT` 规则时，防火墙无法识别 SYN-ACK 是对已发起连接的响应，而是将其当作新的连接请求处理。由于 FORWARD 默认策略是 DROP，且没有允许 `dmz → office` 的规则，SYN-ACK 回包被丢弃，导致 TCP 三次握手无法完成。

### 修复方法

重新添加状态检测规则到 FORWARD 链最前面：

```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

### 验证

```bash
sudo ip netns exec office curl --max-time 2 http://10.40.0.2:8080/
```

### 为什么 ESTABLISHED,RELATED 必不可少

状态检测是防火墙实现双向通信的基础：

- **ESTABLISHED**：表示该连接已经通过 SYN 包建立，后续双向数据包（如 SYN-ACK、ACK、应用数据）都应当放行。
- **RELATED**：表示与已有连接相关联的新连接（如 FTP 数据通道、ICMP 错误报文），也需要放行。

如果没有这两条规则，管理员就必须为每个服务的回程流量单独写允许规则，既繁琐又容易出错。在默认拒绝策略下，缺少状态检测会导致所有 TCP 连接都无法完成三次握手。
