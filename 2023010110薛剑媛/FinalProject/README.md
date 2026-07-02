# 企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：Kali Linux
- 内核版本：6.1.0-kali7-amd64
- WireGuard版本：0.5.1
- iptables版本：1.8.9

## 二、拓扑图和地址规划

### 拓扑图
![alt text](screenshots/topology.png)

### 地址规划表

| 区域 | 网段 | fw侧地址 | 主机地址 | 说明 |
|:-----|:-----|:---------|:---------|:-----|
| office | 10.20.0.0/24 | 10.20.0.1 | 10.20.0.2 | 办公网 |
| guest | 10.30.0.0/24 | 10.30.0.1 | 10.30.0.2 | 访客网 |
| dmz | 10.40.0.0/24 | 10.40.0.1 | 10.40.0.2 | DMZ区 |
| internet | 203.0.113.0/24 | 203.0.113.1 | 203.0.113.10 | 模拟外网 |
| vpn | 10.10.10.0/24 | 10.10.10.1 | 10.10.10.2 | VPN隧道 |

## 三、第一部分：网络规划与基础搭建

### setup.sh 脚本说明

`setup.sh` 脚本包含完整的网络拓扑搭建命令，主要功能：

1. **清理旧环境**：删除可能残留的namespace和veth设备，确保脚本可重复运行
2. **创建6个namespace**：fw、office、guest、dmz、internet、remote
3. **创建5对veth**：连接fw与office、guest、dmz、internet、remote
4. **配置IP地址**：为所有接口分配IP地址
5. **配置默认路由**：各区域默认网关指向fw
6. **开启IP转发**：`net.ipv4.ip_forward=1`
7. **连通性测试**：验证各区域到fw的连通性

### 拓扑搭建步骤

1. **清理旧环境**：删除可能残留的namespace和veth设备，确保脚本可重复运行。

2. **创建6个namespace**：使用`ip netns add`创建fw（防火墙）、office（办公网）、guest（访客网）、dmz（DMZ区）、internet（模拟外网）、remote（远程员工）六个独立的网络命名空间。

3. **创建5对veth**：使用`ip link add`创建虚拟网卡对，连接fw与各区域：
   - `fw-office ↔ office`：连接防火墙与办公网
   - `fw-guest ↔ guest`：连接防火墙与访客网
   - `fw-dmz ↔ dmz`：连接防火墙与DMZ区
   - `fw-inet ↔ inet`：连接防火墙与外网
   - `fw-vpn ↔ remote`：连接防火墙与VPN管理网络

4. **配置IP地址**：按照规划表为每个接口分配IP地址，fw作为各区域的网关（网段的第一个地址），各区域主机使用网段的第二个地址。

5. **配置默认路由**：在各区域主机中设置默认路由指向fw的接口IP，确保所有跨区域流量都经过fw处理。

6. **开启IP转发**：在fw中设置`net.ipv4.ip_forward=1`，允许fw在不同网络接口之间转发数据包。

7. **连通性测试**：从每个区域主机ping fw的对应接口IP，验证基础网络连通性。

### 验证方法

- 使用 `ip netns list` 确认6个namespace全部创建
- 使用 `ip addr show` 确认所有接口IP配置正确且状态为UP
- 使用 `ping` 测试各区域到fw的连通性

### 连通性测试结果

| 测试项 | 源 | 目标 | 结果 |
|:-------|:---|:-----|:-----|
| 1 | office | fw (10.20.0.1) |  PASS |
| 2 | guest | fw (10.30.0.1) | PASS |
| 3 | dmz | fw (10.40.0.1) | PASS |
| 4 | internet | fw (203.0.113.1) | PASS |

**测试结果：所有4组连通性测试全部通过（PASS），基础网络搭建完成。**

## 四、第二部分：防火墙策略实现

### firewall.sh 脚本说明

`firewall.sh` 脚本包含完整的防火墙策略配置，主要功能：

1. **清空旧规则**：清除之前可能存在的iptables规则，确保配置干净
2. **设置默认策略**：FORWARD链默认DROP，INPUT链默认DROP，OUTPUT链默认ACCEPT
3. **配置状态检测**：放行已建立连接和关联连接的流量
4. **配置访问控制规则**：按照最小权限原则配置所有规则

### 规则设计说明

**1. 规则顺序原则**

防火墙规则按以下顺序排列，确保正确匹配：
- 首先：状态检测规则（`ESTABLISHED,RELATED` 放行）
- 其次：具体的放行规则
- 然后：LOG规则（记录被拒绝的流量）
- 最后：REJECT规则（拒绝流量）

**2. 为什么用REJECT而不是DROP**

| 特性 | REJECT | DROP |
|:-----|:-------|:-----|
| 响应 | 返回ICMP错误消息 | 静默丢弃 |
| 客户端体验 | 快速感知连接被拒绝 | 超时等待 |
| 安全性 | 暴露端口不可用信息 | 隐藏服务存在 |
| 排错 | 便于排查问题 | 难以定位问题 |
| 适用场景 | 内部网络 | 对外部网络隐藏服务 |

本实验选择REJECT的原因：
- 内部网络中使用REJECT更友好，便于排查问题
- 端口不可达消息有助于客户端快速失败
- 在企业内部环境中，REJECT不会带来额外的安全风险

**3. 最小权限原则**
- 默认策略为DROP，只放行明确需要的流量
- guest只能访问internet，不能访问内网和DMZ
- office只能访问dmz:8080，不能SSH到dmz
- internet只能通过DNAT访问dmz:8080

### 访问控制规则清单

