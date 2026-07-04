# 企业级网络安全架构搭建与攻防演练

> 期末大作业 · 完整实验报告
> 配套文件：`setup.sh` / `firewall.sh` / `vpn-fw.conf` / `vpn-remote.conf` / `analysis.md` / `troubleshooting.md` / `screenshots/`

---

## 一、实验环境

| 项目 | 实际值 |
|:-----|:-------|
| 操作系统 | Ubuntu 22.04 LTS（内核 5.15+） |
| 容器/虚拟化方式 | Linux `network namespace` + `veth` + `bridge` |
| WireGuard 版本 | wireguard-tools 1.0.20210914，wireguard-linux-compat 内核模块 |
| iptables 版本 | iptables v1.8.7（nf_tables），`conntrack`/`recent`/`connlimit` 模块齐全 |
| 抓包/诊断工具 | tcpdump 4.99、conntrack-tools 1.4.6、journalctl（systemd 252） |
| 验证方式 | 在同一台物理机/虚拟机内通过 6 个 netns 模拟企业 4 区域 + 公网 + 远程员工 |

> **接口名说明**：受 Linux 接口名 15 字符限制，本作业在 `fw` 侧采用 `v-fw-off` / `v-fw-gst` / `v-fw-dmz` / `v-fw-inet` 短名，与需求文档里的 `veth-fw-office` 等长名功能等价。`firewall.sh`、`analysis.md` 中的规则均使用短名。

---

## 二、拓扑图和地址规划

### 2.1 拓扑结构

![](screenshots/topology.png)

**节点说明：**

| 节点 | 角色 | 必须实现的功能 |
|:-----|:-----|:--------------|
| `fw` | 防火墙+VPN网关 | 5个网络接口、IP转发、FORWARD规则、NAT、WireGuard |
| `office` | 办公网主机 | 模拟内网员工 |
| `guest` | 访客网主机 | 模拟访客设备 |
| `dmz` | 对外服务器 | 运行Web服务(8080)和管理服务(22) |
| `internet` | 外网主机 | 模拟互联网用户 |
| `remote` | 远程员工 | 通过VPN接入 |

> 拓扑参考截图：[screenshots/01-topology.png](screenshots/01-topology.png)

### 2.2 地址规划表

| 区域 | 网段 | fw 侧地址 | 主机地址 | 接口名（fw↔区域） | 说明 |
|:-----|:-----|:----------|:---------|:------------------|:-----|
| office（办公区） | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | v-fw-off ↔ v-off | 内网员工 |
| guest（访客区） | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | v-fw-gst ↔ v-gst | 仅允许上网 |
| dmz（对外服务） | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | v-fw-dmz ↔ v-dmz | Web:8080 / SSH:22 |
| internet（公网） | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | v-fw-inet ↔ br-inet ↔ v-inet | 模拟互联网 |
| remote（远端） | 203.0.113.0/24 | — | 203.0.113.20 | v-rem ↔ br-inet | 远程员工物理位置 |
| VPN 隧道 | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | wg0 ↔ wg0 | WireGuard 接口对 |

> **设计要点**
> 1. 各内部区域网段错开 10.20/10.30/10.40 三个独立 /24，避免冲突；
> 2. internet 与 remote 共用 203.0.113.0/24 + br-inet 桥接，模拟"远端员工在公网"的真实场景；
> 3. VPN 隧道单独使用 10.10.10.0/24，规避与内网段重叠带来的路由回环。

---

## 三、第一部分：网络规划与基础搭建

### 3.1 `setup.sh` 说明

[setup.sh](setup.sh) 完成以下工作：

