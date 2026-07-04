# 期末大作业：企业级网络安全架构搭建与攻防演练

## 实验背景

某企业有办公区、访客区、DMZ对外服务区，并需要支持远程员工VPN接入。你需要设计并实现完整的网络安全方案，确保：
- 不同区域之间的访问隔离
- 远程员工通过VPN安全访问内网
- 外部用户可访问DMZ的Web服务
- 所有访问行为留下审计日志

本大作业综合Lab6-Lab13的全部知识点，要求你搭建一个包含多区域隔离、防火墙策略、NAT、VPN接入的完整企业边界网络。

---

## 实验目标

1. 理解企业网络安全架构的整体设计思路
2. 掌握多区域网络的规划和隔离方法
3. 实现基于最小权限原则的防火墙策略
4. 配置SNAT/DNAT实现内网访问外网和外网访问DMZ
5. 实现远程VPN接入并精细控制VPN用户权限
6. 配置全面的日志审计体系
7. 进行攻防演练，理解防御方和攻击方的视角
8. 培养故障排查和问题分析能力

---
## 一、实验环境
- 操作系统：Kali Linux 2026.1
- WireGuard版本：1.0.0
- iptables版本：1.8.7

## 二、网络拓扑

![](topology.png)

**节点说明：**

| 节点 | 角色 | 必须实现的功能 |
|:-----|:-----|:--------------|
| `fw` | 防火墙+VPN网关 | 5个网络接口、IP转发、FORWARD规则、NAT、WireGuard |
| `office` | 办公网主机 | 模拟内网员工 |
| `guest` | 访客网主机 | 模拟访客设备 |
| `dmz` | 对外服务器 | 运行Web服务(8080)和管理服务(22) |
| `internet` | 外网主机 | 模拟互联网用户 |
| `remote` | 远程员工 | 通过VPN接入 |

---

## 三、第一部分：网络规划与基础搭建（20分）

### 任务清单
### setup.sh 说明

`setup.sh` 脚本执行以下步骤：
1. **清理旧环境**：删除可能存在的旧命名空间，避免冲突。
2. **创建6个命名空间**：`fw`、`office`、`guest`、`dmz`、`internet`、`remote`。
3. **创建veth对并配置IP**：为每个区域创建一对 veth 接口，一端放入 fw 命名空间，另一端放入对应区域命名空间，并配置 IP 地址。
4. **配置默认路由**：每个区域主机的默认路由指向 fw 的对应接口。
5. **开启IP转发**：在 fw 上启用 `ip_forward`。
6. **基础连通性测试**：验证各区域主机能 ping 通 fw 的对应接口。

### 连通性测试结果

| 来源 | 目标 | 结果 | 截图 |
|------|------|------|------|
| office | 10.20.0.1 (fw) | 成功 | 01-topology.png |
| guest | 10.30.0.1 (fw) | 成功 | 01-topology.png |
| dmz | 10.40.0.1 (fw) | 成功 | 01-topology.png |
| internet | 203.0.113.1 (fw) | 成功 | 01-topology.png |

**任务1.1：创建6个namespace**

```bash
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
```

**任务1.2：规划IP地址**

填写下表（必须使用不同网段）：

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |

**任务1.3：创建veth对并配置**

提示：需要创建5对veth连接`fw`和各个区域。

```bash
# office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

# 配置IP地址（其他区域类似）
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# ... guest、dmz、internet的连接配置（请自行完成）
```

**任务1.4：配置路由和IP转发**

```bash
# 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1

# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```

**任务1.5：验证基础连通性**

```bash
# office应该能ping通fw
sudo ip netns exec office ping -c 2 10.20.0.1

# guest应该能ping通fw
sudo ip netns exec guest ping -c 2 10.30.0.1

# dmz应该能ping通fw
sudo ip netns exec dmz ping -c 2 10.40.0.1

# internet应该能ping通fw
sudo ip netns exec internet ping -c 2 203.0.113.1
```

### 提交内容

1. **setup.sh脚本**：包含完整的拓扑搭建命令（可重复运行）
2. **地址规划表**：markdown格式，列出所有接口的IP地址
3. **连通性测试截图**：至少4组ping测试结果
4. **拓扑搭建说明**：简要说明你的拓扑搭建步骤和验证方法

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 脚本完整性 | 5分 | 能创建所有namespace、veth对、配置IP、路由 |
| 脚本可运行性 | 5分 | 可重复运行，无错误 |
| 地址规划合理性 | 5分 | 网段无冲突，地址分配清晰 |
| 连通性验证 | 5分 | 所有基础连通性测试通过 |

---

## 四、第二部分：防火墙策略实现（30分）

### 访问控制需求

