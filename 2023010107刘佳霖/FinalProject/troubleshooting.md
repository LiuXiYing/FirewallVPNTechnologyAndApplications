# 故障排查报告

## 实验环境
- 操作系统：Ubuntu 22.04 WSL2
- iptables版本：iptables v1.8.7 (nf_tables)

---

## 前置说明
本部分设计三类网络边界典型故障，采用复现故障→分层排查→定位根因→修复验证标准化排障流程，体现开放性排查思路：不固定单一故障点，通过多命令交叉验证、分层抓包、连接跟踪定位问题，同一现象可对应多种底层诱因。

---
## 场景1：DNAT配置了但外网无法访问

### 现象
- `internet` 访问 `203.0.113.1:8080` 超时 (Connection timed out)
- `iptables -t nat -L` 显示DNAT规则存在
- `dmz` 上的Web服务正常运行（`ss -tlnp | grep 8080` 正常监听）

### 复现
```bash
# 删除FORWARD链DNAT放行规则
sudo ip netns exec fw iptables -D FORWARD 20

# 验证失败
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:8080/
# curl: (28) Connection timed out after 2002 milliseconds
```

### 排查过程

| 步骤 | 命令 | 发现 |
|:----|:-----|:-----|
| 1 | `iptables -t nat -L PREROUTING -n -v` | DNAT规则存在，pkts增加（包确实经过DNAT） |
| 2 | `iptables -L FORWARD -n -v` | 缺少 `dport 8080` 的ACCEPT规则 |
| 3 | `tcpdump -i veth-fw-inet -nn port 8080` | SYN包已DNAT转换，目的IP变10.40.0.2 |
| 4 | `conntrack -L \| grep 10.40.0.2` | conntrack有DNAT映射记录 |

### 根因
DNAT（PREROUTING）成功将目的IP从`203.0.113.1`转换为`10.40.0.2`，但**FORWARD链缺少配套放行规则**。转换后的包进入FORWARD链时目的IP已是`10.40.0.2`，因为没有对应的`-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 --dport 8080 -j ACCEPT`规则匹配，最终被FORWARD default DROP策略丢弃。

**核心原理：** DNAT只修改包的目的IP，不改变包的转发路径。转换后的包仍然要经过FORWARD链过滤，必须存在对应的放行规则才能通过。

### 修复与验证
```bash
# 添加FORWARD放行规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 \
  -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 验证
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:8080/
# HTTP 200 (成功)
```

DNAT 外网访问故障排查、修复前后对比
![DNAT 外网访问故障排查、修复前后对比图](screenshots/19-troubleshoot-dnat.png)

---


## 场景2：VPN隧道握手正常但业务访问失败

### 现象
- `wg show` 显示握手正常（`latest handshake: X seconds ago`）
- `remote ping 10.40.0.2` 失败
- `fw` 上没有相关日志

### 原因1：FORWARD链缺少VPN→目标区域的ACCEPT规则

**复现：** 删除VPN→Office的FORWARD ACCEPT规则后，remote无法访问10.20.0.0/24网段。

**修复：**
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT
```

### 原因2：fw未开启IPv4转发

**复现：** `sysctl -w net.ipv4.ip_forward=0` 后，所有跨网段转发全部中断。

**修复：** `sysctl -w net.ipv4.ip_forward=1`

### 快速定位流程

```bash
# 1. 检查ip_forward
sudo ip netns exec fw sysctl net.ipv4.ip_forward
# → 必须为1

# 2. 检查FORWARD链
sudo ip netns exec fw iptables -L FORWARD -n -v | grep wg0
# → 必须有 -i wg0 的 ACCEPT 规则

# 3. 检查VPN隧道
sudo ip netns exec remote wg show
# → latest handshake必须有值

# 4. 检查dmz回程路由
sudo ip netns exec dmz ip route
# → default via 10.40.0.1 必须存在
```
VPN 握手正常但内网不通故障排查
![VPN 握手正常但内网不通故障排查图](screenshots/20-troubleshoot-vpn.png)

---


## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

### 现象
- 三次握手第一个SYN包能通过防火墙
- SYN-ACK回包被防火墙拦截
- curl命令超时

### 复现
```bash
sudo ip netns exec fw iptables -D FORWARD 6
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:8080/
# curl: (28) Connection timed out
```

### tcpdump证实
```
# 抓包位置: fw的veth-fw-inet接口
13:51:19.647729 IP 203.0.113.10.34256 > 203.0.113.1.8080: Flags [S]
# 只有SYN发出，没有SYN-ACK回包被捕获
```

### ESTABLISHED,RELATED必要性分析

| 对比项 | 无状态检测 | 有状态检测 |
|:-------|:----------|:----------|
| 回程流量 | 需为每个方向单独写规则 | ESTABLISHED自动放行 |
| 规则数量 | 翻倍（正向+回程） | 只需正向规则 |
| 复杂协议 | FTP/DNS等拆包协议难以处理 | RELATED自动关联 |
| 配置复杂度 | 高，易遗漏 | 低，维护方便 |

**核心原理：** conntrack使用五元组唯一标识连接。第一个SYN→`NEW`，收到SYN-ACK→升级`ESTABLISHED`，后续双向包自动放行。没有状态检测时，每条来回包都必须手动匹配规则，配置工作翻倍且极易出错。

### 修复
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 验证: HTTP 200
```

---

## 总结

| 场景 | 根因 | 关键排查命令 | 解决方案 |
|:----|:-----|:------------|:---------|
| DNAT失败 | FORWARD放行规则缺失 | `iptables -L FORWARD` | 添加配套ACCEPT规则 |
| VPN业务失败 | 转发规则/转发开关 | `sysctl` + `iptables \| grep wg0` | 修复规则或开启转发 |
| TCP连接失败 | 缺少状态检测 | `tcpdump` + `conntrack -L` | 添加ESTABLISHED,RELATED |

### 核心收获
1. DNAT与FORWARD是两套独立的机制，必须同时配置
2. WireGuard隧道握手正常≠业务可达，还需检查FORWARD和转发开关
3. 状态检测是防火墙基石，没有它TCP连接无法完成

---

### 补充
故障排查自动化脚本（代码块中，复制为 troubleshooting.sh 并执行即可自动复现3个场景）
用法: 将下方脚本内容保存为 troubleshooting.sh，执行 sudo bash troubleshooting.sh

#### 脚本内容

