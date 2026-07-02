#!/bin/bash
# ============================================================
# firewall.sh — 防火墙与VPN技术期末大作业：防火墙策略
# 功能：在fw上配置iptables规则，实现区域隔离、NAT、DNAT
# 运行环境：先执行 setup.sh 后运行
# ============================================================

# 不用 set -e，因为有些可选规则（如 connlimit）可能失败不应中断脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} 请使用 sudo 运行此脚本"
  exit 1
fi

# ---- 在 fw namespace 内操作 ----
FW="ip netns exec fw iptables"

info "========== 清理旧规则 =========="
$FW -F
$FW -t nat -F
$FW -X
info "旧规则已清理"

# ============================================================
# 1. 默认策略：FORWARD 和 INPUT 设为 DROP，OUTPUT ACCEPT
# ============================================================
info "设置默认策略：FORWARD DROP, INPUT DROP, OUTPUT ACCEPT"
$FW -P FORWARD DROP
$FW -P INPUT DROP
$FW -P OUTPUT ACCEPT

# ============================================================
# 1b. INPUT 链规则（允许 fw 本机必要的流量）
# ============================================================
info "配置 INPUT 链规则..."

# 允许回环接口
$FW -A INPUT -i lo -j ACCEPT

# 允许已建立和相关连接（响应包）
$FW -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 允许 ICMP（ping 到防火墙自身接口IP）—— 这是连通性测试的关键
$FW -A INPUT -p icmp -j ACCEPT

# 允许各内网接口的 ICMP
$FW -A INPUT -i veth-fw-office -p icmp -j ACCEPT
$FW -A INPUT -i veth-fw-guest  -p icmp -j ACCEPT
$FW -A INPUT -i veth-fw-dmz    -p icmp -j ACCEPT

# 允许 WireGuard UDP 51820 端口（VPN握手）—— 必须在所有接口上放行
# 因为 remote 发来的握手包可能经过 internet 中转
$FW -A INPUT -p udp --dport 51820 -j ACCEPT

# 允许各内网接口的 TCP 已建立连接（用于 HTTP 响应等）
$FW -A INPUT -i veth-fw-office -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$FW -A INPUT -i veth-fw-guest  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$FW -A INPUT -i veth-fw-dmz    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# OUTPUT 允许已建立连接（防火墙主动发出的包的响应）
$FW -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

info "INPUT 链规则已配置（放行 ICMP + ESTABLISHED + WireGuard UDP）"

# ============================================================
# 2. 状态检测（FORWARD 链，必须放最前面）
# ============================================================
info "添加状态检测规则（ESTABLISHED,RELATED 放行）"
$FW -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ============================================================
# 3. office 区域规则
# ============================================================
info "添加 office 区域规则..."

# office -> dmz:8080 允许
$FW -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 \
    -p tcp --dport 8080 \
    -m conntrack --ctstate NEW -j ACCEPT

# office -> dmz:22 拒绝 + LOG
$FW -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: "

$FW -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 -j REJECT

# office -> internet 允许
$FW -A FORWARD -i veth-fw-office -o veth-fw-inet \
    -s 10.20.0.0/24 \
    -m conntrack --ctstate NEW -j ACCEPT

# ============================================================
# 4. guest 区域规则
# ============================================================
info "添加 guest 区域规则..."

# guest -> office 拒绝 + LOG
$FW -A FORWARD -i veth-fw-guest -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-OFFICE: "

$FW -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT

# guest -> dmz 拒绝 + LOG
$FW -A FORWARD -i veth-fw-guest -o veth-fw-dmz \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-DMZ: "

$FW -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

# guest -> internet 允许
$FW -A FORWARD -i veth-fw-guest -o veth-fw-inet \
    -s 10.30.0.0/24 \
    -m conntrack --ctstate NEW -j ACCEPT

# ============================================================
# 5. dmz 区域规则
# ============================================================
info "添加 dmz 区域规则..."

