set -euo pipefail


# 网络拓扑配置表
# 格式: 命名空间名称, fw端网卡名, 主机端网卡名, fw端IP, 主机端IP
TOPOLOGY=(
    "office:veth-fw-office:veth-office:10.20.0.1/24:10.20.0.2/24"
    "guest:veth-fw-guest:veth-guest:10.30.0.1/24:10.30.0.2/24"
    "dmz:veth-fw-dmz:veth-dmz:10.40.0.1/24:10.40.0.2/24"
    "internet:veth-fw-inet:veth-inet:203.0.113.1/24:203.0.113.10/24"
    "remote:veth-fw-remote:veth-remote:192.168.100.1/30:192.168.100.2/30"
)

FW_NS="fw"
NS_LIST=("office" "guest" "dmz" "internet" "remote" "$FW_NS")

# ==============================================
# 通用工具：提取CIDR中的网关地址
# ==============================================
get_gateway() {
    echo "$1" | cut -d'/' -f1
}

# ==============================================
# 清理旧环境
# ==============================================
cleanup_namespaces() {
    echo "[1/6] 清理旧网络命名空间"
    for ns in "${NS_LIST[@]}"; do
        sudo ip netns del "$ns" 2>/dev/null || true
    done
}

cleanup_veth_devices() {
    echo "[2/6] 清理旧veth设备"
    for link in "${TOPOLOGY[@]}"; do
        IFS=':' read -r _ fw_if host_if _ _ <<< "$link"
        sudo ip link del "$fw_if" 2>/dev/null || true
        sudo ip link del "$host_if" 2>/dev/null || true
    done
}

# ==============================================
# 创建命名空间
# ==============================================
create_namespaces() {
    echo "[3/6] 创建所有网络命名空间"
    for ns in "${NS_LIST[@]}"; do
        sudo ip netns add "$ns"
    done
}

# ==============================================
# 单条veth链路配置
# ==============================================
setup_veth_link() {
    local ns_name="$1"
    local fw_if="$2"
    local host_if="$3"
    local fw_ip="$4"
    local host_ip="$5"

    sudo ip link add "$fw_if" type veth peer name "$host_if"
    sudo ip link set "$fw_if" netns "$FW_NS"
    sudo ip link set "$host_if" netns "$ns_name"

    sudo ip netns exec "$FW_NS" ip addr add "$fw_ip" dev "$fw_if"
    sudo ip netns exec "$FW_NS" ip link set "$fw_if" up

    sudo ip netns exec "$ns_name" ip addr add "$host_ip" dev "$host_if"
    sudo ip netns exec "$ns_name" ip link set "$host_if" up

    sudo ip netns exec "$ns_name" ip link set lo up

    local gw_addr
    gw_addr=$(get_gateway "$fw_ip")
    sudo ip netns exec "$ns_name" ip route add default via "$gw_addr"
}

# ==============================================
# 批量配置拓扑链路
# ==============================================
configure_topology() {
    echo "[4/6] 配置veth网络链路与默认路由"
    for link in "${TOPOLOGY[@]}"; do
        IFS=':' read -r ns_name fw_if host_if fw_ip host_ip <<< "$link"
        setup_veth_link "$ns_name" "$fw_if" "$host_if" "$fw_ip" "$host_ip"
        echo "    ${ns_name} <- ${fw_if} -> ${FW_NS}"
    done
}

# ==============================================
# 开启IP转发
# ==============================================
enable_ip_forwarding() {
    echo "[5/6] 开启IPv4转发"
    sudo ip netns exec "$FW_NS" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

# ==============================================
# 连通性检查
check_connectivity() {
    echo "[6/6] 执行基础连通性检查"

    for link in "${TOPOLOGY[@]}"; do
        IFS=':' read -r ns_name _ _ fw_ip _ <<< "$link"
        gw_addr=$(get_gateway "$fw_ip")

        if sudo ip netns exec "$ns_name" ping -c 2 -W 1 "$gw_addr" >/dev/null; then
            echo "    ✅ ${ns_name} 可达网关 ${gw_addr}"
        else
            echo "    ❌ ${ns_name} 无法到达网关 ${gw_addr}"
            exit 1
        fi
    done
}

# ==============================================
# 主流程
# ==============================================
main() {
    cleanup_namespaces
    cleanup_veth_devices
    create_namespaces
    configure_topology
    enable_ip_forwarding
    check_connectivity

    echo ""
    echo "=========================================="
    echo "网络拓扑搭建完成"
    echo "=========================================="
    echo "防火墙命名空间: $FW_NS"
    echo "业务命名空间: office, guest, dmz, internet, remote"
    echo ""
    echo "下一步可执行: sudo ./firewall.sh"
}

main