```bash
NSFW="sudo ip netns exec fw"
NSINET="sudo ip netns exec internet"
NSREMOTE="sudo ip netns exec remote"
NSDMZ="sudo ip netns exec dmz"

echo "=============================================="
echo "  故障排查专题 - 3个场景复现"
echo "=============================================="
echo ""

# ==================== 场景1 ====================
echo "【场景1】DNAT配置了但外网无法访问"
echo "----------------------------------------------"

echo "步骤1：验证DNAT当前正常工作"
$NSINET curl --max-time 2 http://203.0.113.1:8080/ 2>&1 | head -3
echo ""

echo "步骤2：故意删除FORWARD链DNAT放行规则(#20)"
$NSFW iptables -D FORWARD 20
echo "已删除规则#20 (DNAT配套FORWARD放行)"
echo ""

echo "步骤3：验证外网访问失败"
$NSINET curl --max-time 2 http://203.0.113.1:8080/ 2>&1 | head -5
echo ""

echo "步骤4：tcpdump抓包定位问题"
echo "在fw的veth-fw-inet抓包（DNAT转换后的包）:"
$NSFW tcpdump -i veth-fw-inet -c 2 -nn port 8080 2>/dev/null &
TCPPID=$!
sleep 0.5
$NSINET curl --max-time 1 http://203.0.113.1:8080/ 2>/dev/null
sleep 1
kill $TCPPID 2>/dev/null
wait $TCPPID 2>/dev/null
echo ""

echo "步骤5：排查分析"
echo "- DNAT规则在PREROUTING链仍存在:"
$NSFW iptables -t nat -L PREROUTING -n -v --line-numbers 2>/dev/null | head -5
echo "- 但FORWARD链缺少放行规则，包被policy DROP拦截"
echo "- conntrack显示无DNAT映射（因包未进入FORWARD）"
$NSFW conntrack -L 2>/dev/null | grep 10.40.0.2 | head -3
echo ""

echo "步骤6：修复（重新添加FORWARD放行规则）"
$NSFW iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
echo "已修复，验证:"
$NSINET curl --max-time 2 http://203.0.113.1:8080/ 2>&1 | head -3
echo ""

# ==================== 场景2 ====================
echo "【场景2】VPN隧道握手正常但业务访问失败"
echo "----------------------------------------------"

echo "步骤1：确认VPN当前正常工作"
$NSREMOTE curl --max-time 2 http://10.40.0.2:8080/ 2>&1 | head -3
echo ""

echo "-- 原因1：删除VPN→Office的FORWARD ACCEPT规则 --"
echo "当前VPN→Office规则(#21):"
$NSFW iptables -L FORWARD -n -v --line-numbers 2>/dev/null | grep "wg0.*veth-fw-office"
RULE_LINE=$($NSFW iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -n "wg0.*veth-fw-office" | head -1 | awk '{print $1}')
echo "删除规则#21 (VPN→Office ACCEPT)"
$NSFW iptables -D FORWARD 21
echo "验证VPN访问Office失败:"
$NSREMOTE curl --max-time 2 http://10.20.0.2:8080/ 2>&1 | head -3
echo ""

echo "-- 原因2：临时关闭fw IP转发 --"
$NSFW sysctl -w net.ipv4.ip_forward=0 2>/dev/null
echo "验证VPN访问DMZ失败:"
$NSREMOTE curl --max-time 2 http://10.40.0.2:8080/ 2>&1 | head -3
echo ""

echo "-- 修复 --"
$NSFW sysctl -w net.ipv4.ip_forward=1 2>/dev/null
# 重新添加VPN-OFFICE规则
$NSFW iptables -A FORWARD -i wg0 -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
echo "已修复，验证:"
$NSREMOTE curl --max-time 2 http://10.40.0.2:8080/ 2>&1 | head -3
echo ""

# ==================== 场景3 ====================
echo "【场景3】去掉ESTABLISHED,RELATED后TCP连接失败"
echo "----------------------------------------------"

echo "步骤1：确认当前状态检测正常工作"
$NSINET curl --max-time 2 http://203.0.113.1:8080/ 2>&1 | head -3
echo ""

echo "步骤2：删除ESTABLISHED,RELATED规则(#6)"
$NSFW iptables -D FORWARD 6
echo "已删除规则#6"
echo ""

echo "步骤3：验证TCP连接失败（SYN可以过，但SYN-ACK被拦截）"
$NSINET curl --max-time 2 http://203.0.113.1:8080/ 2>&1 | head -5
echo ""

echo "步骤4：tcpdump证明SYN-ACK被拦截"
$NSFW tcpdump -i veth-fw-inet -c 4 -nn port 8080 2>/dev/null &
TCPPID=$!
sleep 0.5
$NSINET curl --max-time 1 http://203.0.113.1:8080/ 2>/dev/null
sleep 2
kill $TCPPID 2>/dev/null
wait $TCPPID 2>/dev/null
echo ""

echo "步骤5：修复（重新添加ESTABLISHED,RELATED规则）"
$NSFW iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
echo "验证:"
$NSINET curl --max-time 2 http://203.0.113.1:8080/ 2>&1 | head -3
echo ""

echo "=============================================="
echo "  验证最终规则完整性"
echo "=============================================="
$NSFW iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -25
echo ""
echo "=============================================="
echo "  故障排查全部完成，环境已恢复"
echo "=============================================="
```
