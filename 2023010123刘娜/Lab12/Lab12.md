# Lab12：WireGuard 远程接入安全策略

## 从 Lab11 到 Lab12

Lab11 解决的是“VPN 隧道怎么建起来”：

- `client` 和 `vpn` 两端创建 `wg0` 虚拟接口
- WireGuard 用 underlay 网络发送 UDP 51820 加密包
- `AllowedIPs` 决定哪些目标地址交给隧道
- 抓包时，underlay 只能看到外层 UDP 包，`wg0` 能看到解密后的内层流量

但真实部署中，只把 VPN 建起来远远不够。一个远程用户连进来以后，不应该自动拥有整个内网的访问权限。VPN 只是入口，入口后面仍然需要防火墙规则、最小权限策略和日志审计。

本实验重点回答：

> VPN 用户进来以后，能访问什么、不能访问什么，由谁决定，怎么留下证据？

本实验不依赖 Lab11 的残留环境。即使 Lab11 的 namespace、密钥、配置文件都已经清理，也可以从头完成。

---

## 实验目标

完成本实验后，你应该能够：

1. 从零搭建一个 `client - vpn - server` 的远程接入 VPN 实验环境。
2. 配置 WireGuard 隧道，让远程客户端访问内网服务器。
3. 观察“只建隧道、不写防火墙规则”时，VPN 用户访问权限过大的问题。
4. 在 VPN 网关上使用 `FORWARD` 链限制 VPN 用户只能访问指定服务。
5. 使用 `LOG + REJECT` 记录被拒绝的 VPN 流量。
6. 用 tcpdump 对比 underlay、`wg0`、内网接口三处看到的不同流量。
7. 理解 `AllowedIPs` 和 iptables 访问控制的区别。

---

## 实验拓扑

![topology](topology.png)

---

## 准备工作

### 安装工具

本实验需要 Linux 环境，推荐 Ubuntu 虚拟机或云主机。需要以下工具：

```bash
sudo apt update
sudo apt install -y wireguard-tools iproute2 iptables tcpdump curl python3 conntrack
```

检查 WireGuard 工具是否可用：

```bash
wg --version
command -v wg-quick
```

### 建议终端布局

建议同时打开 4 个终端：

| 终端 | 用途 |
| :--- | :--- |
| 终端 A | 在 `server` 中运行 HTTP 服务 |
| 终端 B | 在 `client` 中执行访问测试 |
| 终端 C | 在 `vpn` 中配置 iptables、查看 WireGuard 状态 |
| 终端 D | 运行 tcpdump 或查看日志 |

---

## 任务一：清理残留环境

如果你之前做过 Lab11 或本实验，先清理旧环境，避免同名 namespace、接口或 `wg0` 残留。

```bash
sudo ip netns exec client wg-quick down /etc/wireguard/lab12-client/wg0.conf 2>/dev/null
sudo ip netns exec vpn    wg-quick down /etc/wireguard/lab12-vpn/wg0.conf 2>/dev/null

sudo ip netns exec client ip link del wg0 2>/dev/null
sudo ip netns exec vpn    ip link del wg0 2>/dev/null

sudo ip netns del client 2>/dev/null
sudo ip netns del vpn 2>/dev/null
sudo ip netns del server 2>/dev/null

sudo ip link del veth-client 2>/dev/null
sudo ip link del veth-vpn-ul 2>/dev/null
sudo ip link del veth-server 2>/dev/null
sudo ip link del veth-vpn-lan 2>/dev/null
```

说明：

| 写法 | 含义 |
| :--- | :--- |
| `2>/dev/null` | 忽略“不存在”的错误，便于重复执行 |
| `wg-quick down` | 关闭 WireGuard 接口并删除自动添加的路由 |
| `ip netns del` | 删除 namespace，其中的接口、路由、防火墙规则会随之消失 |

确认清理结果：

```bash
sudo ip netns list
```

如果没有 `client`、`vpn`、`server`，说明清理完成。

---

## 任务二：创建网络拓扑

### 第一步：创建三个 namespace

```bash
sudo ip netns add client
sudo ip netns add vpn
sudo ip netns add server
```

查看：

```bash
sudo ip netns list
```

### 第二步：创建两对 veth

```bash
sudo ip link add veth-client type veth peer name veth-vpn-ul
sudo ip link add veth-server type veth peer name veth-vpn-lan
```

含义：

| veth 对 | 连接关系 |
| :--- | :--- |
| `veth-client <-> veth-vpn-ul` | 远程客户端到 VPN 网关外侧 |
| `veth-server <-> veth-vpn-lan` | VPN 网关内侧到内网服务器 |

### 第三步：把接口放入 namespace

```bash
sudo ip link set veth-client netns client
sudo ip link set veth-vpn-ul netns vpn
sudo ip link set veth-server netns server
sudo ip link set veth-vpn-lan netns vpn
```

### 第四步：配置 IP 地址并启用接口

```bash
# client
sudo ip netns exec client ip addr add 192.0.2.2/24 dev veth-client
sudo ip netns exec client ip link set veth-client up
sudo ip netns exec client ip link set lo up

# vpn
sudo ip netns exec vpn ip addr add 192.0.2.1/24 dev veth-vpn-ul
sudo ip netns exec vpn ip link set veth-vpn-ul up
sudo ip netns exec vpn ip addr add 10.20.0.1/24 dev veth-vpn-lan
sudo ip netns exec vpn ip link set veth-vpn-lan up
sudo ip netns exec vpn ip link set lo up

# server
sudo ip netns exec server ip addr add 10.20.0.2/24 dev veth-server
sudo ip netns exec server ip link set veth-server up
sudo ip netns exec server ip link set lo up
```

### 第五步：配置路由和 IP 转发

`server` 的默认网关指向 `vpn` 的内网侧地址：

```bash
sudo ip netns exec server ip route add default via 10.20.0.1
```

`vpn` 开启 IP 转发：

```bash
sudo ip netns exec vpn sysctl -w net.ipv4.ip_forward=1
```

说明：

| 配置 | 作用 |
| :--- | :--- |
| `server default via 10.20.0.1` | 让 server 回复 VPN 客户端时知道交给 vpn 网关 |
| `net.ipv4.ip_forward=1` | 允许 vpn 在 `wg0` 和内网接口之间转发数据 |

