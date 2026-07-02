# 企业级网络安全架构搭建与攻防演练

## 一、实验环境

- **操作系统**：Ubuntu 22.04 LTS（Linux 内核 5.15+）
- **WireGuard 版本**：1.0.0（wg 工具 v1.0.20210914）
- **iptables 版本**：iptables v1.8.7（nf_tables 后端）
- **主要工具**：`iproute2`、`iptables`、`wireguard-tools`、`tcpdump`、`conntrack`、`journalctl`
- **实验形式**：使用 Linux Network Namespace 在单机上模拟多区域企业网络

## 二、拓扑图和地址规划

## 网络拓扑

![](topology.png)

### 节点说明

| 节点 | 角色 | 必须实现的功能 |
|:-----|:-----|:--------------|
| `fw` | 防火墙 + VPN 网关 | 5 个网络接口、IP 转发、FORWARD 规则、NAT、WireGuard |
| `office` | 办公网主机 | 模拟内网员工 |
| `guest` | 访客网主机 | 模拟访客设备 |
| `dmz` | 对外服务器 | 运行 Web 服务（8080）和管理服务（22） |
| `internet` | 外网主机 | 模拟互联网用户 |
| `remote` | 远程员工 | 通过 VPN 接入 |

### 地址规划表

| 区域 | 网段 | fw 侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ 区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| internet | 203.0.113.0/24 | — | 203.0.113.20 | remote 公网地址 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN 隧道 |

### 接口与 veth 对应关系

| fw 侧接口 | 对端 namespace | 对端接口 | 说明 |
|:----------|:--------------|:---------|:-----|
| veth-fw-office | office | veth-office | 办公网连接 |
| veth-fw-guest | guest | veth-guest | 访客网连接 |
| veth-fw-dmz | dmz | veth-dmz | DMZ 连接 |
| veth-fw-inet | internet | veth-inet | 外网连接 |
| wg0 | remote | wg0 | VPN 隧道 |

详细的拓扑说明和搭建步骤见 `topology_description.md`，地址规划详情见 `address_plan.md`。

## 三、第一部分：网络规划与基础搭建

### 搭建脚本

本实验使用 `setup.sh` 完成所有基础网络搭建，包括创建 namespace、veth pair、配置 IP 地址、路由、WireGuard 密钥以及启动 VPN 隧道。脚本采用 `set -e` 保证可重复运行，并在开头清理旧环境。

主要步骤：

1. 创建并清理 6 个 namespace：fw、office、guest、dmz、internet、remote。
2. 创建 veth pair 连接 fw 与各区域。
3. 在 internet namespace 中创建 bridge，模拟互联网交换机，连接 fw 和 remote 的外网接口。
4. 生成 WireGuard 公私钥，分别写入 fw 和 remote 的配置文件。
5. 配置各区域默认路由指向 fw。
6. 在 fw 上开启 IP 转发。
7. 启动 WireGuard 隧道。

详见 `setup.sh`。

### 验证结果

```bash
sudo ip netns exec office ping -c 2 10.20.0.1
sudo ip netns exec guest ping -c 2 10.30.0.1
sudo ip netns exec dmz ping -c 2 10.40.0.1
sudo ip netns exec internet ping -c 2 203.0.113.1
sudo ip netns exec remote ping -c 2 203.0.113.1
```

所有节点均能与 fw 的对应接口通信，基础拓扑搭建成功。截图见 `screenshots/01-topology.png`。

## 四、第二部分：防火墙策略实现

### 防火墙设计原则

- **默认拒绝**：`FORWARD` 链默认策略为 `DROP`。
- **最小权限**：只放行明确需要的访问，不使用过宽网段。
- **状态检测优先**：先放行 `ESTABLISHED,RELATED` 连接。
- **先记录后拒绝**：所有 `REJECT` 规则前都有对应的 `LOG` 规则。
- **区域隔离**：基于接口方向严格区分 office、guest、dmz、internet、VPN 区域。

### 规则设计说明

