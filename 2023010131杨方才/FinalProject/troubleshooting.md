# troubleshooting.md 故障排查报告
```markdown
# 故障排查完整报告
## 前言
本报告基于本次企业级网络安全实验环境，复现三类运维高频典型故障：DNAT配置完成但外网无法访问DMZ业务、WireGuard隧道握手正常但内网不通、删除连接状态规则后TCP单向通信失败。每类故障完整记录故障现象、复现操作、分步排查流程、底层根因、修复命令与验证结果，总结标准化排障思路，适配企业防火墙日常运维场景。

## 故障一：DNAT规则存在，外网无法访问DMZ 8080业务
### 1. 故障现象
1. 执行`iptables -t nat -L -n`可清晰看到8080端口DNAT映射规则，配置无误；
2. DMZ服务器正常执行`python3 -m http.server 8080`，本地curl 127.0.0.1:8080访问正常；
3. internet命名空间执行`curl http://203.0.113.1:8080`持续连接超时，无返回、无审计拦截日志；
4. fw主机无对应流量拒绝日志，说明流量未触发REJECT拦截规则。

### 2. 故障复现操作
环境正常时，手动删除DNAT配套的FORWARD转发放行规则，制造故障：
```bash
# 进入fw命名空间删除外网访问DMZ 8080放行策略
sudo ip netns exec fw iptables -D FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --syn --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
# 外网重新访问复现超时故障
sudo ip netns exec internet curl --max-time 5 http://203.0.113.1:8080
```

### 3. 分步排查流程
1. **业务自检**：进入dm本地访问8080，确认Web服务监听正常，排除应用层故障；
2. **NAT表校验**：查看nat PREROUTING链，DNAT端口映射配置参数完全正确，排除映射写错；
3. **接口抓包定位丢包**
   - 在veth-fw-inet抓包：可捕获外网发送的TCP SYN请求包；
   - 在veth-fw-dmz抓包：无任何入站报文；
   结论：数据包在fw内部被丢弃，未转发至DMZ；
4. **检查filter FORWARD链**：核对外网流向DMZ的新建连接放行规则，发现配套放行策略已被删除；
5. 核对默认策略：FORWARD默认DROP，无匹配规则流量全部静默丢弃。

### 4. 故障根本原因
DNAT仅负责修改数据包目的IP地址，仅完成地址转换不会自动放行跨网段转发流量。外网流量经DNAT转换后目标变为内网10.40.0.2，此时数据包需要匹配FORWARD链的内网放行规则，缺少对应规则时，流量会被默认DROP策略静默丢弃，不会生成任何拦截日志，表现为访问超时。

### 5. 修复命令与验证
#### 补充缺失的FORWARD放行规则
```bash
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz \
-d 10.40.0.2 -p tcp --syn --dport 8080 \
-m conntrack --ctstate NEW -j ACCEPT
```
#### 验证连通性
```bash
sudo ip netns exec internet curl http://203.0.113.1:8080
```
执行后正常返回Web页面，故障修复。

### 6. 运维总结
NAT地址转换与filter转发规则必须配套部署，PREROUTING DNAT仅修改IP，跨区域访问必须配置对应FORWARD放行策略，排障时结合多接口tcpdump抓包可快速定位丢包节点。

---

## 故障二：WireGuard隧道握手正常，但VPN客户端无法访问内网
### 1. 故障现象
1. 在fw与remote分别执行`wg show`，存在latest handshake握手记录，收发transfer字节持续增长，隧道加密链路正常；
2. remote执行`curl 10.40.0.2:8080`、`ping 10.20.0.2`全部超时；
3. fw内核无VPN违规拦截日志，流量未匹配任何VPN相关规则。

### 2. 故障复现操作
修改remote客户端wg0.conf中AllowedIP字段，移除办公、DMZ业务网段，重启隧道复现故障：
```bash
# 修改配置，仅保留VPN本地网段，无内网路由
sudo sed -i 's/AllowedIPs = 10.20.0.0\/24,10.40.0.0\/24/AllowedIPs = 10.10.10.0\/24/' /etc/wireguard/remote/wg0.conf
# 重载隧道
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
# 内网访问测试，复现超时故障
sudo ip netns exec remote ping 10.40.0.2
```