### 第六步：验证基础连通

从 `client` 测试 underlay：

```bash
sudo ip netns exec client ping -c 2 192.0.2.1
```

从 `server` 测试内网网关：

```bash
sudo ip netns exec server ping -c 2 10.20.0.1
```

此时 `client` 不应该直接访问 `server`：

```bash
sudo ip netns exec client ping -c 2 10.20.0.2
```

如果提示 `Network is unreachable` 或无响应，这是正常现象。因为 VPN 隧道还没有建立，`client` 没有到 `10.20.0.0/24` 的路由。

填写：

| 测试项 | 预期结果 | 你的结果 |
| :--- | :--- | :--- |
| `client -> 192.0.2.1` | 成功 |成功 |
| `server -> 10.20.0.1` | 成功 |成功 |
| `client -> 10.20.0.2` | 失败 |失败 |

---

## 任务三：配置 WireGuard 隧道

### 第一步：生成密钥

在宿主机当前目录执行：

```bash
umask 077
wg genkey | tee lab12-client.key | wg pubkey > lab12-client.pub
wg genkey | tee lab12-vpn.key    | wg pubkey > lab12-vpn.pub
```

查看文件：

```bash
ls -l lab12-client.key lab12-client.pub lab12-vpn.key lab12-vpn.pub
```

说明：

| 文件 | 作用 |
| :--- | :--- |
| `lab12-client.key` | client 私钥，只写入 client 配置 |
| `lab12-client.pub` | client 公钥，写入 vpn 的 `[Peer]` |
| `lab12-vpn.key` | vpn 私钥，只写入 vpn 配置 |
| `lab12-vpn.pub` | vpn 公钥，写入 client 的 `[Peer]` |

### 第二步：创建配置目录

```bash
sudo mkdir -p /etc/wireguard/lab12-client
sudo mkdir -p /etc/wireguard/lab12-vpn
```

读取密钥到变量：

```bash
CLIENT_PRIVATE_KEY=$(cat lab12-client.key)
CLIENT_PUBLIC_KEY=$(cat lab12-client.pub)
VPN_PRIVATE_KEY=$(cat lab12-vpn.key)
VPN_PUBLIC_KEY=$(cat lab12-vpn.pub)
```

### 第三步：写 client 配置

```bash
sudo tee /etc/wireguard/lab12-client/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.1/24
PrivateKey = ${CLIENT_PRIVATE_KEY}

[Peer]
PublicKey = ${VPN_PUBLIC_KEY}
Endpoint = 192.0.2.1:51820
AllowedIPs = 10.20.0.0/24, 10.10.10.2/32
PersistentKeepalive = 25
EOF
```

### 第四步：写 vpn 配置

```bash
sudo tee /etc/wireguard/lab12-vpn/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = ${VPN_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.10.10.1/32
EOF
```

设置权限：

```bash
sudo chmod 600 /etc/wireguard/lab12-client/wg0.conf
sudo chmod 600 /etc/wireguard/lab12-vpn/wg0.conf
```

配置含义：

| 位置 | 字段 | 含义 |
| :--- | :--- | :--- |
| client `[Interface]` | `Address = 10.10.10.1/24` | client 的隧道地址 |
| client `[Peer]` | `Endpoint = 192.0.2.1:51820` | 主动连接 vpn 的 underlay 地址 |
| client `[Peer]` | `AllowedIPs = 10.20.0.0/24, 10.10.10.2/32` | 访问 server 内网和 vpn 的 wg0 地址时走 VPN |
| vpn `[Interface]` | `ListenPort = 51820` | vpn 在 UDP 51820 等待连接 |
| vpn `[Peer]` | `AllowedIPs = 10.10.10.1/32` | vpn 只接受 client 隧道地址发来的内层包 |

### 第五步：启动隧道

先启动 vpn 监听端：

```bash
sudo ip netns exec vpn wg-quick up /etc/wireguard/lab12-vpn/wg0.conf
```

再启动 client：

```bash
sudo ip netns exec client wg-quick up /etc/wireguard/lab12-client/wg0.conf
```

查看接口：

```bash
sudo ip netns exec client ip addr show wg0
sudo ip netns exec vpn ip addr show wg0
```

查看路由：

```bash
sudo ip netns exec client ip route
```

应能看到类似：

```text
10.20.0.0/24 dev wg0 scope link
```

这条路由来自 client 端的 `AllowedIPs = 10.20.0.0/24`。同时，client 端 peer 的 `AllowedIPs` 还包含 `10.10.10.2/32`，这是为了后续能够通过隧道访问 VPN 网关自己的 `wg0` 地址。

### 第六步：触发握手并查看状态

先从 client ping server：

```bash
sudo ip netns exec client ping -c 2 10.20.0.2
```

然后查看：

```bash
sudo ip netns exec client wg show
sudo ip netns exec vpn wg show
```

关注：

| 字段 | 含义 |
| :--- | :--- |
| `latest handshake` | 最近一次握手时间 |
| `transfer` | 隧道收发字节数 |
| `allowed ips` | 当前 peer 的 AllowedIPs |

填写：

| 项目 | 你的填写 |
| :--- | :--- |
| client `wg0` 地址 |10.10.10.1 |
| vpn `wg0` 地址 |10.10.10.2 |
| client 端 `AllowedIPs` |10.20.0.0/24, 10.10.10.2/32 |
| client 路由表中的 `wg0` 路由 |10.20.0.0/24 dev wg0 scope link |
| 是否看到 `latest handshake` |是 |

截图：

![wg_status](wg_status.png)

---

## 任务四：基线测试——只建 VPN 时权限过大

### 第一步：在 server 上启动两个服务

终端 A：

```bash
sudo ip netns exec server python3 -m http.server 8080
```

另一个终端：

```bash
sudo ip netns exec server python3 -m http.server 2222
```

说明：

| 端口 | 用途 |
| :--- | :--- |
| `8080` | 允许 VPN 用户访问的 Web 服务 |
| `2222` | 模拟不应暴露给 VPN 用户的内部服务 |

### 第二步：在没有防火墙限制时测试