- **规则顺序**：`FORWARD` 链顶部优先放行 `ESTABLISHED,RELATED` 连接，确保已建立会话的双向流量不受后续规则影响；随后放置具体的区域放行规则（如 office→dmz:8080、VPN→office 等）；最后按区域放置 LOG/REJECT 规则，并在每一条 REJECT 之前插入对应的 LOG 规则。
- **REJECT vs DROP**：本实验对被拒绝的跨区访问使用 `REJECT`。`REJECT` 会返回 ICMP 错误报文，对合法用户更友好（能立即知道连接被策略拒绝），也方便攻击方测试时快速判断命中了策略。`DROP` 则静默丢弃，隐蔽性更强，但会让连接一直挂起直到超时。由于本实验以审计和演示为主要目的，且所有 REJECT 前都有 LOG，故统一使用 REJECT；在真实互联网入口面对扫描时可酌情使用 DROP。

### 访问控制矩阵

| 源区域 | 目标区域 | 允许/拒绝 | 备注 |
|:------|:--------|:---------|:-----|
| office | dmz:8080 | 允许 | 办公网访问 DMZ 的 Web 服务 |
| office | dmz:22 | 拒绝 + LOG | 禁止办公网 SSH 到 DMZ |
| office | internet | 允许 | 办公网可访问外网（SNAT） |
| guest | internet | 允许 | 访客只能上网 |
| guest | office | 拒绝 + LOG | 访客不能访问办公网 |
| guest | dmz | 拒绝 + LOG | 访客不能访问 DMZ |
| dmz | internet | 允许 | DMZ 可以访问外网（如更新） |
| internet | dmz:8080 | 允许（DNAT） | 外网可访问 DMZ 的 Web |
| internet | dmz:22 | 拒绝 | 外网不能 SSH 到 DMZ |
| internet | office | 拒绝 + LOG | 外网不能访问内网 |
| internet | guest | 拒绝 + LOG | 外网不能访问访客网 |
| VPN | office | 允许 | 远程员工访问办公网 |
| VPN | dmz:8080 | 允许 | 远程员工访问 DMZ 的 Web |
| VPN | dmz:22 | 拒绝 + LOG | 禁止远程 SSH 到 DMZ |
| VPN | guest | 拒绝 + LOG | 禁止访问访客网 |

### 访问测试矩阵

| 来源 | 目标 | 预期结果 | 实际结果 |
|:-----|:-----|:---------|:---------|
| office | dmz:8080 | 成功 | 成功 |
| office | dmz:22 | 失败 + LOG | 失败 |
| guest | office:任意 | 失败 + LOG | 失败 |
| guest | dmz:8080 | 失败 + LOG | 失败 |
| guest | internet:任意 | 成功 | 成功 |
| office | internet:任意 | 成功 | 成功 |
| internet | fw 公网 IP:8080 | 成功（DNAT 到 dmz） | 成功 |
| internet | dmz:22 | 失败 | 失败 |
| VPN | office | 成功 | 成功 |
| VPN | dmz:8080 | 成功 | 成功 |
| VPN | dmz:22 | 失败 + LOG | 失败 |
| VPN | guest | 失败 + LOG | 失败 |

详细的防火墙规则说明见 `firewall_design_description.md`，测试矩阵见 `access_test_matrix.md`，完整规则见 `firewall.sh`。

### NAT 配置

- **SNAT**：对 office、guest、dmz 访问 internet 的流量做 `MASQUERADE`。
- **DNAT**：将 `203.0.113.1:8080` 映射到 `10.40.0.2:8080`，并配置对应的 FORWARD 放行规则。

## 五、第三部分：VPN 远程接入

### WireGuard 配置

`setup.sh` 在搭建过程中会自动生成 WireGuard 密钥对并分别写入 `/etc/wireguard/fw/wg0.conf` 和 `/etc/wireguard/remote/wg0.conf`，同时拷贝到项目目录下作为 `vpn-fw.conf` 和 `vpn-remote.conf`。

**fw 端配置（vpn-fw.conf）：**

```ini
[Interface]
Address = 10.10.10.1/24
PrivateKey = <FW_PRIVATE_KEY>
ListenPort = 51820

[Peer]
PublicKey = <REMOTE_PUBLIC_KEY>
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
```

**remote 端配置（vpn-remote.conf）：**

```ini
[Interface]
Address = 10.10.10.2/24
PrivateKey = <REMOTE_PRIVATE_KEY>

[Peer]
PublicKey = <FW_PUBLIC_KEY>
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
```

### AllowedIPs 设计说明