| 编号 | 规则 | 说明 |
|:-----|:-----|:-----|
| 1 | `ctstate RELATED,ESTABLISHED ACCEPT` | 状态检测 |
| 2 | `office → dmz:8080 ACCEPT` | 办公网访问DMZ Web服务 |
| 3 | `office → dmz:22 LOG` | 办公网SSH到DMZ（日志） |
| 4 | `office → dmz:22 REJECT` | 办公网SSH到DMZ（拒绝） |
| 5 | `guest → office LOG` | 访客访问办公网（日志） |
| 6 | `guest → office REJECT` | 访客访问办公网（拒绝） |
| 7 | `guest → dmz LOG` | 访客访问DMZ（日志） |
| 8 | `guest → dmz REJECT` | 访客访问DMZ（拒绝） |
| 9 | `internet → dmz:8080 ACCEPT` | DNAT放行（外网访问Web） |
| 10 | `office → internet ACCEPT` | 办公网访问外网 |
| 11 | `guest → internet ACCEPT` | 访客访问外网 |
| 12 | `dmz → internet ACCEPT` | DMZ访问外网 |
| 13 | `internet → office LOG` | 外网访问办公网（日志） |
| 14 | `internet → office REJECT` | 外网访问办公网（拒绝） |
| 15 | `internet → guest LOG` | 外网访问访客网（日志） |
| 16 | `internet → guest REJECT` | 外网访问访客网（拒绝） |
| 17 | `internet → dmz:22 LOG` | 外网SSH到DMZ（日志） |
| 18 | `internet → dmz:22 REJECT` | 外网SSH到DMZ（拒绝） |

### NAT规则

**SNAT（源地址转换）**
- `10.20.0.0/24 → fw-inet`：办公网访问外网
- `10.30.0.0/24 → fw-inet`：访客网访问外网
- `10.40.0.0/24 → fw-inet`：DMZ访问外网

**DNAT（目的地址转换）**
- `fw-inet:8080 → 10.40.0.2:8080`：外网访问DMZ Web服务

### 访问控制矩阵

| 来源 | 目标 | 预期结果 | 实际结果 | 状态 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 | 成功 | PASS |
| office | dmz:22 | 失败+LOG | 失败+LOG | PASS |
| office | internet | 成功 | 成功 | PASS |
| guest | internet | 成功 | 成功 | PASS |
| guest | office | 失败+LOG | 失败+LOG | PASS |
| guest | dmz | 失败+LOG | 失败+LOG | PASS |
| dmz | internet | 成功 | 成功 | PASS |
| internet | dmz:8080 | 成功(DNAT) | 成功 | PASS |
| internet | dmz:22 | 失败+LOG | 失败+LOG | PASS |
| internet | office | 失败 | 失败 | PASS |
| internet | guest | 失败 | 失败 | PASS |

**测试结果：11/11 全部通过！** 


## 五、第三部分：VPN远程接入

### WireGuard配置说明

**fw端配置要点：**
- VPN服务器地址：`10.10.10.1/24`
- 监听端口：`51820`
- AllowedIPs：`10.10.10.2/32`（只接受remote的VPN地址）
- MTU：`1280`

**remote端配置要点：**
- VPN客户端地址：`10.10.10.2/24`
- 对端地址：`203.0.113.1:51820`
- AllowedIPs：`10.10.10.0/24,10.20.0.0/24,10.40.0.0/24`
- MTU：`1280`

### VPN配置说明：AllowedIPs设计思路

#### 1. fw端 AllowedIPs 设计思路

`AllowedIPs = 10.10.10.2/32`

fw端只允许remote的VPN地址 `10.10.10.2` 连接，设计考虑：

- **精确匹配**：`/32` 精确匹配单个IP，只允许一个VPN客户端
- **防止伪造**：拒绝其他地址伪装成VPN客户端
- **身份绑定**：每个VPN用户绑定唯一的固定IP
- **最小权限**：只授予连接所需的地址范围

#### 2. remote端 AllowedIPs 设计思路

`AllowedIPs = 10.10.10.0/24,10.20.0.0/24,10.40.0.0/24`

remote端的设计体现了**流量分离**和**最小权限原则**：

| 网段 | 用途 | 设计理由 |
|:-----|:-----|:---------|
| `10.10.10.0/24` | VPN网络本身 | 用于隧道通信，是VPN的基础网络 |
| `10.20.0.0/24` | 办公网段 | VPN用户需要访问办公资源 |
| `10.40.0.0/24` | DMZ网段 | VPN用户需要访问DMZ服务 |

#### 3. 不包含的网段及原因

| 网段 | 不包含原因 |
|:-----|:-----------|
| `10.30.0.0/24` (guest网段) | VPN用户不应访问访客网络，隔离VPN与访客流量 |
| `203.0.113.0/24` (internet网段) | VPN用户的公网流量不应走VPN隧道，避免性能瓶颈 |

#### 4. 设计安全收益

- **流量分离**：VPN流量只用于访问内网，公网流量不走VPN
- **性能优化**：避免VPN隧道成为公网流量的转发瓶颈
- **安全隔离**：VPN用户无法访问guest网段，防止横向移动
- **可扩展性**：后续新增网段只需修改AllowedIPs即可

### VPN访问控制规则

| 规则 | 说明 |
|:-----|:-----|
| `VPN → office ACCEPT` | VPN用户可访问办公网 |
| `VPN → dmz:8080 ACCEPT` | VPN用户可访问DMZ Web服务 |
| `VPN → dmz:22 LOG+REJECT` | VPN用户不能SSH到DMZ |
| `其他VPN流量 REJECT` | 拒绝VPN用户的其他访问 |

### VPN隧道状态

| 检查项 | fw端 | remote端 | 状态 |
|:-------|:-----|:---------|:-----|
| 公钥交换 | ✅ | ✅ | ✅ |
| 监听端口 | 51820 | 53706 | ✅ |
| 对端地址 | 10.10.10.2:53706 | 203.0.113.1:51820 | ✅ |
| 最新握手 | 4 seconds ago | 4 seconds ago | ✅ |
| 传输数据 | ✅ | ✅ | ✅ |

### VPN路由表

**remote端路由分析：**
- `10.10.10.0/24`：VPN网络，走wg0接口
- `10.20.0.0/24`：办公网，走wg0接口（VPN隧道）
- `10.40.0.0/24`：DMZ网段，走wg0接口（VPN隧道）
- 默认路由：走remote物理接口（管理网络）
- 公网流量（如访问互联网）不走VPN隧道

### VPN测试结果

