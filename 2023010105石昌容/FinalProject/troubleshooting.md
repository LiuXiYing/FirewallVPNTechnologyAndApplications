# 故障排查报告

## 场景1：DNAT配置了但外网无法访问

### 故障现象
- `internet`访问`203.0.113.1:8080`失败（curl超时）
- `iptables -t nat -L`显示DNAT规则存在且正确
- `dmz`上的python http.server服务运行正常（本地测试可达）

### 重现故障
```bash
# 故意删除DNAT对应的FORWARD放行规则
sudo ip netns exec fw iptables -D FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# 测试访问（此时会失败）
sudo ip netns exec internet curl --max-time 5 http://203.0.113.1:8080/
# 输出：curl: (28) Connection timed out after 5001 milliseconds
```

### 排查过程

**步骤1：确认DNAT规则是否存在**
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v --line-numbers
```
输出显示DNAT规则存在，pkts计数器在增长，说明数据包确实到达了PREROUTING链并匹配了DNAT规则。

**步骤2：检查FORWARD链是否放行DNAT后的流量**
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "10.40.0.2"
```
输出为空或只有REJECT规则，说明FORWARD链没有放行DNAT转换后的流量。

**步骤3：使用conntrack观察DNAT映射**
```bash
sudo ip netns exec fw conntrack -L | grep "10.40.0.2"
```
输出为空，说明连接跟踪表中没有DNAT的映射记录。这证实数据包在PREROUTING被DNAT转换后，在FORWARD链被丢弃了。

**步骤4：多接口抓包定位**
```bash
# 终端1：在internet侧接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5 port 8080

# 终端2：在dmz侧接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5 port 8080
```
在veth-fw-inet能看到SYN包到达，但veth-fw-dmz看不到任何包，说明包在FORWARD链被丢弃。

### 根本原因

DNAT规则只在PREROUTING链做目的地址转换（203.0.113.1:8080 → 10.40.0.2:8080），转换后的数据包仍然需要经过FORWARD链的检查。由于FORWARD链默认策略是DROP，且没有放行从`veth-fw-inet`到`veth-fw-dmz`、目的为`10.40.0.2:8080`的规则，DNAT后的数据包被默认DROP丢弃。

### 修复方法
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
```

### 验证修复
```bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
# 应返回HTTP 200和目录列表
```

---

## 场景2：VPN隧道握手正常但业务访问失败

### 故障现象
- `wg show`显示`latest handshake`正常（最近握手在几秒内）
- `transfer`有数据增长（说明有数据在传输）
- `remote curl http://10.20.0.2:8000/`失败（curl超时）
- `remote curl http://10.40.0.2:8080/`失败（curl超时）
- `fw`上没有相关拒绝日志

### 可能原因1：FORWARD防火墙规则缺失/顺序错误

**故障说明**：
VPN隧道握手正常，说明WireGuard配置正确、加密通信已建立。但数据包到达fw后，在FORWARD链中没有匹配的放行规则，或者放行规则被放在catch-all REJECT规则之后，导致VPN流量被默认DROP丢弃。

**重现**：
```bash
# 方法1：故意删除VPN到office的FORWARD规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "veth-fw-office"
# 找到行号N，删除它
sudo ip netns exec fw iptables -D FORWARD N

# 方法2：用-A追加到链末尾（在catch-all REJECT之后），规则不会生效
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 测试访问（此时会失败）
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
# 输出：curl: (28) Connection timed out after 3001 milliseconds
```

**排查过程**：

**步骤1：确认VPN隧道层是否正常**
```bash
sudo ip netns exec remote wg show
# latest handshake < 2分钟，transfer > 0 → 隧道层正常
sudo ip netns exec fw wg show
# 同样确认握手正常
```
隧道层正常，排除WireGuard配置问题。

**步骤2：确认路由层**
```bash
sudo ip netns exec remote ip route get 10.20.0.2
# 输出：10.20.0.2 via 10.10.10.1 dev wg0 src 10.10.10.2
```
路由正确，数据包确实走wg0接口发出。排除路由问题。

