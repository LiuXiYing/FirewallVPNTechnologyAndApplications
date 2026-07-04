#!/bin/bash
# ============================================================
# setup.sh - 企业网络拓扑搭建（完整版，含基础防火墙）
# 适用实验第一部分：网络规划与基础搭建（20分）
# ============================================================

set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 1. 彻底清理 ----------
cleanup() {
    info "清理旧环境（命名空间 + veth 接口）..."
    for ns in fw office guest dmz internet remote; do
        sudo ip netns del "$ns" 2>/dev/null && info "删除命名空间 $ns" || true
    done
    # 删除所有以 veth- 开头的接口（防止遗留）
    for v in $(ip link show | grep -o 'veth-[^:@]*' | sort -u); do
        sudo ip link del "$v" 2>/dev/null && info "删除 veth 接口 $v" || true
    done
    # 清空 iptables 规则（避免旧规则干扰）
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -X 2>/dev/null || true
    ok "清理完成"
}

# ---------- 2. 创建命名空间 ----------
create_namespaces() {
    info "创建 6 个网络命名空间..."
    for ns in fw office guest dmz internet remote; do
        sudo ip netns add "$ns"
        ok "创建 $ns"
    done
}

# ---------- 3. 创建 veth 对并配置 IP ----------
create_veth_pairs() {
    info "创建 veth 对并配置 IP 地址..."

    # office  (10.20.0.0/24)
    sudo ip link add veth-fw-office type veth peer name veth-office
    sudo ip link set veth-fw-office netns fw
    sudo ip link set veth-office netns office
    sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
    sudo ip netns exec fw ip link set veth-fw-office up
    sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
    sudo ip netns exec office ip link set veth-office up
    sudo ip netns exec office ip link set lo up

    # guest  (10.30.0.0/24)
    sudo ip link add veth-fw-guest type veth peer name veth-guest
    sudo ip link set veth-fw-guest netns fw
    sudo ip link set veth-guest netns guest
    sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
    sudo ip netns exec fw ip link set veth-fw-guest up
    sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
    sudo ip netns exec guest ip link set veth-guest up
    sudo ip netns exec guest ip link set lo up

    # dmz  (10.40.0.0/24)
    sudo ip link add veth-fw-dmz type veth peer name veth-dmz
    sudo ip link set veth-fw-dmz netns fw
    sudo ip link set veth-dmz netns dmz
    sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
    sudo ip netns exec fw ip link set veth-fw-dmz up
    sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
    sudo ip netns exec dmz ip link set veth-dmz up
    sudo ip netns exec dmz ip link set lo up

    # internet (203.0.113.0/24)
    sudo ip link add veth-fw-inet type veth peer name veth-inet
    sudo ip link set veth-fw-inet netns fw
    sudo ip link set veth-inet netns internet
    sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
    sudo ip netns exec fw ip link set veth-fw-inet up
    sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
    sudo ip netns exec internet ip link set veth-inet up
    sudo ip netns exec internet ip link set lo up

    # remote (VPN 隧道模拟，10.10.10.0/24)
    sudo ip link add veth-fw-rmt type veth peer name veth-rmt
    sudo ip link set veth-fw-rmt netns fw
    sudo ip link set veth-rmt netns remote
    sudo ip netns exec fw ip addr add 10.10.10.1/24 dev veth-fw-rmt
    sudo ip netns exec fw ip link set veth-fw-rmt up
    sudo ip netns exec remote ip addr add 10.10.10.2/24 dev veth-rmt
    sudo ip netns exec remote ip link set veth-rmt up
    sudo ip netns exec remote ip link set lo up

    ok "所有 veth 对创建并配置完成"
}

# ---------- 4. 配置路由与转发 ----------
configure_routing() {
    info "配置默认路由并开启 IP 转发..."
    sudo ip netns exec office ip route add default via 10.20.0.1
    sudo ip netns exec guest  ip route add default via 10.30.0.1
    sudo ip netns exec dmz    ip route add default via 10.40.0.1
    sudo ip netns exec internet ip route add default via 203.0.113.1
    sudo ip netns exec remote ip route add default via 10.10.10.1
    sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null   # 宿主机兜底
    ok "路由与转发配置完成"
}

# ---------- 5. 基础防火墙（最小权限原则） ----------
configure_firewall() {
    info "应用基础防火墙策略（最小权限）..."
    # 在 fw 命名空间中操作
    sudo ip netns exec fw iptables -P INPUT DROP
    sudo ip netns exec fw iptables -P FORWARD DROP
    sudo ip netns exec fw iptables -P OUTPUT ACCEPT

    # 允许回环 & 已建立连接
    sudo ip netns exec fw iptables -A INPUT -i lo -j ACCEPT
    sudo ip netns exec fw iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    sudo ip netns exec fw iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    # 允许各区域 ping fw（便于管理）
    sudo ip netns exec fw iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

    # 允许办公网 → DMZ
    sudo ip netns exec fw iptables -A FORWARD -s 10.20.0.0/24 -d 10.40.0.0/24 -j ACCEPT

    # 允许 VPN 用户 → 办公网 & DMZ
    sudo ip netns exec fw iptables -A FORWARD -s 10.10.10.0/24 -d 10.20.0.0/24 -j ACCEPT
    sudo ip netns exec fw iptables -A FORWARD -s 10.10.10.0/24 -d 10.40.0.0/24 -j ACCEPT

    # 其他转发默认拒绝（已由 FORWARD DROP 实现）
    ok "基础防火墙策略已生效"
}

# ---------- 6. 连通性自动化校验 ----------
verify_connectivity() {
    info "验证基础三层连通性..."
    local failed=0
    test_ping() {
        local ns=$1; local target=$2; local desc=$3
        if sudo ip netns exec "$ns" ping -c 2 -W 1 "$target" &>/dev/null; then
            ok "$desc → $target 可达"
        else
            warn "$desc → $target 不可达"
            ((failed++))
        fi
    }
    test_ping office   10.20.0.1    "office"
    test_ping guest    10.30.0.1    "guest"
    test_ping dmz      10.40.0.1    "dmz"
    test_ping internet 203.0.113.1  "internet"
    test_ping remote   10.10.10.1   "remote"

    if [ $failed -eq 0 ]; then
        ok "所有基础连通性测试通过！"
    else
        warn "$failed 个测试失败，请检查配置。"
    fi
}

# ---------- 7. 显示摘要 ----------
show_summary() {
    echo ""
    echo "==================== 配置摘要 ===================="
    echo "命名空间及 IP 地址："
    echo "  fw      : 10.20.0.1, 10.30.0.1, 10.40.0.1, 203.0.113.1, 10.10.10.1"
    echo "  office  : 10.20.0.2"
    echo "  guest   : 10.30.0.2"
    echo "  dmz     : 10.40.0.2"
    echo "  internet: 203.0.113.10"
    echo "  remote  : 10.10.10.2"
    echo ""
    echo "防火墙策略（基础）："
    echo "  - INPUT 默认 DROP，允许回环、已建立连接、ICMP"
    echo "  - FORWARD 默认 DROP，仅允许 办公网→DMZ 和 VPN→办公网/DMZ"
    echo "  - OUTPUT 默认 ACCEPT"
    echo "================================================="
}

# ---------- 主流程 ----------
main() {
    echo -e "${BLUE}>>> 企业网络拓扑搭建（第一部分） <<<${NC}"
    cleanup
    create_namespaces
    create_veth_pairs
    configure_routing
    configure_firewall
    verify_connectivity
    show_summary
    ok "脚本执行完毕。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi