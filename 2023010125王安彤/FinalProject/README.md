# 企业级网络安全架构搭建与攻防演练

## 一、实验环境
- 操作系统：kali、Ubuntu 22.04 LTS
- WireGuard版本：v1.0.20210914
- iptables版本：v1.8.7

## 二、拓扑图和地址规划
（手绘或工具绘制的拓扑图）
┌───────────── remote 远程员工 ─────────┐
│  wg0:10.10.10.2/24                    │
└───────────────────┬───────────────────┘
                    │ WireGuard隧道
                    ▼
┌────────────────────────────────────────────────────── fw 防火墙（多网关） ─────────────────────────────────────────────────┐
│ wg0:10.10.10.1/24  │ veth-fw-office:10.20.0.1/24 │ veth-fw-guest:10.30.0.1/24 │ veth-fw-dmz:10.40.0.1/24 │ veth-fw-inet:203.0.113.1/24 │
└────────┬──────────┴───────────┬────────────────┴──────────────┬────────────┴──────────────┬────────────┴───────────────┘
         │                      │                               │                           │
         ▼                      ▼                               ▼                           ▼
┌─────office办公区────┐  ┌────guest访客区────┐       ┌────dmz服务区────┐        ┌────internet模拟外网────┐
│veth-office:10.20.0.2│  │veth-guest:10.30.0.2│       │veth-dmz:10.40.0.2│        │veth-inet:203.0.113.10 │
│内网员工主机         │  │访客隔离设备        │       │Web(8080)+SSH(22) │        │外网用户客户端          │
└─────────────────────┘  └───────────────────┘       └─────────────────┘        └───────────────────────┘

（地址规划表）
| 归属命名空间     | 网卡设备名     | 所属网段       | IP地址/掩码     | 默认网关       | 功能说明               |
| :--------------- | :------------- | :------------- | :-------------- | :------------- | :--------------------- |
| fw(防火墙)       | veth-fw-office | 10.20.0.0/24   | 10.20.0.1/24    | -              | 对接办公区网关接口     |
| fw(防火墙)       | veth-fw-guest  | 10.30.0.0/24   | 10.30.0.1/24    | -              | 对接访客区网关接口     |
| fw(防火墙)       | veth-fw-dmz    | 10.40.0.0/24   | 10.40.0.1/24    | -              | 对接DMZ服务器区网关    |
| fw(防火墙)       | veth-fw-inet   | 203.0.113.0/24 | 203.0.113.1/24  | -              | 模拟外网出口公网接口   |
| office           | veth-office    | 10.20.0.0/24   | 10.20.0.2/24    | 10.20.0.1      | 企业办公主机           |
| guest            | veth-guest     | 10.30.0.0/24   | 10.30.0.2/24    | 10.30.0.1      | 访客隔离主机           |
| dmz              | veth-dmz       | 10.40.0.0/24   | 10.40.0.2/24    | 10.40.0.1      | 对外Web服务器          |
| internet         | veth-inet      | 203.0.113.0/24 | 203.0.113.10/24 | 203.0.113.1    | 模拟外网客户端         |
| fw(VPN服务端)    | wg0            | 10.10.10.0/24  | 10.10.10.1/24   | -              | WireGuard隧道服务端    |
| remote(VPN客户端)| wg0            | 10.10.10.0/24  | 10.10.10.2/24   | 10.10.10.1     | 远程员工VPN客户端      |

