# 企业级网络安全架构实验故障排查报告
## 一、报告概述
### 1.1 实验背景
本次基于Linux Network Namespace、iptables、WireGuard搭建多安全域企业网络，划分办公网、访客网、DMZ、外网、VPN隧道五大区域，实现四层访问控制、DNAT外网发布、远程VPN接入、安全日志审计功能。实验过程中出现DNAT访问失败、VPN连通异常、TCP双向通信中断、访客外网不通四类典型网络故障，本报告记录故障现象、完整排查流程、根因分析、修复方案与优化建议。

### 1.2 环境基础信息
| 项目 | 版本信息 |
| ---- | ---- |
| 系统 | Ubuntu 22.04.3 LTS |
| 防火墙 | iptables 1.8.7(nf_tables) |
| VPN | WireGuard 1.0.20200513 |
| 网络隔离 | Linux Network Namespace |
| 连接跟踪 | conntrack |
| 抓包工具 | tcpdump |

### 1.3 报告目的
1. 完整复现实验故障，标准化网络排障流程；
2. 区分NAT、转发规则、状态检测、路由、VPN权限等不同故障根因；
3. 总结通用排查思路，形成可复用的企业边界网关故障处理规范；
4. 针对每类故障给出事前预防配置优化方案。

## 二、故障清单总览
| 故障编号 | 故障名称 | 故障等级 | 影响范围 | 是否解决 |
| ---- | ---- | ---- | ---- | ---- |
| Fault-01 | DNAT配置完成，外网无法访问DMZ 8080 | 高 | 外网对外业务不可用 | ✅ 已修复 |
| Fault-02 | WireGuard隧道握手正常，VPN无法访问内网 | 高 | 远程员工无法接入办公/DMZ | ✅ 已修复 |
| Fault-03 | 删除ESTABLISHED规则后所有TCP跨域访问失败 | 高 | 全网跨区域双向通信中断 | ✅ 已修复 |
| Fault-04 | 访客网可通网关，但无法访问外网互联网 | 高 | 访客区域无外网权限 | ✅ 已修复 |
| Fault-05 | 日志洪水，大量重复拒绝日志占用磁盘IO | 中 | 系统负载升高，日志无法留存关键攻击记录 | ✅ 已优化 |

## 三、分故障详细排查记录
### Fault-01：DNAT规则存在，外网无法访问DMZ 8080
#### 3.1 故障现象
1. iptables nat表PREROUTING存在完整DNAT映射，将203.0.113.1:8080转发至10.40.0.2:8080；
2. 外网namespace执行curl访问公网8080端口连接超时；
3. DMZ内Web服务正常监听8080，本地访问无异常。

#### 3.2 分步排查流程
1. **检查NAT规则**
```bash
sudo ip netns exec fw iptables -t nat -L PREROUTING -n -v
```
结果：DNAT映射规则完整存在，无配置缺失。

2. **检查FORWARD转发放行规则**
```bash
sudo ip netns exec fw iptables -L FORWARD -n -v | grep 8080
```
结果：缺少DNAT转换后目标10.40.0.2的FORWARD放行规则。

3. **入口抓包验证流量到达**
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-inet port 8080
```
结果：外网SYN请求可正常到达防火墙外网接口。

4. **出口抓包验证转发**
```bash
sudo ip netns exec fw tcpdump -ni veth-fw-dmz port 8080
```
结果：无数据包转发至DMZ接口。

5. **连接跟踪表校验**
```bash
sudo ip netns exec fw conntrack -L | grep 8080
```
结果：无新建连接跟踪记录。

#### 3.3 根因分析
DNAT仅修改数据包目的IP，属于**NAT表处理逻辑**；跨网段转发依赖FORWARD链放行策略。数据包完成DNAT转换后，匹配FORWARD链无对应ACCEPT规则，被默认DROP策略静默丢弃。两条规则缺一不可：NAT做地址转换，FORWARD允许跨域通行。

#### 3.4 修复命令
```bash
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 \
-p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

#### 3.5 预防优化方案
1. 编写nat与forward绑定的自动化脚本，配置DNAT时自动生成对应放行规则；
2. 上线前分层测试：先内网访问DMZ，再外网DNAT访问，分层定位故障；
3. 配置规则计数器监控，定期校验业务端口规则是否存在。

### Fault-02：WireGuard握手成功，VPN无法访问内网
#### 3.1 故障现象
1. `wg show` 显示隧道握手正常，存在收发流量；
2. VPN客户端可ping通网关隧道地址10.10.10.1；
3. 无法连通办公网10.20.0.0/24与DMZ 10.40.0.0/24。

#### 3.2 分步排查流程
1. **检查客户端路由表**
```bash
sudo ip netns exec remote ip route get 10.20.0.2
```
结果：10.20.0.0/24网段路由指向wg0隧道，路由无异常。

2. **防火墙内核转发开关**
```bash
sudo ip netns exec fw sysctl net.ipv4.ip_forward
```
结果：ip_forward=1，转发已开启。

3. **核查VPN专用FORWARD放行规则**
```bash
sudo ip netns exec fw iptables -L FORWARD -n | grep wg0
```
结果：不存在wg0→办公网、wg0→DMZ的放行规则。

#### 3.3 根因分析
WireGuard仅完成加密隧道封装，不具备访问控制能力。隧道连通仅代表底层加密链路正常，所有VPN访问内网的跨网段流量仍受iptables FORWARD链管控，缺少对应放行规则直接阻断流量。

