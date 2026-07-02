# 故障排查记录

## 故障 1: WireGuard 隧道无法建立

### 现象
执行 `vpn-setup.sh` 后，`wg show` 显示隧道存在但握手失败（latest handshake 为空）。

### 排查过程

1. **检查 fw 端是否监听 51820 端口**
```bash
ip netns exec fw ss -ulnp | grep 51820
```
结果：正常监听。

2. **检查 firewall 是否放行 UDP 51820**
```bash
ip netns exec fw iptables -L INPUT -n -v | grep 51820
```
结果：未找到放行规则。**原因：firewall.sh 中 INPUT 链默认 DROP，但只放行了 51820 的 INPUT 规则**

3. **检查 remote 能否到达 fw 的 203.0.113.1**
```bash
ip netns exec remote ping -c 2 203.0.113.1
```
结果：不通。**原因：remote 在 192.0.2.0/24 网段，需要经过 internet 转发**

4. **检查 internet 是否开启了 IP 转发**
```bash
ip netns exec internet sysctl net.ipv4.ip_forward
```
结果：`net.ipv4.ip_forward = 0`。**根因：internet 未开启 IP 转发**

### 解决方案
在 `setup.sh` 中添加：
```bash
ip netns exec internet sysctl -w net.ipv4.ip_forward=1
```
并在 internet 上添加路由：
```bash
ip netns exec internet ip route add 192.0.2.0/24 dev veth-inet-rem
```

### 验证
重新运行后 `wg show` 显示握手成功。

---

## 故障 2: DNAT 访问失败

### 现象
从 internet 访问 `http://203.0.113.1:8080/` 返回连接超时。

### 排查过程

1. **检查 NAT 规则**
```bash
ip netns exec fw iptables -t nat -L PREROUTING -n -v
```
结果：DNAT 规则存在，计数器为 0（没有匹配到包）。

2. **检查 FORWARD 链是否放行 DNAT 后的流量**
```bash
ip netns exec fw iptables -L FORWARD -n -v | grep 8080
```
结果：规则存在。

3. **检查 dmz 服务是否启动**
```bash
ip netns exec dmz curl http://10.40.0.2:8080/
```
结果：服务正常。

4. **检查 fw 是否开启了 IP 转发**
```bash
ip netns exec fw sysctl net.ipv4.ip_forward
```
结果：`net.ipv4.ip_forward = 0`。**根因：fw 未开启 IP 转发**

### 解决方案
在 `setup.sh` 中确保：
```bash
ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```

### 验证
重新访问成功。

---

## 故障 3: LOG 规则不产生日志

### 现象
违规访问被正确拒绝，但 `journalctl -k` 中找不到对应日志。

### 排查过程

1. **检查 LOG 规则是否在 REJECT 之前**
```bash
ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
结果：发现某条 LOG 规则排在 REJECT 之后。**原因：iptables 规则按顺序匹配，REJECT 先命中后 LOG 不会执行**

2. **检查速率限制是否过严**
```bash
# 查看 LOG 规则的计数器
ip netns exec fw iptables -L FORWARD -n -v | grep LOG
```
结果：计数器为 0，说明包没有到达 LOG 规则。

### 解决方案
重新排列规则，确保每条 LOG 规则在对应 REJECT 规则之前：
```bash
# 先删除错误顺序的规则
ip netns exec fw iptables -D FORWARD <行号>
# 再用 -I 插入到正确位置
ip netns exec fw iptables -I FORWARD <行号> ... -j LOG --log-prefix "..."
```

### 验证
重新触发违规后，`journalctl -k` 中出现对应日志。

---

## 故障 4: guest NAT 上网失败

### 现象
guest 可以 ping 通 fw (10.30.0.1)，但无法访问 internet (203.0.113.10)。

### 排查过程

1. **检查 guest 默认路由**
```bash
ip netns exec guest ip route
```
结果：默认路由指向 10.30.0.1，正常。

2. **检查 NAT 规则**
```bash
ip netns exec fw iptables -t nat -L POSTROUTING -n -v
```
结果：guest 的 MASQUERADE 规则存在。

3. **检查 FORWARD 链是否放行 guest → internet**
```bash
ip netns exec fw iptables -L FORWARD -n -v | grep "veth-fw-guest.*veth-fw-inet"
```
结果：未找到放行规则。**原因：guest → internet 的 FORWARD 规则缺失**

### 解决方案
在 `firewall.sh` 中添加：
```bash
$FW -A FORWARD -i veth-fw-guest -o veth-fw-inet \
    -s 10.30.0.0/24 \
    -m conntrack --ctstate NEW -j ACCEPT
