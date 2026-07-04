set -e

echo "========================================="
echo "  企业网络安全架构 - 防火墙规则配置"
echo "========================================="

# ============================================
# 清理规则函数
# ============================================
flush_rules() {
    echo ""
    echo "[1/6] 清理旧规则..."
    sudo ip netns exec fw iptables -F FORWARD
    sudo ip netns exec fw iptables -t nat -F
    sudo ip netns exec fw iptables -X
    sudo ip netns exec fw iptables -t nat -X
    echo "  ✅ 规则清理完成"
}

# ============================================
# 基础 FORWARD 配置
# ============================================
setup_forward_base() {
    echo ""
    echo "[2/6] 配置 FORWARD 链..."
    sudo ip netns exec fw iptables -P FORWARD DROP
    echo "  - FORWARD 默认策略: DROP"
    
    sudo ip netns exec fw iptables -A FORWARD \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    echo "  - 状态检测规则: ✅"
}

# ============================================
# 区域访问控制
# ============================================
setup_zone_access() {
    echo ""
    echo "[3/6] 配置区域间访问控制..."
    
    # Office 规则
    echo "  - office 访问规则..."
    _add_forward_rule "office" "dmz" "10.20.0.0/24" "10.40.0.2" "tcp --dport 8080" "ACCEPT" "office -> dmz:8080 (允许)"
    _add_forward_rule "office" "inet" "10.20.0.0/24" "" "" "ACCEPT" "office -> internet (允许)"
    _add_forward_rule "office" "dmz" "10.20.0.0/24" "10.40.0.2" "tcp --dport 22" "LOG" "office -> dmz:22 (LOG)"
    _add_forward_rule "office" "dmz" "10.20.0.0/24" "10.40.0.2" "tcp --dport 22" "REJECT" "office -> dmz:22 (拒绝)"
    
    # Guest 规则
    echo "  - guest 访问规则..."
    _add_forward_rule "guest" "inet" "10.30.0.0/24" "" "" "ACCEPT" "guest -> internet (允许)"
    _add_forward_rule "guest" "office" "10.30.0.0/24" "10.20.0.0/24" "" "LOG" "guest -> office (LOG)"
    _add_forward_rule "guest" "office" "10.30.0.0/24" "10.20.0.0/24" "" "REJECT" "guest -> office (拒绝)"
    _add_forward_rule "guest" "dmz" "10.30.0.0/24" "10.40.0.0/24" "" "LOG" "guest -> dmz (LOG)"
    _add_forward_rule "guest" "dmz" "10.30.0.0/24" "10.40.0.0/24" "" "REJECT" "guest -> dmz (拒绝)"
    
    # DMZ 规则
    echo "  - dmz 访问规则..."
    _add_forward_rule "dmz" "inet" "10.40.0.0/24" "" "" "ACCEPT" "dmz -> internet (允许)"
    
    # Internet 规则
    echo "  - internet 访问规则..."
    _add_forward_rule "inet" "dmz" "" "10.40.0.2" "tcp --dport 8080" "ACCEPT" "internet -> dmz:8080 (DNAT放行)"
    _add_forward_rule "inet" "office" "" "10.20.0.0/24" "" "LOG" "internet -> office (LOG)"
    _add_forward_rule "inet" "office" "" "10.20.0.0/24" "" "REJECT" "internet -> office (拒绝)"
    _add_forward_rule "inet" "guest" "" "10.30.0.0/24" "" "REJECT" "internet -> guest (拒绝)"
    _add_forward_rule "inet" "dmz" "" "10.40.0.2" "tcp --dport 22" "REJECT" "internet -> dmz:22 (拒绝)"
}

