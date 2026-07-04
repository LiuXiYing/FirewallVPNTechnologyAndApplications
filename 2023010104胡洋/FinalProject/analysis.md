# 攻防演练分析报告

## 一、攻击方任务分析

### 1. guest扫描office网段

攻击命令：

```bash
for i in {1..10}; do
  sudo ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null && echo "10.20.0.$i is up"
done
```
• 攻击目标：访客网段 guest 主机批量 ICMP 探测办公网段 10.20.0.0/24 存活主机，实现内网资产测绘。
• 安全策略与拦截原理：guest 属于低信任安全域，office 为高可信内网办公域，防火墙配置专属隔离规则，匹配入接口veth-fw-guest、出接口veth-fw-office、源网段10.30.0.0/24、目的网段10.20.0.0/24；数据包先匹配 LOG 规则生成GUEST-TO-OFFICE审计日志，再执行 REJECT 拒绝转发。
• 攻击结果：仅 guest 本地同命名空间主机可连通，所有跨网段探测全部失败，无法扫描获取办公网存活资产。


### 2. guest尝试绕过防火墙访问dmz:22

攻击命令：

```bash
sudo ip netns exec guest curl --local-port 80 --max-time 2 http://10.40.0.2:22/
sudo ip netns exec guest curl --local-port 443 --max-time 2 http://10.40.0.2:22/
```
• 攻击思路：攻击者修改客户端本地源端口为 80、443 等常见 Web 端口，企图伪装普通网页流量绕过访客访问 DMZ 的拦截策略。
• 拦截原理：防火墙GUEST-TO-DMZ拦截规则匹配核心条件为入接口 veth-fw-guest、出接口 veth-fw-dmz、目标端口 22，不校验客户端源端口，只要流量来自访客域、目标为 DMZ 22 端口，直接拦截并生成审计日志。
• 攻击结果：更换任意本地源端口均无法绕过访问控制，访问全部超时失败；证明安全域隔离应基于进出接口、目标服务管控，而非单纯依赖源端口识别流量。


### 3. guest尝试伪造VPN流量

攻击思路：攻击者在 guest 主机伪造 VPN 合法客户端源 IP10.10.10.2，试图匹配 VPN 放行规则访问 DMZ 业务。
双重拦截原因：
1. 防火墙 VPN 放行规则强制限定入接口为wg0，伪造数据包从访客网卡veth-fw-guest流入，无法匹配 VPN 专属转发规则，直接触发GUEST-TO-DMZ拦截；
2. TCP 通信依赖双向会话，即便伪造请求包抵达 DMZ 服务器，服务器回包会依据路由转发至 wg0 隧道，无法返回 guest 命名空间，TCP 三次握手无法完成；
3. WireGuard 隧道依靠密钥认证对等端，仅 remote 主机能建立合法 wg0 加密流量，三层 IP 伪造无法绕过二层接口 + 应用层密钥双重校验。

攻击结论：单纯伪造三层源 IP 无法突破基于安全接口、加密隧道的访问控制策略。

### 4. REJECT和DROP表现差异

1. REJECT：丢弃数据包同时返回 ICMP 端口不可达响应，攻击者可快速判定目标 IP 真实存活，泄露内网网段、开放端口等资产信息；优势是连通性反馈直观，适用于内网教学、故障调试场景。
1. DROP：静默丢弃数据包，无任何回程响应，访问表现为超时，攻击者无法区分主机离线、链路故障、防火墙拦截，大幅增加内网探测难度。
生产环境建议：公网、非可信访客边界优先使用 DROP，减少内网拓扑泄露；内网实验调试场景使用 REJECT，方便故障定位，实验选用 REJECT 用于直观观测拦截效果、留存日志截图。

## 二、防御方任务分析

### 1. 如何从日志识别guest攻击

核心判定字段：
1. IN=veth-fw-guest：流量入接口为访客网卡，直接判定来源为 guest 安全域；
2. SRC=10.30.0.2：源 IP 属于访客网段，辅助佐证；
3. 自定义日志前缀GUEST-TO-OFFICE/GUEST-TO-DMZ：专属审计标签，精准区分访客越权访问行为；
补充说明：三层源 IP 可通过 hping3 工具伪造，不可单独作为溯源依据，必须结合二层入接口字段综合判断攻击来源。

### 2. 日志IN=veth-fw-guest OUT=veth-fw-office的含义

该字段组合代表数据包从低信任访客域进入防火墙，尝试转发至高可信办公内网，属于跨安全域违规访问行为。按照网络分区安全规范，访客设备禁止访问办公核心资产，该日志代表防火墙成功拦截横向扫描、越权渗透类风险流量，是安全隔离策略生效的直接证据

### 3. 大量相同来源日志的风险

短周期内出现大量相同SRC、相同入接口的拦截日志，代表该主机正在执行自动化探测行为：
• 目的 IP 连续递增：ICMP 网段扫描；
• 目的端口遍历变化：TCP 端口扫描、服务探测；
• 高频访问 22、3306、3389 等管理端口：账号暴力破解。
风险处置：该现象说明 guest 主机已失陷，存在内网横向渗透隐患；需提取日志源 IP 定位终端查杀恶意程序，必要时临时封禁源 IP 阻断扫描行为；实验配置limit 5/min日志限流规则，避免海量扫描日志占满系统缓冲区。

## 三、规则计数器分析

查看规则计数器：

```bash
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
```

