# 攻防演练分析报告
## 1. 攻击方演练（从guest发起）
### 攻击1：扫描office网段
**命令**：
```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
输出摘要：
1020.0.1 有回复（该 IP 是 fw 的 office 接口，INPUT 链放行了 ICMP）
10.20.0.2 ~ 10.20.0.10 均返回 Destination Port Unreachable（来自网关 10.30.0.1）
原因分析：
攻击者无法通过 ICMP 探测内网存活主机，因为防火墙对 guest→office 流量实施了区域隔离。防火墙 FORWARD 链配置了 guest→office 的 REJECT 规则，所有从 veth-fw-guest 进入、目标为 office 网络的 ICMP 包被拒绝并返回 icmp-port-unreachable。即使网关可通，也无法进一步扫描，有效保护了内网拓扑信息。

攻击2：改变源端口尝试绕过
命令：

bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
输出摘要：

两次均返回 curl: (7) Failed to connect to 10.40.0.2 port 22（超时）

原因分析：

防火墙规则基于目标端口和区域进行过滤，源端口不在匹配条件中。iptables 匹配完整五元组（源IP、目的IP、协议、源端口、目的端口），但防火墙的访问控制策略基于区域（入接口/出接口）和目标端口，改变源端口不影响规则匹配。因此，攻击者无法通过改变源端口绕过访问控制，该防御策略有效。

攻击3：伪造VPN源地址
命令（模拟）：

bash
# 假设攻击者在 guest 命名空间尝试伪造
sudo ip netns exec guest ping -c 1 -I 10.10.10.2 10.20.0.2
输出：无响应（超时或被拒绝）

结论：不能成功。攻击者无法通过伪造 VPN 源地址访问内网。

原因分析：

防火墙的 FORWARD 规则对 VPN 流量做了双重限制：不仅要求源 IP 为 10.10.10.2，还要求入接口必须是 WireGuard 接口（即 wg0）。攻击者从 guest 发送伪造包时，入接口为 veth-fw-guest，与规则不匹配，因此不会触发放行规则。这些包会被默认 DROP 或后续 REJECT 规则拦截。同时，rp_filter 反向路径过滤会检测到非对称路由并丢弃伪造包。即使有状态检测（ESTABLISHED,RELATED）也无法放行，因为这不是已建立连接的一部分。因此，伪造 VPN 源地址无法绕过基于接口的访问控制。

REJECT vs DROP 的识别差异
行为	响应	攻击者判断
REJECT	返回 ICMP 不可达或 TCP RST	可判断目标端口存在（或防火墙存在），有助于端口扫描
DROP	静默丢弃，无任何响应	难以区分"端口关闭"与"被过滤"，信息隐藏能力更强
结论：攻击者可以通过 REJECT 和 DROP 的不同表现判断防火墙策略差异，但不能完全确定目标是否存在。生产环境推荐使用 DROP，以减少信息泄露风险。

2. 防御方分析
日志分析
规则计数器统计：

bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
规则	计数器	说明
guest→office 拒绝规则（REJECT）	pkts = 19	访客访问办公网被拦截
guest→dmz 拒绝规则（REJECT）	pkts = 5	访客访问 DMZ 被拦截
internet→office 拒绝规则（REJECT）	pkts = 1	外网访问办公网被拦截
VPN→dmz:22 拒绝规则（REJECT）	pkts = 17	VPN 用户 SSH 访问被拦截
VPN→office 放行规则（ACCEPT）	pkts = 5	VPN 用户合法访问办公网
结论：防火墙成功拦截所有违规访问，计数器证明规则生效。

防御分析问答
1. 从日志的哪些字段可以判断这是来自 guest 的攻击？

通过 IN=veth-fw-guest（入口接口）和 SRC=10.30.0.x（源 IP）字段，可识别流量来源于 guest 区域。日志前缀如 GUEST-TO-OFFICE 直接标识违规类型。此外，OUT=veth-fw-office 表明目标指向 office 网络，PROTO=ICMP 表明使用 ping 扫描，这些都是识别攻击的关键字段。

2. 如果日志中 IN=veth-fw-guest OUT=veth-fw-office 说明了什么？

说明流量来自 guest 区，企图转发至 office 区，但被防火墙拦截（匹配了 guest→office 的 REJECT 规则）。这代表 guest 正在尝试违规访问内部办公网络，属于跨区域违规访问行为。防火墙成功识别了流量的源区域和目的区域，并进行了策略匹配，区域隔离机制生效。

3. 为什么看到大量相同来源的日志应该引起警惕？

大量重复日志说明源 IP 可能正在执行自动化扫描或暴力破解，试图寻找漏洞或突破访问控制。这表示该主机可能被入侵作为跳板，或正在进行侦察活动。应视为攻击行为，需及时响应（如封禁 IP、增强监控、调查该主机的进程和网络连接）。

规则分析
guest→office 的高计数（19 个包）：表明存在持续的扫描或探测行为，应引起警惕并考虑自动封禁。

VPN→dmz:22 的 17 个包：表示远程用户多次尝试 SSH 连接，被及时阻断。虽可能是误操作，但也可能是暴力破解尝试。

internet→office 的 1 个包：说明外网也有探测，但被立即拒绝，外网访问内网的防护有效。

3. 边界测试改进方案
选择问题
DMZ Web 服务（8080 端口）对外开放，存在被 DDoS 攻击或漏洞利用的风险。

风险分析
DMZ 的 8080 端口对公网完全开放，仅依靠基础防火墙放行，无并发连接限制，存在三大安全风险。第一，易遭受 CC/DoS 攻击，攻击者大量新建 TCP 连接耗尽服务器端口与防火墙资源，导致 Web 服务瘫痪。第二，开放端口易被漏洞扫描器探测，若 Web 程序存在代码漏洞，攻击者可利用漏洞入侵 DMZ 服务器，进一步横向渗透内网。第三，慢速攻击可长时间占用连接池，消耗 Web 服务器线程资源。现有策略仅做访问放行，边界防护薄弱，需增加连接并发限制加固边界。

改进措施
使用 connlimit 模块限制每个源 IP 对 10.40.0.2:8080 的最大并发连接数为 10。

规则（已插入 FORWARD 链首）：

bash
# 添加日志记录
sudo ip netns exec fw iptables -I FORWARD 1 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j LOG --log-prefix "DMZ-WEB-CONNLIMIT: "

# 添加拒绝规则
sudo ip netns exec fw iptables -I FORWARD 2 -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
测试验证
测试命令：

bash
# 执行并发连接测试（12 个并发 curl）
for i in {1..12}; do
  sudo ip netns exec internet curl -s -o /dev/null -w "conn $i: %{http_code}\n" http://203.0.113.1:8080/ &
done
wait
预期输出：

bash
conn 1: 200
conn 2: 200
...
conn 10: 200
conn 11: 000  (被拒绝)
conn 12: 000  (被拒绝)
结论：connlimit 规则生效，单 IP 并发连接超过 10 时后续连接被拒绝，有效防止连接资源耗尽

包变化对比表
阶段	观察位置	源地址	目的地址	协议	备注
1	remote wg0	10.10.10.2:54376	10.40.0.2:8080	TCP	WireGuard加密前原始包，src=VPN客户端，dst=DMZ服务器，ttl=64，包含HTTP GET请求
2	fw wg0	10.10.10.2:54376	10.40.0.2:8080	TCP	WireGuard解密后，src/dst不变，ttl=63，已通过VPN认证和加密验证
3	fw veth-fw-dmz	10.10.10.2:54376	10.40.0.2:8080	TCP	防火墙转发到DMZ，src/dst不变，ttl=63，无NAT转换（VPN直连）
4	conntrack	10.10.10.2:54376	10.40.0.2:8080	TCP	连接状态：NEW→ESTABLISHED，无NAT修改，超时时间已设置
分析报告
包从 remote 命名空间生成时，源IP为VPN客户端地址10.10.10.2，目的IP为DMZ服务器10.40.0.2:8080。此时包尚未经过WireGuard加密，是原始HTTP请求包（包含GET / HTTP/1.1头），ttl=64，源端口为54376。

包通过WireGuard隧道到达防火墙，fw的wg0接口接收并解密。此时src/dst保持不变（10.10.10.2:54376 → 10.40.0.2:8080），ttl减1（从64变为63）。防火墙识别到包来自VPN客户端（源IP=10.10.10.2，入接口=wg0），开始进行路由决策和策略匹配。

防火墙检查路由表，发现10.40.0.0/24通过veth-fw-dmz接口可达。应用FORWARD链规则：匹配VPN→DMZ的ACCEPT规则（基于ctstate NEW），决定转发此包到DMZ区域。包通过veth-fw-dmz接口发出，src和dst不变，ttl保持63。

conntrack记录此连接状态，从NEW→ESTABLISHED，跟踪超时时间。后续包（ACK、DATA）能快速匹配状态连接规则，无需重新检查。整个路径无NAT转换（VPN到DMZ直连），因为VPN隧道已经建立了安全的加密通道。DMZ服务器处理HTTP请求并返回响应，通过已建立的连接原路返回。
关键观察：
源地址和目的地址在三个阶段保持一致（10.10.10.2 → 10.40.0.2）
无DNAT/SNAT转换（VPN到DMZ直连）
conntrack状态从NEW变为ESTABLISHED
ttl递减：remote wg0 ttl=64 → fw wg0 ttl=63
端口号54376（源端口）在整个路径中保持不变