## 三、第一部分：网络规划与基础搭建
（包含setup.sh的说明和连通性测试结果）
1. setup.sh 脚本说明
setup.sh为一键拓扑初始化脚本，完整实现如下功能：
批量创建 6 个网络命名空间：fw、office、guest、dmz、internet、remote；
生成 5 组 veth 虚拟网卡对，分别连接防火墙与各业务网段；
为所有网卡配置静态 IP 地址并启用网卡、本地回环 lo；
为 office/guest/dmz/internet 配置指向 fw 的默认路由；
在 fw 命名空间开启内核 IPv4 数据包转发功能；
输出各节点连通性验证命令，方便一键测试网络基础互通。
脚本具备可重复运行特性，执行前自动清理重复 namespace 与 veth 设备，避免网段冲突。
2. 连通性测试结果
执行基础 ping 连通测试，全部节点均可正常 ping 通防火墙对应网口：
office ping 10.20.0.1 连通；
guest ping 10.30.0.1 连通；
dmz ping 10.40.0.1 连通；
internet ping 203.0.113.1 连通；
各节点仅能直连网关，跨网段流量未放行，符合未配置防火墙前基础网络隔离状态。
3. 搭建步骤简述
执行setup.sh创建隔离网络环境；
核对各网卡 IP 与网段无冲突；
检查各主机默认路由指向防火墙；
开启防火墙 IP 转发；
使用 ping 命令验证直连网关连通性；
保存所有连通测试截图至screenshots目录。

## 四、第二部分：防火墙策略实现
（包含firewall.sh的说明和访问控制矩阵）
1. firewall.sh 脚本说明
脚本基于 iptables 实现企业最小权限访问控制，分为四大模块：
基础全局策略：FORWARD 链默认 DROP，配置状态跟踪 ESTABLISHED/RELATED 放行；
区域访问控制规则：严格区分 office、guest、dmz、internet 互通权限，所有拒绝流量添加带标识 LOG 日志；
NAT 转换规则：SNAT 实现内网访问外网、DNAT 实现外网访问 DMZ；
日志限流规则：对扫描、违规访问日志做速率限制，防止日志洪水攻击。
规则顺序遵循状态规则在前、精准放行规则次之、日志规则、拒绝规则最后，规避规则匹配失效问题。

2. 访问控制矩阵

| 来源 | 目标 | 预期结果 | 实际结果 | 截图 |
|:-----|:-----|:---------|:---------|:-----|
| office | dmz:8080 | 成功 |curl 正常返回 Web 页面，数据包放行 |04-access-success.png |
| office | dmz:22 | 失败+LOG |连接被拒绝，内核日志打印 OFFICE-TO-DMZ-SSH |05-access-deny.png |
| guest | office:任意 | 失败+LOG |ping/curl 全部阻断，日志输出 GUEST-TO-OFFICE |05-access-deny.png |
| guest | dmz:8080 | 失败+LOG |Web 访问超时拒绝，生成 GUEST-TO-DMZ 审计日志 |05-access-deny.png |
| guest | internet:任意 | 成功 |ping 203.0.113.10 连通，SNAT 转换正常 |04-access-success.png  |
| office | internet:任意 | 成功 |外网互通，内网地址正常做源地址转换 |04-access-success.png  |
| internet | fw公网IP:8080 | 成功(DNAT到dmz) |外网访问防火墙 8080，自动跳转 dmz 服务器页面 |04-access-success.png  |
| internet | dmz:22 | 失败 |外网发起 22 端口连接直接被 REJECT 拦截，生成 INET-TO-DMZ-SSH 日志 |05-access-deny.png |
3. NAT 配置说明
SNAT (MASQUERADE)：办公、访客、DMZ 网段访问外网时自动转换为防火墙公网 IP，隐藏内网地址；
DNAT 端口映射：外网请求防火墙 8080 端口转发至 DMZ 服务器 10.40.0.2，配套 FORWARD 双向放行规则。