# dmz -> internet 允许（回包走 ESTABLISHED 规则）
$FW -A FORWARD -i veth-fw-dmz -o veth-fw-inet \
    -s 10.40.0.0/24 \
    -m conntrack --ctstate NEW -j ACCEPT

# ============================================================
# 6. internet 区域规则
# ============================================================
info "添加 internet 区域规则..."

# internet -> dmz:8080 (仅DNAT后的流量允许，直连到10.40.0.2:8080的流量应被拒绝)
# PREROUTING 中给目标为 203.0.113.1:8080 的流量打 mark 100，
# FORWARD 链只放行带 mark 100 的新连接，从而实现 DNAT 与直连的区分
$FW -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 8080 \
    -m mark --mark 100 -j ACCEPT

# internet -> office 拒绝 + LOG
$FW -A FORWARD -i veth-fw-inet -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-OFFICE: "

$FW -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT

# internet -> guest 拒绝
$FW -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT

# internet -> dmz (非8080端口) 拒绝
$FW -A FORWARD -i veth-fw-inet -o veth-fw-dmz -j REJECT

# ============================================================
# 7. VPN 区域规则
# ============================================================
info "添加 VPN 区域规则..."

# VPN -> office 允许
$FW -A FORWARD -i wg0 -o veth-fw-office \
    -s 10.10.10.0/24 -d 10.20.0.0/24 \
    -m conntrack --ctstate NEW -j ACCEPT

# VPN -> dmz:8080 允许
$FW -A FORWARD -i wg0 -o veth-fw-dmz \
    -s 10.10.10.0/24 -d 10.40.0.2 \
    -p tcp --dport 8080 \
    -m conntrack --ctstate NEW -j ACCEPT

# VPN -> dmz:22 拒绝 + LOG
$FW -A FORWARD -i wg0 -o veth-fw-dmz \
    -s 10.10.10.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -j LOG --log-prefix "VPN-TO-DMZ-SSH: "

$FW -A FORWARD -i wg0 -o veth-fw-dmz \
    -s 10.10.10.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 -j REJECT

# 其他 VPN 流量拒绝 + LOG
$FW -A FORWARD -i wg0 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "VPN-DENY: "

$FW -A FORWARD -i wg0 -j REJECT

# ============================================================
# 8. NAT 配置
# ============================================================
info "配置 NAT..."

# SNAT: 内网访问外网（MASQUERADE 动态源地址转换）
$FW -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT: 外网访问 dmz:8080（端口转发）
# 限制 -d 203.0.113.1：只把发给防火墙公网 IP 的流量转发到 dmz
# 直连 10.40.0.2 的流量不做 DNAT，会被 FORWARD REJECT 拦截
# 注意：先打 mark 100 再 DNAT，FORWARD 链靠 mark 100 识别 DNAT 流量
$FW -t nat -A PREROUTING -i veth-fw-inet -p tcp -d 203.0.113.1 --dport 8080 \
    -j MARK --set-mark 100
$FW -t nat -A PREROUTING -i veth-fw-inet -p tcp -d 203.0.113.1 --dport 8080 \
    -j DNAT --to-destination 10.40.0.2:8080

# ============================================================
# 9. 连接数限制（安全增强）
# ============================================================
info "添加连接数限制规则（防止单IP滥用）..."
$FW -I FORWARD -p tcp --syn --dport 8080 -d 10.40.0.2 \
    -m connlimit --connlimit-above 10 --connlimit-mask 32 \
    -j REJECT --reject-with tcp-reset 2>/dev/null || \
    warn "connlimit 模块不可用，跳过连接数限制"

# ============================================================
# 10. 显示规则
# ============================================================
echo ""
info "========== INPUT 链规则 =========="
$FW -L INPUT -n -v --line-numbers

echo ""
info "========== FORWARD 链规则 =========="
$FW -L FORWARD -n -v --line-numbers

echo ""
info "========== NAT 表规则 =========="
$FW -t nat -L -n -v --line-numbers

echo ""
info "========== 防火墙配置完成 =========="
info "下一步：运行 vpn-setup.sh 配置 WireGuard VPN"
