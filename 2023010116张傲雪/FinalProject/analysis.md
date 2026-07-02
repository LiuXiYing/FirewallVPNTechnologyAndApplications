5.1攻击演练
**提交内容：**
- 3种攻击的命令和结果截图
![攻击演练1](11-attack-scan.png)
![攻击演练2](12-attack-bypass.png)
- 每种攻击失败的原因分析（各100字）
攻击1：扫描office网段
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
结果： 只有网关10.20.0.1可通，其他主机全部被REJECT
原因分析：guest到office的流量被防火墙明确REJECT。fw的FORWARD链规则 -i veth-fw-guest -o veth-fw-office -j REJECT 拦截了所有从guest网段(10.30.0.0/24)发往office网段(10.20.0.0/24)的包。攻击者只能扫描到网关，无法发现内网主机，实现了guest与office的有效隔离。

攻击2：尝试绕过防火墙访问dmz:22
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest nc -zv -w 2 10.40.0.2 22
结果： 所有尝试均失败（Connection refused / Connection timed out）
原因分析：防火墙规则基于目标IP、目标端口和入接口做过滤，不关心源端口。规则 -i veth-fw-guest -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT拦截了所有从guest到dmz:22的流量。改变源端口（80、443）或使用不同工具（nc、telnet）都无法绕过。

攻击3：尝试伪造VPN流量
sudo ip netns exec guest ping -c 1 -I 10.10.10.2 10.20.0.2
sudo ip netns exec guest hping3 -S -p 8000 -a 10.10.10.2 10.20.0.2 -c 1
结果： Failed binding local connection end / 100% packet loss
原因分析：WireGuard使用加密隧道，所有数据包需要私钥加密签名。伪造的包没有正确密钥，无法通过wg0接口。即使进入，防火墙也基于实际入接口（veth-fw-guest）做过滤，不会匹配wg0的允许规则。三层防护使伪造VPN流量完全无法成功。

- 回答：攻击者能否从REJECT和DROP的不同表现判断目标是否存在？
攻击者无法单纯依靠 REJECT/DROP区分目标是否存在,REJECT返回ICMP不可达仅能证明防火墙拦截，无法判断后端主机是否存活；DROP静默丢弃，无任何返回报文，攻击者无法获取网段、端口存活信息，外网边界推荐使用 DROP 提升隐蔽性。

5.2-任务1 
回答问题：
1. 从日志的哪些字段可以判断这是来自guest的攻击？
从日志的IN字段判断，如果是IN=veth-fw-guest说明数据包从guest网卡进入；从SRC字段（源地址）判断，如果是10.30.0.0/24网段；从log-prefix判断，如果是 GUEST-TO-OFFICE或 GUEST-TO-DMZ。三个字段综合可准确判断攻击来自guest。
2. 如果日志中`IN=veth-fw-guest OUT=veth-fw-office`，说明了什么？
说明有流量从guest区域（10.30.0.0/24）试图访问office区域（10.20.0.0/24），被防火墙拦截。这是典型的跨区域违规访问，违反了"访客区不能访问办公区"的安全策略，防火墙成功阻止了该行为。
3. 为什么看到大量相同来源的日志应该引起警惕？
大量相同来源的日志表明可能有自动化攻击工具在运行，可能在进行端口扫描、暴力破解等恶意行为。需要立即调查源IP，可能封禁IP，检查是否有其他系统被入侵，这是攻击前兆的明显信号。

