# 攻防演练分析报告

## 一、攻击演练总结

### 攻击1：Ping扫描探测（信息收集）

guest 批量 ping 扫描 office 网段结果
![guest 批量 ping 扫描 office 网段结果图](screenshots/11-attack-scan.png)

**攻击命令：**
```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**攻击结果：**

| 扫描目标 | 结果 |
|---------|------|
| 10.20.0.1（FW网关） | ✅ 可达 |
| 10.20.0.2（office主机） | ❌ Destination Port Unreachable |
| 10.20.0.3-10.20.0.10 | ❌ 全部被拦截 |

**失败原因分析：** 防火墙 FORWARD 链规则#10（`-i veth-fw-guest -o veth-fw-office -j REJECT`）拦截所有穿越流量，并生成 9 条 GUEST-TO-OFFICE 审计日志。但 FW 自身接口（10.20.0.1）不受 FORWARD 限制，存在轻微信息泄露风险——攻击者至少能判断 office 网段存在。

---

### 攻击2：源端口绕过尝试

修改源端口尝试访问 DMZ 22 端口
![修改源端口尝试访问 DMZ 22 端口图](screenshots/12-attack-bypass.png)

**攻击命令：**
```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**攻击结果：** 两次均失败（`curl: (7) Failed to connect`），生成 GUEST-TO-DMZ 审计日志。

**失败原因分析：** 防火墙基于**网卡匹配**（`-i veth-fw-guest -o veth-fw-dmz`）而非源端口。无论使用哪个源端口（80/443/随机），只要从 guest 进入、发往 dmz 出口，即被规则#4（LOG）+ 规则#11（REJECT）拦截。区域隔离设计有效抵抗源端口伪造绕过。

---

### 攻击3：伪造VPN源IP（理论分析）

**攻击设想：** 攻击者伪造 src IP 为 10.10.10.2，从 guest 发送包到 office/dmz，试图冒充 VPN 客户端。

**防御分析：** 即使攻击者能伪造源 IP，仍无法绕过：
1. **入网卡匹配：** VPN 放行规则要求 `-i wg0`，guest 发出的包从 `veth-fw-guest` 进入，`-i` 参数不匹配
2. **REJECT兜底：** 不符合 ACCEPT 规则的流量最终被 GUEST-TO-OFFICE/REJECT 拦截

---

### 关键问题：从REJECT和DROP能否判断目标存在？

**能部分判断。** REJECT 返回 ICMP Port Unreachable，攻击者可识别存活主机；DROP 无响应，无法区分目标不存在还是被拦截。建议生产环境使用 DROP 防信息泄露。

---

## 二、防御分析总结

### 任务1：从日志中识别攻击

攻击行为分类审计完整日志
![攻击行为分类审计完整日志图](screenshots/13-defense-logs.png)

攻击日志关键字段解读：

| 日志字段 | 安全信息 |
|:--------|:--------|
| `IN=veth-fw-guest` | 流量来源 — guest 命名空间 |
| `OUT=veth-fw-office` | 攻击方向 — 试图进入办公网 |
| `SRC=10.30.0.2` | 攻击者身份 — guest 主机 IP |
| `PROTO=ICMP TYPE=8` | 攻击类型 — Ping 扫描 |

**大量相同来源日志告警规则：** 5 秒内 9 条 GUEST-TO-OFFICE 日志明显非正常流量，应触发 SOC 告警并自动限速。

### 任务2：规则计数器分析

FORWARD 链规则数据包计数器统计
![FORWARD 链规则数据包计数器统计图](screenshots/14-defense-counters.png)

```
规则#5  GUEST-TO-OFFICE: LOG pkts=21  ← 记录违规日志
规则#10 REJECT:          REJECT pkts=21  ← 执行实际拦截
```

**关键发现：** LOG 与 REJECT 计数完全匹配（21=21），证明**每条违规流量先记录后拦截**，无一遗漏。