## 五、第三部分：VPN远程接入
（包含WireGuard配置说明和测试结果）
1. WireGuard 配置说明
包含vpn-fw.conf服务端、vpn-remote.conf客户端两份配置：
密钥：wg genkey 生成公私钥，配置文件权限 600 防泄露；
服务端 wg0：监听 51820，仅允许 10.10.10.2 接入；
客户端 AllowedIPs 仅配置办公 10.20.0.0/24、DMZ 10.40.0.0/24，外网不走隧道；
PersistentKeepalive 保持隧道 NAT 环境持续握手。
2. VPN 防火墙访问控制规则
允许 VPN 访问全部办公网段；
允许 VPN 访问 DMZ 8080 Web 服务；
拒绝 VPN 访问 DMZ 22 端口并记录日志；
所有未匹配 VPN 流量统一拒绝并标记VPN-DENY。
3. VPN 测试结果
wg show：两端握手成功，收发数据包计数正常；
合法访问：remote 可正常访问 office、dmz:8080；
违规访问：dmz:22、guest 网段全部拦截并生成审计日志；
remote 路由仅内网网段指向 wg 隧道，外网走本地网络。
4. AllowedIP 设计思路
不配置 0.0.0.0/0 全流量隧道，仅业务内网加密传输，减轻网关负载，缩小攻击面，避免隧道滥用访问恶意外网资源。

## 六、第四部分：安全审计与日志分析
（包含LOG规则说明和日志分析报告）
1.LOG 规则配置
所有 REJECT 规则前均配置 LOG 规则，使用不同前缀，并对高频违规（如 guest 扫描）加入速率限制（limit 5/min burst 10），防止日志洪泛。
| 违规访问事件 | 日志前缀标识 | 限流策略 |
| :----------- | :----------- | :------- |
| guest 访问办公区 | `GUEST-TO-OFFICE:` | `limit 5/min burst 10` |
| guest 访问 DMZ | `GUEST-TO-DMZ:` | `limit 5/min burst 10` |
| VPN 尝试 SSH DMZ | `VPN-TO-DMZ-SSH:` | 无限流 |
| 外网访问内网办公区 | `INET-TO-OFFICE:` | `limit 5/min burst 10` |
| VPN 未授权流量 | `VPN-DENY:` | `limit 5/min burst 10` |

触发违规场景
执行 5 种违规访问命令（截图 09-logs-realtime.png）：
guest curl 10.20.0.2:8000      → 失败，日志 GUEST-TO-OFFICE
guest curl 10.40.0.2:8080      → 失败，日志 GUEST-TO-DMZ
remote curl 10.40.0.2:22       → 失败，日志 VPN-TO-DMZ-SSH
internet curl 10.20.0.2:8000   → 超时，日志 INET-TO-OFFICE
internet curl 203.0.113.1:3306 → 拒绝，日志 VPN-DENY（实际应归为INET→未开放端口，但规则未单独覆盖，统一由默认DROP处理）

2.日志统计
使用 journalctl -k --grep 统计各类事件计数（截图 10-logs-stats.png）
| 事件类型 | 触发次数 | 实际记录日志数 | 是否生效 |
| :------- | :------- | :------------- | :------- |
| guest→office | 1 | 1 | 是 |
| guest→dmz | 1 | 1 | 是 |
| VPN→dmz:22 | 1 | 1 | 是 |
| internet→office | 1 | 1 | 是 |
| VPN其他违规 | 1 | 1 | 是 |

日志分析报告
防火墙内核日志是内网安全审计核心数据源，五元组信息可完整还原攻击链路。LOG 规则必须放置 REJECT/DROP 之前，否则无法记录数据包。日志限流机制限制高频扫描产生海量日志，防止磁盘占满。差异化日志前缀便于运维快速分类告警，提升威胁排查效率。