5.2-任务2
回答问题：
1. 哪条规则拦截了guest访问office？
FORWARD 链中匹配入接口veth-fw-guest、出接口veth-fw-office的 REJECT 规则负责拦截访客访问办公网，该规则上方配套带GUEST-TO-OFFICE前缀的 LOG 审计规则。规则匹配逻辑为：数据包从访客网卡流入、目标转发至办公内网网卡时，先写入内核审计日志记录五元组信息，再执行 REJECT 动作返回连接拒绝。执行iptables -L FORWARD -n -v --line-numbers可看到该规则独立行，带有数据包计数，所有访客访问办公区的流量都会命中本条规则，实现隔离拦截。
2. 如果guest→office的规则计数很高，说明了什么？
规则计数器数值持续走高，代表大量访客流量尝试访问办公内网，存在明显内网侦察行为。正常合规场景下访客不会主动访问办公网段，高频计数说明访客设备存在恶意程序、外来人员私自扫描内网，或是访客主机被攻击者控制，持续发起横向渗透探测。大量违规流量长期产生会占用防火墙处理性能，同时频繁生成审计日志消耗磁盘空间，风险在于攻击者收集内网资产后，会寻找开放端口发起漏洞攻击，需要临时封禁高频率源 IP，同时加强访客设备准入管控。
3. REJECT和DROP在安全性上有什么区别？
REJECT 会向访问源返回 ICMP 不可达或 TCP 重置报文，客户端能明确感知端口 / 网段被拦截，适合实验调试方便排错，但会向攻击者暴露防火墙拦截边界，攻击者可判断网段是否存在；DROP 静默丢弃数据包，不返回任何响应，攻击者无法区分目标主机不存在还是被防火墙拦截，外网生产环境更安全。内网测试可用 REJECT 便于排查故障，公网边界推荐 DROP 隐藏内网拓扑，减少攻击者侦察信息，缩小暴露攻击面
**提交内容：**
- 日志截图（含攻击特征）
![防御日志](13-defense-logs.png)
- 规则计数器截图
![防御规则](14-defense-counters.png)


5.3边界测试
**提交内容：**
- 选择的问题及风险分析（200字）
   我的选择是3VPN没有限制连接频率，风险分析：暴力破解风险：攻击者可通过VPN端口(51820)进行大量连接尝试，
   猜测VPN密钥或尝试中间人攻击；拒绝服务攻击：攻击者发送大量伪造的VPN握手包，消耗防火墙CPU资源，
   导致合法VPN用户无法连接，造成业务中断；端口扫描：攻击者通过高频连接探测防火墙规则和网络拓扑，
   为后续攻击收集信息；资源耗尽：大量无效连接占用系统资源（内存、连接表），影响其他服务正常运行。
- 改进方案的实现代码
#标记新连接
sudo ip netns exec fw iptables -I FORWARD 1 \
  -i wg0 -m state --state NEW -m recent --name vpnlimit --set
#超频连接记录日志
sudo ip netns exec fw iptables -I FORWARD 1 \
  -i wg0 -m state --state NEW \
  -m recent --name vpnlimit --update --seconds 60 --hitcount 5 \
  -j LOG --log-prefix "VPN-RATE-LIMIT: " --log-level 4
#超频连接拒绝
sudo ip netns exec fw iptables -I FORWARD 1 \
  -i wg0 -m state --state NEW \
  -m recent --name vpnlimit --update --seconds 60 --hitcount 5 \
  -j REJECT --reject-with icmp-port-unreachable
- 测试效果截图
![边界测试](15-improvement.png)

5.4高级任务
**提交内容：**
- 4个位置的抓包截图
![remote抓包](16-tcpdump-remote.png)
![fw抓包](17-tcpdump-fw.png)
- 包变化对比表

| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:-----|:---------|:-------|:---------|:-----|:-----|
| 1 | remote wg0 |10.10.10.2 |10.40.0.2 |TCP | 封装前 |
| 2 | fw wg0 |10.10.10.2 |10.40.0.2 |TCP | 解封装后 |
| 3 | fw veth-fw-dmz |10.10.10.2 |10.40.0.2 |TCP | 转发到dmz |
| 4 | conntrack |10.10.10.2 |10.40.0.2 |TCP | 连接跟踪记录 |
- conntrack记录截图
![conntrack记录](18-conntrack.png)
- 分析报告（300字）：说明包是如何一步步被处理的
remote客户端原始TCP业务数据包由WireGuard加密封装为UDP 51820报文，通过公网发送至fw外网接口；fw接收UDP报文后解封装，还原内层源地址10.10.10.2、目的地址 10.40.0.2的TCP请求。
数据包进入fw FORWARD链，匹配wg0入接口、dmz 8080放行规则，conntrack创建NEW状态连接记录；数据包从veth-fw-dmz转发至DMZ服务器。
服务器返回的响应数据包匹配ESTABLISHED回程规则，原路转发回wg0隧道，重新加密封装发回remote。整个流程不做SNAT转换，VPN客户端真实隧道IP完整保留，防火墙可精准审计远程员工访问行为；conntrack全程跟踪TCP全连接生命周期，保证双向通信正常。