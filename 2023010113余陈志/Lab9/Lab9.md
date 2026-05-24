# Lab9：从访问控制到记录在案：防火墙的双重能力

## 实验背景

前面我们已经学过包结构、TCP 连接、防火墙规则和 NAT。但真实网络里，光会写几条规则还不够——有两个问题必须同时解决：

1. **分区**：主机本来就不应该混在一起。办公区、DMZ、访客区必须隔开。
2. **审计**：防火墙拦了流量，但你怎么知道有没有人在尝试跨区访问？如果没有日志，防火墙就是一个"哑巴保安"——能拦人，但不记录谁来过、什么时候来的、来了多少次。

本次实验把这两个问题**放在一起解决**，因为真实环境中的防火墙从来都是"分区 + 审计"一体化的。

实验分三个阶段，层层递进：

| 阶段 | 内容 | 核心问题 |
| :--- | :--- | :--- |
| 一 | 用 namespace 搭建网络分区，配上访问控制规则 | "谁能访问谁？" |
| 二 | 引入 LOG target，让每一次拦截都留下记录 | "谁在尝试访问谁？" |
| 三 | 用前缀过滤和速率限制管理日志 | "日志多了怎么办？" |

> **环境说明**：本实验使用 Linux `network namespace` 在一台机器上模拟 4 个区域（`office`、`guest`、`dmz`、`fw`）。
> `iptables -j LOG` 写入内核日志，用 `journalctl -k` 或 `dmesg` 读取。
> namespace 不隔离内核日志，所有 LOG 规则都写入同一份内核日志。

---

## 实验拓扑

```text
office (10.0.1.2) ----\
                       \
                        fw (10.0.1.1 / 10.0.2.1 / 10.0.3.1)
                       /  \
guest  (10.0.2.2) ---/    dmz (10.0.3.2)
```

**地址规划：**

| 区域 | 地址 |
| :--- | :--- |
| `office` | `10.0.1.2/24` |
| `fw` ↔ office | `10.0.1.1/24` |
| `guest` | `10.0.2.2/24` |
| `fw` ↔ guest | `10.0.2.1/24` |
| `dmz` | `10.0.3.2/24` |
| `fw` ↔ dmz | `10.0.3.1/24` |

**访问控制目标：**

1. `office` 可以访问 `dmz` 的 Web 服务（`10.0.3.2:8080`）
2. `guest` 不能访问 `dmz`
3. `guest` 不能访问 `office`

---

## 第一阶段：搭建网络分区

### 任务 1：创建 namespace 并组网

#### 1.1 创建 4 个 namespace

```bash
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add fw
```

#### 1.2 创建 veth 对

```bash
sudo ip link add veth-office type veth peer name veth-fw-office
sudo ip link add veth-guest  type veth peer name veth-fw-guest
sudo ip link add veth-dmz    type veth peer name veth-fw-dmz
```

#### 1.3 将 veth 放入对应的 namespace

```bash
sudo ip link set veth-office    netns office
sudo ip link set veth-fw-office netns fw

sudo ip link set veth-guest     netns guest
sudo ip link set veth-fw-guest  netns fw

sudo ip link set veth-dmz       netns dmz
sudo ip link set veth-fw-dmz    netns fw
```

#### 1.4 配置 IP 地址并启用接口

```bash
# 配地址
sudo ip netns exec office ip addr add 10.0.1.2/24 dev veth-office
sudo ip netns exec fw     ip addr add 10.0.1.1/24 dev veth-fw-office
sudo ip netns exec guest  ip addr add 10.0.2.2/24 dev veth-guest
sudo ip netns exec fw     ip addr add 10.0.2.1/24 dev veth-fw-guest
sudo ip netns exec dmz    ip addr add 10.0.3.2/24 dev veth-dmz
sudo ip netns exec fw     ip addr add 10.0.3.1/24 dev veth-fw-dmz

# 启用 lo
sudo ip netns exec office ip link set lo up
sudo ip netns exec guest  ip link set lo up
sudo ip netns exec dmz    ip link set lo up
sudo ip netns exec fw     ip link set lo up

# 启用 veth
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec guest  ip link set veth-guest up
sudo ip netns exec dmz    ip link set veth-dmz up
sudo ip netns exec fw     ip link set veth-fw-office up
sudo ip netns exec fw     ip link set veth-fw-guest  up
sudo ip netns exec fw     ip link set veth-fw-dmz    up
```

#### 1.5 配置默认路由

```bash
sudo ip netns exec office ip route add default via 10.0.1.1
sudo ip netns exec guest  ip route add default via 10.0.2.1
sudo ip netns exec dmz    ip route add default via 10.0.3.1
```

#### 1.6 在 fw 中开启 IP 转发

```bash
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
```

#### 1.7 验证连通性（此时还没有任何防火墙规则）