此时新建 namespace 内的 `FORWARD` 默认通常是 ACCEPT。先观察“只建隧道”的效果：

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:2222/
sudo ip netns exec client ping -c 3 10.20.0.2
```

预期：三个测试都可能成功。

这说明：

> `AllowedIPs = 10.20.0.0/24, 10.10.10.2/32` 只是让 client 到 server 内网和 vpn 的 wg0 地址的流量进入隧道，并没有限制 client 到底能访问 server 的哪些端口。

填写：

| 测试 | 预期 | 你的结果 |
| :--- | :--- | :--- |
| `client -> server:8080` | 成功 |成功 |
| `client -> server:2222` | 成功 |成功 |
| `client -> server ping` | 成功 |成功 |

截图：

![baseline](baseline.png)

---

## 任务五：配置 VPN 访问控制

现在把 `vpn` 网关变成真正的访问控制点。

### 第一步：清空 FORWARD 并设置默认 DROP

```bash
sudo ip netns exec vpn iptables -F FORWARD
sudo ip netns exec vpn iptables -P FORWARD DROP
```

说明：

| 命令 | 含义 |
| :--- | :--- |
| `-F FORWARD` | 清空转发链规则 |
| `-P FORWARD DROP` | 默认拒绝所有转发流量 |

### 第二步：放行已建立连接

```bash
sudo ip netns exec vpn iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

这条规则必须放在前面。否则即使 client 的请求被允许，server 返回的响应也可能被默认 DROP。

### 第三步：只允许 VPN 用户访问 server:8080

```bash
sudo ip netns exec vpn iptables -A FORWARD \
  -i wg0 -o veth-vpn-lan \
  -s 10.10.10.1 -d 10.20.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
```

规则含义：

| 条件 | 含义 |
| :--- | :--- |
| `-i wg0` | 流量从 VPN 隧道进入 |
| `-o veth-vpn-lan` | 流量准备转发到内网侧 |
| `-s 10.10.10.1` | 只允许这个 VPN 客户端 |
| `-d 10.20.0.2` | 只允许访问这台 server |
| `--dport 8080` | 只允许访问 Web 服务端口 |
| `--ctstate NEW` | 只匹配新连接，后续包由 ESTABLISHED 规则处理 |

### 第四步：记录其他 VPN 访问

```bash
sudo ip netns exec vpn iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: " --log-level 4
```

说明：

| 参数 | 含义 |
| :--- | :--- |
| `-i wg0` | 只记录来自 VPN 的转发流量 |
| `--limit 5/min` | 稳定状态每分钟最多记录 5 条 |
| `--limit-burst 10` | 允许初始突发最多 10 条 |
| `--log-prefix "VPN-DENY: "` | 给日志打标签，便于过滤 |

### 第五步：拒绝其他 VPN 访问

```bash
sudo ip netns exec vpn iptables -A FORWARD \
  -i wg0 \
  -j REJECT
```

注意：LOG 不会终止匹配，所以必须在 LOG 后面放一条真正的拒绝规则。

### 第六步：查看规则

```bash
sudo ip netns exec vpn iptables -L FORWARD -n -v --line-numbers
```

填写：

| 行号 | target | 匹配条件 | 作用 |
| :--- | :--- | :--- | :--- |
| 1 |ACCEPT |所有接口（in * out *），源 / 目的任意地址，状态为 RELATED,ESTABLISHED |允许已建立或相关联的连接的流量通过，保障会话正常通信 |
| 2 |ACCEPT |协议 TCP，从 wg0 接口进入、从 veth-vpn-lan 接口出去，源地址 10.10.10.1，目的地址 10.20.0.2，目的端口 8080，状态为 NEW |允许从 client 地址 10.10.10.1 发起的、访问 server 服务 10.20.0.2:8080 的新建 TCP 连接通过 |
| 3 |LOG |从 wg0 接口进入，其他任意，限制为每分钟最多 5 条日志（burst 10） |对从 wg0 接口进入、未被前面规则匹配的流量进行日志记录，日志前缀为 VPN-DENY: |
| 4 |REJECT |从 wg0 接口进入，其他任意 |拒绝所有从 wg0 接口进入、未被前面规则匹配的流量，并返回 icmp-port-unreachable 错误 |

---

## 任务六：验证 VPN 策略

### 第一步：访问允许的服务

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
```

预期：成功。

### 第二步：访问禁止的服务

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:2222/
```

预期：失败，并产生 `VPN-DENY` 日志。

### 第三步：测试 ICMP

```bash
sudo ip netns exec client ping -c 3 10.20.0.2
```

预期：失败，并产生 `VPN-DENY` 日志。

### 第四步：观察规则计数器

```bash
sudo ip netns exec vpn iptables -L FORWARD -n -v --line-numbers
```

重点观察：

- 访问 `8080` 时，ACCEPT 规则计数增加。
- 访问 `2222` 或 ping 时，LOG/REJECT 规则计数增加。

填写：

| 测试 | 成功/失败 | 命中的规则 | 计数器是否增加 |
| :--- | :--- | :--- | :--- |
| `client -> server:8080` |成功 |规则 2（wg0 到 veth-vpn-lan，tcp dpt:8080 NEW） |是（规则 2 的 pkts 计数器为 1） |
| `client -> server:2222` |失败 |规则 3（LOG）和规则 4（REJECT） |是（规则 3 和规则 4 的 pkts 计数器均为 4） |
| `client -> server ping` |失败 |规则 3（LOG）和规则 4（REJECT） |是（规则 3 和规则 4 的 pkts 计数器均为 4，包含 ping 流量） |

截图：

![policy_test](policy_test.png)

---

## 任务七：查看日志

### 第一步：处理 namespace 日志常见问题

如果你确认 LOG 规则计数增加，但 `journalctl` 或 `dmesg` 看不到日志，先在宿主机执行：

```bash
sudo sysctl -w net.netfilter.nf_log_all_netns=1
```

然后重新触发一次禁止访问。

### 第二步：查看 VPN-DENY 日志

```bash
sudo journalctl -k --grep "VPN-DENY" --no-pager
```

或：

```bash
sudo dmesg | grep "VPN-DENY"
```

一条典型日志类似：