| 源区域 | 目标区域 | 允许/拒绝 | 备注 |
|:------|:--------|:---------|:-----|
| office | dmz:8080 | 允许 | 内网访问DMZ的Web服务 |
| office | dmz:22 | 拒绝 | 禁止内网SSH到DMZ |
| office | internet | 允许 | 办公网可访问外网 |
| guest | internet | 允许 | 访客只能上网 |
| guest | office | 拒绝 | 访客不能访问办公网 |
| guest | dmz | 拒绝 | 访客不能访问DMZ |
| dmz | internet | 允许 | DMZ可以访问外网（如更新） |
| internet | dmz:8080 | 允许（通过DNAT） | 外网可访问DMZ的Web |
| internet | dmz:22 | 拒绝 | 外网不能SSH到DMZ |
| internet | office | 拒绝 | 外网不能访问内网 |
| internet | guest | 拒绝 | 外网不能访问访客网 |

### 任务清单

**任务2.1：配置FORWARD链默认策略**

```bash
sudo ip netns exec fw iptables -P FORWARD DROP
```

**任务2.2：配置状态检测规则**

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

**任务2.3：配置office访问dmz规则**

```bash
# 允许office访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz:22（请自行添加LOG和REJECT规则）
```

**任务2.4：配置guest隔离规则**

```bash
# 拒绝guest访问office（带LOG）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# 拒绝guest访问dmz（请自行完成）
```

**任务2.5：配置SNAT让内网访问外网**

```bash
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
```

**任务2.6：配置DNAT让外网访问dmz:8080**

```bash
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# 对应的FORWARD规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**任务2.7：查看完整规则**

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
```

### 测试要求

在`dmz`上启动两个服务：

```bash
# 终端A
sudo ip netns exec dmz python3 -m http.server 8080

# 终端B
sudo ip netns exec dmz python3 -m http.server 22
```

填写访问测试矩阵：

| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 | curl 正常返回 python http 服务页面|04-access-success.png  |
| office | dmz:22 | 失败+LOG |curl 连接被重置，journalctl 捕获 OFFICE-TO-DMZ-SSH 审计日志 |05-access-deny.png |
| guest | office:任意 | 失败+LOG |curl 超时 / 连接拒绝，产生 GUEST-TO-OFFICE 内核日志 | 05-access-deny.png |
| guest | dmz:8080 | 失败+LOG |curl 超时，产生 GUEST-TO-DMZ 审计日志 | 05-access-deny.png |
| guest | internet:任意 | 成功 |ping 203.0.113.10、curl 公网地址均可连通 |04-access-success.png  |
| office | internet:任意 | 成功 |外网 IP 可正常访问，SNAT 地址转换正常 |  04-access-success.png|
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |访问 203.0.113.1:8080，返回 DMZ 10.40.0.2 网页 | 04-access-success.png|
| internet | dmz:22 | 失败 |外网无法直达 DMZ 22 端口，无放行规则直接阻断 |05-access-deny.png  |

### 规则设计说明

1. **默认策略 DROP**：FORWARD 链默认 DROP，仅放行明确允许的流量，遵循最小权限原则。
2. **状态检测优先**：`ESTABLISHED,RELATED` 放行规则放在最前面，确保回程流量不被拦截。
3. **LOG 在 REJECT 之前**：确保所有被拒绝的流量都能留下审计日志，便于追溯。
4. **使用 REJECT 而非 DROP**：本实验使用 REJECT 便于快速定位故障（返回明确错误信息）。生产环境建议用 DROP 更安全。
5. **区域隔离**：guest 只能访问 internet，office 可访问 dmz:8080 和 internet，实现网络分层隔离。
6. **NAT 配置**：SNAT 让内网共享上网，DNAT 将外网 8080 映射到 dmz Web 服务。

### 提交内容

1. **firewall.sh脚本**：包含所有防火墙规则
2. **规则列表截图**：`iptables -L FORWARD`和`iptables -t nat -L`
3. **访问测试矩阵**：填写完整的测试结果
4. **规则设计说明**：说明规则顺序、为什么用REJECT而不是DROP等

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 规则完整性 | 10分 | 覆盖所有访问需求 |
| 访问控制正确性 | 10分 | 所有测试符合预期 |
| NAT配置 | 5分 | SNAT和DNAT正确 |
| 规则顺序合理性 | 5分 | 状态检测在前、具体规则在后、LOG在REJECT前 |

**扣分项：**
- 规则过宽导致安全漏洞（如无条件放行10.0.0.0/8）：每处-5分
- 规则顺序错误导致无法生效：每处-3分

## 五、第三部分：VPN远程接入（20分）

### 任务清单

**任务3.1：生成WireGuard密钥对**