在 `dmz` 中启动 Web 服务：

```bash
sudo ip netns exec dmz python3 -m http.server 8080
```

在另一个终端测试：

```bash
# 这两条在配规则前都应该成功（因为还没有任何拦截）
sudo ip netns exec office curl --max-time 3 http://10.0.3.2:8080/
sudo ip netns exec guest  curl --max-time 3 http://10.0.3.2:8080/
```

> 保持 `dmz` 中的 `python3 -m http.server 8080` 持续运行，后续测试都要用到。

---

### 任务 2：配置访问控制规则（无日志版本）

现在在 `fw` 中设置 iptables 规则，实现访问控制目标。

```bash
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -s 10.0.1.0/24 -d 10.0.3.2 -p tcp --dport 8080 -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -s 10.0.2.0/24 -d 10.0.3.2 -p tcp --dport 8080 -j REJECT
sudo ip netns exec fw iptables -A FORWARD -s 10.0.2.0/24 -d 10.0.1.0/24 -j REJECT
```

查看规则：

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

你应该看到：

```text
num  target    prot opt source          destination
1    ACCEPT    all  --  0.0.0.0/0       0.0.0.0/0       ctstate RELATED,ESTABLISHED
2    ACCEPT    tcp  --  10.0.1.0/24     10.0.3.2        tcp dpt:8080
3    REJECT    tcp  --  10.0.2.0/24     10.0.3.2        tcp dpt:8080
4    REJECT    all  --  10.0.2.0/24     10.0.1.0/24
```

**规则解读（很重要，请理解后再继续）：**

| 行号 | 作用 | 为什么放在这个位置 |
| :--- | :--- | :--- |
| 1 | 允许已建立连接的回包通过 | 否则 TCP 三次握手永远无法完成 |
| 2 | 放行 `office -> dmz:8080` | 白名单：合法业务流量 |
| 3 | 拒绝 `guest -> dmz:8080` | 访客不能访问内部服务 |
| 4 | 拒绝 `guest -> office` | 访客不能接触办公网 |
| 默认 | 其余全部丢弃（`-P FORWARD DROP`） | 白名单模型：只放已知合法流量 |

---

### 任务 3：测试访问控制

#### 3.1 测试 `office -> dmz`（应该成功）

```bash
sudo ip netns exec office curl --max-time 3 http://10.0.3.2:8080/
```

预期：返回 HTML 目录列表。

#### 3.2 测试 `guest -> dmz`（应该被拒绝）

```bash
sudo ip netns exec guest curl --max-time 3 http://10.0.3.2:8080/
```

预期：`Connection refused` 或超时。

#### 3.3 测试 `guest -> office`（应该被拒绝）

```bash
sudo ip netns exec guest curl --max-time 3 http://10.0.1.2:8080/
```

预期：连接失败。

**填写下表：**

| 测试项 | 结果（成功/失败） | 现象描述 |
| :----- | :-------------- | :------- |
| `office -> dmz:8080` |成功|防火墙规则 2 明确允许 10.0.1.0/24 访问 10.0.3.2:8080，流量会被正常转发，curl 可正常访问服务|
| `guest -> dmz:8080` |失败|防火墙规则 3 拒绝 10.0.2.0/24 访问 10.0.3.2:8080，且第一张图中 sudo ip netns exec guest curl http://10.0.3.2:8080/ 返回 Could not connect to server，验证了访问失败|
| `guest -> office` |失败|防火墙规则 4 拒绝 10.0.2.0/24 访问 10.0.1.0/24 的所有流量，且第一张图中 sudo ip netns exec guest curl http://10.0.1.2:8080/ 返回 Could not connect to server，验证了访问失败|

**第一阶段小结**：现在防火墙在正常工作——该放的放，该拦的拦。你可以截图 `topology.png`（地址与连通性）和 `baseline_rules.png`（规则 + 测试结果），然后我们进入第二阶段。

---

## 第二阶段：让防火墙"开口说话"

第一阶段做完了，但你发现一个问题没有？

> `guest` 访问 `dmz` 被拒绝了——但**你拿不出任何证据**证明"有人尝试过"。

如果是真实网络，安全团队需要知道：
- 谁在尝试跨区访问？（源 IP）
- 想访问什么服务？（目的端口）
- 什么时候发生的？（时间戳）
- 发生了多少次？（频次）

没有日志，这些问题全部无法回答。接下来我们给防火墙加上"眼睛"。

---

### 新工具：iptables LOG target 与内核日志

#### LOG target 是什么

`LOG` 是 iptables 的一个特殊 target。与 `ACCEPT`、`DROP`、`REJECT` 不同，**LOG 不终止规则匹配**——它把命中的包的信息写入内核日志，然后继续向后匹配下一条规则。

