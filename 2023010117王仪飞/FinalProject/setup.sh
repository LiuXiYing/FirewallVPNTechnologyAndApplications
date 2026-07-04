set -e
# ============================================
# 颜色定义
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}  企业网络安全架构 - 拓扑搭建脚本${NC}"
    echo -e "${BLUE}=========================================${NC}"
}

print_header

# ============================================
# 清理函数
# ============================================
cleanup_environment() {
    echo ""
    echo -e "${YELLOW}[1/7] 清理现有环境...${NC}"
    
    # 停止 WireGuard
    for ns in fw remote; do
        sudo ip netns exec ${ns} wg-quick down wg0 2>/dev/null || true
    done
    
    # 停止 HTTP 服务
    sudo pkill -f "python3 -m http.server" 2>/dev/null || true
    
    # 删除 namespace
    for ns in fw office guest dmz internet remote; do
        sudo ip netns del ${ns} 2>/dev/null || true
    done
    
    # 清理 veth
    for iface in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet veth-fw-remote \
                 veth-office veth-guest veth-dmz veth-inet veth-remote; do
        sudo ip link del ${iface} 2>/dev/null || true
    done
    
    sleep 1
    echo -e "  ${GREEN}✅ 清理完成${NC}"
}

# ============================================
# 创建 namespace
# ============================================
create_namespaces() {
    echo ""
    echo -e "${YELLOW}[2/7] 创建 6 个 network namespace...${NC}"
    
    local namespaces=("fw" "office" "guest" "dmz" "internet" "remote")
    for ns in "${namespaces[@]}"; do
        sudo ip netns add ${ns}
        echo -e "  ${GREEN}✅ 创建 ${ns}${NC}"
    done
    
    echo -e "  ${GREEN}✅ 所有 namespace 创建完成${NC}"
}

# ============================================
# 创建 veth 对
# ============================================
create_veth_pairs() {
    echo ""
    echo -e "${YELLOW}[3/7] 创建 veth 对并配置 IP 地址...${NC}"
    
    # 定义连接配置: 名称, namespace, fw侧IP, 对端IP
    local connections=(
        "office:10.20.0.1/24:10.20.0.2/24"
        "guest:10.30.0.1/24:10.30.0.2/24"
        "dmz:10.40.0.1/24:10.40.0.2/24"
        "inet:203.0.113.1/24:203.0.113.10/24"
        "remote:10.100.0.1/24:10.100.0.2/24"
    )
    
    for conn in "${connections[@]}"; do
        IFS=':' read -r name fw_ip peer_ip <<< "${conn}"
        local veth_fw="veth-fw-${name}"
        local veth_peer="veth-${name}"
        
        echo -e "  - ${BLUE}配置 ${name} 网段...${NC}"
        
        sudo ip link add ${veth_fw} type veth peer name ${veth_peer}
        sudo ip link set ${veth_fw} netns fw
        sudo ip link set ${veth_peer} netns ${name}
        
        sudo ip netns exec fw ip addr add ${fw_ip} dev ${veth_fw}
        sudo ip netns exec fw ip link set ${veth_fw} up
        
        sudo ip netns exec ${name} ip addr add ${peer_ip} dev ${veth_peer}
        sudo ip netns exec ${name} ip link set ${veth_peer} up
        sudo ip netns exec ${name} ip link set lo up
    done
    
    echo -e "  ${GREEN}✅ 所有 veth 对配置完成${NC}"
}

# ============================================
# 配置路由
# ============================================
configure_routing() {
    echo ""
    echo -e "${YELLOW}[4/7] 配置路由...${NC}"
    
    # 设置默认网关
    sudo ip netns exec office ip route add default via 10.20.0.1
    sudo ip netns exec guest ip route add default via 10.30.0.1
    sudo ip netns exec dmz ip route add default via 10.40.0.1
    sudo ip netns exec internet ip route add default via 203.0.113.1
    sudo ip netns exec remote ip route add 10.10.10.1/32 via 10.100.0.1
    
    echo -e "  ${GREEN}✅ 路由配置完成${NC}"
}

# ============================================
# 开启 IP 转发
# ============================================
enable_ip_forward() {
    echo ""
    echo -e "${YELLOW}[5/7] 开启 IP 转发...${NC}"
    sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo -e "  ${GREEN}✅ IP 转发已开启${NC}"
}

# ============================================
# 连通性测试
# ============================================
test_connectivity() {
    echo ""
    echo -e "${YELLOW}[6/7] 验证连通性...${NC}"
    
    local tests=(
        "office:10.20.0.1"
        "guest:10.30.0.1"
        "dmz:10.40.0.1"
        "internet:203.0.113.1"
        "remote:10.100.0.1"
    )
    
    for test in "${tests[@]}"; do
        IFS=':' read -r ns target <<< "${test}"
        echo -n "  - ${ns} -> ${target}: "
        if sudo ip netns exec ${ns} ping -c 2 ${target} > /dev/null 2>&1; then
            echo -e "${GREEN}✅ 成功${NC}"
        else
            echo -e "${RED}❌ 失败${NC}"
        fi
    done
}

# ============================================
# 显示信息
# ============================================
show_summary() {
    echo ""
    echo -e "${YELLOW}[7/7] 配置信息汇总${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo ""
    echo -e "${BLUE}📋 地址规划表：${NC}"
    echo "  ┌─────────────┬───────────────┬───────────────┐"
    echo "  │ 区域        │ fw 侧地址     │ 主机地址      │"
    echo "  ├─────────────┼───────────────┼───────────────┤"
    echo "  │ office      │ 10.20.0.1/24  │ 10.20.0.2/24  │"
    echo "  │ guest       │ 10.30.0.1/24  │ 10.30.0.2/24  │"
    echo "  │ dmz         │ 10.40.0.1/24  │ 10.40.0.2/24  │"
    echo "  │ internet    │ 203.0.113.1/24│ 203.0.113.10/24│"
    echo "  │ vpn         │ 10.10.10.1/24 │ 10.10.10.2/24 │"
    echo "  │ fw-remote   │ 10.100.0.1/24 │ 10.100.0.2/24 │"
    echo "  └─────────────┴───────────────┴───────────────┘"
    echo ""
    echo -e "${BLUE}📌 namespace 列表：${NC}"
    sudo ip netns list
    echo ""
    echo -e "${BLUE}📌 veth 接口列表（fw 端）：${NC}"
    sudo ip netns exec fw ip link show | grep -E "veth-fw|wg0" || echo "  暂无 wg0 接口"
    echo ""
    echo -e "${BLUE}📌 路由表（fw）：${NC}"
    sudo ip netns exec fw ip route
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  ✅ 拓扑搭建完成！${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo "提示："
    echo "  - 下一步请运行 firewall.sh 配置防火墙规则"
    echo "  - 查看连通性测试结果请参考 01-topology.png"
}

# ============================================
# 主执行流程
# ============================================
cleanup_environment
create_namespaces
create_veth_pairs
configure_routing
enable_ip_forward
test_connectivity
show_summary