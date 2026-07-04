## 一、攻防演练实验环境概述
本次攻防实验基于 Linux network namespace 虚拟企业网络，划分办公区 office、访客区 guest、DMZ 服务区、外网 internet、远程 VPN 客户端 remote 五大隔离区域，防火墙 fw 通过 iptables 实现区域访问控制、SNAT/DNAT 地址转换，WireGuard 提供加密远程接入。
攻击发起节点统一为访客区 guest 主机，模拟企业外来未信任设备横向渗透行为；防御手段依托防火墙状态检测、访问白名单、连接限流、内核日志审计完成。
## 二、攻击场景复现与结果分析
2.1 攻击 1：访客主机 ICMP 网段扫描办公网段
攻击操作命令
```bash
sudo ip netns exec guest bash -c 'for i in {1..10};do ping -c1 -W1 10.20.0.$i 2>/dev/null && echo "存活主机：10.20.0.$i";done'
```
实验现象
所有 ping 请求全部超时，无任何存活主机输出，内核持续打印GUEST-TO-OFFICE审计日志。
攻击失效根本原因
防火墙 FORWARD 链配置完整 guest 至办公区阻断规则，所有入接口 veth-fw-guest、出接口 veth-fw-office 流量直接 REJECT 并记录日志。ICMP 请求无法抵达办公主机，同时无 ICMP 应答报文返回，攻击者无法收集内网网段拓扑、在线资产信息，横向侦察攻击完全失效。
防御有效性总结
逻辑区域隔离策略可从网络底层阻断未信任区域对内网资产扫描，防止内网信息泄露。

2.2 攻击 2：修改 TCP 源端口尝试绕过 DMZ 22 端口限制
攻击操作命令
```bash
#使用本地80端口访问DMZ 22
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22
#使用本地443端口访问DMZ 22
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22
```
实验现象
两次访问均连接超时，日志输出GUEST-TO-DMZ违规访问记录。
攻击失效根本原因
防火墙访问控制规则匹配目标端口，与客户端随机源端口无关。无论攻击者更换任意本地发起端口，目标端口 22 匹配阻断规则，数据包直接丢弃。仅通过修改源端口无法绕过基于目的端口的最小权限访问控制策略。
防御有效性总结
基于五元组目的端口的精准访问控制不存在该类绕过漏洞，端口限制策略稳定可靠。

2.3 攻击 3：伪造 VPN 网段源 IP 尝试渗透内网
攻击思路
攻击者在 guest 主机构造源地址为 VPN 网段 10.10.10.2 的数据包，试图欺骗防火墙放行流量，访问办公区、DMZ 业务。
实验现象
伪造数据包全部被防火墙静默丢弃，无任何访问响应，无 VPN 相关日志生成。
攻击失效多层防护机制
WireGuard 隧道报文携带公私钥签名，普通 namespace 无法生成合法加密报文，伪造裸 IP 包无隧道封装；
Linux 内核 rp_filter 反向路由校验：数据包源 IP 对应合法入接口为 wg0，当前入接口为 veth-fw-guest，路由校验失败直接丢弃；
防火墙仅对 wg0 入站流量开放内网访问权限，其他接口无 VPN 放行规则。
三层防护叠加，地址伪造攻击完全无法突破边界。

## 三、防御体系能力分析
3.1 日志溯源分析能力
内核 iptables 日志携带IN入接口、OUT出接口、SRC源 IP、DST目的 IP、DPT目标端口关键字段：
日志IN=veth-fw-guest OUT=veth-office可快速判定访客对内网横向扫描行为；
差异化 log-prefix（GUEST-TO-OFFICE/VPN-DENY 等）可自动区分攻击类型，无需人工过滤大量原始日志；
limit 日志限流机制防止高频扫描产生日志洪水，避免磁盘占满、运维告警淹没。

3.2 防火墙规则计数器分析
执行sudo ip netns exec fw iptables -L FORWARD -n -v可查看每条规则命中次数：
若 guest 阻断规则计数持续上涨，代表访客区存在持续扫描、探测行为；
VPN 拒绝规则计数升高，说明远程员工存在越权访问操作，需核查人员权限；
DNAT 外网 Web 放行规则计数可统计网站外部访问量，辅助业务运维。

3.3 REJECT 与 DROP 防御策略优劣对比
| 策略 | 响应行为 | 安全风险 | 适用场景 |
| :--- | :------- | :------- | :------- |
| REJECT | 返回 TCP RST/ICMP 不可达 | 攻击者可判断 IP、端口真实存在，泄露内网拓扑 | 内网办公、调试环境 |
| DROP | 静默丢弃无任何回复 | 攻击者无法区分主机离线/防火墙拦截，隐蔽性强 | DMZ、外网入站边界 |

本实验外网访问 DMZ 22 采用 DROP 策略，进一步降低外网探测带来的内网信息泄露风险。
## 四、现有边界安全漏洞与加固方案
4.1 现存安全风险
DMZ 对外开放 8080 Web 服务，未限制单 IP 最大并发 TCP 连接，易遭受 CC 攻击、SYN 洪水，耗尽服务器 CPU、连接资源，引发业务中断。
4.2 加固 iptables 规则实现
```bash
# 超限连接日志记录，标记CC攻击
sudo ip netns exec fw iptables -I FORWARD -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j LOG --log-prefix "DMZ-CC-LIMIT: "
# 超过10个并发直接拒绝连接
sudo ip netns exec fw iptables -A FORWARD -p tcp --syn --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset
```
## 五、VPN 全链路数据包追踪分析（加分项）
抓包观测点位
remote wg0：客户端明文内网数据包，外层 WireGuard 加密封装；
fw wg0：防火墙解密后原始内网报文，源 IP 为 10.10.10.2；
fw veth-fw-dmz：转发至 DMZ 服务器，源 IP 保持 VPN 客户端地址不变；
conntrack 连接跟踪表：存储完整五元组，自动放行会话回程流量。
链路总结
WireGuard 仅负责传输层加密，访问权限完全由防火墙独立管控，加密与访问控制分层解耦，不会出现隧道全开放导致的内网暴露风险。
## 六、整体攻防总结
本套企业边界防御架构基于区域隔离 + 最小权限 + 日志审计核心思想，可有效抵御网段扫描、端口绕过、IP 伪造等网络层基础攻击。现有短板集中在 Web 服务无并发限流、VPN 无暴力破解防护，可通过 connlimit 连接限制、recent 模块防爆破完善纵深防御。
网络层防火墙仅能抵御底层攻击，若需防护 SQL 注入、XSS 等 Web 应用攻击，需叠加 WAF、入侵检测系统形成完整安全防护体系。