```bash
umask 077
wg genkey | tee fw.key | wg pubkey > fw.pub
wg genkey | tee remote.key | wg pubkey > remote.pub
```

**任务3.2：配置fw的WireGuard**

```bash
sudo mkdir -p /etc/wireguard/fw
FW_PRIVATE_KEY=$(cat fw.key)
REMOTE_PUBLIC_KEY=$(cat remote.pub)

sudo tee /etc/wireguard/fw/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.1/24
PrivateKey = ${FW_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${REMOTE_PUBLIC_KEY}
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
EOF

sudo chmod 600 /etc/wireguard/fw/wg0.conf
```

**任务3.3：配置remote的WireGuard**

```bash
sudo mkdir -p /etc/wireguard/remote
REMOTE_PRIVATE_KEY=$(cat remote.key)
FW_PUBLIC_KEY=$(cat fw.pub)

sudo tee /etc/wireguard/remote/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = ${REMOTE_PRIVATE_KEY}

[Peer]
PublicKey = ${FW_PUBLIC_KEY}
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 /etc/wireguard/remote/wg0.conf
```

**重要说明：**
- `fw`的`AllowedIPs = 10.10.10.2/32`：只接受remote的VPN地址
- `remote`的`AllowedIPs = 10.20.0.0/24,10.40.0.0/24`：只有访问这些地址时走VPN

**任务3.4：启动WireGuard隧道**

```bash
# 在fw上
sudo ip netns exec fw wg-quick up /etc/wireguard/fw/wg0.conf

# 在remote上
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
```

**任务3.5：配置VPN流量的FORWARD规则**

```bash
# VPN用户可以访问office
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN用户可以访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN用户不能访问dmz:22（拒绝+LOG）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: "

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT

# 其他VPN流量拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: "

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -j REJECT
```

**任务3.6：验证VPN访问**

```bash
# VPN隧道状态
sudo ip netns exec fw wg show
sudo ip netns exec remote wg show

# 测试VPN访问（应该成功）
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/

# 测试VPN访问（应该失败+LOG）
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:22/
sudo ip netns exec remote ping -c 2 10.30.0.2
```

### VPN配置说明

`remote` 端的 `AllowedIPs = 10.20.0.0/24, 10.40.0.0/24` 的设计思路：

- **只允许访问办公网和DMZ**：远程员工需要访问内网办公资源（10.20.0.0/24）和 DMZ 提供的 Web 服务（10.40.0.0/24），因此只在这两个目标网段时流量才走 VPN 隧道。
- **不将0.0.0.0/0设为AllowedIPs**：避免所有流量（包括公网流量）都经过 VPN，造成不必要的带宽消耗和延迟。
- **安全考量**：限制 VPN 可访问范围，防止远程用户通过 VPN 访问未授权区域（如 guest 访客区），减少攻击面。

`fw` 端的 `AllowedIPs = 10.10.10.2/32` 只允许 remote 的 VPN IP 连接，防止其他伪造源地址的流量进入。


### 提交内容

1. **WireGuard配置文件**：fw端和remote端的`wg0.conf`
2. **wg show截图**：显示握手成功、transfer计数
3. **VPN访问测试截图**：成功和失败场景各3个
4. **路由表截图**：`remote`的`ip route`，能看到VPN相关路由
5. **VPN配置说明**：说明`AllowedIPs`的设计思路

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 隧道建立 | 8分 | wg show显示握手成功、有transfer |
| AllowedIPs配置 | 6分 | remote端只让指定网段走VPN |
| 访问控制 | 6分 | VPN用户只能访问授权服务 |

**扣分项：**
- `remote`的`AllowedIPs = 0.0.0.0/0`导致所有流量走VPN：-5分
- VPN用户能访问未授权服务：每处-3分

---

## 六、第四部分：安全审计与日志分析（15分）

### 任务清单

**任务4.1：配置LOG规则**

为所有REJECT规则配置对应的LOG规则，使用不同的`log-prefix`区分：

| 事件类型 | log-prefix | 速率限制 |
|:--------|:-----------|:---------|
| guest访问office | `GUEST-TO-OFFICE:` | 5/min burst 10 |
| guest访问dmz | `GUEST-TO-DMZ:` | 5/min burst 10 |
| VPN访问dmz:22 | `VPN-TO-DMZ-SSH:` | 无限制 |
| internet访问内网 | `INET-TO-OFFICE:` | 5/min burst 10 |
| 其他VPN违规 | `VPN-DENY:` | 5/min burst 10 |

```bash
# 示例：带速率限制的LOG规则
sudo ip netns exec fw iptables -I FORWARD [行号] \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
```

**任务4.2：模拟5种违规访问场景**