## 七、第五部分：攻防演练
（包含攻击演练、防御分析、边界测试）
1. 攻击方任务（从 guest 发起）
攻击1：Ping 扫描 office 网段
命令：for i in {1..10}; do ping -c 1 10.20.0.$i; done
结果：所有包均被 REJECT，返回 ICMP 端口不可达，无法获取任何存活信息。
原因：防火墙明确拒绝 guest→office 所有流量，扫描完全失效。
攻击2：改变源端口尝试绕过 dmz:22
命令：curl --local-port 80 http://10.40.0.2:22/ 和 --local-port 443
结果：连接被拒绝（截图 12-attack-bypass.png）。
原因：iptables 规则基于五元组中的目标端口（22），源端口变化不影响匹配，规则依然生效。
攻击3：伪造 VPN 源地址 10.10.10.2
尝试从 guest 伪造源 IP 为 10.10.10.2 访问内网。
结果：失败，WireGuard 加密认证机制确保伪造包无法通过，且反向路径过滤（rp_filter）会丢弃非对称路由包。
结论：VPN 安全性强，无法伪造。
REJECT vs DROP 分析：攻击者可通过 REJECT 返回的 ICMP 错误判断目标存在；而 DROP 静默丢弃，无法区分目标不存在或被防火墙拦截，因此对外部接口应优先使用 DROP。

2. 防御方任务（日志分析与规则分析）
日志识别攻击：
字段 IN=veth-fw-guest 明确指示流量来自 guest 区域。
若 IN=veth-fw-guest OUT=veth-fw-office，说明攻击者试图从访客区横向渗透至办公区。
大量相同来源日志表明可能正遭受扫描或暴力破解，需及时封堵源 IP。
规则计数器分析（截图 14-defense-counters.png）：
拦截 guest→office 的规则是第 6/7 行（LOG+REJECT），计数器显示 pkts=11，说明已拦截多次尝试。
高计数表明 guest 网段存在持续违规行为，需进一步溯源并考虑临时黑名单。
安全性差异：REJECT 暴露防火墙存在，DROP 隐藏性更好，生产环境对外部流量通常使用 DROP。

3. 边界测试与改进方案
选择问题：DMZ Web 服务（8080）对外开放，可能遭受 DDoS/CC 攻击。
风险分析：
攻击者可发起大量并发连接耗尽 Web 服务器资源。
暴力破解或目录扫描可能利用 Web 漏洞。
资源滥用影响合法用户体验。
改进方案：使用 connlimit 模块限制单个源 IP 对 DMZ Web 服务的最大并发连接数（如 10 个）。
实现代码：
```bash
#记录超限连接
sudo ip netns exec fw iptables -I FORWARD 1 \
  -p tcp --syn --dport 8080 -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j LOG --log-prefix "DMZ-CC-LIMIT: "
#拒绝超限连接
sudo ip netns exec fw iptables -I FORWARD 2 \
  -p tcp --syn --dport 8080 -d 10.40.0.2 \
  -m connlimit --connlimit-above 10 --connlimit-mask 32 \
  -j REJECT --reject-with tcp-reset 
```

5.4 高级任务：追踪包的完整变化过程
**填写包变化对比表：**
 | 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
| :--- | :------- | :----- | :------- | :--- | :--- |
| 1    | remote wg0 | 10.10.10.2 | 10.40.0.2 | TCP | WireGuard 封装前，原始内网明文数据包，目标端口 8080 |
| 2    | fw wg0 | 10.10.10.2 | 10.40.0.2 | TCP | WireGuard 解密后裸内网 IP 报文，无地址转换 |
| 3    | fw veth-fw-dmz | 10.10.10.2 | 10.40.0.2 | TCP | 防火墙转发至 DMZ 网段，源 IP 保持 VPN 客户端地址不变 |
| 4    | conntrack | 10.10.10.2 | 10.40.0.2 | TCP | 完整五元组会话记录，自动放行该连接回程响应流量 |

## 八、故障排查
（包含至少3个故障场景的排查过程）
场景1：DNAT配置了但外网无法访问
现象：internet 访问 203.0.113.1:8080 无响应。
排查：
iptables -t nat -L PREROUTING 显示 DNAT 规则存在。
dmz 服务正常运行。
检查 FORWARD 规则，发现缺少从 veth-fw-inet 到 veth-fw-dmz 的 ACCEPT 规则（或顺序错误）。
解决：添加 FORWARD 放行规则，并确保状态检测规则在前。
验证：再次 curl 成功返回页面。