1. guest 访问 office 网段对应规则说明
FORWARD 链存在成对防护规则：
• LOG 审计规则：匹配访客到办公网流量，添加GUEST-TO-OFFICE日志标签留存访问记录；
• REJECT 拒绝规则：拦截违规跨域流量，终止转发。
两条规则共享同一套进出接口匹配条件，数据包先日志、后拦截；规则中pkts、bytes计数器会统计所有拦截数据包总量，本次 guest 网段扫描产生 11 条拦截报文，计数器数值同步增长。
2. 规则计数器数值持续走高的处置思路
若GUEST-TO-OFFICE对应规则数据包、字节计数器持续上涨，说明访客域存在持续性批量访问办公网行为：
• 少量零星计数：用户误操作，无重大风险；
• 短时间数值暴涨：自动化扫描、渗透攻击，需立即溯源日志源 IP，隔离风险主机并排查恶意程序。
3. REJECT 与 DROP 安全性对比
REJECT：调试友好，但向外泄露内网资产存活信息，存在信息泄露风险；
DROP：无任何响应报文，隐蔽性更强，对公网、访客边界防护更安全，缺点是故障排查难度提升；
实验场景选用 LOG+REJECT 组合，兼顾日志审计与实验现象可视化。

## 四、边界测试与改进方案

### 原始风险点
DMZ 业务服务器10.40.0.2:8080对公网 internet 开放 DNAT 映射，防火墙无并发连接限制，存在两大风险：
1. 攻击者发起 CC/DDoS 海量长连接攻击，耗尽服务器内核连接表、文件句柄，造成 Web 业务瘫痪；
2. 无连接管控可批量扫描 Web 路径、暴力破解后台账号，若 Web 存在漏洞可作为跳板横向渗透内网。
2. 加固方案：connlimit 单 IP 并发连接限制
新增两条边界防护规则，插入 FORWARD 链最前端优先匹配：
```bash
# 并发超限日志记录规则
sudo ip netns exec fw iptables -I FORWARD 1 \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m connlimit --connlimit-above 2 --connlimit-mask 32 \
  -j LOG --log-prefix "CONN-LIMIT-BLOCK: " --log-level 4

# 并发超限流量拒绝规则
sudo ip netns exec fw iptables -I FORWARD 2 \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m connlimit --connlimit-above 2 --connlimit-mask 32 \
  -j
 REJECT --reject-with tcp-reset
 ```
### 完整测试流程
1. 清理原有 VPN 侧 8080 并发限制规则，消除流量匹配冲突；
2. 加载上述 connlimit 加固规则，确认规则位于 FORWARD 链首部；
3. internet 命名空间后台并发 4 条 curl 访问模拟 CC 攻击：
```bash
for i in {1..4}; do
  sudo ip netns exec internet curl --max-time 3 http://203.0.113.1:8080/ >/dev/null 2>&1 &
done
wait
```
1. 现象：单 IP 最多建立 2 条合法连接，第 3、4 条超限连接直接被重置拒绝；
2. 日志验证：dmesg | grep CONN-LIMIT-BLOCK可查看超限拦截审计日志；
3. 计数器验证：查看 FORWARD 链，LOG、REJECT 规则 pkts 数值大于 0，加固策略生效。
4. 加固效果总结
基于 iptables connlimit 模块实现轻量级抗 CC、防批量扫描防护，无需额外部署 WAF、流量清洗设备，适合小型网络边界基础防护；无法完全抵御大流量 DDoS，生产高并发业务需搭配专业流量清洗设备。
## 五、高级任务：VPN 客户端 remote 访问 DMZ 8080 数据包全流程分析
数据包流转明细
| 阶段 | 观察位置 | 源地址 | 目的地址 | 协议 | 备注 |
|:---|:---|:---|:---|:---|:---|
| 1 | remote wg0 |10.10.10.2:49242  |10.40.0.2:8080  | TCP |封装前，内网原始明文报文，携带 HTTP GET 请求  |
| 2 | fw wg0 |10.10.10.2:49242  |10.40.0.2:8080 | TCP |解封装后，WireGuard 剥离外层加密 UDP，内层 IP 报文无修改  |
| 3 | fw veth-fw-dmz | 10.10.10.2:49242 |10.40.0.2:8080  | TCP |转发到 dmz 网段，仅更换出口虚拟网卡，四层数据完全不变  |
| 4 | conntrack |10.10.10.2:49242  |10.40.0.2:8080  | TCP |连接跟踪记录，保存双向五元组，会话状态 TIME_WAIT  |

完整流程分析
1. remote 客户端生成访问 DMZ 的 TCP 报文，原始内网 IP 报文送入 wg0 网卡，WireGuard 程序对完整 TCP 报文加密封装为 UDP 数据包，通过公网传输至防火墙 fw；
2. 数据包抵达 fw 的 wg0 隧道网卡，内核 WireGuard 模块解密、剥离外层 UDP 头部，还原出未改动的原始 TCP 报文；
3. 防火墙 netfilter 匹配 VPN 访问 DMZ 放行规则，全程不做 SNAT/DNAT 地址转换，直接将原始报文转发至 veth-fw-dmz 虚拟网卡送入 DMZ 网段；
4. 内核 conntrack 持续记录 TCP 会话完整生命周期，双向应答报文依靠状态检测规则正常回程；
整体传输仅增加 WireGuard 加密封装 / 解封装操作，四层 IP、端口、应用载荷全程不变，VPN 仅提供加密传输，不修改业务报文地址信息。