这意味着 LOG 必须和 DROP 或 REJECT **成对出现**：

```text
规则 N：   匹配条件 → LOG     （记录）
规则 N+1： 匹配条件 → REJECT  （拦截）
```

同一个包先命中 LOG 留下记录，再命中 REJECT 被拒绝。

#### --log-prefix：给日志打标签

```bash
iptables ... -j LOG --log-prefix "GUEST-TO-DMZ: "
```

`--log-prefix` 在日志行开头加一段固定前缀，最长 29 个字符（含末尾空格）。有了前缀，就能用 `grep` 精确过滤出某类事件。

#### 读取内核日志

`iptables -j LOG` 写入的是 Linux **内核日志**。两种常用读法：

| 命令 | 适用场景 | 关键参数 |
| :--- | :--- | :--- |
| `sudo journalctl -k -f` | systemd 系统（推荐） | `-k`=只看内核日志，`-f`=实时追踪 |
| `sudo dmesg -w` | 无 systemd 或更简单环境 | `-w`=实时显示新消息 |

加过滤：

```bash
sudo journalctl -k -f --grep "GUEST-TO-DMZ"    # journalctl 方式
sudo dmesg -w | grep "GUEST-TO-DMZ"            # dmesg 方式
```

#### 一行日志长什么样

```text
[12345.678901] GUEST-TO-DMZ: IN=veth-fw-guest OUT=veth-fw-dmz
  MAC=... SRC=10.0.2.2 DST=10.0.3.2 LEN=60 TOS=0x00
  PROTO=TCP SPT=54321 DPT=8080 FLAGS=SYN
```

| 字段 | 含义 |
| :--- | :--- |
| `[12345.678]` | 系统启动后的秒数（内核时间戳） |
| `GUEST-TO-DMZ:` | 你设置的 `--log-prefix` |
| `IN=` | 包从哪个接口进入 |
| `OUT=` | 包将从哪个接口转发出去 |
| `MAC=` | 二层头信息，通常能看到源/目的 MAC；排查链路方向时有帮助 |
| `SRC=` | 源 IP 地址 |
| `DST=` | 目的 IP 地址 |
| `LEN=` | IP 包总长度（字节） |
| `TOS=` | Type of Service / DSCP 相关字段，表示服务质量标记 |
| `PREC=` | 旧式优先级字段，现代环境中通常是 `0x00` |
| `TTL=` | 生存时间，每经过一跳会减 1，可辅助判断路径长度 |
| `ID=` | IP 分片标识，同一报文分片后通常共享同一个 ID |
| `DF` | Don't Fragment 标志，表示该包不允许被分片 |
| `PROTO=` | 协议（TCP / UDP / ICMP） |
| `SPT=` | 源端口 |
| `DPT=` | 目的端口 |
| `WINDOW=` | TCP 窗口大小，表示接收端当前可接受的数据量 |
| `RES=` | TCP 头中的保留位，通常为 `0x00` |
| `SYN` / `ACK` / `FIN` / `RST` | TCP 标志位；`SYN` 常表示新连接请求，`RST` 常表示异常中断或拒绝 |
| `URGP=` | TCP 紧急指针，通常为 0 |

看到一行日志时，最值得先读的通常是这几组字段：

1. `GUEST-TO-DMZ:`：这是谁触发的哪一类规则。
2. `IN=` 和 `OUT=`：包是从哪个区域进、准备往哪个区域去。
3. `SRC=` 和 `DST=`：是谁访问谁。
4. `PROTO=`、`SPT=`、`DPT=`：访问的是哪种协议、从哪个源端口发起、目标服务端口是多少。
5. `SYN`/`ACK`/`RST`：这是新连接、已建立连接中的报文，还是异常/拒绝相关报文。

---

### 任务 4：为拦截规则加上 LOG

现在把第一阶段中两条 REJECT 规则改造成"先 LOG，再 REJECT"的形式。

#### 4.1 清空现有规则，保留默认策略

```bash
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -P FORWARD DROP
```

#### 4.2 加回放行规则（不变）

```bash
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -s 10.0.1.0/24 -d 10.0.3.2 -p tcp --dport 8080 -j ACCEPT
```

#### 4.3 将 `guest -> dmz` 改造成 LOG + REJECT

```bash
# 先 LOG
sudo ip netns exec fw iptables -A FORWARD \
  -s 10.0.2.0/24 -d 10.0.3.2 -p tcp --dport 8080 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

# 再 REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -s 10.0.2.0/24 -d 10.0.3.2 -p tcp --dport 8080 \
  -j REJECT
```

**关键点**：LOG 和 REJECT 的匹配条件完全相同，LOG 必须排在 REJECT 前面。

#### 4.4 将 `guest -> office` 也改造成 LOG + REJECT