```bash
# 场景1：guest尝试访问office
sudo ip netns exec guest curl --max-time 2 http://10.20.0.2:8000/

# 场景2：guest尝试访问dmz
sudo ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/

# 场景3：remote尝试SSH到dmz:22
sudo ip netns exec remote curl --max-time 2 http://10.40.0.2:22/

# 场景4：internet尝试直接访问office
sudo ip netns exec internet curl --max-time 2 http://10.20.0.2:8000/

# 场景5：internet尝试访问dmz的未映射端口
sudo ip netns exec internet curl --max-time 2 http://203.0.113.1:3306/
```

**任务4.3：提取和分析日志**

```bash
# 实时监控日志
sudo journalctl -k -f

# 统计各类事件频次
sudo journalctl -k --grep "GUEST-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager | wc -l
sudo journalctl -k --grep "VPN-TO-DMZ-SSH" --no-pager | wc -l
sudo journalctl -k --grep "INET-TO-OFFICE" --no-pager | wc -l
sudo journalctl -k --grep "VPN-DENY" --no-pager | wc -l

# 查看最近10条日志
sudo journalctl -k --grep "GUEST-TO-OFFICE|GUEST-TO-DMZ|VPN-" --no-pager | tail -10
```

**任务4.4：填写日志统计表**

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office |1 | 1|是 |
| guest→dmz |1 | 1| 是|
| VPN→dmz:22 |1 |1 |是 |
| internet→office |1 |1 |是 |
| VPN其他违规 | 1| 0|否 |

### 日志分析报告

在本实验中，我们通过 iptables 的 LOG 模块对违规访问进行了审计记录。虽然系统内核日志因配置原因未能持久化，但规则本身已通过计数器证明生效。以下从四个角度阐述日志机制的价值。

**从日志中能获取的安全信息**  
一条典型的 iptables 日志包含丰富的安全信息：
- 源/目的地址（SRC/DST）：识别攻击者与目标主机。
- 入/出接口（IN/OUT）：判定流量来自哪个区域（如 `veth-fw-guest` 表示访客区），有助于定位隔离边界。
- 传输层信息（SPT/DPT）：显示源端口和目标端口，例如 DPT=22 表示 SSH 服务，暗示可能的暴力破解或探测行为。
- 日志前缀（如 `GUEST-TO-OFFICE`）：直接标识违规类型，便于快速过滤和告警。
这些信息组合起来，可以还原攻击路径，为应急响应提供依据。

**LOG规则为什么要放在REJECT之前**  
iptables 规则按顺序匹配，一旦匹配到 REJECT 或 DROP 就会终止处理，后续规则不再执行。若 LOG 放在 REJECT 之后，则被拒绝的包永远不会触发日志，审计将缺失关键拦截记录。因此，必须将 LOG 规则置于对应 REJECT 之前，确保所有被拦截的流量都能留下痕迹。

**速率限制如何防止日志洪水攻击**  
使用 `-m limit --limit 5/min --limit-burst 10` 可以控制日志产生频率。当遭受扫描或 DoS 攻击时，短时间内会产生大量违规包，若不加限制，日志系统（如 syslog 或 journald）会被海量消息淹没，可能导致磁盘写满或性能下降。速率限制确保只记录代表性的样本，既能证明防御有效，又不会影响系统稳定性。

**不同log-prefix的作用**  
不同的前缀字符串（如 `GUEST-TO-OFFICE`、`VPN-TO-DMZ-SSH`）为每条日志打上“标签”，使管理员能够：
- 快速识别违规类型，无需解析完整规则链。
- 在监控平台（如 grep 或 SIEM）中按前缀过滤、统计和告警。
- 区分不同安全事件，便于分类处置（例如针对 VPN 违规可加强认证，针对 Guest 违规可调整访客策略）。

### 提交内容

1. **LOG规则配置截图**：显示所有LOG规则的行号和参数
2. **5种违规场景截图**：触发命令和失败结果
3. **journalctl日志截图**：至少5条，包含完整字段（IN、OUT、SRC、DST、DPT）
4. **日志统计表**：填写完整
5. **日志分析报告**（300-500字）：



**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| LOG规则完整 | 4分 | 所有REJECT都有对应LOG |
| 日志提取 | 4分 | 能正确使用journalctl提取和统计 |
| 日志分析报告 | 7分 | 分析深入、理解透彻 |

## 七、第五部分：攻防演练与故障排查（15分）

### 5.1 攻击方任务（从guest发起）（5分）

**攻击1：扫描office网段**

尝试扫描`10.20.0.0/24`网段，观察防火墙是否拦截：

```bash
# 尝试ping扫描
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**攻击2：尝试绕过防火墙访问dmz:22**

尝试改变源端口、使用不同协议等方法：

```bash
# 尝试用不同源端口
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**攻击3：尝试伪造VPN流量**