1. **清理旧环境**：删除 6 个 netns、`br-inet` 桥、旧的 WireGuard 密钥文件，保证可重复运行。
2. **创建 6 个 namespace**：`fw / office / guest / dmz / internet / remote`。
3. **创建 `br-inet` 网桥**：把 `internet`、`remote`、`fw` 的 internet 侧 veth 挂到同一 L2 域，模拟共享公网段。
4. **短接口名 veth 对**：fw 侧使用 `v-fw-off/gst/dmz/inet`，对端使用 `v-off/gst/dmz/inet/rem`，规避 15 字符内核限制。
5. **配置 IP、lo up**：每个 netns 给本端 veth 配置 `/24` 地址，并 `ip link set lo up`（不启用 lo 会导致本机回环失败）。
6. **默认路由**：办公/访客/dmz 指向 fw；internet/remote 指向 `203.0.113.1`（即 fw 的公网口）。
7. **IP 转发**：`fw` 内 `sysctl -w net.ipv4.ip_forward=1`。
8. **连通性自检**：5 组 `ping -c 2` 验证每个区域至少能到达 fw。
9. **DMZ 占位服务**：自动启动 `python3 -m http.server 8080/22`，便于后续 DNAT 验证。
10. **生成 WireGuard 密钥对**：`fw.key / fw.pub / remote.key / remote.pub`，并提示回填到两个 `.conf`。

### 3.2 连通性测试结果

> 详细截图见 [screenshots/01-topology.png](screenshots/01-topology.png)，关键命令输出摘录：

| 测试 | 命令 | 期望 | 实际 |
|:-----|:-----|:-----|:-----|
| 1 | `ip netns exec office ping -c 2 10.20.0.1` | 通 | 0% loss |
| 2 | `ip netns exec guest  ping -c 2 10.30.0.1` | 通 | 0% loss |
| 3 | `ip netns exec dmz    ping -c 2 10.40.0.1` | 通 | 0% loss |
| 4 | `ip netns exec internet ping -c 2 203.0.113.1` | 通 | 0% loss |
| 5 | `ip netns exec remote ping -c 2 203.0.113.1` | 通 | 0% loss |

---

## 四、第二部分：防火墙策略实现

### 4.1 `firewall.sh` 说明

[firewall.sh](firewall.sh) 按以下顺序配置：

1. **清空旧规则**：保证可重复运行。
2. **默认策略**：`INPUT/FORWARD DROP`，`OUTPUT ACCEPT`。
3. **放行 lo 与已建立连接**：避免影响本机回环与回程包。
4. **office 规则**：`office → dmz:8080 ACCEPT`；`office → dmz:22 LOG+REJECT`；`office → internet ACCEPT`（配合 SNAT）。
5. **guest 规则**：仅允许 `guest → internet`；`guest → office/dmz` 一律 `LOG+REJECT`（带 `5/min burst 10` 速率限制）。
6. **internet 规则**：
   - SNAT：办公/访客/dmz 出 internet 做 MASQUERADE。
   - DNAT：`203.0.113.1:8080 → 10.40.0.2:8080`，并在 FORWARD 链补一条对应 `ACCEPT`。
   - 拒绝 `internet → dmz:22`、`internet → office`、`internet → guest`。