```bash
sudo ip netns exec fw iptables -A FORWARD \
  -s 10.0.2.0/24 -d 10.0.1.0/24 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -s 10.0.2.0/24 -d 10.0.1.0/24 \
  -j REJECT
```

#### 4.5 查看完整规则

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

预期输出：

```text
num  target    prot opt source          destination
1    ACCEPT    all  --  0.0.0.0/0       0.0.0.0/0       ctstate RELATED,ESTABLISHED
2    ACCEPT    tcp  --  10.0.1.0/24     10.0.3.2        tcp dpt:8080
3    LOG       tcp  --  10.0.2.0/24     10.0.3.2        tcp dpt:8080  LOG flags 0 ... prefix "GUEST-TO-DMZ: "
4    REJECT    tcp  --  10.0.2.0/24     10.0.3.2        tcp dpt:8080  reject-with icmp-port-unreachable
5    LOG       all  --  10.0.2.0/24     10.0.1.0/24     LOG flags 0 ... prefix "GUEST-TO-OFFICE: "
6    REJECT    all  --  10.0.2.0/24     10.0.1.0/24     reject-with icmp-port-unreachable
```

**填写下表：**

| 项目 | 你的填写 |
| :--- | :------- |
| LOG 规则条数 |2 条|
| REJECT 规则条数 |2 条|
| `GUEST-TO-DMZ:` LOG 位于第几行 |第 3 行|
| 对应的 REJECT 位于第几行 |第 4 行|
| LOG 与 REJECT 的匹配条件是否完全一致 |是|

**简答：**

1. 如果把 LOG 放在 REJECT 之后，LOG 规则还会被命中吗？为什么？

> 答：iptables 的规则是按顺序逐条匹配的，一旦数据包匹配到某条规则并执行了动作，就会停止后续规则的匹配。
当数据包匹配到 REJECT 规则时，会直接被拒绝并丢弃（同时发送 ICMP 不可达包），数据包不会继续往下传递，因此后面的 LOG 规则就永远不会被触发了。
LOG 规则本身不会中断数据包流程，但如果前面的 REJECT 规则先匹配到了数据包，数据包就会被丢弃，无法到达 LOG 规则的位置。

---

### 任务 5：触发日志并实时观察

#### 5.0 如果规则命中了但看不到日志，先处理这个常见问题

在 Ubuntu 24.04 这类使用 `iptables-nft` 的环境中，如果你已经确认 `LOG` 规则命中计数在增长，但 `journalctl -k` 和 `dmesg` 仍然看不到任何 `GUEST-TO-*` 日志，通常是因为内核默认不记录来自非初始 network namespace 的 netfilter LOG。

先在**宿主机**执行：

```bash
sudo sysctl -w net.netfilter.nf_log_all_netns=1
```

然后重新触发一次 `guest` 的违规访问，再观察日志。这个开关要在宿主机设置，不是在 `fw` namespace 里设置。

#### 5.1 打开日志监视（终端 D）

```bash
# 推荐
sudo journalctl -k -f

# 或
sudo dmesg -w
```

保持这个终端持续运行，切换到另一个终端（终端 B）触发访问。

#### 5.2 触发 guest 的违规访问

在终端 B 分别执行：

```bash
# guest -> dmz（会被 REJECT，预期产生 LOG）
sudo ip netns exec guest curl --max-time 3 http://10.0.3.2:8080/

# guest -> office（会被 REJECT，预期产生 LOG）
sudo ip netns exec guest curl --max-time 3 http://10.0.1.2:8080/

# office -> dmz（会被 ACCEPT，预期不产生 LOG）
sudo ip netns exec office curl --max-time 3 http://10.0.3.2:8080/
```

每次执行后立刻切回终端 D，观察内核日志的变化。

#### 5.3 填写下表

| 测试 | 访问结果 | 是否出现 LOG | 日志前缀 |
| :--- | :------- | :---------- | :------- |
| `guest -> dmz:8080` |失败（curl 报错 Could not connect to server）|是|GUEST-TO-DMZ:|
| `guest -> office` |失败（curl 报错 Could not connect to server）|是|GUEST-TO-OFFICE:|
| `office -> dmz:8080` |成功（正常访问到网页内容）|否|无|

**从终端 D 复制一条实际日志行：**

```text
May 21 09:18:17 DESKTOP-Q2V2U99 kernel: GUEST-T
O-OFFICE: IN=veth-fw-guest OUT=veth-fw-office M
AC=e6:59:a1:24:bd:d0:46:a5:2d:83:29:08:08:00 SR
C=10.0.2.2 DST=10.0.1.2 LEN=60 TOS=0x00 PREC=0x
00 TTL=63 ID=40146 DF PROTO=TCP SPT=34440 DPT=8
080 WINDOW=64240 RES=0x00 SYN URGP=0
```