**步骤3：确认防火墙层 — 抓包定位丢包点**
```bash
# 在fw的wg0接口抓包
sudo ip netns exec fw tcpdump -ni wg0 -c 5 host 10.10.10.2 &
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
```
在wg0接口能抓到remote发来的请求包，说明包已到达fw。

```bash
# 在fw的veth-fw-office接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 5 host 10.20.0.2 &
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
```
在veth-fw-office接口看不到任何包，说明包在FORWARD链被丢弃。

**步骤4：检查FORWARD规则**
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```
观察规则计数器的pkts列：
- wg0→office的ACCEPT规则pkts=0，说明没有被命中
- 检查该规则是否在catch-all REJECT规则之后
- 如果用`-A`追加规则，新规则会放在已有REJECT之后，永远无法匹配

**根本原因**：
FORWARD链中存在catch-all REJECT规则（用于拒绝未授权的VPN流量），该规则位于链末尾。使用`iptables -A`追加新的ACCEPT规则时，新规则被放在REJECT之后。iptables按顺序匹配规则，数据包先匹配到REJECT规则被丢弃，永远不会到达后面的ACCEPT规则。或者FORWARD链中根本没有对应的放行规则。

**修复方法**：
```bash
# 方法1：使用-I在REJECT之前插入规则（推荐）
sudo ip netns exec fw iptables -I FORWARD 26 \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 方法2：如果规则已用-A追加到末尾，先删除再重新插入
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers | grep "veth-fw-office"
# 假设行号是30（在REJECT之后）
sudo ip netns exec fw iptables -D FORWARD 30
sudo ip netns exec fw iptables -I FORWARD 26 \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

**验证修复**：
```bash
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
# 应返回HTTP 200和目录列表

# 再次检查规则计数器
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep "veth-fw-office"
# 确认pkts计数 > 0，说明规则已生效
```

### 可能原因2：AllowedIPs配置错误

**故障说明**：
`AllowedIPs`决定哪些目标网段的流量走WireGuard隧道。如果remote端的`AllowedIPs`没有包含目标网段（如缺少10.20.0.0/24或10.40.0.0/24），WireGuard不会将发往这些网段的包通过隧道发送，而是走默认路由。

**重现**：
```bash
# 修改remote的WireGuard配置，去掉10.20.0.0/24
sudo tee /etc/wireguard/remote/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = <原私钥>

[Peer]
PublicKey = <fw公钥>
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.40.0.0/24    # 只包含dmz，不包含office
PersistentKeepalive = 25
EOF

# 重启WireGuard
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

# 测试访问（office网段会失败）
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
# 输出：curl: (28) Connection timed out
```

**排查过程**：

**步骤1：确认VPN隧道层**
```bash
sudo ip netns exec remote wg show
# latest handshake正常，transfer有数据 → 隧道本身没问题
```

**步骤2：检查路由表**
```bash
sudo ip netns exec remote ip route
# 输出中只看到 10.40.0.0/24 dev wg0，没有 10.20.0.0/24 dev wg0
```

**步骤3：对比路由决策**
```bash
# 访问dmz网段 — 走wg0（正常）
sudo ip netns exec remote ip route get 10.40.0.2
# 输出：10.40.0.2 dev wg0 src 10.10.10.2

# 访问office网段 — 不走wg0（异常）
sudo ip netns exec remote ip route get 10.20.0.2
# 输出：10.20.0.2 via <默认网关> dev veth-remote  # 走了默认路由而非wg0！
```
对比两个结果：10.40.0.2走wg0，10.20.0.2走veth-remote默认路由。说明AllowedIPs中缺少10.20.0.0/24。

**步骤4：确认AllowedIPs配置**
```bash
sudo ip netns exec remote wg showconf wg0 | grep -i allowed
# 输出：AllowedIPs = 10.40.0.0/24
# 缺少 10.20.0.0/24
```

**根本原因**：
WireGuard的`AllowedIPs`字段有两个作用：
1. **加密策略**：只有源地址在peer的AllowedIPs范围内的包才会被接受解密
2. **路由策略**：wg-quick会根据AllowedIPs自动添加内核路由，只有目标地址匹配的包才走wg0