```text
VPN-DENY: IN=wg0 OUT=veth-vpn-lan SRC=10.10.10.1 DST=10.20.0.2 PROTO=TCP SPT=54321 DPT=2222 SYN
```

字段解释：

| 字段 | 含义 |
| :--- | :--- |
| `IN=wg0` | 包从 VPN 隧道进入 |
| `OUT=veth-vpn-lan` | 包准备转发到内网接口 |
| `SRC=10.10.10.1` | VPN 客户端隧道地址 |
| `DST=10.20.0.2` | 内网服务器地址 |
| `PROTO=TCP` | 协议 |
| `DPT=2222` | 目标端口 |
| `SYN` | TCP 新连接请求 |

填写：

| 项目 | 你的填写 |
| :--- | :--- |
| 日志前缀 |VPN-DENY: |
| `IN=` |wg0 |
| `OUT=` |veth-vpn-lan |
| `SRC=` |10.10.10.1 |
| `DST=` |10.20.0.2 |
| `PROTO=` |TCP |
| `DPT=` |2222 |

截图：

![vpn_log](vpn_log.png)

---

## 任务八：保护 VPN 网关自身管理面

前面的规则都写在 `FORWARD` 链，因为它们控制的是：

```text
client -> vpn -> server
```

也就是“经过 VPN 网关转发”的流量。

但 VPN 用户还可能直接访问 VPN 网关自己，例如：

```text
client -> vpn:9090
```

这种流量的目的地是 `vpn` 本机进程，不会走 `FORWARD` 链，而是走 `INPUT` 链。真实环境中，VPN 网关上可能有 SSH、Web 管理页面、监控端口等服务，这些管理面不应该默认暴露给所有 VPN 用户。

本任务用 `9090` 端口模拟 VPN 网关自己的管理服务。

> 注意：client 端配置里必须包含 `AllowedIPs = 10.20.0.0/24, 10.10.10.2/32`。如果只写 `10.20.0.0/24`，client 访问 `10.10.10.2` 时可能找不到对应的 WireGuard peer，表现为 `curl` 立刻失败，而不是被 INPUT 链拦截。

### 第一步：在 vpn 上启动模拟管理服务

在一个新终端执行：

```bash
sudo ip netns exec vpn python3 -m http.server 9090
```

这个服务运行在 `vpn` namespace 内，监听 `0.0.0.0:9090`，因此理论上 `client` 可以通过 `vpn` 的 `wg0` 地址访问它。

### 第二步：从 client 访问 vpn 自身服务

```bash
sudo ip netns exec client curl --max-time 3 http://10.10.10.2:9090/
```

如果此时 `INPUT` 链默认是 ACCEPT，访问通常会成功。

如果这里立刻失败，先检查两项：

```bash
sudo ip netns exec vpn ss -lntp | grep 9090
sudo ip netns exec client wg show
```

确认：

1. `vpn` 上确实有服务监听 `0.0.0.0:9090` 或 `10.10.10.2:9090`。
2. `client wg show` 中 peer 的 `allowed ips` 包含 `10.10.10.2/32`。

这说明：

> `FORWARD` 链只管穿过 VPN 网关的流量，不会阻止 VPN 用户访问 VPN 网关自己的服务。

### 第三步：添加 INPUT 日志规则

在 `vpn` namespace 中执行：

```bash
sudo ip netns exec vpn iptables -I INPUT 1 \
  -i wg0 -p tcp --dport 9090 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-MGMT-DENY: " --log-level 4
```

说明：

| 条件 | 含义 |
| :--- | :--- |
| `INPUT` | 处理目的地是 vpn 本机进程的包 |
| `-i wg0` | 只匹配来自 VPN 隧道的访问 |
| `--dport 9090` | 只匹配模拟管理端口 |
| `VPN-MGMT-DENY` | 管理面拒绝日志前缀 |

### 第四步：添加 INPUT 拒绝规则

```bash
sudo ip netns exec vpn iptables -I INPUT 2 \
  -i wg0 -p tcp --dport 9090 \
  -j REJECT
```

查看 INPUT 链：

```bash
sudo ip netns exec vpn iptables -L INPUT -n -v --line-numbers
```

### 第五步：再次测试

```bash
sudo ip netns exec client curl --max-time 3 http://10.10.10.2:9090/
```

预期：访问失败，并产生 `VPN-MGMT-DENY` 日志。

查看日志：

```bash
sudo journalctl -k --grep "VPN-MGMT-DENY" --no-pager
```

填写：

| 测试 | 加 INPUT 规则前 | 加 INPUT 规则后 | 是否产生日志 |
| :--- | :--- | :--- | :--- |
| `client -> vpn:9090` |成功 |失败 |是 |

### 第六步：对比 INPUT 与 FORWARD

填写：

| 访问目标 | 经过的链 | 原因 |
| :--- | :--- | :--- |
| `client -> server:8080` | `FORWARD` |流量是从 client 经 vpn 转发到 server，目的不是 vpn 本机进程，因此走 FORWARD 链。 |
| `client -> server:2222` | `FORWARD` |与上同理，流量目的地是 server，需经 vpn 转发，因此走 FORWARD 链。 |
| `client -> vpn:9090` | `INPUT` |流量目的地是 vpn 本机（监听 9090 端口的 python 进程），因此走 INPUT 链。 |

---

## 任务九：用 conntrack 观察 VPN 内层连接

Lab7 和 Lab8 已经用过 conntrack。到了 VPN 场景，需要特别注意：

> WireGuard 的加密隧道状态由 WireGuard 自己维护，`wg show` 负责显示；conntrack 不是 WireGuard 的隧道映射表。

但是，当 WireGuard 解密出内层 IP 包后，这些内层 TCP/ICMP 连接仍然会进入 Linux 网络栈，并被 conntrack 跟踪。iptables 中的 `-m conntrack --ctstate ESTABLISHED,RELATED` 匹配的就是这些连接状态。

简单讲：**WireGuard 负责把加密隧道打通，conntrack 负责跟踪隧道里跑的那些真实连接。** 写 iptables 规则时，你只需要对着内层 IP 思考，当成没有 VPN 的普通转发场景来写就对了。

