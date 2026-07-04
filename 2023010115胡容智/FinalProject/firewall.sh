#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# 脚本名称: firewall.sh
# 脚本功能: 有状态检测防火墙策略加固、地址转换（NAT）及全链路零信任访问控制

set -euo pipefail

IPTABLES="sudo ip netns exec fw iptables"

echo "[*] 正在初始化 Netfilter 策略链，清空既有规则..."
# 1. 默认规则清空与计数器重置
$IPTABLES -F
$IPTABLES -X
$IPTABLES -Z
$IPTABLES -t nat -F
$IPTABLES -t nat -X

# 2. 确立“非显式允许即拒绝”的零信任安全基线
echo "[*] 配置默认安全控制面基线 (DROP)..."
$IPTABLES -P INPUT DROP
$IPTABLES -P FORWARD DROP
$IPTABLES -P OUTPUT ACCEPT

# 3. 允许有状态连接（ESTABLISHED, RELATED）无缝回程放行
echo "[*] 部署有状态连接检测跟踪机制..."
$IPTABLES -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
$IPTABLES -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 4. 边界防火墙自身 INPUT 链安全加固
# 允许本地环回测试，放行外部协商 VPN 的 51820 端口
$IPTABLES -A INPUT -i lo -j ACCEPT
$IPTABLES -A INPUT -p udp --dport 51820 -j ACCEPT
$IPTABLES -A INPUT -j LOG --log-prefix "FW-INPUT-DENIED: "

# 5. 横向与纵向访问控制策略（FORWARD 链）

# --- 5.1 信任内网域 (Internal) 访问策略 ---
# 允许内网自由流向核心服务区 (Server) 开展业务操作
$IPTABLES -A FORWARD -i veth-fw-internal -o veth-fw-server -j ACCEPT
# 允许内网通过 SNAT 访问外网及公共服务区
$IPTABLES -A FORWARD -i veth-fw-internal -o veth-fw-pub -j ACCEPT
$IPTABLES -A FORWARD -i veth-fw-internal -o veth-fw-public -j ACCEPT

# --- 5.2 公共服务域 (Public) 物理隔离策略 ---
# 显式禁止公共服务域向信任内网域横向移动
$IPTABLES -A FORWARD -i veth-fw-public -o veth-fw-internal -j LOG --log-prefix "PUBLIC-TO-INTERNAL: "
$IPTABLES -A FORWARD -i veth-fw-public -o veth-fw-internal -j DROP
# 允许公共服务域单向访问核心服务区生产业务 (3000 端口)
$IPTABLES -A FORWARD -i veth-fw-public -o veth-fw-server -p tcp --dport 3000 -j ACCEPT

# --- 5.3 远程办公端 (VPN 隧道接口) 纵向最小化授权 ---
# 仅允许远程 VPN 接入端访问核心服务区的 3000 端口及信任内网，全面封锁其他敏感端口
$IPTABLES -A FORWARD -i wg0 -o veth-fw-server -p tcp --dport 3000 -j ACCEPT
$IPTABLES -A FORWARD -i wg0 -o veth-fw-internal -j ACCEPT

# --- 5.4 跨安全域管理端口 (SSH) 全域拦截 ---
# 杜绝任何外网、公共区对内网和服务器的 22 端口探测
$IPTABLES -A FORWARD -p tcp --dport 22 -j LOG --log-prefix "ILLEGAL-SSH-SCAN: "
$IPTABLES -A FORWARD -p tcp --dport 22 -j DROP

# --- 5.5 异常与越权流量的末端审计机制 ---
# 捕获所有漏网的越权非法流量并固化至内核日志中
$IPTABLES -A FORWARD -j LOG --log-prefix "BORDER-CROSS-DENIED: "
$IPTABLES -A FORWARD -j DROP

# 6. 地址转换（NAT）策略部署

# --- 6.1 源地址转换 (SNAT) ---
# 隐藏内网及公共区拓扑，对外统一映射为防火墙公网口 IP
$IPTABLES -t nat -A POSTROUTING -s 172.16.10.0/24 -o veth-fw-pub -j SNAT --to-source 198.51.100.1
$IPTABLES -t nat -A POSTROUTING -s 172.16.20.0/24 -o veth-fw-pub -j SNAT --to-source 198.51.100.1

# --- 6.2 目的地址转换 (DNAT) 业务发布 ---
# 将防火墙公网口的 8080 端口映射到核心服务区明文服务器的 3000 端口
$IPTABLES -t nat -A PREROUTING -d 198.51.100.1 -p tcp --dport 8080 -j DNAT --to-destination 172.16.30.2:3000
# 联动补充：在 FORWARD 链中前置放行经 DNAT 转换后的三层目的流量
$IPTABLES -I FORWARD 1 -d 172.16.30.2 -p tcp --dport 3000 -j ACCEPT

# 7. WSL2 环境兼容性与高级防御策略技术备注
# 注：若在标准生产系统或原生 Linux 内核下运行，请取消以下高级限制策略的注释：
# $IPTABLES -A FORWARD -p tcp --dport 3000 -m limit --limit 5/min -j LOG --log-prefix "CONN-LIMIT-TRIGGER: "
# $IPTABLES -A FORWARD -p tcp --dport 3000 -m connlimit --connlimit-above 10 -j REJECT --reject-with tcp-reset
# $IPTABLES -A FORWARD -i veth-fw-public -m recent --set --name SCANNER
# $IPTABLES -A FORWARD -i veth-fw-public -m recent --update --seconds 1 --hitcount 20 --name SCANNER -j REJECT

echo "[✓] 纵深防御网络安全防火墙基线策略灌入完毕！"