```

### 验证
guest 成功通过 NAT 访问 internet。

---

## 故障 5: VPN 用户无法访问 office

### 现象
WireGuard 隧道建立成功（ping 10.10.10.1 通），但 VPN 用户无法访问 office (10.20.0.2)。

### 排查过程

1. **检查 remote 路由表**
```bash
ip netns exec remote ip route
```
结果：缺少到 10.20.0.0/24 的路由。

2. **检查 WireGuard AllowedIPs**
```bash
# 查看 remote 端配置
cat conf/vpn-remote.conf
```
结果：`AllowedIPs = 10.20.0.0/24, 10.40.0.0/24`，配置正确。

3. **检查 fw 端 FORWARD 规则**
```bash
ip netns exec fw iptables -L FORWARD -n -v | grep wg0
```
结果：缺少 VPN → office 的 FORWARD 放行规则。

### 解决方案
1. 确认 `vpn-setup.sh` 中已添加路由：
```bash
ip netns exec remote ip route add 10.20.0.0/24 dev wg0
```
2. 确认 `firewall.sh` 中已添加：
```bash
$FW -A FORWARD -i wg0 -o veth-fw-office \
    -s 10.10.10.0/24 -d 10.20.0.0/24 \
    -m conntrack --ctstate NEW -j ACCEPT
```

### 验证
VPN 用户成功访问 office Web 服务。

---

## 故障 6: tcpdump 抓不到包

### 现象
在 fw 上执行 `tcpdump -ni veth-fw-dmz` 等待包，但没有任何输出。

### 排查过程

1. **确认流量方向**
检查是否在正确的接口上抓包。VPN 流量进入 fw 后，从 `wg0` 接口入，经 FORWARD 转发后从 `veth-fw-dmz` 出。

2. **确认测试服务已启动**
```bash
# 在另一个终端检查 dmz 服务
ip netns exec dmz ss -tlnp | grep 8080
```
结果：服务未启动。

3. **确认触发命令正确**
```bash
ip netns exec remote curl http://10.40.0.2:8080/
```
结果：需要在 tcpdump 启动后再执行此命令。

### 解决方案
按正确顺序操作：
1. 终端 A: 启动 tcpdump
2. 终端 B: 启动 dmz 服务
3. 终端 C: 执行触发命令

```bash
# 终端 A
sudo ip netns exec fw tcpdump -ni wg0 -c 5
# 终端 B
sudo ip netns exec dmz python3 -m http.server 8080
# 终端 C
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

### 验证
tcpdump 成功抓取到 WireGuard 加密包和解密后的明文包。

---

## 总结

| 故障编号 | 故障描述 | 根因 | 解决方案 |
|:---------|:---------|:-----|:---------|
| 1 | WG隧道握手失败 | internet未开转发 | 开启internet的ip_forward |
| 2 | DNAT访问失败 | fw未开IP转发 | 开启fw的ip_forward |
| 3 | LOG规则无日志 | LOG在REJECT之后 | 调整规则顺序 |
| 4 | guest NAT失败 | 缺FORWARD放行规则 | 添加guest→internet规则 |
| 5 | VPN无法访问office | 缺路由和FORWARD规则 | 添加路由和放行规则 |
| 6 | tcpdump抓不到包 | 操作顺序错误 | 先抓包后触发流量 |

核心教训：
1. **IP 转发是基础**：所有需要转发流量的 namespace 都要开启 `net.ipv4.ip_forward=1`
2. **规则顺序很重要**：iptables 规则按顺序匹配，LOG 必须在 REJECT/DROP 之前
3. **FORWARD 和 NAT 要配合**：仅有 NAT 规则不够，还需要 FORWARD 链放行
4. **调试要分层**：从物理层 → 链路层 → 网络层 → 传输层 → 应用层逐层排查