### 第一步：清空旧 conntrack 记录

```bash
sudo ip netns exec vpn conntrack -F
```

说明：

| 命令 | 含义 |
| :--- | :--- |
| `conntrack -F` | 清空当前 namespace 中的 conntrack 表，便于观察新连接 |

### 第二步：触发一次允许的 VPN 访问

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
```

### 第三步：查看内层 TCP 连接

```bash
sudo ip netns exec vpn conntrack -L -p tcp
```

你应该能看到类似记录：

```text
tcp  6  ... ESTABLISHED src=10.10.10.1 dst=10.20.0.2 sport=xxxxx dport=8080 ...
                         src=10.20.0.2 dst=10.10.10.1 sport=8080 dport=xxxxx ...
```

重点字段：

| 字段 | 含义 |
| :--- | :--- |
| `src=10.10.10.1` | VPN 客户端的隧道地址 |
| `dst=10.20.0.2` | 内网服务器地址 |
| `dport=8080` | 被允许访问的服务端口 |
| `ESTABLISHED` | conntrack 认为这条 TCP 连接已经建立 |

### 第四步：对比外层 WireGuard UDP

再查看 UDP 记录：

```bash
sudo ip netns exec vpn conntrack -L -p udp
```

如果能看到 UDP 51820 相关记录，它对应的是 WireGuard 外层 underlay 通信，例如：

```text
src=192.0.2.2 dst=192.0.2.1 dport=51820
```

这和内层 TCP 连接不同：

| 类型 | 地址 | 协议 | 说明 |
| :--- | :--- | :--- | :--- |
| 外层 WireGuard 包 | `192.0.2.2 -> 192.0.2.1` | UDP 51820 | 加密隧道本身 |
| 内层业务连接 | `10.10.10.1 -> 10.20.0.2` | TCP 8080 | 解密后被防火墙处理的连接 |

### 第五步：填写观察表

| 观察项 | 你的填写 |
| :--- | :--- |
| 内层 TCP 连接源地址 |10.10.10.1 |
| 内层 TCP 连接目的地址 |10.20.0.2 |
| 内层 TCP 目标端口 |8080 |
| 外层 UDP 源地址 |192.0.2.2 |
| 外层 UDP 目的地址 |192.0.2.1 |
| 外层 UDP 目标端口 |51820 |

---

## 任务十：抓包观察策略作用位置

本任务要证明：WireGuard 外层包和防火墙处理的内层包不是同一个层次。

### 抓包点一：underlay 接口

在 `vpn` 的外侧接口抓包：

```bash
sudo ip netns exec vpn tcpdump -ni veth-vpn-ul -l udp port 51820
```

从 client 访问 server：

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
```

你应该只看到类似：

```text
192.0.2.2.xxxxx > 192.0.2.1.51820: UDP
192.0.2.1.51820 > 192.0.2.2.xxxxx: UDP
```

underlay 看不到 `10.10.10.1`、`10.20.0.2`、`HTTP` 内容。

### 抓包点二：vpn 的 wg0 接口

```bash
sudo ip netns exec vpn tcpdump -ni wg0 -l
```

再次访问：

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
```

你应该看到内层流量：

```text
10.10.10.1.xxxxx > 10.20.0.2.8080: Flags [S]
10.20.0.2.8080 > 10.10.10.1.xxxxx: Flags [S.]
```

### 抓包点三：vpn 的内网接口

```bash
sudo ip netns exec vpn tcpdump -ni veth-vpn-lan -l host 10.20.0.2
```

分别测试：

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:2222/
```

观察：

- 访问 `8080` 时，内网接口能看到转发给 server 的包。
- 访问 `2222` 时，包在 `vpn` 的 FORWARD 链被拒绝，内网接口不应看到完整连接。

填写：

| 抓包位置 | 看到的地址 | 协议/端口 | 说明 |
| :--- | :--- | :--- | :--- |
| `veth-vpn-ul` |192.0.2.1 ↔ 192.0.2.2 | UDP 51820 | 外层加密包 |
| `wg0` |10.10.10.1 ↔ 10.20.0.2 | TCP/ICMP | 解密后的内层包 |
| `veth-vpn-lan` |10.10.10.1 ↔ 10.20.0.2 | TCP 8080 | 被允许转发的内网包 |

截图：

![tcpdump_compare](tcpdump_compare.png)

---

## 任务十一：故障排查练习

本任务故意制造三个常见错误。每个错误观察完成后，都要恢复配置，再继续下一个错误。

### 故障一：删除 ESTABLISHED,RELATED 规则

#### 第一步：删除状态放行规则

```bash
sudo ip netns exec vpn iptables -D FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

#### 第二步：访问允许的服务

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:8080/
```

预期：访问可能失败或超时。

原因：

- client 发出的新连接请求能命中 `--dport 8080` 的 ACCEPT 规则。
- server 返回的响应方向是 `veth-vpn-lan -> wg0`。
- 如果没有 `ESTABLISHED,RELATED`，响应包不匹配允许规则，会被默认 DROP。

#### 第三步：恢复规则

```bash
sudo ip netns exec vpn iptables -I FORWARD 1 \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
```

再次测试 `server:8080`，确认恢复成功。

### 故障二：把 LOG 放在 REJECT 后面

本故障用临时端口 `3333` 演示错误规则顺序。

#### 第一步：插入错误顺序规则

先查看当前行号：

```bash
sudo ip netns exec vpn iptables -L FORWARD -n --line-numbers
```

在允许规则之后、通用 `VPN-DENY` 之前插入两条临时规则。假设要插入到第 3 行：

```bash
sudo ip netns exec vpn iptables -I FORWARD 3 \
  -i wg0 -p tcp --dport 3333 \
  -j REJECT

sudo ip netns exec vpn iptables -I FORWARD 4 \
  -i wg0 -p tcp --dport 3333 \
  -j LOG --log-prefix "WRONG-ORDER: " --log-level 4
```

这两条规则故意把 `REJECT` 放在 `LOG` 前面。

#### 第二步：触发访问

```bash
sudo ip netns exec client curl --max-time 3 http://10.20.0.2:3333/
```

查看日志：

```bash
sudo journalctl -k --grep "WRONG-ORDER" --no-pager
```