- **fw 端 `AllowedIPs = 10.10.10.2/32`**：只接受 remote 的 VPN 地址，防止其他源伪造 VPN 地址。
- **remote 端 `AllowedIPs = 10.20.0.0/24,10.40.0.0/24`**：仅访问办公网和 DMZ 时走 VPN，避免所有流量都经过 VPN。

### 验证结果

隧道状态：

```bash
sudo ip netns exec fw wg show
sudo ip netns exec remote wg show
```

路由表（remote 上能看到 VPN 相关路由）：

```bash
sudo ip netns exec remote ip route
```

成功访问（3 个）：

```bash
sudo ip netns exec remote ping -c 2 10.20.0.2
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
```

失败访问（3 个）：

```bash
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:22/
sudo ip netns exec remote ping -c 2 10.30.0.2
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:3306/
```

`wg show` 显示 `latest handshake` 和 `transfer` 计数正常，VPN 访问测试通过，未授权访问被日志记录并拒绝。截图见 `screenshots/06-vpn-status.png`、`screenshots/07-vpn-success.png` 和 `screenshots/08-vpn-deny.png`。

详细的 VPN 配置说明见 `vpn_config_description.md`。

## 六、第四部分：安全审计与日志分析

### LOG 规则配置

为所有 REJECT 规则配置了对应的 LOG 规则，使用不同的 `log-prefix` 区分事件类型：

| 事件类型 | log-prefix | 速率限制 |
|:--------|:-----------|:---------|
| guest 访问 office | `GUEST-TO-OFFICE:` | 5/min burst 10 |
| guest 访问 dmz | `GUEST-TO-DMZ:` | 5/min burst 10 |
| office 访问 dmz:22 | `OFFICE-TO-DMZ-SSH:` | 5/min burst 10 |
| VPN 访问 dmz:22 | `VPN-TO-DMZ-SSH:` | 无限制 |
| internet 访问内网 | `INET-TO-OFFICE:` | 5/min burst 10 |
| internet 访问访客网 | `INET-TO-GUEST:` | 5/min burst 10 |
| 其他 VPN 违规 | `VPN-DENY:` | 5/min burst 10 |

### 违规场景模拟

模拟了以下 5 种违规访问场景，并触发对应的日志：

1. guest 尝试访问 office：`curl http://10.20.0.2:8000/`
2. guest 尝试访问 dmz：`curl http://10.40.0.2:8080/`
3. remote 尝试访问 dmz:22：`curl http://10.40.0.2:22/`
4. internet 尝试直接访问 office：`curl http://10.20.0.2:8000/`
5. internet 尝试访问 dmz 的未映射端口：`curl http://203.0.113.1:3306/`

### 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest → office | 1 | 1 | 是 |
| guest → dmz | 1 | 1 | 是 |
| VPN → dmz:22 | 1 | 1 | 是 |
| internet → office | 1 | 1 | 是 |
| VPN 其他违规 | 0 | 0 | 是 |

### 日志分析报告

iptables 的 LOG 目标会为命中规则的数据包生成内核日志，这些日志包含丰富的安全字段：源地址 `SRC`、目的地址 `DST`、源端口 `SPT`、目的端口 `DPT`、协议类型 `PROTO`、进入接口 `IN`、离开接口 `OUT` 以及精确的内核时间戳。通过组合这些字段，可以完整还原一次连接请求的路径：它从哪个区域进入防火墙、想访问哪个区域的目标、使用什么协议和端口。例如，当看到 `IN=veth-fw-guest`、`OUT=veth-fw-office`、`SRC=10.30.0.2`、`DST=10.20.0.2`、`log-prefix="GUEST-TO-OFFICE:"` 时，可以立即判断这是 guest 区域对 office 区域的未授权访问尝试。

LOG 规则必须放在对应的 REJECT 规则之前。iptables 的规则链按顺序匹配，一旦命中 REJECT 目标，数据包会立即被处理并终止后续匹配。如果 LOG 规则位于 REJECT 之后，违规数据包在被记录之前就已经被丢弃，审计日志将出现缺失，从而无法追溯攻击行为。因此，本实验在每条 REJECT 规则之前都插入了对应的 LOG 规则，确保“先记录、后拒绝”。