### 3. 分步排查流程
1. 隧道状态检查：wg show确认握手、流量收发正常，排除公网端口、密钥错误；
2. 客户端路由查询：执行`ip route`，不存在10.20.0.0/24、10.40.0.0/24隧道路由；
3. 流量路径判断：访问内网数据包未送入wg0隧道，从默认网关发出，未到达fw的wg接口；
4. 核查wg配置文件：AllowedIPs仅配置VPN隧道本地网段，未添加业务内网网段；
5. 原理确认：AllowedIPs控制哪些流量走WireGuard隧道，未配置网段不会生成对应路由。

### 4. 故障根本原因
WireGuard客户端`AllowedIPs`字段是路由控制核心参数，只有配置的目标网段流量才会路由至wg0加密隧道。本次仅填写VPN本地网段，访问办公、DMZ的数据包不会进入隧道，直接走本机默认网卡发送，无法抵达防火墙wg接口，自然不会匹配VPN放行规则，访问全程超时。

### 5. 修复方案与验证
#### 修改客户端AllowedIPs配置
```
[Peer]
PublicKey = fw服务端公钥
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
```
#### 重启隧道并测试
```bash
sudo ip netns exec remote wg-quick down /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf
sudo ip netns exec remote curl http://10.40.0.2:8080
```
正常返回网页，故障解决。

### 6. 运维总结
隧道握手正常仅代表加密链路连通，路由规则独立控制内网流量是否进入隧道；排障优先查看客户端ip路由表与AllowedIPs字段，区分链路故障与路由故障。

---

## 故障三：删除ESTABLISHED状态规则后TCP单向不通
### 1. 故障现象
1. office发起`curl 10.40.0.2:8080`，SYN请求可到达DMZ服务器；
2. DMZ回复的SYN-ACK回程报文被防火墙丢弃，客户端长时间连接超时；
3. 无任何拒绝日志，回程流量无匹配放行规则。

### 2. 故障复现操作
删除FORWARD链首行的连接状态放行规则，复现单向不通故障：
```bash
# 删除状态规则
sudo ip netns exec fw iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 测试单向访问故障
sudo ip netns exec office curl --max-time 5 http://10.40.0.2:8080
```

### 3. 分步排查流程
1. 两端抓包：office侧仅发送SYN无响应，DMZ侧收到SYN并回复SYN-ACK；
2. fw多接口抓包：veth-fw-dmz可捕获服务器回程报文，veth-fw-office无回程流量；
3. 查看FORWARD规则：缺少ESTABLISHED、RELATED状态放行策略；
4. 原理验证：新建连接NEW匹配业务放行规则，但回程响应属于已建立连接，无对应放行策略，被默认DROP丢弃。

### 4. 故障根本原因
iptables conntrack连接跟踪机制区分新建连接与回程响应流量。我们仅为客户端主动发起的NEW新建流量配置放行规则，服务器返回的应答报文状态为ESTABLISHED/RELATED，无专用放行规则时会被默认策略丢弃，造成TCP三次握手无法完成，表现为单向可发、无返回。

### 5. 修复命令与验证
将状态规则插入FORWARD链最顶端（最高优先级）：
```bash
sudo ip netns exec fw -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 重新测试访问
sudo ip netns exec office curl http://10.40.0.2:8080
```
双向通信恢复正常。

### 6. 运维总结
conntrack状态规则是所有TCP业务的基础基线，必须放置在FORWARD链第一条，缺失会导致所有跨网段TCP单向不通，是网络环境部署第一条必配规则。

## 通用标准化故障排查流程
1. 连通性基础测试：ping网关，确认底层路由、网卡UP；
2. 应用层验证：确认服务器端口监听正常，排除程序故障；
3. 多接口tcpdump抓包，定位丢包发生在哪个网络节点；
4. 核查路由表：客户端/防火墙网段路由是否完整；
5. 校验iptables filter、nat两条规则链，核对放行/拦截策略；
6. 查看内核journalctl审计日志，确认流量是否触发拦截；
7. 复现故障、执行修复、复测验证连通性。

## 报告总结
本次复现的三类故障覆盖NAT地址转换、WireGuard隧道路由、连接状态检测三大企业防火墙高频运维场景，故障根源均为配置缺失、规则顺序错误、路由范围配置不当。通过抓包、路由查询、规则校验三层手段可快速定位流量丢包位置，形成标准化排障流程，能够迁移到真实企业边界防火墙、VPN网关运维工作中，提升故障定位效率，减少业务中断时长。
```