预期：访问被拒绝，但看不到 `WRONG-ORDER` 日志。

原因：

> iptables 规则按顺序匹配。包命中 `REJECT` 后，处理立即结束，后面的 LOG 规则没有机会执行。

#### 第三步：删除临时错误规则

先查看行号：

```bash
sudo ip netns exec vpn iptables -L FORWARD -n --line-numbers
```

然后删除刚才插入的两条临时规则。若它们仍在第 3、4 行，可执行：

```bash
sudo ip netns exec vpn iptables -D FORWARD 3
sudo ip netns exec vpn iptables -D FORWARD 3
```

说明：删除原第 3 行后，原第 4 行会变成新的第 3 行，所以第二次仍删除第 3 行。

### 故障三：把管理面拦截规则错写到 FORWARD 链

这个故障用来验证：访问 `vpn` 自己的 `9090` 管理端口走 `INPUT` 链，不走 `FORWARD` 链。

#### 第一步：临时删除正确的 INPUT 管理面规则

先查看 `INPUT` 链行号：

```bash
sudo ip netns exec vpn iptables -L INPUT -n --line-numbers
```

删除任务八中添加的 `VPN-MGMT-DENY` 和 `REJECT` 规则。按实际行号删除，并且建议从较大的行号开始删。例如如果它们在第 1、2 行：

```bash
sudo ip netns exec vpn iptables -D INPUT 2
sudo ip netns exec vpn iptables -D INPUT 1
```

确认 `client` 又能访问 `vpn:9090`：

```bash
sudo ip netns exec client curl --max-time 3 http://10.10.10.2:9090/
```

#### 第二步：把管理面拦截规则错误地写到 FORWARD 链

故意在 `FORWARD` 链中插入拦截 `9090` 的规则：

```bash
sudo ip netns exec vpn iptables -I FORWARD 3 \
  -i wg0 -p tcp --dport 9090 \
  -j LOG --log-prefix "WRONG-CHAIN: " --log-level 4

sudo ip netns exec vpn iptables -I FORWARD 4 \
  -i wg0 -p tcp --dport 9090 \
  -j REJECT
```

再次访问：

```bash
sudo ip netns exec client curl --max-time 3 http://10.10.10.2:9090/
```

预期：访问仍然成功。

查看 FORWARD 计数器和日志：

```bash
sudo ip netns exec vpn iptables -L FORWARD -n -v --line-numbers
sudo journalctl -k --grep "WRONG-CHAIN" --no-pager
```

预期：

| 项目 | 现象 |
| :--- | :--- |
| `client -> vpn:9090` | 仍然成功 |
| `WRONG-CHAIN` 规则计数器 | 不增加 |
| `WRONG-CHAIN` 日志 | 没有 |

解释：

> 目的地是 `vpn` 本机进程的包走 `INPUT` 链。即使你在 `FORWARD` 链写了拒绝规则，也拦不住 `client -> vpn:9090`。

#### 第三步：清理错误的 FORWARD 规则

查看行号：

```bash
sudo ip netns exec vpn iptables -L FORWARD -n --line-numbers
```

删除刚才的 `WRONG-CHAIN` 临时规则。若它们仍在第 3、4 行：

```bash
sudo ip netns exec vpn iptables -D FORWARD 3
sudo ip netns exec vpn iptables -D FORWARD 3
```

#### 第四步：恢复正确的 INPUT 管理面规则

```bash
sudo ip netns exec vpn iptables -I INPUT 1 \
  -i wg0 -p tcp --dport 9090 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-MGMT-DENY: " --log-level 4

sudo ip netns exec vpn iptables -I INPUT 2 \
  -i wg0 -p tcp --dport 9090 \
  -j REJECT
```

再次测试：

```bash
sudo ip netns exec client curl --max-time 3 http://10.10.10.2:9090/
```

预期：访问失败，并产生 `VPN-MGMT-DENY` 日志。

填写：

| 故障 | 现象 | 原因 | 修复方法 |
| :--- | :--- | :--- | :--- |
| 删除 `ESTABLISHED,RELATED` |允许的服务（如 server:8080）访问失败 / 超时 |服务器返回的响应流量不匹配 FORWARD 链的默认规则，被 DROP 策略丢弃 |恢复规则：iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT |
| `LOG` 放在 `REJECT` 后面 |访问被拒绝，但无法看到预期的日志 |iptables 规则按顺序匹配，流量命中 REJECT 后直接终止处理，不会继续匹配后面的 LOG 规则 |调整规则顺序，将 LOG 规则插入到 REJECT 规则之前 |
| 管理面规则错写到 `FORWARD` |访问 vpn:9090 仍然成功，FORWARD 链的规则计数器不增加、无日志 |访问 vpn 本机服务的流量走 INPUT 链，不会经过 FORWARD 链，因此 FORWARD 链的规则对其无效 |删除 FORWARD 链中的错误规则，将管理面拦截规则添加到 INPUT 链 |

---

## 任务十二：清理环境

实验结束后关闭隧道并删除 namespace：

```bash
sudo ip netns exec client wg-quick down /etc/wireguard/lab12-client/wg0.conf 2>/dev/null
sudo ip netns exec vpn    wg-quick down /etc/wireguard/lab12-vpn/wg0.conf 2>/dev/null

sudo ip netns del client 2>/dev/null
sudo ip netns del vpn 2>/dev/null
sudo ip netns del server 2>/dev/null

sudo ip netns list
```

---

## 实验结果填写

### A. 拓扑与隧道

| 项目 | 你的填写 |
| :--- | :--- |
| client underlay 地址 |192.0.2.2 |
| vpn underlay 地址 |192.0.2.1 |
| server 地址 |10.20.0.2 |
| client wg0 地址 |10.10.10.1 |
| vpn wg0 地址 |10.10.10.2 |
| 是否看到 WireGuard 握手 |是 |

### B. 基线测试

| 测试 | 只建 VPN 时是否成功 |
| :--- | :--- |
| `client -> server:8080` |成功 |
| `client -> server:2222` |成功 |
| `client -> server ping` |成功 |

### C. 加防火墙后的测试