为了防止日志洪水攻击，本实验对除关键事件外的 LOG 规则使用了 `-m limit --limit 5/min --limit-burst 10`。该参数表示平均每分钟最多记录 5 条日志，突发上限为 10 条。当遭受端口扫描、DDoS 或暴力破解时，大量连接请求不会全部写入日志，从而避免日志文件暴涨、磁盘耗尽和系统性能下降。这种速率限制是日志审计体系的一道自我保护机制。

最后，为不同违规场景设置不同的 `log-prefix`（如 `GUEST-TO-OFFICE:`、`VPN-TO-DMZ-SSH:`、`INET-TO-OFFICE:`、`VPN-DENY:`），可以方便地使用 `journalctl --grep` 进行分类检索、批量统计和告警关联。不同前缀使得在海量日志中快速定位特定事件成为可能，也便于后续通过 SIEM 或脚本进行自动化分析。

## 七、第五部分：攻防演练

攻防演练的完整过程、攻击命令、失败原因分析、防御方分析、边界测试改进方案以及高级任务（包追踪）详见 `analysis.md`。本节给出核心结论：

### 攻击方演练

| 攻击 | 结果 | 失败原因 |
|:-----|:-----|:---------|
| 从 guest 扫描 office 网段 | 失败 | 命中 `GUEST-TO-OFFICE` LOG/REJECT 规则 |
| 修改源端口访问 dmz:22 | 失败 | 防火墙基于接口方向而非源端口匹配 |
| 伪造 VPN 源地址 | 失败 | 反向路径过滤（rp_filter）和接口方向隔离 |

### 防御方分析

- 从日志的 `SRC`、`IN` 接口和 `log-prefix` 可以判断攻击来源。
- 规则计数器高说明可能存在扫描或探测行为。
- REJECT 对合法用户更友好，DROP 隐蔽性更强。

### 边界测试改进

**选择的问题及风险分析**

选择“dmz:8080 对外开放”进行防护。DMZ 的 Web 服务通过 DNAT 暴露到公网 `203.0.113.1:8080`，虽然满足了外部访问需求，但也面临被扫描、暴力破解、DDoS 或 Web 漏洞利用的风险。如果不加限制，单台攻击主机可以在短时间内建立大量并发连接，耗尽服务器资源，同时产生大量日志，影响正常业务访问。

**改进方案实现代码**

```bash
# 限制单 IP 对 dmz:8080 的并发连接数
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset

# 限制单 IP 的新建连接速率
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m limit --limit 20/min --limit-burst 30 \
  -j ACCEPT
```

第一条规则使用 `connlimit` 限制每个源 IP 对 dmz:8080 的并发 TCP 连接数不超过 10，超出部分以 TCP RST 拒绝；第二条规则使用 `limit` 限制新建连接速率，防止瞬时洪水。测试时，从 internet 使用 `ab` 或 `curl` 循环发起大量请求，可以观察到超过阈值的连接被拒绝，而正常请求仍能通过。测试效果截图见 `screenshots/15-improvement.png`。

### 高级任务：包追踪

通过 4 个位置同时抓包（remote wg0、fw wg0、fw veth-fw-dmz、fw conntrack），完整追踪了 remote 通过 VPN 访问 dmz:8080 的包变化过程，验证了 WireGuard 封装/解封装、策略转发和连接跟踪的协同工作。

## 八、故障排查

本实验记录了 3 个典型故障场景及其排查过程，详见 `troubleshooting.md`：

1. **DNAT 配置了但外网无法访问**
   - 原因：缺少 DNAT 对应的 FORWARD 放行规则。
   - 修复：添加 `-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 --dport 8080` 的 ACCEPT 规则。

2. **VPN 隧道握手正常但业务访问失败**
   - 原因 1：remote 的 `AllowedIPs` 未包含目标网段。
   - 原因 2：fw 的 FORWARD 规则缺少 VPN→dmz 的放行。
   - 原因 3：fw 未开启 IP 转发。
   - 修复：分别修正配置、添加规则、开启 IP 转发。

3. **去掉 ESTABLISHED,RELATED 后 TCP 连接失败**
   - 原因：SYN-ACK 回包被当作新连接丢弃，三次握手无法完成。
   - 修复：将状态检测规则置于 FORWARD 链最前面。

## 九、遇到的问题和解决方法

1. **WireGuard 隧道无法建立，提示公钥不匹配**
   - 问题：手动编辑配置文件时公钥填写错误。
   - 解决：使用 `setup.sh` 自动生成密钥对并写入配置，避免手动复制错误。