### REJECT vs DROP 安全性对比

| 特性 | REJECT | DROP |
|:-----|:-------|:-----|
| 反馈 | ICMP Port Unreachable | 无任何响应 |
| 连接超时 | 立即返回（毫秒级） | 超时等待（秒级） |
| 信息泄露 | 泄露 IP 存在 | 不泄露 |
| 生产建议 | 内网调试可用 | 外网必选 |

---

## 三、边界改进方案

DMZ 并发连接限制加固方案
![DMZ 并发连接限制加固方案图](screenshots/15-improvement.png)

### 问题识别

DMZ:8080 无并发连接限制，存在以下风险：
- **DDoS 攻击：** 单 IP 数千个 TCP 连接耗尽 FW conntrack 表
- **CC 攻击：** 大量慢速 HTTP 请求占用服务器资源
- **端口扫描：** 快速扫描判断 Web 服务是否存活

### 解决方案

```bash
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**规则说明：**
- `-p tcp --syn`：仅匹配三次握手第一个 SYN 包
- `--connlimit-above 10`：单 IP 最大 10 个并发连接
- `--connlimit-mask 32`：按单个 IP（/32）统计
- `--reject-with tcp-reset`：TCP RST 快速断开

**WSL 适配说明：** WSL2 内核未编译 `xt_connlimit` 模块，已在 `firewall.sh` 第 104-109 行注释保留，生产环境取消注释即可生效。

---

## 四、高级任务：包追踪分析

**截图：** `16-tcpdump-remote.png`、`17-tcpdump-fw.png`、`18-conntrack.png`
remote 端 wg0 网卡抓包
![remote 端 wg0 网卡抓包图](screenshots/16-tcpdump-remote.png)

防火墙 wg0、veth-fw-dmz 抓包
![防火墙 wg0、veth-fw-dmz 抓包图](screenshots/17-tcpdump-fw.png)

conntrack 连接跟踪表 VPN 会话记录
![conntrack 连接跟踪表 VPN 会话记录图](screenshots/18-conntrack.png)

### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 关键字段 |
|:----|:--------|:-------|:---------|:-----|:--------|
| 1 | remote wg0 | 10.10.10.2:37944 | 10.40.0.2:8080 | TCP SYN→SYN-ACK→ACK | 封装前原始三次握手 |
| 2 | fw wg0 | 10.10.10.2:37944 | 10.40.0.2:8080 | TCP SYN→SYN-ACK→ACK | 解密后内容与位置1一致 |
| 3 | fw veth-fw-dmz | 10.10.10.2↔10.40.0.2 | SYN↔SYN-ACK | MAC:FW↔DMZ | L2帧头变换，L3/L4不变 |
| 4 | conntrack | 10.10.10.2:37944↔10.40.0.2:8080 | TIME_WAIT | [ASSURED] | 双向连接跟踪 |

### 流程分析

1. **remote 端：** curl → AllowedIPs → wg0 加密 → UDP 外层封装 → 发送到 203.0.113.1:51820
2. **fw 解封装：** 收到 UDP → 私钥解密 → 还原 IP 包 → 注入 wg0 接口
3. **fw 转发：** FORWARD 规则#22 ACCEPT → veth-fw-dmz → DMZ http.server 响应
4. **conntrack：** 记录双向五元组，后续 HTTP 响应由状态检测（规则#6）放行

---

## 五、整体安全评估

1. **纵深防御有效：** 单一防御点（如源端口过滤）易被绕过，多层防御（网卡+端口+状态检测）更有效
2. **最小权限原则：** VPN 的 AllowedIPs 只包含必要网段（10.20.0.0/24, 10.40.0.0/24），而非 0.0.0.0/0
3. **审计溯源完善：** LOG 规则前置（规则#1-#5）确保所有违规行为先记录后拦截，完整审计链
4. **性能平衡：** conntrack 状态检测避免每条包都遍历规则链，兼顾安全与性能

---

### 补充：包追踪自动化脚本
#### 1. 脚本简要说明
1.1 脚本作用：用于 5.4 高级包追踪实验，自动化抓取 remote VPN客户端访问dmz:8080 全链路数据包，一键完成多节点抓包、流量触发、报文打印、连接跟踪查看，无需手动开多个终端操作。
1.1.2 核心流程
①新建临时目录 /tmp/packet_trace 存放抓包文件；
②后台同时启动 3 处tcpdump抓包：
remote wg0：WireGuard 封装前原始内网包
fw wg0：防火墙解封装后的报文
fw veth-fw-dmz：转发至 DMZ 的二层报文
③延迟等待抓包进程就绪，执行 curl 生成访问流量；
自动关闭所有抓包进程，读取 pcap 文件打印报文内容；
④过滤并输出 fw 的 conntrack 连接跟踪表，查看 TCP 会话状态。
1.1.3 关键参数说明
-c 3：仅捕获 3 个包自动停止，减少冗余输出；
-w 文件名：保存原始 pcap 抓包文件，支持离线分析；
-nn -e：数字显示 IP / 端口，打印二层 MAC 头部，直观对比转发前后包变化；
conntrack -L：查看状态防火墙会话表，验证 ESTABLISHED 放行逻辑。

##### 2.追踪remote通过VPN访问dmz:8080的完整过程
```bash
TRACE_DIR=/tmp/packet_trace
mkdir -p $TRACE_DIR