| 测试项 | 预期结果 | 实际结果 | 状态 |
|:-------|:---------|:---------|:-----|
| VPN连通性 (ping 10.10.10.1) | 成功 | 成功 | PASS |
| remote → office:8000 | 成功 | 成功 | PASS |
| remote → dmz:8080 | 成功 | 成功 | PASS |
| remote → dmz:22 | 失败+LOG | 失败+LOG | PASS |
| remote → guest | 失败 | 失败 | PASS |
| remote → internet | 失败 | 失败 | PASS |

**测试结果：6/6 全部通过！** 


## 六、第四部分：安全审计与日志分析

### LOG规则配置说明

#### 1. LOG规则清单

为所有REJECT规则配置了对应的LOG规则，使用不同的`log-prefix`区分事件类型：

| 事件类型 | log-prefix | 速率限制 | 说明 |
|:--------|:-----------|:---------|:-----|
| internet→dmz未映射端口 | `INET-TO-DMZ-DENY:` | 5/min burst 10 | 外网扫描未开放端口 |
| internet→office | `INET-TO-OFFICE:` | 5/min burst 10 | 外网尝试访问办公网 |
| office→dmz:22 | `OFFICE-TO-DMZ-SSH:` | 无限制 | 办公网SSH到DMZ |
| guest→office | `GUEST-TO-OFFICE:` | 5/min burst 10 | 访客访问办公网 |
| guest→dmz | `GUEST-TO-DMZ:` | 5/min burst 10 | 访客访问DMZ |
| internet→dmz:22 | `FW-INTERNET-TO-DMZ-SSH:` | 无限制 | 外网SSH到DMZ |
| VPN→dmz:22 | `VPN-TO-DMZ-SSH:` | 无限制 | VPN用户SSH到DMZ |
| VPN其他违规 | `VPN-DENY:` | 5/min burst 10 | VPN用户其他违规访问 |

#### 2. LOG规则配置命令

```bash
# internet→dmz未映射端口（插入到FORWARD链第1行）
sudo ip netns exec fw iptables -I FORWARD 1 -i fw-inet -o fw-dmz ! -d 10.40.0.2 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-DMZ-DENY: " --log-level 4

# internet→office（插入到FORWARD链第2行）
sudo ip netns exec fw iptables -I FORWARD 2 -i fw-inet -o fw-office -d 10.20.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

# office→dmz:22（插入到FORWARD链第5行）
sudo ip netns exec fw iptables -I FORWARD 5 -i fw-office -o fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4

# guest→office（插入到FORWARD链第9行）
sudo ip netns exec fw iptables -I FORWARD 9 -i fw-guest -o fw-office -s 10.30.0.0/24 -d 10.20.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

# guest→dmz（插入到FORWARD链第11行）
sudo ip netns exec fw iptables -I FORWARD 11 -i fw-guest -o fw-dmz -s 10.30.0.0/24 -d 10.40.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

# internet→dmz:22（插入到FORWARD链第14行）
sudo ip netns exec fw iptables -I FORWARD 14 -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "FW-INTERNET-TO-DMZ-SSH: " --log-level 4

# VPN→dmz:22（插入到FORWARD链第17行）
sudo ip netns exec fw iptables -I FORWARD 17 -i wg0 -o fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

# VPN其他违规（追加到FORWARD链末尾）
sudo ip netns exec fw iptables -A FORWARD -i wg0 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "VPN-DENY: " --log-level 4
```

#### 3. LOG规则验证

通过 `iptables -L FORWARD -n -v --line-numbers` 查看LOG规则：

| 行号 | 规则 | 包计数 | 说明 |
|:-----|:-----|:-------|:-----|
| 1 | `LOG` prefix "INET-TO-DMZ-DENY" | 0 | internet→dmz未映射端口 |
| 2 | `LOG` prefix "INET-TO-OFFICE" | 12 | internet→office |
| 5 | `LOG` prefix "OFFICE-TO-DMZ-SSH" | 2 | office→dmz:22 |
| 9 | `NFLOG` prefix "GUEST-TO-OFFICE" | 4 | guest→office |
| 11 | `NFLOG` prefix "GUEST-TO-DMZ" | 6 | guest→dmz |
| 14 | `LOG` prefix "FW-INTERNET-TO-DMZ-SSH" | 0 | internet→dmz:22 |
| 17 | `NFLOG` prefix "VPN-TO-DMZ-SSH" | 3 | VPN→dmz:22 |
| 18 | `LOG` prefix "VPN-TO-DMZ-SSH" | 6 | VPN→dmz:22 |
| 19 | `LOG` prefix "VPN-DENY" | 0 | VPN其他违规 |

**说明：** 部分规则使用NFLOG（通过tcpdump捕获），部分使用LOG（通过dmesg/日志文件）。包计数不为0的规则证明已成功捕获违规流量。

### 5种违规访问场景

| 场景 | 触发命令 | 预期结果 | 实际结果 | 对应LOG |
|:-----|:---------|:---------|:---------|:---------|
| 1 | `guest curl 10.20.0.2:8000` | 失败 | `Failed to connect` | `GUEST-TO-OFFICE` |
| 2 | `guest curl 10.40.0.2:8080` | 失败 | `Connection timed out` | `GUEST-TO-DMZ` |
| 3 | `remote curl 10.40.0.2:22` | 失败 | `Failed to connect` | `VPN-TO-DMZ-SSH` |
| 4 | `internet curl 10.20.0.2:8000` | 失败 | `Connection timed out` | `INET-TO-OFFICE` |
| 5 | `internet curl 203.0.113.1:3306` | 失败 | `Failed to connect` | `INET-TO-DMZ-DENY` |


### 日志统计表

| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
|:--------|:---------|:--------------|:---------|
| guest→office | 4 | 4 | ✅ |
| guest→dmz | 6 | 6 | ✅ |
| VPN→dmz:22 | 3 | 3 | ✅ |
| internet→office | 12 | 12 | ✅ |
| VPN其他违规 | 0 | 0 | ✅ |

### 日志分析报告

#### 1. 从日志中能获取哪些安全信息？

通过防火墙日志，可以获取以下关键安全信息：