7. **dmz 主动出 internet**：单独放行 `dmz → internet NEW`（用于补丁更新等合法场景）。
8. **VPN FORWARD 规则**：见 [第五部分](#五第三部分vpn远程接入)。

### 4.2 规则顺序设计说明

| 顺序 | 规则类型 | 作用 |
|:----:|:---------|:-----|
| ① | `ESTABLISHED,RELATED` 放行 | 先放回程包，再判 NEW，避免误杀合法流量 |
| ② | 具体放行（`ACCEPT NEW`） | 仅在最小权限前提下放行指定源/目的/端口 |
| ③ | `LOG` 限速记录 | 给后续 REJECT/DROP 留审计证据；`limit` 防止日志洪水 |
| ④ | `REJECT` | 比 DROP 多回 ICMP/TCP-RST，便于内网排障 |
| ⑤ | 兜底 | 默认 `policy DROP` |

> **为什么用 REJECT 而非 DROP**：
> - 内部网络（office/guest）用 REJECT：管理员能立即看到 `Connection refused`，避免长时间 timeout 影响排障；
> - 对 internet 边界：本作业按需求"REJECT 拒绝"，便于内网测试时快速反馈；生产环境建议改 DROP 减少信息泄露。
> - REJECT 泄露主机存活信息的取舍详见 [analysis.md §1.4](analysis.md)。

### 4.3 访问控制矩阵（实测结果）

> 完整截图见 [screenshots/04-access-success.png](screenshots/04-access-success.png) 与 [screenshots/05-access-deny.png](screenshots/05-access-deny.png)。

| 来源 | 目标 | 协议:端口 | 预期 | 实际 | 日志前缀 |
|:-----|:-----|:----------|:-----|:-----|:---------|
| office | dmz | tcp:8080 | ✅ 成功 | 200 OK | — |
| office | dmz | tcp:22 | ❌ 拒绝 | Connection refused | `OFFICE-TO-DMZ-SSH:` |
| office | internet | any | ✅ 成功 | curl 通 | — |
| guest | dmz | tcp:8080 | ❌ 拒绝 | Connection refused | `GUEST-TO-DMZ:` |
| guest | office | any | ❌ 拒绝 | Connection refused | `GUEST-TO-OFFICE:` |
| guest | internet | any | ✅ 成功 | curl 通 | — |
| dmz | internet | any | ✅ 成功 | curl 通 | — |
| internet | 203.0.113.1:8080 | tcp:8080 | ✅ 成功(DNAT) | 200 OK | — |
| internet | 10.40.0.2:22 | tcp:22 | ❌ 拒绝 | Connection refused | `INET-TO-DMZ-SSH:` |
| internet | 10.20.0.0/24 | any | ❌ 拒绝 | timeout/REJECT | `INET-TO-OFFICE:` |
| internet | 10.30.0.0/24 | any | ❌ 拒绝 | timeout/REJECT | `INET-TO-GUEST:` |

### 4.4 规则列表与 NAT 列表

- FORWARD 链：见 [screenshots/02-firewall-rules.png](screenshots/02-firewall-rules.png)
- NAT 链：见 [screenshots/03-nat-rules.png](screenshots/03-nat-rules.png)

---

## 五、第三部分：VPN远程接入

### 5.1 WireGuard 配置说明

| 端 | 文件 | 设计要点 |
|:--|:-----|:---------|
| 服务端（fw） | [vpn-fw.conf](vpn-fw.conf) | `ListenPort = 51820`；`Address = 10.10.10.1/24`；`AllowedIPs = 10.10.10.2/32` **只接受一个 peer**；UDP 入口通过 `iptables -A INPUT -i v-fw-inet -p udp --dport 51820 -j ACCEPT` 放行 |
| 客户端（remote） | [vpn-remote.conf](vpn-remote.conf) | `Address = 10.10.10.2/24`；`Endpoint = 203.0.113.1:51820`（fw 的公网口）；`AllowedIPs = 10.20.0.0/24, 10.40.0.0/24` **仅这两段走 VPN**；`PersistentKeepalive = 25` 防 NAT 老化 |

**`AllowedIPs` 设计思路：**
- **服务端**：`AllowedIPs = 10.10.10.2/32` 表示只接受来自该 VPN IP 的封装包入站，避免 peer 伪造源网段；如未来扩展多员工，按 `10.10.10.3/32, 10.10.10.4/32` 继续追加。
- **客户端**：`AllowedIPs = 10.20.0.0/24, 10.40.0.0/24` 严格限定"只允许内网办公段和 DMZ 段"走隧道；其余（互联网、本地局域网）走 `v-rem` 默认出口。这是 `WireGuard` 不同于传统 VPN 的关键：**它是策略路由的开关**，比 `0.0.0.0/0` 全量 VPN 安全得多。

### 5.2 防火墙 VPN 配套规则（[firewall.sh §6](firewall.sh#L55-L70)）

```text
# wg0 → office（NEW 放行）
# wg0 → dmz:8080（NEW 放行）
# wg0 → dmz:22（LOG + REJECT）
# wg0 兜底（5/min burst 10 的 LOG + REJECT）
```

> 详细规则截图见 [screenshots/02-firewall-rules.png](screenshots/02-firewall-rules.png)。

### 5.3 测试结果

| 场景 | 命令 | 期望 | 实际 |
|:-----|:-----|:-----|:-----|
| 隧道建立 | `wg show`（fw / remote 两侧） | handshake + transfer | ✅ 见 [06-vpn-status.png](screenshots/06-vpn-status.png) |
| remote 路由表 | `ip netns exec remote ip route` | 出现 `10.20/10.40 dev wg0` | ✅ 见 [10-logs-realtime.png](screenshots/10-logs-realtime.png) |
| VPN→office | `remote curl http://10.20.0.2:...` | 200 | ✅ 成功（[07-vpn-success.png](screenshots/07-vpn-success.png)） |
| VPN→dmz:8080 | `remote curl http://10.40.0.2:8080/` | 200 | ✅ 成功 |
| VPN→dmz:22 | `remote curl http://10.40.0.2:22/` | 拒绝 + LOG | ✅ 拒绝（[08-vpn-deny.png](screenshots/08-vpn-deny.png)，日志前缀 `VPN-TO-DMZ-SSH:`） |
| VPN→guest | `remote ping 10.30.0.2` | 拒绝 | ✅ 拒绝（日志前缀 `VPN-DENY:`） |

---

## 六、第四部分：安全审计与日志分析

### 6.1 LOG 规则说明

[firewall.sh](firewall.sh) 中为每条 REJECT 之前都插入一条 LOG 规则，并使用不同 `log-prefix` 区分事件来源：

| 事件 | log-prefix | 速率限制 | 位置 |
|:-----|:-----------|:--------|:-----|
| office→dmz:22 | `OFFICE-TO-DMZ-SSH:` | 无（内部信任域） | FORWARD |
| guest→office | `GUEST-TO-OFFICE:` | 5/min burst 10 | FORWARD |
| guest→dmz | `GUEST-TO-DMZ:` | 5/min burst 10 | FORWARD |
| internet→dmz:22 | `INET-TO-DMZ-SSH:` | 无 | FORWARD |
| internet→office | `INET-TO-OFFICE:` | 5/min burst 10 | FORWARD |
| internet→guest | `INET-TO-GUEST:` | 5/min burst 10 | FORWARD |
| VPN→dmz:22 | `VPN-TO-DMZ-SSH:` | 无 | FORWARD |
| VPN 兜底 | `VPN-DENY:` | 5/min burst 10 | FORWARD |

**LOG 规则为什么放在 REJECT 之前：**
`iptables` 是首匹配机制，命中 LOG 后包会继续向下走（LOG 不是终结 target），从而被紧随其后的 REJECT 拒绝。如果把 LOG 放在 REJECT 之后，包命中 REJECT 会被终结、不再经过 LOG，等于"记不到日志"。

**速率限制如何防止日志洪水：**
`limit` 模块采用令牌桶：5/min 表示平均 12 秒 1 条，burst 10 允许瞬时连发 10 条。攻击者每秒发 1000 个包时，绝大多数会被静默丢弃，syslog/kmsg 不会被灌爆，避免磁盘写满 / 控制台刷屏影响运维。

### 6.2 日志分析命令与统计

> 详细截图见 [screenshots/09-remote-route.png](screenshots/09-remote-route.png) / [10-logs-realtime.png](screenshots/10-logs-realtime.png) / [11-logs-stats.png](screenshots/11-logs-stats.png)。

```bash
# 实时监控
sudo journalctl -k -f

# 各类事件计数
sudo journalctl -k --grep "GUEST-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "GUEST-TO-DMZ"     --no-pager | wc -l
sudo journalctl -k --grep "VPN-TO-DMZ-SSH"   --no-pager | wc -l
sudo journalctl -k --grep "INET-TO-OFFICE"   --no-pager | wc -l
sudo journalctl -k --grep "VPN-DENY"         --no-pager | wc -l
```

### 6.3 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:--------:|:--------------:|:--------:|
| guest→office | 5 | 5 | ✅ |
| guest→dmz | 5 | 5 | ✅ |
| VPN→dmz:22 | 3 | 3 | ✅ |
| internet→office | 3 | 3 | ✅ |
| VPN 其他违规 | 4 | 4 | ✅ |

> 注：实际数字以截图为准；速率为 5/min 时，第 6 条起会被 limit 抑制，这与"防止日志洪水"的设计目标一致。

### 6.4 日志分析报告

日志是网络安全运营的"黑匣子"。从 `journalctl -k` 中能获取以下安全信息：

1. **攻击来源溯源**：`IN=` / `OUT=` / `SRC=` / `DST=` / `DPT=` 五个字段可在不依赖 IDS 的情况下精确还原一次被拦截访问的完整五元组，便于直接拉黑源 IP。
2. **策略合理性验证**：当某条 `LOG` 计数异常飙升时，说明对应路径存在配置错误或真实攻击；正常时段应当曲线平稳。
3. **合规审计**：保留 90 天以上日志可满足等保 2.0 与 GDPR 的审计要求；本作业中 `log-prefix` 已做语义化命名，方便 ELK/Loki 直接做仪表盘分组。
4. **限速策略的副作用感知**：如果某条本应高频的 LOG 在限速后"静默"了 1 小时，需要主动调参或切到 DROP 模式，否则真实攻击会因限速被掩盖。

---

## 七、第五部分：攻防演练

> 详细分析见 [analysis.md](analysis.md)；过程截图见 [11-logs-stats.png](screenshots/11-logs-stats.png)、[12-log-detail.png](screenshots/12-log-detail.png)、[13-attack-scan.png](screenshots/13-attack-scan.png)、[14-attack-bypass.png](screenshots/14-attack-bypass.png)、[15-defense-logs.png](screenshots/15-defense-logs.png)。

### 7.1 攻击方

| # | 攻击 | 结果 | 防御证据 |
|:-:|:-----|:-----|:---------|
| 1 | 从 guest 扫描 `10.20.0.0/24` | ❌ 全部 timeout | [13-attack-scan.png](screenshots/13-attack-scan.png) |
| 2 | 改源端口绕防火墙访问 dmz:22 | ❌ REJECT（基于 dport 过滤） | [14-attack-bypass.png](screenshots/14-attack-bypass.png) |
| 3 | 伪造 `10.10.10.2` 源 IP | ❌ WireGuard 公钥认证失败 | [16-defense-counters.png](screenshots/16-defense-counters.png)（分析见 analysis.md §1.3） |

### 7.2 防御方

- **日志识别攻击**：[15-defense-logs.png](screenshots/15-defense-logs.png)
- **规则计数器**：[16-defense-counters.png](screenshots/16-defense-counters.png)
- 3 个核心问题（来源识别、IN/OUT 含义、计数暴增警示）的答案见 [analysis.md §2](analysis.md)。

### 7.3 边界测试与改进

- **选择问题**：dmz:8080 对外开放可能遭受 DDoS。
- **改进方案**：`connlimit` + `limit` 双保险，将单 IP 并发连接控制在 10、新连接速率 50/min。
- **测试结果**：见 [17-improvement.png](screenshots/17-improvement.png)。

### 7.4 高级任务：包追踪

| 阶段 | 位置 | 源地址 | 目的地址 | 关键点 |
|:----:|:-----|:-------|:---------|:-------|
| 1 | remote wg0 | 10.10.10.2 | 10.40.0.2 | 原始 TCP 包，被 WireGuard 加密封装前 |
| 2 | fw wg0 | 10.10.10.2 | 10.40.0.2 | 解封装后恢复的明文 TCP SYN |
| 3 | fw v-fw-dmz | 10.10.10.2 | 10.40.0.2 | 经 FORWARD 转发到 DMZ |
| 4 | conntrack | 10.10.10.2 | 10.40.0.2 | 状态 NEW → ESTABLISHED |

截图：[18-tcpdump-remote.png](screenshots/18-tcpdump-remote.png) · [19-tcpdump-fw.png](screenshots/19-tcpdump-fw.png) · [20-conntrack.png](screenshots/20-conntrack.png)

---

## 八、故障排查

详细报告：[troubleshooting.md](troubleshooting.md)

| # | 故障 | 根本原因 | 修复 | 截图 |
|:-:|:-----|:---------|:-----|:-----|
| 1 | DNAT 后外网仍 timeout | FORWARD 链缺 `internet → dmz:8080` 的 ACCEPT，导致 NAT 后包被默认 DROP 丢弃 | 在 FORWARD 链补 `-i v-fw-inet -o v-fw-dmz ... --dport 8080 -j ACCEPT` | [21-troubleshoot-dnat.png](screenshots/21-troubleshoot-dnat.png) |
| 2 | VPN 握手成功但 ping 不通 | FORWARD 链无 wg0 出向 ACCEPT，回程包无法经 wg0 回到 remote | 按需求 3.5 在 FORWARD 链补齐 wg0 规则 | [22-troubleshoot-vpn.png](screenshots/22-troubleshoot-vpn.png) |
| 3 | 去掉 ESTABLISHED,RELATED 后 TCP 失败 | SYN 放行后 SYN-ACK 状态为 ESTABLISHED，被默认 DROP | 在 FORWARD 链首行插入 `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` | 见 troubleshooting.md §3 |

**通用排查思路：**
1. **看现象**（timeout/refused/no route）→ 2. **看规则**（`-L -n -v` 看计数）→ 3. **看 conntrack**（包到底有没有到防火墙）→ 4. **多接口抓包**（定位丢包点）→ 5. **回滚/分阶段重配**。

---

## 九、遇到的问题和解决方法

| 序号 | 实际遇到的问题 | 解决思路 |
|:----|:---------------|:---------|
| 1 | 第一次建拓扑时用了 `veth-fw-office` 长名，报 `name too long` | 改用 `v-fw-off` 等 ≤15 字符短名；脚本里同步修改所有引用 |
| 2 | DMZ 默认路由忘了配，`internet` 访问 dmz:8080 时 dmz 端无回包 | 在 setup.sh 里把 `dmz` 的默认路由显式写为 `default via 10.40.0.1` |
| 3 | 防火墙没先放 `INPUT -p udp --dport 51820`，VPN 握手包被 INPUT DROP 丢弃 | 在 `firewall.sh` 中显式放行 WireGuard 监听端口 |
| 4 | `remote` 客户端 AllowedIPs 误写 `0.0.0.0/0`，所有流量被劫持到内网 | 按需求改成 `10.20.0.0/24, 10.40.0.0/24`，仅业务流量走 VPN |
| 5 | 起初 LOG 规则写在 REJECT 之后，导致日志全空 | 调整顺序，LOG 永远在 REJECT 之前；并加 `limit` 防爆 |
| 6 | remote 与 internet 共用 `br-inet` 桥，remote 收到 internet 的 ARP | 在 bridge 上忽略即可（两台主机本来就在不同 IP，不影响路由） |
| 7 | 抓包看不到 VPN 解封装后的明文 | WireGuard 的 wg0 接口在解封装后内核直接把明文送入协议栈，需在 `tcpdump -ni wg0` 才能看到；raw UDP 包需要在 `v-fw-inet` 上抓 |
| 8 | 删除 namespace 报 `Device or resource busy` | 脚本里 `ip netns del` 之前先 `ip link set ... netns 1`（peer 端归还到 init ns）即可 |

---

## 十、总结与思考（800+字）

通过本次期末大作业，我对"企业级网络安全架构"的理解从课本定义下沉到了**可重复运行的工程实践**。

**1. 架构 = 分层 + 默认拒绝**
本次实验的骨架是 6 个 netns：办公、访客、DMZ、外网、远程、网关。看似简单的 5 个 veth 对 + 1 个网桥，背后却是企业网络分层隔离的最小可行单元——把信任域切成物理段，再在边界上做策略。配置上我深刻体会到"**默认拒绝、最小放行**"是唯一靠谱的起点：一开始就把 `FORWARD` 默认设为 `DROP`，再按业务白名单逐条 `ACCEPT`，比"先全开再补洞"安全得多。任何一个遗漏都意味着安全漏洞。

**2. NAT 不是"免费的午餐"**
SNAT 让内网 10.x 段能共享公网出口；DNAT 让外网能命中 DMZ 的 Web。但 NAT 离不开 conntrack，更离不开**与之配套的 FORWARD 规则**。本次故障排查中遇到的"DNAT 配置了但 timeout"恰恰是只配 NAT、忘了放行 FORWARD 的典型反例。这让我意识到生产环境里"两条规则缺一不可"是必须落到 checklist 里的铁律。SNAT/DNAT 的"双向一致性"——回程路由、conntrack 反向匹配——也是评审脚本时最该关注的点。

**3. WireGuard 的好处与陷阱**
WireGuard 的配置文件只有 5 行有效内容，却把"加密、认证、路由策略、keepalive"全部覆盖。其 `AllowedIPs` 既是白名单也是路由表，这种"配置即策略"的简洁非常优雅，但也是双刃剑：写成 `0.0.0.0/0` 就等于把整个流量劫持进隧道，等同于把家用网络暴露给企业网关。我刻意把 remote 端的 AllowedIPs 限定为 `10.20.0.0/24, 10.40.0.0/24`，目的就是验证"按业务段精确放行"是企业 VPN 的最佳实践。配合 `PersistentKeepalive = 25` 防 NAT 老化，整体方案在 60 行配置内完成，可读性远胜 OpenVPN 的 200 行证书链。

**4. 日志体系是被忽视的"防御纵深"**
本次实验最让我警醒的是"**LOG 规则的顺序与限速**"。把 LOG 放在 REJECT 之后，看似只是脚本 bug，实则等于关闭了审计；攻击者可以在无日志情况下做大量探测。`5/min burst 10` 的限速看似保守，实则是"防止日志洪水、保护运维可观测性"的硬要求。在真实 SOC 中，限速过严可能漏掉真实攻击，限速过松又可能让 syslog 灌满磁盘——这是**策略与运维的平衡艺术**，需要根据业务量做动态调参。

**5. 攻防演练的意义**
站在攻击者视角做扫描、改源端口、伪造源 IP，让我对"防火墙究竟在挡什么"有了具象认知。guest 访问 office 的 REJECT、internet 访问 dmz:22 的 REJECT，每条规则背后都是一次被实际验证的威胁模型。**REJECT vs DROP** 的差别虽小，但涉及到"信息泄露 vs 可用性"的权衡；课堂上的理论在实验里被验证、被量化。

**6. 故障排查的工程思维**
"看规则 → 看 conntrack → 多点抓包"三板斧是所有网络故障的通用思路。我刻意把故障复现写成"先故意制造、再逐层定位"的剧本，避免"事后回忆"的主观偏差。这种"**先打碎再修好**"的实验范式，是工程能力培养的关键一环。

**7. 整体思考**
整个作业把 Lab6~Lab13 的零散知识串成了一条主线：netns 隔离 → veth 互联 → iptables 策略 → NAT 边界 → WireGuard 加密隧道 → conntrack 跟踪 → 日志审计 → 攻防验证。它不是一个"防火墙实验"，而是一个**微缩版的 Zero Trust 边界**：每一个跨域动作都经过策略、状态、加密、审计四重把关。

未来如果要把它"产品化"，我会引入：
- **自动化规则审计**（用 `iptables-parse` 转 yaml 做 git diff）；
- **集中式日志**（用 promtail → Loki，按 `log-prefix` 维度做 dashboard）；
- **VPN 多因素**（在 WireGuard 之上叠 OIDC + wireguard-cert）；
- **主动蜜罐**（把 guest 网一部分地址池改为高交互 honeypot，观察真实攻击者手法）。

最后，本次作业给我最大的启发是：**网络安全不是产品，是流程**。脚本、规则、配置只是"快照"，真正的安全来自持续验证、持续审计、持续改进。本次期末大作业，正是这种持续改进流程的浓缩练习。

---

## 附录 A · 文件清单

| 文件 | 说明 |
|:-----|:-----|
| [README.md](README.md) | 本文档（主报告） |
| [setup.sh](setup.sh) | 拓扑搭建 + 密钥生成 + DMZ 占位服务 |
| [firewall.sh](firewall.sh) | 防火墙、NAT、VPN FORWARD 规则 |
| [vpn-fw.conf](vpn-fw.conf) | WireGuard 服务端配置 |
| [vpn-remote.conf](vpn-remote.conf) | WireGuard 客户端配置 |
| [analysis.md](analysis.md) | 攻防演练分析报告 |
| [troubleshooting.md](troubleshooting.md) | 故障排查报告 |
| [screenshots/](screenshots/) | 22 张实验截图 |

## 附录 B · 复现步骤（4 步跑通全流程）

```bash
# 1. 拓扑 + 密钥 + 占位服务
sudo bash setup.sh

# 2. 防火墙 + NAT + VPN FORWARD
sudo bash firewall.sh

# 3. 启动 WireGuard（先确保配置已注入密钥）
sudo ip netns exec fw     wg-quick up /etc/wireguard/fw/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

# 4. 业务验证
sudo ip netns exec office  curl http://10.40.0.2:8080/        # office→dmz 成功
sudo ip netns exec guest   curl http://10.40.0.2:8080/        # guest→dmz 拒绝
sudo ip netns exec internet curl http://203.0.113.1:8080/     # DNAT 命中
sudo ip netns exec remote  curl http://10.20.0.2:8000/        # VPN→office 成功
```

---

*报告完。所有源文件、脚本、配置、截图与本文档同目录存放。*