remote端AllowedIPs只包含10.40.0.0/24，WireGuard只为该网段添加了路由。发往10.20.0.0/24的包匹配不到wg0路由，走了默认路由（通过veth-remote出去），根本不会进入VPN隧道。

**修复方法**：

> **注意**：仅用`wg set`修改AllowedIPs不会自动更新内核路由表，必须手动添加路由或重启WireGuard。

```bash
# 方法1：手动添加路由（快速修复，不改变配置文件）
sudo ip netns exec remote ip route add 10.20.0.0/24 dev wg0

# 方法2：修改配置文件后重启WireGuard（推荐，永久生效）
# 编辑 /etc/wireguard/remote/wg0.conf，将AllowedIPs改为：
# AllowedIPs = 10.20.0.0/24,10.40.0.0/24

sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
# wg-quick up会自动根据AllowedIPs添加对应路由
```

**验证修复**：
```bash
# 确认路由已添加
sudo ip netns exec remote ip route | grep wg0
# 应同时看到 10.20.0.0/24 dev wg0 和 10.40.0.0/24 dev wg0

# 确认路由决策正确
sudo ip netns exec remote ip route get 10.20.0.2
# 应输出：10.20.0.2 dev wg0 src 10.10.10.2

# 测试访问
sudo ip netns exec remote curl --max-time 3 http://10.20.0.2:8000/
# 应返回HTTP 200
```

### 快速定位问题的方法（两原因对比）

| 排查步骤 | 原因1（FORWARD规则缺失） | 原因2（AllowedIPs错误） |
|:--------|:----------------------|:----------------------|
| `wg show` | 握手正常 | 握手正常 |
| `ip route get 10.20.0.2` | 走wg0 ✓ | 走veth-remote（默认路由） ✗ |
| `tcpdump -ni wg0` on fw | 能抓到包 | 抓不到包 |
| `tcpdump -ni veth-fw-office` | 抓不到包 | 抓不到包 |
| `iptables -L FORWARD -n -v` | wg0→office规则pkts=0 | wg0→office规则pkts=0 |
| **定位关键** | 包到达fw的wg0但被FORWARD丢弃 | 包根本没进入VPN隧道，从remote就走错了 |

分层排查口诀：
```bash
# 1. 确认VPN隧道层
sudo ip netns exec remote wg show

# 2. 确认路由层（关键区分点！）
sudo ip netns exec remote ip route get 10.20.0.2
# 走wg0 → 路由正确，问题在fw的FORWARD
# 不走wg0 → 路由问题，检查AllowedIPs

# 3. 确认防火墙层
sudo ip netns exec fw iptables -L FORWARD -n -v | grep wg0

# 4. 分层抓包定位
sudo ip netns exec fw tcpdump -ni wg0 -c 5
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 5
```

---

## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败

### 故障现象
- 三次握手的第一个SYN包能通过防火墙
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时（`Connection timed out`）

### 重现故障
```bash
# 找到状态检测规则的行号
sudo ip netns exec fw iptables -L FORWARD -n --line-numbers | grep ESTABLISHED
# 假设行号是1

# 删除状态检测规则
sudo ip netns exec fw iptables -D FORWARD 1

# 测试（会超时）
sudo ip netns exec office curl --max-time 10 http://10.40.0.2:8080/
# 输出：curl: (28) Connection timed out after 10001 milliseconds
```

### 排查过程

**步骤1：确认ESTABLISHED,RELATED规则已被删除**
```bash
# 查看FORWARD链规则，确认第一条不再是ESTABLISHED,RELATED规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -5
```
正常情况下，FORWARD链第一条应该是 `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`。
删除后，第一条将变成其他规则（如NEW状态放行规则）。如果第一条仍然是 `all -- * * 0.0.0.0/0 0.0.0.0/0` 且有pkts计数增长，说明规则没有被成功删除。

**步骤2：观察连接跟踪表中的连接状态**
```bash
# 注意：必须在curl运行期间查看，连接结束后conntrack条目会被回收
# 方法：开两个终端窗口同时操作
# 终端A：运行curl（会持续等待直到超时）
sudo ip netns exec office curl --max-time 10 http://10.40.0.2:8080/

# 终端B：趁curl还在等待时立即查看（curl超时前执行）
# 方式一：通过 /proc/net/nf_conntrack 查看（内核原生支持，无需额外安装conntrack工具）
sudo ip netns exec fw cat /proc/net/nf_conntrack | grep "10.40.0.2"

# 方式二：如果安装了conntrack工具，也可以用
sudo ip netns exec fw conntrack -L | grep "10.40.0.2"
```