- **源IP（SRC）**：识别攻击来源，如 `10.30.0.2` 来自 guest 区域
- **目标IP（DST）**：识别被攻击目标，如 `10.20.0.2` 是 office 主机
- **目标端口（DPT）**：识别攻击类型，如端口22是 SSH 服务，端口3306是 MySQL
- **协议（PROTO）**：识别攻击方式，如 TCP 连接、ICMP 扫描
- **输入/输出接口（IN/OUT）**：识别流量路径，如 `wg0→fw-dmz` 表示VPN到DMZ
- **时间戳**：识别攻击时间模式，便于追踪攻击规律
- **TCP标志（Flags）**：识别扫描类型，如 SYN 扫描、全连接扫描

#### 2. LOG规则为什么要放在REJECT之前？

LOG规则必须放在REJECT之前，因为：

- REJECT/DROP 会终止包的处理，后面的规则不再执行
- 先LOG后REJECT确保所有被拒绝的流量都被记录，保证审计完整性
- 如果LOG放在REJECT之后，被拒绝的包直接丢弃，LOG永远不会触发
- 正确的顺序：**状态检测 → 放行规则 → LOG规则 → REJECT规则**

#### 3. 速率限制如何防止日志洪水攻击？

- 使用 `--limit 5/min --limit-burst 10` 限制每分钟最多5条日志
- 防止攻击者大量发送包导致日志文件暴涨
- 保护系统存储资源（磁盘空间）和性能（I/O）
- 避免合法日志被大量垃圾日志淹没
- 在洪水攻击时仍能记录少量样本，便于识别攻击模式

#### 4. 不同log-prefix的作用是什么？

- **快速识别违规类型**：通过前缀快速定位事件，无需查看完整日志
- **便于日志分类统计**：支持 `grep` 分类检索和统计分析
- **支持自动化告警**：可配置监控规则，针对不同前缀触发不同告警
- **便于安全事件分析**：不同前缀对应不同安全策略，便于分级处理
- **提高排错效率**：快速定位问题是哪类访问被拒绝

## 七、第五部分：攻防演练

### 7.1 攻击方任务

#### 攻击1：扫描office网段

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```

**结果：**
- `10.20.0.1`（fw）→ ✅ 可达
- `10.20.0.2`（office）→ ❌ `Destination Port Unreachable`
- `10.20.0.3~10` → ❌ 被拒绝或超时

**失败原因分析：**
guest网段被防火墙隔离，FORWARD链默认策略为DROP，且没有允许guest→office的规则。攻击者的ping请求到达fw后，匹配到guest→office的REJECT规则，返回ICMP不可达消息。攻击者无法探测内网存活主机，防火墙成功阻断了扫描行为。

#### 攻击2：尝试绕过防火墙访问dmz:22

```bash
# 使用不同源端口尝试绕过
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```

**结果：** 全部超时（`Connection timed out`）

**失败原因分析（100字）：**
防火墙规则基于目标IP和端口（10.40.0.2:22）进行过滤，不关心源端口。改变源端口无法绕过基于目标端口的过滤规则。防火墙的状态检测机制会跟踪连接状态，即使改变源端口，目标端口22仍然被REJECT规则拦截。

#### 攻击3：尝试伪造VPN流量

```bash
sudo ip netns exec guest ping -c 1 -I 10.10.10.2 10.20.0.2 2>&1
sudo ip netns exec guest curl --interface 10.10.10.2 --max-time 2 http://10.20.0.2:8000/ 2>&1
```

**结果：**
- `ping: bind: 无法分配被请求的地址`
- `curl: (45) Failed to connect ... Failed binding local connection end`

**思考：攻击者能否伪造源地址为10.10.10.2的包来访问内网？**

**答案：不能。**

**失败原因分析（100字）：**
guest命名空间没有10.10.10.2这个IP地址，操作系统拒绝绑定不属于自己的IP。伪造源IP攻击在操作系统层面就被阻止了，无需防火墙介入。即使通过其他方式强行发送伪造包，防火墙的conntrack状态检测也会识别出这是非法包（没有建立过对应的连接）并丢弃。

#### REJECT vs DROP 分析

**攻击者能否从REJECT和DROP的不同表现判断目标是否存在？**

**能判断。**

| 响应类型 | 攻击者观察 | 判断结论 |
|:---------|:-----------|:---------|
| **REJECT** | 收到ICMP不可达或TCP RST | 目标存在，端口被拒绝 |
| **DROP** | 无响应，超时 | 无法判断（目标不存在/网络不通/被防火墙DROP） |

**安全建议：**
- **对外部网络**：使用DROP更安全，攻击者无法探测网络拓扑
- **对内部网络**：使用REJECT更友好，便于快速定位问题
- **本实验选择**：内部网络使用REJECT，便于排错；部分对外规则使用DROP

---

### 7.2 防御方任务

#### 任务1：从日志中识别攻击

**1. 从日志哪些字段判断是guest攻击？**

从日志字段可以判断：
- **IN=fw-guest**：流量从guest接口进入防火墙，说明来源是guest区域
- **SRC=10.30.0.0/24**：源地址属于guest网段，确认来源区域
- **OUT=fw-office**：目标出口是office接口，说明攻击目标指向办公网
- **DST=10.20.0.0/24**：目标地址属于office网段，确认攻击目标
- 结合以上字段可以确定攻击来源（guest）和攻击目标（office）

**2. 如果日志中IN=fw-guest OUT=fw-office，说明了什么？**

说明一个来自guest区域的包试图穿越防火墙到达office区域，被防火墙拦截。这表示存在跨区域访问尝试，可能是：
- **误配置**：guest用户错误配置了网络访问
- **攻击行为**：攻击者正在尝试横向移动，从访客区渗透到办公区
- **违规访问**：违反了guest只能访问internet的安全策略

**3. 为什么大量相同来源的日志应该引起警惕？**

大量相同来源的日志表明可能正在进行：
- **端口扫描**：攻击者在探测目标主机的开放端口
- **暴力破解**：攻击者在尝试爆破SSH、HTTP等服务的密码
- **自动化攻击**：使用脚本或工具进行批量攻击
- 需要及时阻断并调查，防止攻击成功

#### 任务2：分析规则的防御效果

**1. 哪条规则拦截了guest访问office？**

第10行：`REJECT all -- fw-guest fw-office 10.30.0.0/24 10.20.0.0/24`

该规则拒绝所有从guest（10.30.0.0/24）到office（10.20.0.0/24）的流量，包计数为20，证明已被触发。

**2. 如果guest→office的规则计数很高，说明了什么？**

说明guest正在持续尝试访问office，可能原因：
- 正在进行网络扫描或攻击
- 应用程序配置错误导致频繁重试
- 需要调查并采取额外防御措施（如临时封禁）

**3. REJECT和DROP在安全性上有什么区别？**

| 特性 | REJECT | DROP |
|:-----|:-------|:-----|
| 响应 | 返回ICMP错误/TCP RST | 静默丢弃，无响应 |
| 暴露信息 | 暴露目标存在 | 隐藏目标存在 |
| 扫描探测 | 可被探测到 | 不可被探测 |
| 客户端体验 | 快速失败 | 等待超时 |
| 适用场景 | 内部网络 | 对外部网络 |

---

### 7.3 边界测试与改进方案

#### 选择的问题

**dmz:8080对外开放，可能被DDoS攻击**

#### 风险分析

dmz:8080作为对外Web服务，是攻击者的主要攻击目标。存在以下风险：

1. **DDoS攻击**：攻击者可能利用大量僵尸主机发起海量并发连接，耗尽服务器资源（连接数、CPU、内存），导致服务不可用
2. **单IP耗尽**：没有连接数限制时，单IP可以无限建立连接，造成拒绝服务
3. **资源竞争**：恶意连接占用大量系统资源，影响正常用户的访问

**改进方案**：使用iptables connlimit模块限制每个源IP的并发连接数，防止单IP耗尽服务器资源。

#### 改进方案实现

```bash
# 限制单IP对dmz:8080的最大并发连接数为3
sudo ip netns exec fw iptables -I FORWARD 4 -i fw-office -o fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m connlimit --connlimit-above 3 --connlimit-mask 32 -j REJECT --reject-with tcp-reset