**简答：**

1. `office -> dmz` 成功了但没有日志，这合理吗？如果想记录"所有被放行的流量"，应该怎么做？

> 答：合理。
合理性说明：iptables 的 LOG 规则仅对匹配到该规则的数据包生效。office -> dmz 的流量匹配了 ACCEPT 规则（第 2 行），被直接放行，不会继续向下匹配 LOG 或 REJECT 规则，因此不会产生日志，这是完全符合 iptables 按顺序匹配的逻辑的。
记录所有被放行流量的做法：
在 ACCEPT 规则之前添加 LOG 规则：例如在第 2 行之前插入一条匹配 10.0.1.0/24 -> 10.0.3.2:8080 的 LOG 规则，这样流量在被放行前会先触发日志。
全局放行流量的日志记录：在 FORWARD 链的最前面添加一条 LOG 规则，匹配所有 state RELATED,ESTABLISHED 或需要放行的流量，确保放行前先记录日志。
也可以使用 --log-prefix 为放行流量设置专属前缀，便于区分日志。

2. 从日志里你能读出什么信息？"谁在访问谁的什么服务"能还原出来吗？

> 答：从日志中可以读出的信息：源 IP 地址（谁发起访问）、目的 IP 地址（访问谁）、源端口、目的端口（访问什么服务 / 端口）、协议类型（TCP/UDP）、数据包长度、TTL、连接状态（如 SYN）等关键信息。
“谁在访问谁的什么服务”完全可以还原出来：
例如，日志中会包含 SRC=10.0.2.x DST=10.0.3.2 DPT=8080 这类字段，结合之前设置的 GUEST-TO-DMZ: 前缀，就能明确还原出是 guest 网段的主机在访问 dmz 网段 10.0.3.2 的 8080 端口（HTTP 服务）。

---

### 任务 6：用前缀过滤日志

内核日志里不只有 iptables 的消息，还有各种驱动、硬件事件。如果不过滤，想在嘈杂的输出中找到防火墙日志会很困难。

#### 6.1 按前缀精确过滤

```bash
# 只看 GUEST-TO-DMZ 事件
sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager

# dmesg 方式
sudo dmesg | grep "GUEST-TO-DMZ"
```

#### 6.2 按前缀模糊匹配

```bash
# 同时看 GUEST-TO-DMZ 和 GUEST-TO-OFFICE（共前缀）
sudo journalctl -k --grep "GUEST-TO" --no-pager
```

#### 6.3 统计每类事件各发生多少次

```bash
sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager    | wc -l
sudo journalctl -k --grep "GUEST-TO-OFFICE" --no-pager | wc -l
```

#### 6.4 循环多次触发，验证计数增长

```bash
for i in $(seq 1 5); do
  sudo ip netns exec guest curl --max-time 2 http://10.0.3.2:8080/ 2>/dev/null
done
```

再次统计，确认条数增加了 5。

**填写下表：**

| 项目 | 你的填写 |
| :--- | :------- |
| `GUEST-TO-DMZ` 总日志条数 |11 条|
| `GUEST-TO-OFFICE` 总日志条数 |1 条|
| 循环 5 次后 `GUEST-TO-DMZ` 增加了多少 |5 条（从 6 条→11 条，增加了 5 条）|
| 你使用的过滤命令 |sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager 或 sudo journalctl -k --grep "GUEST-TO-OFFICE" --no-pager|

**简答：**

1. `--log-prefix` + `grep` 组合，相当于给不同事件打了不同"标签"。在真实场景中这有什么实际价值？

> 答：快速分类与审计：不同前缀可以区分不同类型的流量事件（如非法访问、正常放行、端口扫描），使用 grep 可以快速过滤出目标日志，避免在海量日志中人工查找。
故障排查效率提升：当网络出现异常时，可以直接通过前缀定位到对应事件的日志，快速判断问题根源（如哪个网段在尝试访问哪个服务）。
安全监控与告警：可以基于不同前缀的日志设置告警规则，例如当出现大量 GUEST-TO-DMZ 日志时，触发异常访问告警。
日志可读性增强：--log-prefix 会在日志前添加自定义标记，即使不使用 grep，也能一眼识别出该日志对应的规则场景，便于理解。

2. 如果防火墙每秒拦截上千个包，不加限制地写 LOG 会有什么后果？

> 答：系统性能下降：高频写入日志会占用大量磁盘 I/O 和 CPU 资源，可能导致防火墙或服务器卡顿，甚至影响正常业务流量的转发。
日志文件膨胀：无限制的日志会快速占用磁盘空间，导致磁盘爆满，甚至引发系统日志服务异常（如 journalctl 崩溃）。
关键日志被淹没：大量重复的拦截日志会覆盖或稀释真正重要的日志（如正常业务日志、异常攻击日志），增加排查难度。
日志服务过载：日志服务（如 syslog、journald）在处理海量日志时可能出现延迟、丢包或崩溃，导致日志无法正常记录。