输出示例：
```
tcp  6 58 SYN_RECV src=10.20.0.2 dst=10.40.0.2 sport=34060 dport=8080
     src=10.40.0.2 dst=10.20.0.2 sport=8080 dport=34060 mark=0 use=1
```

关键信息解读：
- **状态为 `SYN_RECV`**：服务端已收到SYN并发送了SYN-ACK，但客户端未收到ACK（因为SYN-ACK被防火墙DROP了）
- **双向地址都有记录**：说明conntrack已经看到了请求和回复两个方向的数据包
- **连接无法完成**：三次握手卡在半开状态，永远无法进入ESTABLISHED

**步骤3：抓包证明SYN-ACK被拦截**
```bash
# 在fw的两个接口同时抓包
# 终端A：在office侧接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-office -c 10 "host 10.20.0.2 and port 8080"

# 终端B：在dmz侧接口抓包
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 10 "host 10.40.0.2 and port 8080"

# 终端C：触发连接
sudo ip netns exec office curl --max-time 10 http://10.40.0.2:8080/
```

抓包结果分析：
- `veth-fw-dmz`：能看到office发出的SYN包到达dmz，dmz回复SYN-ACK
- `veth-fw-office`：能看到office发出SYN包，但看不到dmz的SYN-ACK回复（被FORWARD链DROP）

tcpdump输出会显示类似的重复重传模式：
```
10.20.0.2.xxxxx > 10.40.0.2.8080: Flags [S], seq ...     # SYN → 到达dmz
10.40.0.2.8080 > 10.20.0.2.xxxxx: Flags [S.], seq ...    # SYN-ACK ← dmz发出(但在FORWARD被DROP)
10.20.0.2.xxxxx > 10.40.0.2.8080: Flags [S], seq ...     # SYN 重传(office没收到SYN-ACK)
10.40.0.2.8080 > 10.20.0.2.xxxxx: Flags [S.], seq ...    # SYN-ACK 重传(又被DROP)
```

### 根本原因

状态检测规则`-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT`的作用是放行已建立连接的返回流量。没有这条规则时：

1. office发出的SYN包匹配`-m conntrack --ctstate NEW -j ACCEPT`规则，成功到达dmz
2. dmz收到SYN后回复SYN-ACK，conntrack表中连接状态变为`SYN_RECV`
3. SYN-ACK包到达fw的FORWARD链，但它不属于NEW状态，也没有ESTABLISHED,RELATED规则来放行
4. SYN-ACK包被FORWARD链默认策略DROP丢弃
5. office收不到SYN-ACK，持续重传SYN，连接状态始终卡在`SYN_RECV`
6. 客户端最终超时，连接失败

### 修复方法
```bash
# 恢复状态检测规则（必须放在FORWARD链第一条）
sudo ip netns exec fw iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

### ESTABLISHED,RELATED的必要性

状态检测是状态防火墙的核心功能：
- **ESTABLISHED**：允许已建立连接的返回流量。没有它，任何双向通信都无法正常工作，因为只有NEW状态的初始包能匹配放行规则
- **RELATED**：允许与已有连接相关的流量。例如FTP的active模式数据通道、ICMP错误消息（如"需要分片"）等
- 这两条规则保证了防火墙既能严格限制入站连接，又能让合法通信的双向流量正常通过

---

## 总结

通过以上三个故障排查场景，可以总结出以下排查方法论：

1. **分层排查**：从底层到上层逐层检查（接口→路由→NAT→FORWARD→应用）
2. **抓包对比**：在数据包经过的各个节点抓包，对比找出丢包位置
3. **conntrack辅助**：利用连接跟踪表观察NAT转换和连接状态
4. **规则计数器**：观察pkts计数器判断规则是否被命中
5. **最小化重现**：隔离变量，逐个排除可能原因