sudo ip netns exec fw iptables -I FORWARD 14 -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m connlimit --connlimit-above 3 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
```

#### 测试效果

| 测试项 | 结果 | 说明 |
|:-------|:-----|:-----|
| 单个连接 | ✅ 成功 | 返回HTML内容 |
| 4个并发连接 | 3个成功，1个被拒绝 | connlimit触发 |
| connlimit计数 | pkts>0 | 规则生效 |

---

### 7.4 高级任务：追踪包的完整变化过程

#### 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 | 10.10.10.2:56778 | 10.40.0.2:8080 | TCP | VPN封装前，TTL=64 |
| 2 | fw wg0 | 10.10.10.2:56778 | 10.40.0.2:8080 | TCP | VPN解封装后，TTL=64 |
| 3 | fw fw-dmz | 10.10.10.2:56778 | 10.40.0.2:8080 | TCP | 转发到dmz，TTL=63 |
| 4 | conntrack | 10.10.10.2→10.40.0.2:8080 | 10.40.0.2→10.10.10.2:56778 | TCP | 双向连接跟踪，[ASSURED] |

#### 包完整处理流程分析报告（300字）

本次实验追踪了 remote 通过 VPN 访问 dmz:8080 的完整包处理流程：

**1. remote wg0（封装前）**
包从 remote 的 wg0 接口发出，源地址为 10.10.10.2:56778，目标为 10.40.0.2:8080，TTL=64。这是 WireGuard 封装前的原始 TCP SYN 包，包含完整的 HTTP 请求。

**2. fw wg0（解封装后）**
包到达防火墙的 wg0 接口，经过 WireGuard 解封装后，包内容与 remote 端完全一致，源地址和目标地址不变，TTL=64。防火墙识别出这是一个发往 dmz 的请求。

**3. fw fw-dmz（转发）**
防火墙查找路由表，目标 10.40.0.2 在 fw-dmz 接口，包从该接口转发出去。此过程中 TTL 减为 63，表示包经过了一次路由跳转。此时包已从 VPN 隧道转换为物理网络包。

**4. conntrack 记录**
防火墙记录了完整的连接跟踪信息：原始方向 `src=10.10.10.2→dst=10.40.0.2:8080`，回复方向 `src=10.40.0.2→dst=10.10.10.2`。标记为 `[ASSURED]` 表示双向通信已成功确认。

**关键发现：**
- 包在 VPN 隧道中保持原始内容，只有 TTL 在转发时递减
- conntrack 自动跟踪双向连接，无需人工配置
- 防火墙在转发过程中不修改源/目标 IP，只做路由决策
- VPN 封装/解封装对应用层数据透明

## 八、故障排查

### 场景1：DNAT配置了但外网无法访问

#### 故障现象
- internet访问 `203.0.113.1:8080` 失败
- `iptables -t nat -L` 显示DNAT规则存在
- dmz上的服务正常运行

#### 重现故障

删除FORWARD链中 `fw-inet → fw-dmz` 的ACCEPT规则，制造故障：

```bash
# 查看当前规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "fw-inet.*fw-dmz.*8080"

# 删除ACCEPT规则（制造故障）
sudo ip netns exec fw iptables -D FORWARD 14

# 验证删除
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "fw-inet.*fw-dmz.*8080"
```

#### 排查过程

| 步骤 | 排查命令 | 结果 | 结论 |
|:-----|:---------|:-----|:-----|
| 1 | `iptables -t nat -L PREROUTING \| grep 8080` | DNAT规则存在（pkts=4） | DNAT配置正确 |
| 2 | `iptables -L FORWARD \| grep "fw-inet.*fw-dmz.*8080"` | 只有connlimit，无ACCEPT | ❌ FORWARD缺少放行规则 |
| 3 | `ip netns exec dmz ip route \| grep default` | default via 10.40.0.1 | dmz路由正确 |
| 4 | `conntrack -L \| grep 8080` | 无连接记录 | 包未到达dmz |
| 5 | 外网访问测试 | `Connection timed out` | ❌ 访问失败 |

#### 根本原因

FORWARD链缺少 `fw-inet → fw-dmz` 的ACCEPT规则，导致DNAT后的包无法转发到dmz。

#### 修复方法

```bash
# 恢复ACCEPT规则
sudo ip netns exec fw iptables -I FORWARD 14 -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