场景2：VPN隧道握手正常但业务访问失败（模拟关闭IP转发）
现象：wg show 显示握手成功，但 remote ping 10.40.0.2 超时。
排查步骤（截图 20-troubleshoot-vpn.png）：
在 fw 上抓包：wg0 收到包，但 veth-fw-dmz 无包发出。
检查 net.ipv4.ip_forward，发现值为 0（临时关闭）。
查看 conntrack 表，无相关记录。
根本原因：IP 转发未开启。
修复：sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1。
验证：再次 ping 和 curl 成功。

场景3：去掉 ESTABLISHED,RELATED 状态检测导致 TCP 连接失败
现象：office 访问 dmz:8080 三次握手完成，但数据传输超时。
排查：在 fw 抓包，观察到 SYN 包通过，SYN-ACK 回包被 DROP（因为无状态跟踪，防火墙认为回包是无效的 NEW 连接）。
原因：缺少 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 规则。
修复：在 FORWARD 链第一条添加该规则。
必要性：状态检测保证回程流量被放行，同时避免为每个方向手动添加规则，简化配置且提高安全性。

## 九、遇到的问题和解决方法
（实验过程中的实际问题和解决思路）
1.重复执行脚本造成 IP 网段冲突
问题：多次运行 setup.sh，残留 namespace 与 veth 网卡造成地址重叠。
解决：脚本开头增加批量清理命令，每次运行重置完整网络环境。
2.WireGuard 握手成功无数据传输
问题：客户端 AllowedIPs 配置 0.0.0.0/0，路由冲突流量无法转发。
解决：仅配置业务内网网段走加密隧道。
3.iptables 日志无输出
问题：LOG 规则写在 REJECT 规则后方，数据包丢弃前未记录。
解决：调整规则顺序，日志规则前置。
4.SNAT 内网无法访问外网
问题：MASQUERADE 网段书写错误，内网流量未做地址转换。
解决：为 office、guest、dmz 分别配置独立 POSTROUTING 转换规则。
5.日志缺少五元组信息
问题：未读取内核原始日志。
解决：使用journalctl -k抓取完整内核网络日志。

## 十、总结与思考
（至少500字，包含对企业网络安全架构的整体理解）
本次实验依托 Linux 网络命名空间搭建模拟企业安全边界，完整覆盖网络分区、防火墙访问控制、NAT 地址转换、WireGuard 远程 VPN、安全审计、攻防验证、故障排障整套工程流程，还原中小企业真实网络安全建设场景。
整套架构核心安全思路为分层隔离、最小权限、全程审计。通过划分办公、访客、DMZ 三大逻辑区域，从网络层阻断横向渗透；防火墙默认拒绝所有跨网段流量，仅开放业务刚需端口，大幅缩小攻击面；所有越权访问自动生成带标记审计日志，为安全事件溯源提供完整证据。
WireGuard 轻量化 VPN 平衡远程办公便捷性与内网数据安全，隧道加密、细粒度路由、防火墙三层权限管控多层防护；SNAT 隐藏内网资产，DNAT 满足外部用户访问公开业务需求。攻防演练验证隔离策略可拦截网段扫描、端口绕过、IP 伪造等基础攻击，同时识别出 DMZ 无并发限流等短板，并通过 connlimit 模块完成加固优化。
故障排查过程加深了 TCP 连接跟踪、路由转发、NAT 底层原理理解，掌握抓包、连接跟踪、日志分析等实用运维工具。本方案仅实现网络层基础防御，无法抵御 Web 漏洞、恶意代码等应用层攻击，后续可叠加 WAF、入侵检测、终端安全构建纵深防御体系。分层隔离、权限管控、日志审计仍是企业网络安全不可缺少的底层基础架构，具备很强工程实践价值。