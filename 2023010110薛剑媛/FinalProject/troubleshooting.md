# 故障排查报告

## 场景1：DNAT配置了但外网无法访问

### 故障现象
- internet访问 `203.0.113.1:8080` 失败
- `iptables -t nat -L` 显示DNAT规则存在
- dmz上的服务正常运行

### 重现故障

删除FORWARD链中 `fw-inet → fw-dmz` 的ACCEPT规则：

```bash
# 查看当前规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "fw-inet.*fw-dmz.*8080"

# 删除ACCEPT规则（制造故障）
sudo ip netns exec fw iptables -D FORWARD 14

# 验证删除
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "fw-inet.*fw-dmz.*8080"
```

### 排查过程

| 步骤 | 排查命令 | 预期结果 | 实际结果 | 结论 |
|:-----|:---------|:---------|:---------|:-----|
| 1 | `iptables -t nat -L PREROUTING \| grep 8080` | DNAT规则存在 | 存在（pkts=4） | ✅ DNAT配置正确 |
| 2 | `iptables -L FORWARD \| grep "fw-inet.*fw-dmz.*8080"` | ACCEPT规则存在 | 只有connlimit | ❌ FORWARD缺少放行规则 |
| 3 | `ip netns exec dmz ip route \| grep default` | default via 10.40.0.1 | 正确 | ✅ dmz路由正常 |
| 4 | `conntrack -L \| grep 8080` | 有连接记录 | 无记录 | ❌ 包未到达dmz |
| 5 | 外网访问测试 | 成功 | `Connection timed out` | ❌ 访问失败 |

### 根本原因

FORWARD链缺少 `fw-inet → fw-dmz` 的ACCEPT规则。DNAT规则将外网请求重定向到dmz:8080，但FORWARD链没有放行规则，导致包无法转发到dmz。

### 修复方法

```bash
# 恢复ACCEPT规则
sudo ip netns exec fw iptables -I FORWARD 14 -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

### 验证修复

```bash
# 查看规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "fw-inet.*fw-dmz.*8080"

# 测试访问
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```

**结果：** 返回HTML内容 ✅

### 排查要点总结

1. **DNAT存在但无法访问** → FORWARD规则缺失
2. **conntrack无记录** → 包未到达dmz
3. **修复方法** → 恢复ACCEPT规则

---

## 场景2：VPN隧道握手正常但业务访问失败

### 故障现象
- `wg show` 显示 `latest handshake` 正常
- `remote ping 10.40.0.2` 失败
- fw上没有相关日志

### 排查过程

| 步骤 | 排查命令 | 预期结果 | 实际结果 | 结论 |
|:-----|:---------|:---------|:---------|:-----|
| 1 | `wg show` | latest handshake正常 | 正常 | ✅ VPN隧道正常 |
| 2 | `ip route \| grep wg0` | 目标网段在wg0 | 缺少10.40.0.0/24 | ❌ 路由可能缺失 |
| 3 | `wg show \| grep allowed` | 包含目标网段 | 缺少10.40.0.0/24 | ❌ AllowedIPs错误 |
| 4 | `sysctl net.ipv4.ip_forward` | 1 | 1 | ✅ IP转发开启 |
| 5 | `iptables -L FORWARD \| grep wg0` | ACCEPT规则存在 | 缺少ACCEPT | ❌ FORWARD规则缺失 |

### 原因1：AllowedIPs配置错误

```bash
# 查看当前AllowedIPs
sudo ip netns exec remote wg show | grep allowed

# 修改配置（移除10.40.0.0/24）
sudo ip netns exec remote wg set wg0 peer ... allowed-ips 10.10.10.0/24,10.20.0.0/24

# 修复
sudo ip netns exec remote wg set wg0 peer ... allowed-ips 10.10.10.0/24,10.20.0.0/24,10.40.0.0/24
```

### 原因2：FORWARD规则缺失

```bash
# 删除ACCEPT规则（制造故障）
sudo ip netns exec fw iptables -D FORWARD 16

# 修复
sudo ip netns exec fw iptables -I FORWARD 16 -i wg0 -o fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

### 快速定位方法

