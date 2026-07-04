#!/bin/bash

set -euo pipefail
# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ---------- 1. 清理旧规则 ----------
cleanup_rules() {
    info "清理旧规则..."
    sudo ip netns exec fw iptables -F 2>/dev/null || true
    sudo ip netns exec fw iptables -t nat -F 2>/dev/null || true
    sudo ip netns exec fw iptables -X 2>/dev/null || true
    ok "规则清理完成"
}

# ---------- 2. 配置 FORWARD 链默认策略 ----------
configure_forward_policy() {
    info "配置 FORWARD 链默认策略..."
    sudo ip netns exec fw iptables -P FORWARD DROP
    ok "FORWARD 默认策略：DROP"
}

# ---------- 3. 配置状态检测规则 ----------
configure_state_tracking() {
    info "配置状态检测规则..."
    sudo ip netns exec fw iptables -A FORWARD \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j ACCEPT
    ok "状态检测规则已添加"
}

# ---------- 4. 配置区域间访问控制 ----------
configure_zone_policies() {
    info "配置区域间访问控制..."

    # ----- office 访问规则 -----
    # office → dmz:8080（允许）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-office -o veth-fw-dmz \
        -s 10.20.0.0/24 -d 10.40.0.0/24 \
        -p tcp --dport 8080 \
        -m conntrack --ctstate NEW \
        -j ACCEPT
    ok "office → dmz:8080（允许）"

    # office → dmz:22（拒绝 + LOG）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-office -o veth-fw-dmz \
        -s 10.20.0.0/24 -d 10.40.0.0/24 \
        -p tcp --dport 22 \
        -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-office -o veth-fw-dmz \
        -s 10.20.0.0/24 -d 10.40.0.0/24 \
        -p tcp --dport 22 \
        -j REJECT --reject-with icmp-port-unreachable
    ok "office → dmz:22（拒绝 + LOG）"

    # office → internet（允许）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-office -o veth-fw-inet \
        -s 10.20.0.0/24 \
        -m conntrack --ctstate NEW \
        -j ACCEPT
    ok "office → internet（允许）"

    # ----- guest 访问规则 -----
    # guest → internet（允许）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-guest -o veth-fw-inet \
        -s 10.30.0.0/24 \
        -m conntrack --ctstate NEW \
        -j ACCEPT
    ok "guest → internet（允许）"

    # guest → office（拒绝 + LOG，带速率限制）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-guest -o veth-fw-office \
        -s 10.30.0.0/24 -d 10.20.0.0/24 \
        -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-guest -o veth-fw-office \
        -s 10.30.0.0/24 -d 10.20.0.0/24 \
        -j REJECT --reject-with icmp-port-unreachable
    ok "guest → office（拒绝 + LOG）"

    # guest → dmz（拒绝 + LOG，带速率限制）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-guest -o veth-fw-dmz \
        -s 10.30.0.0/24 -d 10.40.0.0/24 \
        -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-guest -o veth-fw-dmz \
        -s 10.30.0.0/24 -d 10.40.0.0/24 \
        -j REJECT --reject-with icmp-port-unreachable
    ok "guest → dmz（拒绝 + LOG）"

    # ----- dmz 访问规则 -----
    # dmz → internet（允许）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-dmz -o veth-fw-inet \
        -s 10.40.0.0/24 \
        -m conntrack --ctstate NEW \
        -j ACCEPT
    ok "dmz → internet（允许）"

    # ----- internet 访问规则 -----
    # internet → dmz:8080（DNAT 放行）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-inet -o veth-fw-dmz \
        -d 10.40.0.0/24 \
        -p tcp --dport 8080 \
        -m conntrack --ctstate NEW \
        -j ACCEPT
    ok "internet → dmz:8080（DNAT 放行）"

    # internet → dmz:22（拒绝 + LOG）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-inet -o veth-fw-dmz \
        -d 10.40.0.0/24 \
        -p tcp --dport 22 \
        -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-inet -o veth-fw-dmz \
        -d 10.40.0.0/24 \
        -p tcp --dport 22 \
        -j REJECT --reject-with icmp-port-unreachable
    ok "internet → dmz:22（拒绝 + LOG）"

    # internet → office（拒绝 + LOG）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-inet -o veth-fw-office \
        -d 10.20.0.0/24 \
        -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-inet -o veth-fw-office \
        -d 10.20.0.0/24 \
        -j REJECT --reject-with icmp-port-unreachable
    ok "internet → office（拒绝 + LOG）"

    # internet → guest（拒绝）
    sudo ip netns exec fw iptables -A FORWARD \
        -i veth-fw-inet -o veth-fw-guest \
        -d 10.30.0.0/24 \
        -j REJECT --reject-with icmp-port-unreachable
    ok "internet → guest（拒绝）"
}

# ---------- 5. 配置 NAT ----------
configure_nat() {
    info "配置 NAT..."

    # SNAT - 内网访问外网
    sudo ip netns exec fw iptables -t nat -A POSTROUTING \
        -s 10.20.0.0/24 -o veth-fw-inet \
        -j MASQUERADE
    ok "office → internet SNAT 配置完成"

    sudo ip netns exec fw iptables -t nat -A POSTROUTING \
        -s 10.30.0.0/24 -o veth-fw-inet \
        -j MASQUERADE
    ok "guest → internet SNAT 配置完成"

    sudo ip netns exec fw iptables -t nat -A POSTROUTING \
        -s 10.40.0.0/24 -o veth-fw-inet \
        -j MASQUERADE
    ok "dmz → internet SNAT 配置完成"

    # DNAT - 外网访问 dmz:8080
    sudo ip netns exec fw iptables -t nat -A PREROUTING \
        -i veth-fw-inet \
        -p tcp --dport 8080 \
        -j DNAT --to-destination 10.40.0.2:8080
    ok "internet → dmz:8080 DNAT 配置完成"
}

# ---------- 6. 显示规则摘要 ----------
show_summary() {
    echo ""
    echo "==================== 防火墙规则摘要 ===================="
    echo ""
    echo "FORWARD 链规则（含计数器）："
    sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
    echo ""
    echo "NAT 规则："
    sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
    echo "========================================================"
}

# ---------- 主流程 ----------
main() {
    echo -e "${BLUE}>>> 企业网络安全架构 - 防火墙规则配置 <<<${NC}"
    cleanup_rules
    configure_forward_policy
    configure_state_tracking
    configure_zone_policies
    configure_nat
    show_summary
    ok "防火墙规则配置完成！"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi