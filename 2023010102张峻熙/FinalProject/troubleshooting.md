# 故障排查报告

## 故障场景一：DNAT访问异常

### 现象

Internet无法访问DMZ提供的Web服务。

### 排查过程

1. 查看NAT规则

```bash
sudo ip netns exec fw iptables -t nat -L -n -v
```

确认PREROUTING链中存在DNAT规则。

2. 查看FORWARD规则

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v
```

确认存在允许Internet访问DMZ:8080的ACCEPT规则。

3. 查看DMZ服务状态

```bash
sudo ip netns exec dmz ss -lnt
```

确认8080端口已监听。

### 故障原因

DNAT规则或FORWARD规则配置错误，或者DMZ服务未启动，均可能导致Internet无法访问DMZ服务。

### 解决方法

重新添加DNAT规则，确保FORWARD链允许TCP 8080访问，并重新启动DMZ Web服务。

---

## 故障场景二：VPN无法建立

### 现象

执行

```bash
wg show
```

没有Latest Handshake。

### 排查过程

1. 查看WireGuard状态

```bash
sudo ip netns exec fw wg show
sudo ip netns exec remote wg show
```

2. 检查配置文件

```bash
cat /etc/wireguard/fw/wg0.conf
cat /etc/wireguard/remote/wg0.conf
```

重点检查：

- PrivateKey
- PublicKey
- Endpoint
- AllowedIPs
- ListenPort

3. 重启WireGuard

```bash
sudo ip netns exec fw wg-quick down wg0
sudo ip netns exec remote wg-quick down wg0

sudo ip netns exec fw wg-quick up /etc/wireguard/fw/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

4. 再次查看状态

```bash
wg show
```

确认出现

- latest handshake
- transfer

说明VPN恢复正常。

---

## 本实验遇到的问题

实验初期使用10.10.10.0/24作为WireGuard地址，与Remote网络发生地址冲突，导致VPN无法正常建立和路由异常。

解决方案是重新规划VPN地址，将WireGuard网络修改为172.16.100.0/24。

修改后：

- fw：172.16.100.1/24
- remote：172.16.100.2/24

同时修改AllowedIPs及iptables规则中的源地址，重新启动WireGuard后成功建立VPN连接。

最终wg show能够显示Latest Handshake和Transfer信息，VPN访问DMZ Web服务成功，实验恢复正常。