#!/bin/bash
set -euo pipefail

# 全局常量，方便修改网段
NS_LIST=("fw" "office" "guest" "dmz" "internet" "remote")
VETH_LIST=(
    "veth-fw-office" "veth-office"
    "veth-fw-guest" "veth-guest"
    "veth-fw-dmz" "veth-dmz"
    "veth-fw-inet" "veth-inet"
)

# ===================== 清理残留环境      =====================
echo "[1/5] 清理旧命名空间、veth虚拟网卡"
# 删除所有namespace
for ns in "${NS_LIST[@]}"; do
    sudo ip netns del "${ns}" 2>/dev/null || true
done

# 删除所有veth设备
for dev in "${VETH_LIST[@]}"; do
    sudo ip link del "${dev}" 2>/dev/null || true
done

# ===================== 创建全部网络命名空间 =====================
echo "[2/5] 创建6个网络namespace"
for ns in "${NS_LIST[@]}"; do
    sudo ip netns add "${ns}"
done

# 通用配置函数：统一创建veth对、分配IP、配置网关、启用lo
# 参数：fw侧网卡 主机侧网卡 fw侧IP 主机IP 主机ns名称
create_veth_pair() {
    local fw_if="$1"
    local host_if="$2"
    local fw_ip="$3"
    local host_ip="$4"
    local host_ns="$5"

    # 创建veth成对设备
    sudo ip link add "${fw_if}" type veth peer name "${host_if}"
    sudo ip link set "${fw_if}" netns fw
    sudo ip link set "${host_if}" netns "${host_ns}"

    # 配置fw端网卡
    sudo ip netns exec fw ip addr flush dev "${fw_if}" 2>/dev/null || true
    sudo ip netns exec fw ip addr add "${fw_ip}" dev "${fw_if}"
    sudo ip netns exec fw ip link set "${fw_if}" up
    sudo ip netns exec fw ip link set lo up

    # 配置业务主机端网卡
    sudo ip netns exec "${host_ns}" ip addr flush dev "${host_if}" 2>/dev/null || true
    sudo ip netns exec "${host_ns}" ip addr add "${host_ip}" dev "${host_if}"
    sudo ip netns exec "${host_ns}" ip link set "${host_if}" up
    sudo ip netns exec "${host_ns}" ip link set lo up

    # 配置默认网关（提取fw侧IP前缀作为网关）
    local gw_addr=$(echo "${fw_ip}" | cut -d'/' -f1)
    sudo ip netns exec "${host_ns}" ip route del default 2>/dev/null || true
    sudo ip netns exec "${host_ns}" ip route add default via "${gw_addr}"
}

# ===================== 批量创建四段veth链路 =====================
echo "[3/5] 配置各区域veth网络链路"
# office
create_veth_pair "veth-fw-office" "veth-office" "10.20.0.1/24" "10.20.0.2/24" "office"
# guest
create_veth_pair "veth-fw-guest" "veth-guest" "10.30.0.1/24" "10.30.0.2/24" "guest"
# dmz
create_veth_pair "veth-fw-dmz" "veth-dmz" "10.40.0.1/24" "10.40.0.2/24" "dmz"
# internet
create_veth_pair "veth-fw-inet" "veth-inet" "203.0.113.1/24" "203.0.113.10/24" "internet"
# --- remote ---
sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote
sudo ip netns exec fw ip addr add 192.168.100.1/30 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
sudo ip netns exec remote ip addr add 192.168.100.2/30 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up
sudo ip netns exec remote ip route add default via 192.168.100.1

# ===================== 开启防火墙IP转发（临时+系统兜底） =====================
echo "[4/5] 开启fw命名空间IPv4转发"
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
# 全局内核转发兜底（防止宿主机拦截跨ns转发）
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# ===================== 连通性自动化校验 =====================
echo "[5/5] 基础三层连通性测试"
check_ping_connect() {
    local target_ns="$1"
    local dest_ip="$2"
    if sudo ip netns exec "${target_ns}" ping -c 2 -W 1 "${dest_ip}" >/dev/null; then
        echo "✅ ${target_ns} 连通网关 ${dest_ip}"
    else
        echo "❌ 错误：${target_ns} 无法连通 ${dest_ip}"
        exit 1
    fi
}

check_ping_connect "office" "10.20.0.1"
check_ping_connect "guest" "10.30.0.1"
check_ping_connect "dmz" "10.40.0.1"
check_ping_connect "internet" "203.0.113.1"

echo -e "\n==================== 拓扑搭建全部完成 ===================="
echo "后续执行：sudo ./firewall.sh 加载防火墙NAT与访问规则"
echo "VPN配置请执行对应vpn脚本"