| 测试 | 结果 | 原因 |
| :--- | :--- | :--- |
| `client -> server:8080` |成功 |命中了 FORWARD 链中专门放行 10.10.10.1 -> 10.20.0.2:8080 的规则，允许访问。 |
| `client -> server:2222` |失败 |未匹配到放行规则，命中了 LOG 和 REJECT 兜底规则，连接被拒绝。 |
| `client -> server ping` |失败 |ICMP 流量未被允许，命中了 LOG 和 REJECT 兜底规则，请求被拒绝。 |

### D. 日志与抓包

| 项目 | 你的填写 |
| :--- | :--- |
| `VPN-DENY` 日志条数 |多条（分别对应访问 2222 和 ping 被拒绝） |
| 日志中被拒绝的目标端口 |2222（TCP） |
| underlay 抓包看到的协议 |UDP（端口 51820，WireGuard 外层加密包） |
| `wg0` 抓包看到的源地址 |10.10.10.1（客户端隧道地址） |
| 内网接口是否能看到被拒绝的 2222 连接 |否（流量在 vpn 的 FORWARD 链就被拒绝，未转发到内网接口） |

### E. VPN 网关管理面保护

| 项目 | 你的填写 |
| :--- | :--- |
| 模拟管理服务端口 |9090 |
| 加 INPUT 规则前是否能访问 |是 |
| 加 INPUT 规则后是否能访问 |否 |
| 管理面拒绝日志前缀 |VPN-MGMT-DENY: |
| `client -> vpn:9090` 经过的链 |INPUT |

### F. conntrack 观察

| 项目 | 你的填写 |
| :--- | :--- |
| 内层 TCP 连接源地址 |	10.10.10.1 |
| 内层 TCP 连接目的地址 |10.20.0.2 |
| 内层 TCP 目标端口 |8080 |
| 内层连接状态 |	ESTABLISHED |
| 外层 UDP 源地址 |	192.0.2.2 |
| 外层 UDP 目的地址 |	192.0.2.1 |
| 外层 UDP 目标端口 |	51820 |
| WireGuard 隧道状态应看 `conntrack` 还是 `wg show` |	wg show |

### G. 故障排查

| 故障 | 现象 | 原因 | 修复方法 |
| :--- | :--- | :--- | :--- |
| 删除 `ESTABLISHED,RELATED` |允许的服务（如 server:8080）访问失败 / 超时 |服务器返回的响应流量不匹配 FORWARD 链的默认规则，被 DROP 策略丢弃 |恢复规则：iptables -I FORWARD \-m conntrack --ctstate ESTABLISHED,RELATED \-j ACCEPT |
| `LOG` 放在 `REJECT` 后面 |访问被拒绝，但无法看到预期的日志 |iptables 规则按顺序匹配，流量命中 REJECT 后直接终止处理，不会继续匹配后面的 LOG 规则 |调整规则顺序，将 LOG 规则插入到 REJECT 规则之前 |
| 管理面规则错写到 `FORWARD` |访问 vpn:9090 仍然成功，FORWARD 链的规则计数器不增加、无日志 |访问 vpn 本机服务的流量走 INPUT 链，不会经过 FORWARD 链，因此 FORWARD 链的规则对其无效 |删除 FORWARD 链中的错误规则，将管理面拦截规则添加到 INPUT 链 |

---

## 思考题