#### 验证修复

```bash
# 查看规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "fw-inet.*fw-dmz.*8080"

# 测试访问
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
```

**结果：** 返回HTML内容 ✅

---

### 场景2：VPN隧道握手正常但业务访问失败

#### 故障现象
- `wg show` 显示 `latest handshake` 正常
- `remote ping 10.40.0.2` 失败
- fw上没有相关日志

#### 原因1：FORWARD规则拒绝了VPN流量

**重现故障：** 删除VPN→dmz:8080的ACCEPT规则

```bash
# 查看当前VPN规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep wg0

# 删除ACCEPT规则（制造故障）
sudo ip netns exec fw iptables -D FORWARD 16

# 验证删除
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep wg0
```

**排查过程：**

| 步骤 | 排查命令 | 结果 | 结论 |
|:-----|:---------|:-----|:-----|
| 1 | `wg show` | latest handshake正常 | VPN隧道正常 |
| 2 | `ip route \| grep wg0` | 10.40.0.0/24 dev wg0 | remote路由正确 |
| 3 | `sysctl net.ipv4.ip_forward` | ip_forward=1 | fw转发已开启 |
| 4 | `iptables -L FORWARD \| grep wg0` | 缺少VPN→dmz:8080 ACCEPT | ❌ FORWARD规则缺失 |

**根本原因：** FORWARD链缺少 `wg0 → fw-dmz` 的ACCEPT规则，导致VPN流量无法转发到dmz。

**修复方法：**
```bash
sudo ip netns exec fw iptables -I FORWARD 16 -i wg0 -o fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

#### 原因2：AllowedIPs配置错误

**重现故障：** 修改remote的AllowedIPs，移除10.40.0.0/24

```bash
# 查看当前AllowedIPs
sudo ip netns exec remote wg show | grep allowed

# 修改配置（移除10.40.0.0/24）
sudo ip netns exec remote wg set wg0 peer $(sudo ip netns exec remote wg show | grep peer | awk '{print $2}') allowed-ips 10.10.10.0/24,10.20.0.0/24

# 验证修改
sudo ip netns exec remote wg show | grep allowed
```

**排查过程：**

| 步骤 | 排查命令 | 结果 | 结论 |
|:-----|:---------|:-----|:-----|
| 1 | `wg show` | latest handshake正常 | VPN隧道正常 |
| 2 | `wg show \| grep allowed` | 缺少10.40.0.0/24 | ❌ AllowedIPs配置错误 |
| 3 | `ip route \| grep wg0` | 无10.40.0.0/24路由 | 路由缺失 |

**根本原因：** remote端AllowedIPs缺少 `10.40.0.0/24`，导致发往dmz的流量不走VPN隧道。

**修复方法：**
```bash
sudo ip netns exec remote wg set wg0 peer $(sudo ip netns exec remote wg show | grep peer | awk '{print $2}') allowed-ips 10.10.10.0/24,10.20.0.0/24,10.40.0.0/24
```

#### 如何快速定位问题

| 排查顺序 | 检查项 | 命令 | 判断标准 |
|:---------|:-------|:-----|:---------|
| 1 | VPN隧道状态 | `wg show` | latest handshake是否正常 |
| 2 | VPN路由 | `ip route \| grep wg0` | 目标网段是否在wg0 |
| 3 | AllowedIPs | `wg show \| grep allowed` | 目标网段是否包含 |
| 4 | IP转发 | `sysctl net.ipv4.ip_forward` | 是否为1 |
| 5 | FORWARD规则 | `iptables -L FORWARD \| grep wg0` | 是否有ACCEPT规则 |

---

### 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

#### 故障现象
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

#### 重现故障

删除ESTABLISHED,RELATED规则，制造故障：

```bash
# 查看当前状态检测规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5

# 删除ESTABLISHED,RELATED规则
sudo ip netns exec fw iptables -D FORWARD 3

# 验证删除
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5
```

#### 排查过程

| 步骤 | 排查命令 | 结果 | 结论 |
|:-----|:---------|:-----|:-----|
| 1 | `iptables -L FORWARD \| head -5` | 无ESTABLISHED,RELATED | ❌ 状态检测规则缺失 |
| 2 | `tcpdump -i fw-office -c 5` | 0 packets | SYN包被拦截 |
| 3 | `tcpdump -i fw-dmz -c 5` | 0 packets | SYN-ACK无法到达 |
| 4 | `conntrack -L \| grep 8080` | 无连接记录 | 连接未建立 |
| 5 | 测试访问 | `Connection timed out` | ❌ 访问失败 |

#### tcpdump验证

在fw的fw-office接口抓包：

```bash
sudo ip netns exec fw tcpdump -i fw-office -c 5 -n port 8080
```

**结果：** 0 packets captured，说明SYN包在FORWARD链被connlimit规则拦截。

#### 根本原因

缺少 `ESTABLISHED,RELATED` 规则后，TCP三次握手中的SYN-ACK回包不属于 `NEW` 状态，无法通过FORWARD链。SYN包到达fw-office接口后，被connlimit规则匹配并REJECT，后续的SYN-ACK无法到达dmz。

#### 修复方法

```bash
sudo ip netns exec fw iptables -I FORWARD 3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

#### ESTABLISHED,RELATED的必要性

- **ESTABLISHED**：允许已建立连接的双向通信，包括SYN-ACK回包
- **RELATED**：允许FTP等协议的辅助连接
- **没有此规则时**：SYN-ACK回包被拦截，TCP三次握手无法完成
- **状态检测是防火墙的核心功能**：保证合法连接的双向通信

#### 验证修复

```bash
# 查看规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5

# 重新测试
sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080/
```