---

## 第三阶段：日志速率控制

### 任务 7：用 --limit 限制日志写入频率

如果每秒有大量同类包被拦截（比如遭遇扫描攻击），不加限制的 LOG 会让日志系统不堪重负，甚至影响系统性能。`-m limit` 模块可以限制每条规则的日志写入频率。

#### 7.1 删除原来的 `GUEST-TO-DMZ` LOG 规则

```bash
# 先查行号
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers

# 按行号删除 GUEST-TO-DMZ 的 LOG 规则
sudo ip netns exec fw iptables -D FORWARD <行号>
```

#### 7.2 插入带速率限制的 LOG 规则

```bash
sudo ip netns exec fw iptables -I FORWARD 3 \
  -s 10.0.2.0/24 -d 10.0.3.2 -p tcp --dport 8080 \
  -m limit --limit 3/min --limit-burst 5 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
```

| 参数 | 含义 |
| :--- | :--- |
| `-I FORWARD 3` | 插入到第 3 行，保持在 REJECT 规则之前 |
| `-m limit` | 使用 `limit` 模块进行速率匹配 |
| `--limit 3/min` | 稳定状态下每分钟最多写 3 条日志 |
| `--limit-burst 5` | 允许初始突发最多 5 条，之后降到 `--limit` 速率 |

#### 7.3 快速触发 10 次访问

```bash
# 先记下本轮测试开始时间，避免把历史日志也算进去
start=$(date '+%Y-%m-%d %H:%M:%S')

for i in $(seq 1 10); do
  sudo ip netns exec guest curl --max-time 1 http://10.0.3.2:8080/ 2>/dev/null
done
```

#### 7.4 统计实际产生的日志条数

```bash
# 只统计“本轮测试开始以后”新增的日志
sudo journalctl -k --since "$start" --grep "GUEST-TO-DMZ" --no-pager | wc -l

# 同时看规则计数，直观看到“10 次访问都被 REJECT，但 LOG 只记了少数几次”
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

**关键观察**：

1. `guest -> dmz` 的 10 次访问仍然都会失败，说明后面的 `REJECT` 对每次访问都生效。
2. `journalctl --since "$start" ... | wc -l` 统计到的新增日志条数不超过 `--limit-burst` 的值（5 条）。
3. `iptables -L FORWARD -n -v` 中第 4 条 `REJECT` 的命中次数会明显大于第 3 条 `LOG` 的命中次数，这就是 `limit` 生效的直接证据。

如果你想把这个现象看得更清楚，可以连续执行两次下面的对照命令：

```bash
sudo journalctl -k --since "$start" --grep "GUEST-TO-DMZ" --no-pager
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

你应该能看到：日志行数最多只有 5 条，但 `REJECT` 规则已经处理了 10 次访问。

#### 7.5 填写下表

| 项目 | 你的填写 |
| :--- | :------- |
| 触发访问次数 | 10 |
| 实际写入日志条数 |5 条（终端输出 wc -l 结果为 5）|
| `--limit-burst 5` 的含义 |表示初始突发最多允许匹配 5 个数据包，超出限制的数据包不会触发该 LOG 规则；配合 avg 3/min，后续每分钟最多再记录 3 条日志|
| 未记录的访问是否仍然被 REJECT |是|

**简答：**

1. `--limit` 只控制了 LOG 的写入频率，但后面的 REJECT 仍对每个包生效。这说明 LOG 和 REJECT 在逻辑上是什么关系？

> 答：LOG 和 REJECT 是相互独立、互不影响的两条规则：
LOG 规则仅负责匹配数据包并写入日志，不会改变数据包的处理流程；
REJECT 规则仅负责拒绝数据包，不受前面 LOG 规则是否匹配的影响；
它们是按顺序执行的两个独立动作，--limit 只是对 LOG 规则的匹配条件做了限制，不会影响后续的 REJECT 规则。

2. "没记录就当没发生"和"仍然拦截但不记录"有本质区别吗？为什么安全审计中这个区别很重要？

> 答：有本质区别。
从实际效果看：前者既不记录也不拦截，攻击者可以成功访问目标服务；后者虽然不记录日志，但依然会拒绝数据包，攻击者的访问会失败。
在安全审计中，日志是追踪攻击行为、定位攻击源、分析攻击模式的关键证据。如果 “拦截但不记录”，会导致安全事件的审计线索缺失，无法追溯攻击过程，也无法评估攻击规模和频率，不利于后续的安全加固和应急响应；而 “没记录就当没发生” 会直接让攻击成功，带来更严重的安全风险。

---

### 任务 8：清理