1. `AllowedIPs` 和 iptables 访问控制分别解决什么问题？为什么不能只靠 `AllowedIPs` 做权限控制？
答：AllowedIPs是WireGuard自身的策略，兼具路由与入站过滤功能：一方面指定哪些目标网段流量进入加密隧道，另一方面仅放行来源地址在规则内的隧道报文；它仅能基于 IP 网段做控制，无法区分端口、协议。iptables是Linux内核防火墙，可基于接口、IP、端口、协议、连接状态实现精细化管控，同时支持流量日志审计。只依靠AllowedIPs权限粒度过粗，会造成内网访问权限泛滥，且不具备日志审计、精准拦截能力，无法满足安全要求。
2. 为什么 VPN 用户访问内网服务器时，规则要写在 `FORWARD` 链，而不是 `INPUT` 链？
答：INPUT链的作用是处理目的地是本机进程的流量，比如访问VPN网关自身的SSH、HTTP 管理服务。而VPN用户访问内网服务器的流量，目的地是内网服务器，VPN网关只是一个中间转发节点，并非流量的最终接收者，这类转发流量会被内核交给FORWARD链处理。如果把规则写在INPUT链上，转发流量根本不会经过该链，规则就会完全失效，无法起到访问控制的作用。
3. 本实验中 `ESTABLISHED,RELATED` 规则如果删除，访问 `server:8080` 会出现什么现象？
答：访问会失败或超时。因为ESTABLISHED,RELATED规则允许已建立连接的响应流量通过，而删除该规则后，虽然client发出的server:8080请求能命中ACCEPT规则，但server返回的响应流量无法匹配任何允许规则，会被FORWARD链的默认DROP策略丢弃，导致TCP三次握手无法完成，最终表现为访问失败或超时。
4. 为什么 LOG 必须放在 REJECT 前面？
答：iptables规则是按顺序逐条匹配的，流量命中某条规则后会按规则动作处理，不再继续向下匹配。如果把LOG放在REJECT后面，流量会先命中REJECT规则被拒绝，处理流程直接终止，后面的LOG规则永远不会被触发，无法记录被拒绝的访问日志；只有把LOG放在REJECT前面，流量才会先被记录日志，再被拒绝，才能实现 “拒绝 + 审计” 的完整功能。
5. underlay 抓包只能看到 UDP 51820，这对通信安全意味着什么？它还能暴露哪些信息？
答：这意味着WireGuard的内层业务流量（如 TCP、ICMP）被加密封装在UDP包中，underlay网络无法直接查看内层的源 / 目的地址、端口和数据内容，大幅提升了通信的保密性，中间人无法窃取或篡改业务数据。
但它仍会暴露一些信息：比如VPN网关和客户端的公网IP地址、WireGuard使用的固定端口51820，攻击者可以通过这些信息识别VPN服务，甚至发起针对性的扫描或攻击；同时固定的端口也会让流量特征更容易被识别，带来一定的流量分析风险。
6. 如果一个真实企业允许 VPN 用户访问整个内网 `10.0.0.0/8`，可能带来哪些风险？
答：这会带来严重的安全风险：
1.权限过大，用户可以访问内网所有网段和端口，包括管理服务、数据库、敏感业务系统，一旦用户账号被攻破，攻击者就能横向渗透整个内网；
2.无法限制用户访问范围，不符合 “最小权限原则”，任何用户的误操作或恶意行为都可能影响整个内网；
3.缺乏访问审计和拒绝记录，无法追踪用户的访问行为，出现安全事件后难以溯源；
4.内网暴露面过大，VPN用户可能利用内网漏洞发起攻击，威胁整个企业网络的安全。
7. `client -> vpn:9090` 和 `client -> server:8080` 分别经过哪条 iptables 链？为什么不同？
答：client -> vpn:9090经过INPUT链，因为该流量的目的地是VPN网关本机运行的 python3 -m http.server进程，属于访问本机服务的流量；而client -> server:8080 经过FORWARD链，因为该流量的目的地是内网服务器，VPN网关只是转发节点，并非流量的最终接收者，转发流量会被内核交给FORWARD链处理。两者的核心区别在于流量的目的地是否为VPN网关本机。
8. conntrack 能看到 WireGuard 外层 UDP 包和内层 TCP 连接。为什么不能把 WireGuard 隧道本身理解成 conntrack 的 NAT 映射？
答：WireGuard隧道不能等同于conntrack 的NAT映射，原因如下：
1.会话模型不同：NAT 是对同一条 IP 会话做地址 / 端口改写；WireGuard 属于隧道封装，外层 UDP 隧道连接、内层业务连接是两条完全独立的会话。
2.工作层级不同：NAT 是三层地址转换，无加密能力；WireGuard 在内层报文外封装 UDP 头部并全程加密，属于加密隧道技术。
3.状态管理不同：conntrack 只跟踪普通 IP 连接状态，无法识别 WireGuard 的密钥协商、握手、保活等隧道专属状态，隧道生命周期由 WireGuard 进程独立管理。
9. 如果 VPN 网关上有 SSH 管理端口，应该允许哪些来源访问？应该如何写日志？
答:应该只允许企业可信的管理网段或固定公网IP访问，禁止所有VPN用户和未知公网地址访问，严格遵循最小权限原则。日志可以通过iptables的LOG规则配置：
1.放行可信运维IP（示例地址可根据实际修改）
iptables -A INPUT -s 192.168.1.100 -p tcp --dport 22 -j ACCEPT
2.记录VPN访问SSH的违规流量（限流防止日志刷屏）
iptables -I INPUT -i wg0 -p tcp --dport 22 -m limit --limit 5/min -j LOG --log-prefix "VPN-SSH-DENY: " --log-level 4
3.拒绝所有VPN侧访问SSH
iptables -I INPUT -i wg0 -p tcp --dport 22 -j REJECT这样可以记录所有从VPN隧道访问SSH端口的被拒绝流量，便于审计和异常排查。
10. 当 `wg show` 有握手但业务访问失败时，应该按什么顺序检查服务监听、路由表、防火墙规则、日志和计数器？
答：按以下顺序排查：
1.先检查服务监听：在目标服务器上确认服务是否正常运行、端口是否监听，如ss -lntp | grep 8080；
2.再检查路由表：确认client有到目标网段的路由，VPN网关和服务器的默认网关配置正确；
3.然后检查防火墙规则：查看VPN网关的FORWARD链规则，确认是否有允许目标端口的规则；
4.接着查看iptables计数器：确认访问流量是否命中了允许或拒绝规则；
5.最后查看日志：检查VPN-DENY等日志，确认是否有被拒绝的流量记录，定位访问失败的具体原因。

---

## 截图要求

`topology.png` 已提供，不需要截图或重新绘制；提交时保留在 `Lab12.md` 同一目录下，保证打开实验报告时能直接显示。

实验截图须清晰，终端文字可读。截图文件需与本 `Lab12.md` 放在同一目录下，并保证它们能在上方对应任务位置正常显示。只需提交以下 5 张实验截图：

| 截图内容 | 文件名 |
| :--- | :--- |
| `wg show` 与 client 路由表 | `wg_status.png` |
| 只建 VPN 时 8080、2222、ping 都可访问的基线结果 | `baseline.png` |
| VPN 访问控制规则列表、计数器，以及加规则后 8080 成功、2222/ping 失败 | `policy_test.png` |
| `VPN-DENY` 日志 | `vpn_log.png` |
| underlay、wg0、内网接口抓包对比 | `tcpdump_compare.png` |

具体要求：

1. `wg_status.png`：放在任务三末尾，能看到 `wg show` 中的 `latest handshake` 或 `transfer`，以及 client 路由表中指向 `wg0` 的 `10.20.0.0/24` 路由。
2. `baseline.png`：放在任务四末尾，只建立 VPN、未加访问控制规则时，能看到 `client -> server:8080`、`client -> server:2222`、`client -> server ping` 都可访问。
3. `policy_test.png`：放在任务六末尾，能看到 VPN 网关 `FORWARD` 链规则、计数器，以及加规则后 `8080` 成功、`2222` 和 `ping` 失败。
4. `vpn_log.png`：放在任务七末尾，能看到 `VPN-DENY` 日志，日志中应包含被拒绝流量的关键信息，例如源地址、目的地址、协议或目标端口。
5. `tcpdump_compare.png`：放在任务十末尾，能对比 underlay、`wg0`、内网接口三处抓包结果。可以把多张截图拼成一张图。

---

## 提交要求

```text
学号姓名/
└── Lab12/
    ├── Lab12.md             # 本文件（填写完整，含截图与答案）
    ├── topology.png         # 已提供的实验拓扑图
    ├── wg_status.png        # 隧道状态与路由表
    ├── baseline.png         # 未加访问控制前的基线测试
    ├── policy_test.png      # 防火墙策略与访问测试
    ├── vpn_log.png          # VPN-DENY 日志
    └── tcpdump_compare.png  # 三处抓包对比
```

## 截止时间

###### 2026-06-18，届时关于 `Lab12` 的 PR 将不会被合并。