#### 3.4 修复命令
```bash
# VPN访问办公网放行
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-office \
-s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
# VPN访问DMZ 8080放行
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz \
-s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

#### 3.5 预防优化方案
1. VPN配置脚本配套生成专属防火墙访问规则；
2. 分两步验证VPN：先测隧道连通性，再测内网业务访问；
3. 为VPN流量单独添加日志前缀，便于快速定位VPN访问故障。

### Fault-03：删除ESTABLISHED,RELATED规则后TCP通信全断
#### 3.1 故障现象
1. 新建连接SYN包可正常放行；
2. 服务端回复SYN-ACK报文被防火墙丢弃；
3. TCP三次握手无法完成，所有跨域TCP业务访问超时。

#### 3.2 分步排查流程
1. 抓包观察双向流量：客户端SYN到达DMZ，DMZ返回SYN-ACK无回程；
2. 核查FORWARD链头部状态检测规则，发现已删除ESTABLISHED/RELATED放行策略；
3. conntrack无完整TCP会话记录，无法识别回程响应流量。

#### 3.3 根因分析
iptables为状态防火墙，仅对NEW新建连接配置放行规则；服务端返回的响应包属于ESTABLISHED关联流量，无统一放行规则时会被默认DROP。该规则是所有跨网段TCP通信基础，必须置于FORWARD链第一条。

#### 3.4 修复命令
```bash
sudo ip netns exec fw iptables -I FORWARD 1 \
-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

#### 3.5 预防优化方案
1. 脚本固化状态检测规则，禁止手动删除；
2. 所有防火墙规则脚本第一行强制加载连接跟踪放行；
3. 故障排查优先检查状态检测规则是否存在。

### Fault-04：访客网网关可达，无法访问外网
#### 4.1 故障现象
1. guest可ping通网关10.30.0.1；
2. 访问外网203.0.113.10超时；
3. 办公网访问外网完全正常，SNAT MASQUERADE规则存在。

#### 4.2 分步排查流程
1. SNAT NAT表规则完整，外网地址转换逻辑正常；
2. 访客网默认路由指向网关，ip_forward全局开启；
3. FORWARD链缺少guest→外网接口veth-fw-inet放行规则。

#### 4.3 根因分析
SNAT仅负责内网访问外网时源IP地址转换，无法控制数据包是否允许跨网段转发。访客网向外网的流量无FORWARD放行策略，被默认拒绝，地址转换与流量转发为两套独立机制，必须同时配置。

#### 4.4 修复命令
```bash
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet \
-s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
```

### Fault-05：大量重复拒绝日志引发日志洪水
#### 5.1 故障现象
1. 内核日志每秒产生数十条违规访问记录；
2. 服务器磁盘IO升高，系统卡顿；
3. 大量扫描日志覆盖少量真实攻击事件，审计效率下降。

#### 5.2 根因分析
LOG规则未配置速率限制，访客、外网持续扫描会无限生成日志，造成日志DoS，挤占系统存储与IO资源。

#### 5.3 修复优化
1. 为所有拒绝类LOG添加限流参数：
```bash
iptables -I FORWARD -i veth-fw-guest -o veth-fw-office \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "GUEST-TO-OFFICE: "
```
2. 临时封禁高频扫描源IP，阻断持续探测行为。

## 四、通用故障排查标准化流程
### 4.1 四层网络故障排查顺序
1. **底层连通性**：ping网关、检查接口UP、IP地址配置、默认路由；
2. **内核转发开关**：确认`net.ipv4.ip_forward=1`；
3. **路由可达性**：`ip route get`校验目标网段路由出口；
4. **防火墙转发规则**：FORWARD链是否放行NEW新建流量；
5. **NAT规则校验**：DNAT/ MASQUERADE是否存在、匹配接口网段；
6. **连接跟踪**：conntrack查看会话是否建立；
7. **分接口抓包**：入口、出口双向抓包定位丢包位置；
8. **日志审计**：查看内核LOG前缀，定位拦截规则。

### 4.2 VPN专属故障排查顺序
1. WireGuard握手状态 `wg show`；
2. 客户端AllowedIPs网段配置；
3. 两端路由表隧道分流规则；
4. 防火墙wg0接口专属FORWARD放行规则；
5. 对端内网回程路由是否配置。

## 五、故障总结与运维优化建议
### 5.1 故障共性总结
1. 90%跨网段访问故障均为**FORWARD放行规则缺失**，NAT、VPN、跨域访问均依赖转发策略；
2. ESTABLISHED状态检测规则是TCP通信基础，删除后全网双向流量失效；
3. 地址转换(NAT)与流量转发(FORWARD)相互独立，不可混淆；
4. VPN隧道仅提供加密通道，访问权限完全由iptables控制；
5. 日志不加限流会引发系统资源耗尽，属于安全运维隐性故障。

### 5.2 长期运维优化措施
1. **脚本标准化**
所有网络、防火墙、VPN配置统一使用shell脚本部署，删除手动操作，配置项一一绑定（DNAT自动生成转发规则、VPN自动生成访问规则）。
2. **分层测试机制**
网络搭建完成后按顺序测试：内网互通→区域跨域访问→外网DNAT→VPN远程接入，分层定位故障。
3. **日志标准化规范**
所有拒绝规则统一配置limit限流，区分不同攻击日志前缀，便于过滤、告警、统计。
4. **规则巡检机制**
定期查看iptables规则计数器，监控高频拦截IP与访问行为，提前发现扫描攻击。
5. **生产环境安全调整**
实验环境使用REJECT便于调试；正式外网边界替换为DROP，减少内网资产信息泄露风险。

### 5.3 实验收获
本次故障覆盖企业边界网关全部典型问题，建立四层防火墙+VPN网络完整排障思维：网络连通分为**底层链路、路由转发、防火墙访问控制、地址转换、加密隧道**五层，出现访问异常时逐层剥离排查，可快速定位根因，适用于企业真实Linux网关运维场景。