**结果：** 返回HTML内容 ✅

---

### 故障排查总结

| 场景 | 故障现象 | 根本原因 | 修复方法 |
|:-----|:---------|:---------|:---------|
| 1 | 外网访问dmz:8080失败 | FORWARD缺少ACCEPT规则 | 恢复ACCEPT规则 |
| 2 | VPN握手正常但访问失败 | FORWARD规则缺失/AllowedIPs错误 | 恢复规则或修正AllowedIPs |
| 3 | TCP三次握手的SYN-ACK被拦截 | 缺少ESTABLISHED,RELATED规则 | 恢复状态检测规则 |

### 故障排查方法论

1. **逐层排查**：从物理层→网络层→传输层→应用层
2. **确认正常状态**：先确认哪些是正常的（如VPN隧道状态）
3. **二分定位**：在关键节点抓包，确定包在哪一步丢失
4. **查看计数器**：iptables的pkts计数可以快速定位规则是否命中
5. **conntrack分析**：查看连接跟踪表确认连接状态

## 九、遇到的问题和解决方法

### 问题1：接口名超过16字符导致iptables报错

**现象：**
```
iptables v1.8.13 (nf_tables): interface name `veth-fw-internet' must be shorter than 16 characters
```

**原因：** iptables要求接口名长度不超过15个字符，`veth-fw-internet` 长度为17个字符。

**解决方法：** 将所有接口名缩短：

| 原接口名 | 新接口名 |
|:---------|:---------|
| veth-fw-internet | fw-inet |
| veth-fw-office | fw-office |
| veth-fw-guest | fw-guest |
| veth-fw-dmz | fw-dmz |
| veth-inet | inet |

---

### 问题2：rp_filter导致VPN包被丢弃

**现象：** VPN隧道建立成功，但业务访问超时，tcpdump显示包到达wg0但没有转发。

**原因：** Linux内核的rp_filter（反向路径过滤）默认值为1，会检查包的源IP是否匹配路由表，来自wg0的包源IP为10.10.10.2，但路由表中没有对应回程路由，导致包被丢弃。

**解决方法：** 关闭rp_filter
```bash
sudo ip netns exec fw sysctl -w net.ipv4.conf.all.rp_filter=0
sudo ip netns exec fw sysctl -w net.ipv4.conf.wg0.rp_filter=0
sudo ip netns exec fw sysctl -w net.ipv4.conf.fw-office.rp_filter=0
```

---

### 问题3：iptables LOG规则无输出

**现象：** 配置了LOG规则，但 `dmesg` 和 `journalctl` 都看不到日志。

**原因：** Kali 2025.2默认使用nf_tables后端，LOG输出方式与legacy不同。

**解决方法：** 切换到iptables-legacy
```bash
sudo ip netns exec fw update-alternatives --set iptables /usr/sbin/iptables-legacy
```

或者使用NFLOG + tcpdump捕获日志：
```bash
sudo ip netns exec fw tcpdump -i nflog:1 -n -v
```

---

### 问题4：fw命名空间内无syslog服务

**现象：** 切换到iptables-legacy后，LOG规则仍无输出。

**原因：** fw命名空间内没有运行syslog服务，iptables LOG无法写入日志文件。

**解决方法：** 使用NFLOG替代LOG，通过tcpdump实时捕获
```bash
sudo ip netns exec fw iptables -I FORWARD 9 -i fw-guest -o fw-office -j NFLOG --nflog-prefix "GUEST-TO-OFFICE: " --nflog-group 1
sudo ip netns exec fw tcpdump -i nflog:1 -n -v
```

---

### 问题5：remote没有默认路由导致WireGuard连接失败

**现象：** WireGuard隧道无法建立，`wg show` 显示无handshake。

**原因：** remote命名空间只有lo接口，没有到fw的物理接口和默认路由。

**解决方法：** 创建veth对并配置IP和默认路由
```bash
sudo ip link add fw-vpn type veth peer name remote
sudo ip link set fw-vpn netns fw
sudo ip link set remote netns remote
sudo ip netns exec fw ip addr add 192.168.200.1/24 dev fw-vpn
sudo ip netns exec remote ip addr add 192.168.200.2/24 dev remote
sudo ip netns exec remote ip route add default via 192.168.200.1
```

---

### 问题6：WireGuard AllowedIPs不包含VPN网关导致ping失败

**现象：** VPN隧道建立成功，但 `ping 10.10.10.1` 显示 `Destination Host Unreachable`。

**原因：** remote端AllowedIPs只包含 `10.20.0.0/24,10.40.0.0/24`，不包含 `10.10.10.1`。

**解决方法：** 在AllowedIPs中添加VPN网络
```bash
AllowedIPs = 10.10.10.0/24,10.20.0.0/24,10.40.0.0/24
```

---

### 问题7：internet访问内网无日志

**现象：** 执行 `internet curl 10.20.0.2:8000` 失败，但LOG规则无输出。

**原因：** internet命名空间没有到 `10.20.0.0/24` 和 `10.40.0.0/24` 的路由。

**解决方法：** 添加静态路由
```bash
sudo ip netns exec internet ip route add 10.20.0.0/24 via 203.0.113.1
sudo ip netns exec internet ip route add 10.40.0.0/24 via 203.0.113.1
```

---

### 问题8：VPN访问dmz:8080被拒绝

**现象：** VPN隧道正常，ping 10.10.10.1正常，但 `curl 10.40.0.2:8080` 超时。

**原因：** FORWARD链缺少 `wg0 → fw-dmz:8080 ACCEPT` 规则。

**解决方法：** 添加ACCEPT规则
```bash
sudo ip netns exec fw iptables -I FORWARD 16 -i wg0 -o fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

---

### 问题9：删除ESTABLISHED,RELATED后TCP连接失败

**现象：** 删除状态检测规则后，office curl dmz:8080超时，tcpdump抓不到包。

**原因：** 缺少ESTABLISHED,RELATED规则，SYN包被connlimit规则拦截。