2. **iptables 规则可重复运行性差**
   - 问题：多次运行 firewall.sh 时规则重复追加。
   - 解决：在脚本开头使用 `-F`、`-X`、`-Z` 清空已有规则，并设置默认策略。

3. **DNAT 后外网仍无法访问 dmz:8080**
   - 问题：只配置了 DNAT，缺少 FORWARD 放行规则。
   - 解决：在 `firewall.sh` 中同时添加 DNAT 和对应的 FORWARD ACCEPT 规则。

4. **VPN 访问 dmz 成功但访问 office 失败**
   - 问题：remote 的 `AllowedIPs` 只写了 `10.40.0.0/24`，未包含 office 网段。
   - 解决：将 `AllowedIPs` 修改为 `10.20.0.0/24,10.40.0.0/24`。

5. **日志中看不到违规记录**
   - 问题：LOG 规则放在 REJECT 之后，数据包已被丢弃。
   - 解决：调整规则顺序，确保 LOG 在 REJECT 之前。

## 十、总结与思考

通过本次期末大作业，我完成了一个包含多区域隔离、防火墙策略、NAT、VPN 接入和日志审计的完整企业边界网络安全架构。整个过程涵盖了网络规划、策略实现、安全审计、攻防演练和故障排查等多个层面，使我对企业网络安全有了更系统、更深入的理解。
首先，在网络规划阶段，我深刻体会到地址规划和拓扑设计的重要性。使用独立的网段（10.20.0.0/24、10.30.0.0/24、10.40.0.0/24、203.0.113.0/24、10.10.10.0/24）能够有效避免地址冲突，清晰的区域划分也为后续的策略配置奠定了基础。Linux Network Namespace 是一种轻量且高效的实验方式，通过 veth pair 和 bridge，可以在单机上模拟出复杂的企业网络环境。
其次，防火墙策略的实现让我理解了最小权限原则和状态检测的重要性。默认拒绝（DROP）策略是安全的基础，但仅仅拒绝还不够，必须明确放行每一项合法业务。状态检测规则（ESTABLISHED,RELATED）保证了 TCP 连接的双向通信，而 NAT 则实现了内网访问外网和外网访问 DMZ 的需求。规则顺序同样关键，LOG 必须放在 REJECT 之前，否则审计日志将缺失。通过反复测试访问矩阵，我验证了每条规则的正确性，也认识到任何规则过宽（如放行 10.0.0.0/8）都可能引入安全漏洞。
第三，VPN 远程接入部分让我掌握了 WireGuard 的基本配置和 `AllowedIPs` 的设计思路。fw 端限制对端地址为 `10.10.10.2/32`，remote 端只让 `10.20.0.0/24` 和 `10.40.0.0/24` 走 VPN，这种双向精细控制既保证了业务可达，又防止了 VPN 用户访问未授权区域。同时，我也意识到 VPN 并不是有了隧道就安全，后续的 FORWARD 规则同样决定了 VPN 用户的权限边界。
第四，日志审计和攻防演练让我从防御方和攻击方两个视角理解了网络安全。日志中丰富的字段（SRC、DST、SPT、DPT、IN、OUT、PROTO）可以帮助我们快速定位攻击来源和目标；速率限制和不同的 log-prefix 则是防止日志洪水和提高分析效率的重要手段。在攻击方演练中，伪造源地址、修改源端口等尝试均告失败，说明基于接口方向的区域隔离和反向路径过滤是有效的防御机制。
最后，故障排查专题让我学会了如何系统性地定位问题。DNAT 缺少 FORWARD 规则、AllowedIPs 配置错误、缺少状态检测规则等问题，都需要通过抓包、查看 conntrack、检查路由表和规则计数器等手段逐步排查。这种由现象到原因、再到修复的思维方式，对未来解决实际网络问题非常有帮助。
总之，本次大作业不仅巩固了 iptables、NAT、WireGuard 等技术，更让我认识到企业网络安全是一个系统工程：从网络规划到策略设计，从访问控制到日志审计，从攻击防御到故障排查，每个环节都需要细致严谨。未来在实际生产环境中，还需要结合 IDS/IPS、WAF、堡垒机、SIEM 等更高级的安全设施，构建纵深防御体系。

---


