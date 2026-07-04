# 故障排查报告

## 场景1：DNAT配置了但外网无法访问
### 故障现象
internet访问203.0.113.1:8080失败，但DNAT规则已配置。

### 排查过程
1. **检查NAT规则**
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v
# 检查FORWARD规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
# 使用conntrack查看连接状态
sudo ip netns exec fw conntrack -L | grep 8080
# 抓包验证
sudo ip netns exec fw tcpdump -ni veth-fw-inet -c 5
sudo ip netns exec fw tcpdump -ni veth-fw-dmz -c 5
```
### 根本原因
DNAT只修改了目的地址，但修改后的包仍需通过FORWARD链。默认策略DROP会丢弃所有未匹配包。

### 修复方法
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
### 验证修复
bash
sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/
成功返回HTML页面。
```

## 场景2：VPN隧道握手正常但业务访问失败
### 故障现象
- `wg show`显示`latest handshake`正常
- `remote ping 10.40.0.2`失败
- `fw`上没有相关日志

### 排查过程
1. **检查VPN隧道状态**
```bash
sudo ip netns exec fw wg show
sudo ip netns exec remote wg show
# 检查remote路由表
sudo ip netns exec remote ip route
# 检查fw的FORWARD规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
# 抓包验证
sudo ip netns exec fw tcpdump -ni vpn-fw -c 5
# 检查实际接口名
sudo ip netns exec fw ip link show
```
### 根本原因
WireGuard默认使用`wg0`作为接口名，但FORWARD规则中写成了`vpn-fw`，导致规则不匹配。

### 修复方法
```bash
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT
### 验证修复
bash
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
成功返回HTML页面。
```

## 场景3：去掉ESTABLISHED,RELATED后TCP连接失败
### 故障现象
- 三次握手的第一个SYN包能通过
- 服务器的SYN-ACK回包被防火墙拦截
- curl命令超时

### 排查过程
1. **删除状态检测规则复现故障**
```bash
sudo ip netns exec fw iptables -D FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 业务访问测试
sudo ip netns exec remote curl --max-time 3 http://10.40.0.2:8080/
# 抓包分析流量
sudo ip netns exec fw tcpdump -ni vpn-fw -c 10
# 使用conntrack查看连接状态
sudo ip netns exec fw conntrack -L | grep 10.10.10.2
```

### 根本原因
TCP三次握手流程：
1. client → server: SYN（NEW状态，匹配允许规则）
2. server → client: SYN+ACK（ESTABLISHED状态，无规则匹配被DROP）
3. client → server: ACK（无法到达，连接超时）

去掉ESTABLISHED,RELATED后，回程的SYN+ACK包因无规则匹配被默认DROP策略丢弃，导致TCP三次握手无法完成。

### 修复方法
```bash
# 方法1：恢复ESTABLISHED,RELATED规则（推荐）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```


### 验证修复
```bash
sudo ip netns exec office curl --max-time 3 http://10.40.0.2:8080/
```
成功返回HTML页面。

### 总结
iptables的conntrack状态跟踪机制是现代防火墙的核心：
- **NEW**：匹配连接的首包（如SYN）
- **ESTABLISHED**：匹配已建立连接的后续包（如SYN+ACK、数据包）
- **RELATED**：匹配与现有连接相关的新连接（如FTP数据通道）

正确配置应为：
```bash
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT  # 放行业务回程
iptables -A FORWARD -m conntrack --ctstate NEW -j ACCEPT                  # 允许新连接发起
```
两者缺一不可。
```