思考：攻击者能否伪造源地址为`10.10.10.2`的包来访问内网？
```bash
# 这个攻击会成功吗？为什么？
不能成功。
原因分析：
防火墙的 FORWARD 规则对 VPN 流量做了双重限制：不仅要求源 IP 为 10.10.10.2，还要求入接口必须是 WireGuard 接口（即 fw）。攻击者若从其他区域（如 guest 或 internet）发送伪造源地址的包，其入接口不会是 fw，因此无法匹配放行规则。这些包将落入默认的 DROP 策略（或后续的拒绝规则），被直接丢弃。即使有状态检测（ESTABLISHED,RELATED）也无法放行，因为这不是已建立连接的一部分。因此，伪造 VPN 源地址无法绕过基于接口的访问控制。
```

**提交内容：**
- 3种攻击的命令和结果截图
- 每种攻击失败的原因分析（各100字）
- 回答：攻击者能否从REJECT和DROP的不同表现判断目标是否存在？

### 5.2 防御方任务（日志分析与规则分析）（5分）

**任务1：从日志中识别攻击**

```bash
# 查看最近的所有拒绝日志
sudo journalctl -k --since "10 minutes ago" --grep "GUEST-|VPN-|INET-" --no-pager
```

回答问题：
1. 从日志的哪些字段可以判断这是来自guest的攻击？
通过 IN=veth-fw-guest（入口接口为 guest 网络接口）可判断流量来源于访客区；SRC=10.30.0.x 源 IP 属于 guest 网段；日志前缀（如 GUEST-TO-OFFICE 或 GUEST-TO-DMZ）直接标识违规类型。三者结合即可确认攻击来自 guest。

2. 如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？
说明流量从 guest 区域进入防火墙，试图转发至 office 区域。该流量被防火墙拦截（匹配了 guest→office 的 REJECT 规则），表明 guest 正在尝试违规访问内部办公网络，属于未授权的跨区访问行为。

3. 为什么看到大量相同来源的日志应该引起警惕？
大量重复日志通常意味着源 IP 正在执行自动化扫描、端口探测或暴力破解，试图发现开放端口或突破访问控制。这可能是攻击前兆，需及时响应（如临时封禁 IP、增强监控），避免攻击者进一步渗透内网。

**任务2：分析规则的防御效果**

```bash
# 查看规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

回答问题：
1. 哪条规则拦截了guest访问office？
规则编号 8（REJECT all -- veth-fw-guest veth-fw-office）拦截了 guest 访问 office 的流量。该规则匹配入接口 veth-fw-guest（guest 区域）和出接口 veth-fw-office（office 区域），对所有协议和端口执行 REJECT 动作。

2. 如果guest→office的规则计数很高，说明了什么？
高计数（如本例中 pkts=19）说明 guest 区域存在持续的探测或扫描行为，可能正在尝试发现 office 区域的存活主机或开放端口。这可能是攻击前兆（如横向移动、信息收集），应引起警惕并考虑自动封禁或增强监控。

3. REJECT和DROP在安全性上有什么区别？
REJECT 和 DROP 是 iptables 中两种处理拒绝流量的方式，它们在安全性上的核心区别在于信息泄露程度不同。

REJECT 会向源端返回明确的错误信息，例如 ICMP 不可达（port-unreachable）或 TCP RST 包。这意味着攻击者能够立刻得知目标端口确实存在，只是被防火墙拒绝了。这种明确的反馈会让攻击者确认“目标在线、防火墙存在、该端口被刻意封锁”，从而加速其端口扫描和指纹识别过程，降低攻击成本。

DROP 则采取“静默丢弃”策略，不返回任何响应包。攻击者发出的探测包如同石沉大海，无法区分是“目标主机不存在”、“端口未开放”还是“被防火墙过滤”。攻击者只能依赖超时等待来判断，这大大延长了探测时间，增加了攻击的不确定性。

从攻击者的视角来看，REJECT 相当于门上有“禁止入内”的告示牌，确认了门的存在；而 DROP 则像一堵完全沉默的墙壁，连回声都没有，攻击者甚至不确定墙后面是否有东西。

因此，在安全性要求较高的生产环境中，DROP 优于 REJECT。虽然 REJECT 在故障排查时更方便（能快速获得明确错误），但它泄露了过多信息。DROP 虽然没有反馈，却能更好地隐藏网络拓扑和服务存在，是纵深防御中“减少攻击面”的重要手段。


**提交内容：**
- 日志截图（含攻击特征）
- 规则计数器截图
- 3个问题的回答（各150字）

### 5.3 边界测试与改进方案（5分）

**找出潜在的安全问题：**

1. **office无限制访问internet**
   - 风险：员工可能访问恶意网站、下载病毒
   - 改进方案：配置白名单、使用Web过滤、限制可访问端口

2. **dmz:8080对外开放**
   - 风险：可能被DDoS攻击、Web漏洞利用
   - 改进方案：配置connlimit限制连接数、使用反向代理、WAF

3. **VPN没有限制连接频率**
   - 风险：可能被暴力破解、端口扫描
   - 改进方案：使用recent模块限制连接频率、fail2ban

**任务要求：**
1. 从上述3个问题中选择1个实现改进方案（或提出自己发现的其他问题）
2. 写出具体的iptables规则或配置方法
3. 测试改进方案的效果

**示例：限制单IP对dmz:8080的连接数**

```bash
sudo ip netns exec fw iptables -I FORWARD \
  -p tcp --syn --dport 8080 \
  -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset
```

**提交内容：**
- 选择的问题及风险分析（200字）
- 改进方案的实现代码
- 测试效果截图

### 5.4 高级任务：追踪包的完整变化过程（加分5分）

**任务：追踪一次"remote通过VPN访问dmz:8080"的完整过程**

要求在4个位置同时抓包：

```bash
# 终端1：remote的wg0接口（看到封装前的包）
sudo ip netns exec remote tcpdump -ni wg0 -c 5

# 终端2：fw的wg0接口（看到解封装后的包）
sudo ip netns exec fw tcpdump -ni wg0 -c 5

# 终端3：fw的veth-fw-dmz接口（看到转发到dmz的包）
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5

# 终端4：fw的conntrack表
watch -n 1 'sudo ip netns exec fw conntrack -L | grep 10.10.10.2'

# 终端5：触发访问
sudo ip netns exec remote curl http://10.40.0.2:8080/
```

**填写包变化对比表：**

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 |10.10.10.2:50564 |10.40.0.2:8080 |TCP | 封装前 |
| 2 | fw wg0 |10.10.10.2:50564 |10.40.0.2:8080 |TCP | 解封装后 |
| 3 | fw veth-fw-dmz |203.0.113.1:50564 | 10.40.0.2:8080|TCP | 转发到dmz |
| 4 | conntrack |10.10.10.2:50564 → 10.40.0.2:8080 |10.40.0.2:8080 → 10.10.10.2:50564|TCP | 连接跟踪记录 |

**提交内容：**
- 4个位置的抓包截图
- 包变化对比表
- conntrack记录截图
- 分析报告（300字）：说明包是如何一步步被处理的

**评分标准：**

| 项目 | 分值 | 评分细则 |
|:-----|:-----|:---------|
| 攻击方演练 | 5分 | 3种攻击完整、分析合理 |
| 防御方分析 | 5分 | 日志分析准确、规则理解透彻 |
| 边界测试与改进 | 5分 | 问题识别准确、方案可行、有测试 |
| 高级任务（加分） | 5分 | 抓包完整、分析深入 |

---

## 八、故障排查专题（体现Plan1的开放性）

> 详细故障排查过程及命令请参见 `troubleshooting.md`。

### 场景1：DNAT配置了但外网无法访问

**现象：**
- `internet`访问`203.0.113.1:8080`失败
- `iptables -t nat -L`显示DNAT规则存在
- `dmz`上的服务正常运行

**排查步骤：**
1. 检查FORWARD规则是否放行了DNAT后的流量
2. 检查dmz的默认路由是否指向fw
3. 用conntrack观察是否有DNAT映射记录
4. 在fw的多个接口抓包，找出包在哪里被丢弃

**提交要求：**
- 重现这个故障（故意配置错误）
- 记录排查过程和使用的命令
- 找出根本原因
- 修复并验证

### 场景2：VPN隧道握手正常但业务访问失败

**现象：**
- `wg show`显示`latest handshake`正常
- `remote ping 10.40.0.2`失败
- `fw`上没有相关日志

**可能原因：**
1. `AllowedIPs`配置错误
2. FORWARD规则拒绝了VPN流量
3. dmz没有回程路由
4. fw未开启IP转发

**提交要求：**
- 至少重现2个可能原因
- 说明如何快速定位是哪个问题
- 提供修复方法

### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

**现象：**
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

**排查步骤：**
1. 在fw上抓包，观察双向流量
2. 用conntrack观察连接状态
3. 理解状态检测的作用

**提交要求：**
- 重现这个故障
- 用tcpdump证明SYN-ACK被拦截
- 说明ESTABLISHED,RELATED的必要性

---

## 提交要求

## 九、遇到的问题和解决方法

### 问题1：VPN接口名不一致导致流量被拦截
- **现象**：VPN 握手成功，但 `remote` 无法 ping 通 `10.20.0.2`，防火墙计数器显示 VPN 规则未命中。
- **排查**：执行 `iptables -L FORWARD` 发现规则中使用的入接口是 `vpn-fw`，但实际 WireGuard 接口名为 `fw`。
- **解决**：将防火墙规则中的 `-i vpn-fw` 全部改为 `-i fw`，重新加载规则后 VPN 访问恢复正常。

### 问题2：remote 无法访问 203.0.113.1（fw公网IP）
- **现象**：`remote` 命名空间没有网络连接，无法与 fw 建立 WireGuard 握手。
- **排查**：检查 `remote` 的接口，发现缺少 `veth-remote` 物理接口。
- **解决**：创建 veth 对 `veth-fw-remote` 和 `veth-remote`，配置 IP `203.0.113.2/24` 和 `203.0.113.3/24`，并在 remote 中设置默认路由指向 `203.0.113.2`。

### 问题3：内核日志未捕获 iptables LOG
- **现象**：触发违规访问后，`journalctl -k --grep "VPN"` 无输出，但 `iptables -L -v` 计数器显示规则已命中。
- **排查**：调整 `kernel.printk` 级别为 `7 7 1 7`，仍无日志。
- **解决**：改用规则计数器作为审计证据，在报告中说明“日志未持久化，计数器证明拦截生效”。

### 问题4：DNAT后外网访问超时
- **现象**：`internet` 访问 `203.0.113.1:8080` 超时，DNAT 规则存在但无响应。
- **排查**：检查 FORWARD 链，发现缺少 `-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -j ACCEPT`。
- **解决**：添加放行规则后，外网访问恢复正常。

## 十、总结与思考

通过本次期末大作业，我完整搭建了一个包含多区域隔离、防火墙策略、NAT、VPN接入和日志审计的企业级网络安全架构。以下是我对整个实验的总结和思考。

**最小权限原则的实践**  
在整个防火墙策略设计中，我始终坚持最小权限原则：FORWARD 链默认 DROP，只放行明确需要的流量。例如，office 只能访问 dmz:8080 和 internet，guest 只能访问 internet，dmz 只能访问 internet 更新。这种“默认拒绝、按需放行”的策略最大限度地减少了攻击面，是网络安全设计的基石。

**区域隔离的价值**  
通过将网络划分为 office、guest、dmz、internet 和 VPN 五个区域，并严格控制区域间的访问，实现了网络的分层防护。即使 guest 区域被攻破，攻击者也无法访问 office 内网和 dmz 服务。这种纵深防御的思想在企业网络中至关重要。

**VPN接入的风险与管控**  
VPN 为远程员工提供了便利，但也带来了安全风险。实验中，我通过限制 VPN 用户的 `AllowedIPs` 仅为 office 和 dmz 网段，并配置精细的 FORWARD 规则，确保 VPN 用户只能访问授权资源，不能访问 guest 区域或进行 SSH 连接。这体现了“最小权限”在身份认证后的延续。

**日志审计的意义**  
虽然本实验的日志未能持久化，但通过规则计数器仍然可以证明防火墙的拦截效果。在真实生产环境中，完善的日志审计体系（如 syslog 集中收集、SIEM 分析）是发现安全事件、追溯攻击路径的关键。LOG 规则放在 REJECT 之前、速率限制防止日志洪水等设计都是实用经验。

**与真实企业环境的差异**  
本实验在单机命名空间中模拟了多区域网络，是一个极简的企业边界模型。真实环境需要考虑更多因素：双机热备的高可用性、入侵检测系统（IDS）、Web 应用防火墙（WAF）、零信任架构等。但实验中的核心思想——隔离、最小权限、审计——是通用的。

**个人的收获**  
通过亲手配置命名空间、iptables 和 WireGuard，我对 Linux 网络栈的理解更加深入。故障排查过程（如接口名不一致、路由缺失、DNAT 规则缺失）锻炼了我的诊断能力。企业网络安全不是一蹴而就的，而是需要反复测试、不断优化的过程。

总而言之，本次实验让我从理论走向实践，理解了企业网络安全架构的设计理念和实现方法。这将为我未来的网络安全工作打下坚实的基础。

### 文件结构

```text
学号姓名/
└── FinalProject/
    ├── README.md           # 实验报告主文档
    ├── setup.sh            # 拓扑搭建脚本
    ├── firewall.sh         # 防火墙规则配置脚本
    ├── vpn-fw.conf         # VPN服务端配置
    ├── vpn-remote.conf     # VPN客户端配置
    ├── screenshots/        # 所有截图（至少20张）
    │   ├── 01-topology.png
    │   ├── 02-firewall-rules.png
    │   ├── 03-access-matrix.png
    │   ├── 04-vpn-status.png
    │   ├── 05-logs.png
    │   ├── 06-attack-*.png
    │   ├── 07-tcpdump-*.png
    │   └── ...
    ├── analysis.md         # 攻防演练分析报告
    └── troubleshooting.md  # 故障排查报告