# ============================================
# 辅助函数：添加 FORWARD 规则
# ============================================
_add_forward_rule() {
    local from=$1
    local to=$2
    local src=$3
    local dst=$4
    local proto=$5
    local action=$6
    local desc=$7
    
    local cmd="sudo ip netns exec fw iptables -A FORWARD"
    [[ -n "${from}" ]] && cmd="${cmd} -i veth-fw-${from}"
    [[ -n "${to}" ]] && cmd="${cmd} -o veth-fw-${to}"
    [[ -n "${src}" ]] && cmd="${cmd} -s ${src}"
    [[ -n "${dst}" ]] && cmd="${cmd} -d ${dst}"
    [[ -n "${proto}" ]] && cmd="${cmd} -p ${proto}"
    
    case "${action}" in
        "ACCEPT")
            cmd="${cmd} -m conntrack --ctstate NEW -j ACCEPT"
            ;;
        "REJECT")
            cmd="${cmd} -j REJECT"
            ;;
        "LOG")
            cmd="${cmd} -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix \"${desc}: \" --log-level 4"
            ;;
    esac
    
    eval ${cmd}
    echo "    ✅ ${desc}"
}

# ============================================
# 配置 NAT
# ============================================
setup_nat() {
    echo ""
    echo "[4/6] 配置 NAT..."
    
    # SNAT
    local snat_rules=(
        "10.20.0.0/24:office"
        "10.30.0.0/24:guest"
        "10.40.0.0/24:dmz"
    )
    
    for rule in "${snat_rules[@]}"; do
        IFS=':' read -r subnet name <<< "${rule}"
        sudo ip netns exec fw iptables -t nat -A POSTROUTING \
            -s ${subnet} -o veth-fw-inet -j MASQUERADE
        echo "  - SNAT ${name} -> internet: ✅"
    done
    
    # DNAT
    sudo ip netns exec fw iptables -t nat -A PREROUTING \
        -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
    echo "  - DNAT internet -> dmz:8080: ✅"
}

# ============================================
# 配置 VPN
# ============================================
setup_vpn() {
    echo ""
    echo "[5/6] 配置 VPN 访问控制..."
    
    # VPN 允许规则
    local vpn_allows=(
        "office:10.20.0.0/24::"
        "dmz:10.40.0.2:tcp --dport 8080"
    )
    
    for allow in "${vpn_allows[@]}"; do
        IFS=':' read -r dest subnet proto <<< "${allow}"
        local cmd="sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-${dest} -s 10.10.10.2"
        [[ -n "${subnet}" ]] && cmd="${cmd} -d ${subnet}"
        [[ -n "${proto}" ]] && cmd="${cmd} -p ${proto}"
        cmd="${cmd} -m conntrack --ctstate NEW -j ACCEPT"
        eval ${cmd}
        echo "  - VPN -> ${dest}: ✅"
    done
    
    # VPN SSH 拒绝
    sudo ip netns exec fw iptables -A FORWARD \
        -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 \
        -p tcp --dport 22 \
        -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD \
        -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 \
        -p tcp --dport 22 -j REJECT
    echo "  - VPN -> dmz:22 (拒绝+LOG): ✅"
    
    # VPN 默认拒绝
    sudo ip netns exec fw iptables -A FORWARD \
        -i wg0 -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "VPN-DENY: " --log-level 4
    sudo ip netns exec fw iptables -A FORWARD -i wg0 -j REJECT
    echo "  - VPN 其他流量 (拒绝+LOG): ✅"
}

# ============================================
# 显示规则验证
# ============================================
show_rules() {
    echo ""
    echo "[6/6] 规则验证"
    echo "========================================="
    
    echo ""
    echo "📋 FORWARD 链规则列表："
    echo "----------------------------------------"
    sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
    
    echo ""
    echo "📋 NAT 规则列表："
    echo "----------------------------------------"
    sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
    
    echo ""
    echo "📋 规则统计："
    echo "----------------------------------------"
    local forward_count=$(sudo ip netns exec fw iptables -L FORWARD -n | wc -l)
    local nat_count=$(sudo ip netns exec fw iptables -t nat -L -n | wc -l)
    local log_count=$(sudo ip netns exec fw iptables -L FORWARD -n | grep -c LOG)
    echo "FORWARD 规则总数: ${forward_count}"
    echo "NAT 规则总数: ${nat_count}"
    echo "LOG 规则数: ${log_count}"
    
    echo ""
    echo "========================================="
    echo "  ✅ 防火墙规则配置完成！"
    echo "========================================="
}

# ============================================
# 主执行流程
# ============================================
flush_rules
setup_forward_base
setup_zone_access
setup_nat
setup_vpn
show_rules