**解决方法：** 恢复状态检测规则
```bash
sudo ip netns exec fw iptables -I FORWARD 3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

---

### 问题10：不同命名空间日志查看

**现象：** 在宿主机执行 `journalctl` 看不到防火墙LOG。

**原因：** 防火墙规则在fw命名空间内，日志也在fw命名空间内。

**解决方法：** 使用 `ip netns exec fw` 进入命名空间查看
```bash
sudo ip netns exec fw dmesg | grep "GUEST-TO-OFFICE"
sudo ip netns exec fw journalctl -k --no-pager | grep "GUEST-TO-OFFICE"
```

---

### 问题汇总表

| 序号 | 问题 | 解决方法 | 影响范围 |
|:-----|:-----|:---------|:---------|
| 1 | 接口名超长 | 缩短接口名 | 基础网络 |
| 2 | rp_filter丢包 | 关闭rp_filter | VPN转发 |
| 3 | LOG无输出 | 切换iptables-legacy | 日志审计 |
| 4 | 无syslog | 使用NFLOG+tcpdump | 日志捕获 |
| 5 | remote无路由 | 创建veth对配置路由 | VPN连接 |
| 6 | AllowedIPs缺失 | 添加VPN网段 | VPN连接 |
| 7 | internet无路由 | 添加静态路由 | 外网访问 |
| 8 | FORWARD规则缺失 | 添加ACCEPT规则 | VPN访问 |
| 9 | 状态检测缺失 | 恢复ESTABLISHED规则 | TCP连接 |
| 10 | 命名空间日志隔离 | 使用ip netns exec | 日志查看 |

---

## 十、总结与思考

### 企业网络安全架构的整体理解

通过本次实验，我深入理解了企业网络安全架构的层次化设计思想。一个完整的企业边界网络安全方案，需要从网络隔离、访问控制、安全接入、审计监控和攻防对抗五个维度进行设计。

#### 1. 网络隔离是基础

通过namespace模拟了办公区、访客区、DMZ区和外网区的隔离。不同区域之间通过防火墙进行隔离，体现了"纵深防御"的理念。DMZ区的设计尤为关键，它作为内外网之间的缓冲区，既对外提供服务，又保护内网安全。

#### 2. 访问控制是核心

基于最小权限原则配置防火墙策略，默认拒绝所有流量，只放行明确需要的访问。这种"白名单"策略比"黑名单"更安全。通过iptables实现的状态检测，能够识别合法连接的返回包，进一步提高了安全性。

#### 3. VPN接入是延伸

WireGuard作为现代VPN解决方案，配置简单、性能高效。通过AllowedIPs精确控制VPN流量的路由范围，确保VPN用户只能访问授权资源。这体现了"零信任"思想——即使是合法用户，也只授予最小必要权限。

#### 4. 安全审计是保障

通过LOG规则记录所有被拒绝的流量，构建了完整的安全审计体系。日志分析可以帮助安全管理员识别攻击模式、发现异常行为、追溯安全事件。速率限制机制防止日志洪水攻击，确保审计系统的稳定性。

#### 5. 攻防演练是验证

通过模拟攻击和故障排查，验证了防火墙策略的有效性。攻击方任务展示了攻击者的思路和方法，防御方任务展示了如何从日志中识别攻击，故障排查任务展示了如何快速定位和解决问题。

### 个人思考与收获

#### 对网络安全架构的理解

在实际企业环境中，网络安全是一个持续演进的过程。没有一劳永逸的安全方案，需要根据威胁形势的变化不断调整策略。本次实验虽然在虚拟环境中进行，但其中的设计思路和配置方法可以直接应用于真实场景。

#### 关键技术能力提升

1. **Linux网络命名空间**：理解了网络隔离的实现原理
2. **iptables防火墙**：掌握了规则链、状态检测、NAT的配置方法
3. **WireGuard VPN**：理解了加密隧道的工作原理
4. **日志审计**：学习了安全日志的配置和分析方法
5. **故障排查**：掌握了系统化的排错思路和方法

#### 关键教训

- **命名规范很重要**：接口名超长会导致iptables无法识别
- **不要忽视系统配置**：rp_filter等内核参数对网络有重大影响
- **LOG规则需要仔细测试**：确保日志能正确输出
- **VPN配置中路由和AllowedIPs需要精确匹配**：否则隧道建立但业务不通
- **状态检测是防火墙的核心功能**：移除它会导致TCP连接失败

#### 对企业网络安全的思考

**1. 最小权限原则**

本次实验的核心思想是最小权限原则。默认拒绝所有流量，只放行明确需要的访问。这种思想应该贯穿于整个网络架构设计：

- 防火墙策略：只开放必要的端口和服务
- VPN接入：只授权必要的网段访问
- 区域隔离：不同区域之间严格控制通信

**2. 安全与易用性的平衡**

REJECT vs DROP 的选择就体现了安全与易用性的平衡。对外部网络使用DROP更安全，对内部网络使用REJECT更友好。在实际场景中，需要根据风险等级权衡。

**3. 纵深防御**

单一安全措施无法保证绝对安全，需要构建多层防御体系：

- 第一层：网络隔离（分区）
- 第二层：访问控制（防火墙）
- 第三层：安全接入（VPN）
- 第四层：审计监控（日志）
- 第五层：攻防演练（验证）

**4. 可观测性**

安全体系需要具备可观测性。没有日志记录的安全策略是"黑盒"，无法验证其有效性，也无法在攻击发生时追溯。LOG规则是安全体系的重要组成部分。

#### 对未来学习的启示

通过本次实验，我认识到网络安全是一个综合性领域，需要掌握网络、系统、安全、运维等多方面知识。今后的学习应该注重：

- **理论与实践结合**：不仅要理解原理，更要动手实践
- **系统性思维**：从整体架构角度理解各个组件的关系
- **故障排查能力**：掌握系统化的排错方法
- **安全意识**：在设计方案时始终考虑安全因素

本次实验为我今后从事网络安全相关工作打下了坚实的基础。通过亲手搭建一个完整的企业级网络安全架构，我不仅掌握了技术工具的使用，更重要的是理解了安全方案设计的思路和方法。