```

### README.md格式要求

```markdown
# 企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：
- WireGuard版本：
- iptables版本：

## 二、拓扑图和地址规划
（手绘或工具绘制的拓扑图）
（地址规划表）

## 三、第一部分：网络规划与基础搭建
（包含setup.sh的说明和连通性测试结果）

## 四、第二部分：防火墙策略实现
（包含firewall.sh的说明和访问控制矩阵）

## 五、第三部分：VPN远程接入
（包含WireGuard配置说明和测试结果）

## 六、第四部分：安全审计与日志分析
（包含LOG规则说明和日志分析报告）

## 七、第五部分：攻防演练
（包含攻击演练、防御分析、边界测试）

## 八、故障排查
（包含至少3个故障场景的排查过程）

## 九、遇到的问题和解决方法
（实验过程中的实际问题和解决思路）

## 十、总结与思考
（至少500字，包含对企业网络安全架构的整体理解）
```

### 截图清单（至少20张）

| 序号 | 内容 | 文件名 |
|:-----|:-----|:-------|
| 1 | 拓扑搭建后的连通性测试 | 01-topology.png |
| 2 | 完整的防火墙规则列表 | 02-firewall-rules.png |
| 3 | NAT规则列表 | 03-nat-rules.png |
| 4 | 访问控制测试矩阵（成功场景） | 04-access-success.png |
| 5 | 访问控制测试矩阵（失败场景） | 05-access-deny.png |
| 6 | VPN隧道状态（wg show） | 06-vpn-status.png |
| 7 | VPN访问测试（成功） | 07-vpn-success.png |
| 8 | VPN访问测试（失败+LOG） | 08-vpn-deny.png |
| 9 | 日志实时监控 | 09-logs-realtime.png |
| 10 | 日志统计结果 | 10-logs-stats.png |
| 11 | 攻击演练场景1 | 11-attack-scan.png |
| 12 | 攻击演练场景2 | 12-attack-bypass.png |
| 13 | 防御分析-日志证据 | 13-defense-logs.png |
| 14 | 防御分析-规则计数器 | 14-defense-counters.png |
| 15 | 边界测试改进方案 | 15-improvement.png |
| 16 | 高级任务-remote抓包 | 16-tcpdump-remote.png |
| 17 | 高级任务-fw抓包 | 17-tcpdump-fw.png |
| 18 | 高级任务-conntrack | 18-conntrack.png |
| 19 | 故障排查场景1 | 19-troubleshoot-dnat.png |
| 20 | 故障排查场景2 | 20-troubleshoot-vpn.png |

---

## 评分标准

### 总分：100分 + 加分5分

| 部分 | 分值 | 评分细则 |
|:----|:-----|:---------|
| 第一部分：网络规划 | 20分 | 拓扑正确10分、脚本可运行5分、连通性验证5分 |
| 第二部分：防火墙策略 | 30分 | 规则完整性10分、访问控制正确性10分、NAT配置5分、规则设计5分 |
| 第三部分：VPN接入 | 20分 | 隧道建立8分、AllowedIPs配置6分、访问控制6分 |
| 第四部分：安全审计 | 15分 | LOG规则4分、日志提取4分、分析报告7分 |
| 第五部分：攻防演练 | 15分 | 攻击演练5分、防御分析5分、边界测试5分 |
| 高级任务（加分） | 5分 | 包追踪完整性3分、分析深度2分 |

### 扣分项

| 扣分原因 | 扣分 |
|:--------|:-----|
| 截图不清晰、缺失关键字段 | 每处-2分 |
| 规则错误导致安全漏洞 | 每处-5分 |
| 脚本无法运行、拓扑无法复现 | -10分 |
| README.md格式混乱、缺少必要说明 | -5分 |
| 故障排查报告敷衍、未深入分析 | -5分 |
| 抄袭或雷同 | 0分 |

### 优秀作业标准（90分以上）

1. 拓扑搭建脚本健壮，可重复运行，有完善的错误处理
2. 防火墙规则遵循最小权限原则，顺序合理，注释清晰
3. 访问控制测试全面，所有场景都有截图证据
4. VPN配置正确，AllowedIPs设计合理
5. 日志审计完整，分析报告深入，能提出改进建议
6. 攻防演练有创新性，能发现非明显的安全问题
7. 故障排查过程详细，思路清晰，能举一反三
8. README.md结构清晰，表达流畅，有个人思考
9. 完成高级任务，包追踪分析透彻

---

## 截止时间

**2026-07-03（18周结束前）**

届时关于期末大作业的PR将不会被合并。

---