实验结束后清理所有 namespace：

```bash
sudo ip netns del office
sudo ip netns del guest
sudo ip netns del dmz
sudo ip netns del fw

# 确认清理完毕
sudo ip netns list
```

输出为空即完成。

---

## 实验结果填写

### A. 环境搭建

| 项目 | 你的填写 |
| :--- | :------- |
| `office` 地址 |10.0.1.0/24，网关 10.0.1.1，示例主机 10.0.1.2|
| `guest` 地址 |10.0.2.0/24，网关 10.0.2.1，示例主机 10.0.2.2|
| `dmz` 地址 |10.0.3.0/24，网关 10.0.3.1，示例主机 10.0.3.2|
| `fw` 三个接口地址 |10.0.1.1（接 office）、10.0.2.1（接 guest）、10.0.3.1（接 dmz）|

![环境配置](topology.png)

---

### B. 第一阶段：访问控制规则（无日志）

| 规则作用 | 你的规则 |
| :------- | :------- |
| 默认转发策略 |DROP|
| 允许已建立连接返回 |iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT|
| 允许 `office -> dmz:8080` |iptables -A FORWARD -s 10.0.1.0/24 -d 10.0.3.2 -p tcp --dport 8080 -j ACCEPT|
| 拒绝 `guest -> dmz:8080` |iptables -A FORWARD -s 10.0.2.0/24 -d 10.0.3.2 -p tcp --dport 8080 -j REJECT|
| 拒绝 `guest -> office` |iptables -A FORWARD -s 10.0.2.0/24 -d 10.0.1.0/24 -j REJECT|

| 测试项 | 结果 |
| :----- | :--- |
| `office -> dmz:8080` |成功|
| `guest -> dmz:8080` |失败|
| `guest -> office` |失败|

![访问控制测试](baseline_test.png)

---

### C. 第二阶段：带日志的规则

| 规则行号 | target | 匹配条件 | 前缀（如有） |
| :------- | :----- | :------- | :---------- |
| 1 |ACCEPT|all -- 0.0.0.0/0 state RELATED,ESTABLISHED|-|
| 2 |ACCEPT|tcp -- 10.0.1.0/24 -> 10.0.3.2 dpt:8080|-|
| 3 |LOG|tcp -- 10.0.2.0/24 -> 10.0.3.2 dpt:8080|GUEST-TO-DMZ:|
| 4 |REJECT|tcp -- 10.0.2.0/24 -> 10.0.3.2 dpt:8080|-|
| 5 |LOG|all -- 10.0.2.0/24 -> 10.0.1.0/24|GUEST-TO-OFFICE:|
| 6 |REJECT|all -- 10.0.2.0/24 -> 10.0.1.0/24|-|

| 测试 | 访问结果 | 是否出现 LOG | 日志前缀 |
| :--- | :------- | :---------- | :------- |
| `guest -> dmz:8080` |失败|是|GUEST-TO-DMZ:|
| `guest -> office` |失败|是|GUEST-TO-OFFICE:|
| `office -> dmz:8080` |成功|否|无|

![带日志的规则](log_rules.png)

![实时日志](realtime_log.png)

---

### D. 日志过滤与速率控制

| 项目 | 你的填写 |
| :--- | :------- |
| `GUEST-TO-DMZ` 总条数 |11 条|
| `GUEST-TO-OFFICE` 总条数 |1 条|
| 过滤命令 |sudo journalctl -k --grep "GUEST-TO-DMZ" --no-pager|
| 加 `--limit` 后触发 10 次，日志条数 |5 条|

![日志过滤](log_filter.png)

![速率限制](log_limit.png)

---

## 思考题

1. 为什么 `dmz` 的服务不应该和 `office` 混在同一个网段？用本实验的规则效果来说明。

   > 答：DMZ 区是对外提供服务的区域，Office 区是内部办公区域，两者安全等级不同。如果混在同一网段，就无法通过防火墙规则实现 “仅允许 Office 访问 DMZ、拒绝 Guest 访问 Office” 的精细化控制，一旦 DMZ 的服务被攻破，攻击者可以直接横向移动到 Office 内网，威胁核心数据安全。本实验中，DMZ 和 Office 分属不同网段，防火墙可以精准控制 Guest 对两者的访问权限，有效隔离风险。

2. 为什么 `guest` 一般应该和办公网隔离？

   > 答：Guest 网段通常给访客、外部设备使用，安全可信度低，容易存在恶意设备或攻击行为。如果不隔离，Guest 设备可以直接访问办公网的核心资源，可能导致数据泄露、病毒传播或内网攻击。本实验中，防火墙直接拒绝了 Guest 到 Office 的所有流量，就是为了防止这类风险。