echo "============================================"
echo "  5.4 包追踪 - remote→VPN→dmz:8080"
echo "============================================"
echo ""

# 步骤1：启动3个tcpdump后台抓包
echo "[1/4] 启动tcpdump抓包..."

# 终端1：remote wg0（封装前的原始请求包）
sudo ip netns exec remote tcpdump -i wg0 -c 3 -w $TRACE_DIR/remote-wg0.pcap -s 0 2>/dev/null &
PID1=$!

# 终端2：fw wg0（WireGuard解封装后的包）  
sudo ip netns exec fw tcpdump -i wg0 -c 3 -w $TRACE_DIR/fw-wg0.pcap -s 0 2>/dev/null &
PID2=$!

# 终端3：fw veth-fw-dmz（转发到DMZ的包）
sudo ip netns exec fw tcpdump -i veth-fw-dmz -c 3 -w $TRACE_DIR/fw-dmz.pcap -s 0 2>/dev/null &
PID3=$!

sleep 1  # 等tcpdump启动

# 步骤2：触发VPN访问
echo "[2/4] 触发VPN访问..."
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/ 2>&1
echo ""

sleep 2  # 等待tcpdump捕获完成

# 停止tcpdump
kill $PID1 $PID2 $PID3 2>/dev/null
wait $PID1 $PID2 $PID3 2>/dev/null

# 步骤3：显示抓包结果
echo "[3/4] ====== 抓包结果 ======"

echo ""
echo "--- 位置1: remote wg0（封装前） ---"
sudo ip netns exec remote tcpdump -r $TRACE_DIR/remote-wg0.pcap -nn -e 2>/dev/null | head -5

echo ""
echo "--- 位置2: fw wg0（解封装后） ---"
sudo ip netns exec fw tcpdump -r $TRACE_DIR/fw-wg0.pcap -nn -e 2>/dev/null | head -5

echo ""
echo "--- 位置3: fw veth-fw-dmz（转发到DMZ） ---"
sudo ip netns exec fw tcpdump -r $TRACE_DIR/fw-dmz.pcap -nn -e 2>/dev/null | head -5

# 步骤4：查看conntrack表
echo ""
echo "[4/4] ====== conntrack连接跟踪表 ======"
sudo ip netns exec fw conntrack -L 2>/dev/null | grep -E "10.10.10.2|10.40.0.2" || echo "(无conntrack记录或已超时)"

echo ""
echo "============================================"
echo "  包追踪完成"
echo "============================================"
```