| 排查顺序 | 检查项 | 命令 |
|:---------|:-------|:-----|
| 1 | VPN隧道状态 | `wg show` |
| 2 | VPN路由 | `ip route \| grep wg0` |
| 3 | AllowedIPs | `wg show \| grep allowed` |
| 4 | IP转发 | `sysctl net.ipv4.ip_forward` |
| 5 | FORWARD规则 | `iptables -L FORWARD \| grep wg0` |

### 根本原因

VPN隧道正常（握手成功），但数据包无法到达目标，原因可能是：
1. AllowedIPs未包含目标网段 → 包不走VPN
2. FORWARD规则缺失 → 包到达fw后被丢弃

### 修复验证

```bash
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
```

**结果：** 返回HTML内容 ✅

---

## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

### 故障现象
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

### 重现故障

删除ESTABLISHED,RELATED规则：

```bash
# 查看当前状态检测规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5

# 删除ESTABLISHED,RELATED规则
sudo ip netns exec fw iptables -D FORWARD 3

# 验证删除
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5
```

### 排查过程

| 步骤 | 排查命令 | 结果 | 结论 |
|:-----|:---------|:-----|:-----|
| 1 | `iptables -L FORWARD \| head -5` | 无ESTABLISHED,RELATED | ❌ 状态检测缺失 |
| 2 | `tcpdump -i fw-office -c 5 -n port 8080` | 0 packets | SYN包被拦截 |
| 3 | `tcpdump -i fw-dmz -c 5 -n port 8080` | 0 packets | SYN-ACK无法到达 |
| 4 | `conntrack -L \| grep 8080` | 无记录 | 连接未建立 |
| 5 | 访问测试 | `Connection timed out` | ❌ 访问失败 |

### 抓包验证

```bash
# fw-office接口抓包（0 packets）
sudo ip netns exec fw tcpdump -i fw-office -c 5 -n port 8080

# fw-dmz接口抓包（0 packets）
sudo ip netns exec fw tcpdump -i fw-dmz -c 5 -n port 8080
```

### 根本原因

缺少 `ESTABLISHED,RELATED` 规则后，TCP三次握手中的SYN-ACK回包（属于`RELATED`状态）无法通过FORWARD链。SYN包到达fw后匹配connlimit规则被REJECT，后续的SYN-ACK无法到达dmz。

### ESTABLISHED,RELATED的必要性

| 状态 | 作用 | 影响 |
|:-----|:-----|:-----|
| ESTABLISHED | 允许已建立连接的双向通信 | 没有则无法传输数据 |
| RELATED | 允许FTP等协议的辅助连接 | 没有则辅助连接被阻断 |

### 修复方法

```bash
# 恢复状态检测规则
sudo ip netns exec fw iptables -I FORWARD 3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### 验证修复

```bash
# 查看规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5

# 重新测试
sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080/
```

**结果：** 返回HTML内容 ✅

### 关键发现

1. **状态检测是防火墙核心功能**：没有它TCP连接无法完成
2. **SYN包被connlimit拦截**：缺少ESTABLISHED规则导致SYN包被后续规则处理
3. **抓包证明包被丢弃**：fw-office和fw-dmz都抓不到包

---

## 故障排查总结

### 排查方法论

1. **确认正常状态**：先验证哪些是正常的
2. **逐层排查**：从物理层到应用层
3. **二分定位**：在关键节点抓包
4. **查看计数器**：iptables pkts快速定位
5. **conntrack分析**：确认连接状态

### 三种场景对比

| 场景 | 故障现象 | 根本原因 | 修复方法 |
|:-----|:---------|:---------|:---------|
| 1 | DNAT存在但外网无法访问 | FORWARD缺少ACCEPT | 恢复ACCEPT规则 |
| 2 | VPN握手正常但业务失败 | AllowedIPs错误/FORWARD缺失 | 修正配置 |
| 3 | 去掉状态检测后TCP失败 | 缺少ESTABLISHED,RELATED | 恢复状态检测 |

### 总结

1. DNAT+FORWARD需要配套配置
2. VPN配置需要路由+AllowedIPs+FORWARD三者一致
3. 状态检测是防火墙的**必须配置**
4. LOG规则+包计数是排查的有力工具