3. 第一阶段中为什么必须保留 `ESTABLISHED,RELATED` 规则？如果去掉会怎样？

   > 答：这条规则允许已建立连接的返回流量（如 Office 访问 DMZ 后，DMZ 的响应包）通过防火墙。如果去掉，Office 访问 DMZ 的请求虽然被放行，但 DMZ 的响应包会被默认 DROP 策略拒绝，导致连接无法建立，所有正常访问都会失败。

4. `LOG` target 和 `ACCEPT`/`DROP`/`REJECT` 最本质的区别是什么？为什么 LOG 必须放在 REJECT 前面？

   > 答：本质区别：LOG 仅记录日志，不会改变数据包的处理流程；而 ACCEPT/DROP/REJECT 会直接决定数据包的最终去向（放行或丢弃）。
   LOG 必须放在 REJECT 前面：因为 iptables 规则是按顺序匹配的，如果 LOG 放在 REJECT 后面，数据包会先被 REJECT 丢弃，不会继续匹配后面的 LOG 规则，导致日志无法生成。

5. `office -> dmz` 的成功访问没有日志，被拦截的 `guest` 访问有日志。这是合理的还是疏漏？为什么？

   > 答：这是合理的。因为防火墙的 LOG 规则仅对 Guest 的访问配置了日志记录，Office 的访问直接匹配 ACCEPT 规则被放行，不会触发 LOG 规则。这种设计可以减少正常业务的日志量，仅对异常 / 非法访问进行审计，是常见的日志策略。如果需要记录所有访问，只需在 ACCEPT 规则前添加对应的 LOG 规则即可。

6. `--limit` 控制日志频率后，超出限制的包仍然被 REJECT 但不再写入日志。这和"只要不记录就当没发生"有本质区别吗？

   > 答：有本质区别。
   前者：数据包依然被 REJECT 拒绝，攻击行为被有效阻断，只是日志被限速（减少重复记录），安全风险已被控制。
   后者：既不记录也不拦截，攻击行为会成功，会直接导致安全事件。
   在安全审计中，日志限速是为了避免日志膨胀、保留关键审计信息，而不是放弃对攻击的拦截，两者的安全效果完全不同。

7. 如果后面要接入 VPN，你认为 VPN 用户应该先接入哪个区域？结合网络分区和日志审计两个角度回答。

   > 答：VPN 用户应该先接入 DMZ 区，再通过防火墙规则控制对 Office 内网的访问。
   网络分区角度：DMZ 是对外服务的隔离区域，VPN 用户先进入 DMZ 可以避免直接暴露内网，防火墙可以对 VPN 用户到 Office 的流量进行精细化控制，防止恶意访问直接进入内网。
   日志审计角度：DMZ 区的防火墙规则可以记录所有 VPN 用户的访问日志，便于审计和溯源，同时不会影响内网的正常业务日志，提升审计效率。

---

## 截图要求

- 截图须清晰，终端文字可读。
- 所有截图与本 `Lab9.md` 放在**同一目录**下。

| 截图内容 | 文件名 | 对应阶段 |
| :------- | :----- | :------- |
| 地址与接口配置、连通性验证 | `topology.png` | 任务 1 |
| 无日志版规则 + 三种访问测试结果 | `baseline_test.png` | 任务 2-3 |
| 带 LOG 的完整规则列表 | `log_rules.png` | 任务 4 |
| 实时日志观察（含完整 LOG 行） | `realtime_log.png` | 任务 5 |
| 日志过滤与统计（grep + wc -l） | `log_filter.png` | 任务 6 |
| 速率限制效果（10 次触发，日志远少于 10） | `log_limit.png` | 任务 7 |

**各截图具体要求：**

1. `topology.png`：能看到 namespace 列表、地址配置或 `ip route` 输出。
2. `baseline_test.png`：能看到规则列表 + 三种访问的测试结果（无需 LOG）。
3. `log_rules.png`：能看到 LOG 与 REJECT 成对出现，前缀清晰可辨。
4. `realtime_log.png`：能看到至少一条完整 LOG 行，含 `SRC=`、`DST=`、`DPT=` 等字段。
5. `log_filter.png`：能看到 `grep`/`--grep` 过滤命令及其输出，以及 `wc -l` 统计结果。
6. `log_limit.png`：能看到触发 10 次但日志条数不超过 `--limit-burst`（5 条）的现象。

---

## 提交要求

在自己的文件夹下新建 `Lab9/` 目录，提交以下文件：

```text
学号姓名/
└── Lab9/
    ├── Lab9.md          # 本文件（填写完整，含截图与答案）
    ├── topology.png
    ├── baseline_test.png
    ├── log_rules.png
    ├── realtime_log.png
    ├── log_filter.png
    └── log_limit.png
```

---

## 截止时间

2026-05-28，届时关于 Lab9 的 PR 将不会被合并。

