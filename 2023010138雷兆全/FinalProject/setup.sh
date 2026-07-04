#!/bin/bash
set -euo pipefail

# ========================== 网段与接口配置区（集中修改） ==========================
# 所有命名空间列表
NS_ARRAY=(
    fw
    office
    guest
    dmz
    internet
    remote
)

# 链路配置格式：fw网卡,对端网卡,fwIP/掩码,对端IP/掩码,对端命名空间
LINK_CFG=(
    "veth-fw-office,veth-office,10.20.0.1/24,10.20.0.2/24,office"
    "veth-fw-guest,veth-guest,10.30.0.1/24,10.30.0.2/24,guest"
    "veth-fw-dmz,veth-dmz,10.40.0.1/24,10.40.0.2/24,dmz"
    "veth-fw-inet,veth-inet,203.0.113.1/24,203.0.113.10/24,internet"
    "veth-fw-remote,veth-remote,192.168.100.1/30,192.168.100.2/30,remote"
)

# ========================== 工具函数定义 ==========================
# 清理单条veth设备
clean_veth() {
    local dev="$1"
    if ip link show "$dev" &>/dev/null; then
        sudo ip link delete "$dev"
    fi
}

# 创建一组veth、分配命名空间、配置IP、启用网卡、设置默认网关
build_link() {
    local cfg="$1"
    IFS=',' read -r fw_if host_if fw_cidr host_cidr host_ns <<< "$cfg"

    # 创建veth对
    sudo ip link add "$fw_if" type veth peer name "$host_if"
    sudo ip link set "$fw_if" netns fw
    sudo ip link set "$host_if" netns "$host_ns"

    # 配置fw侧地址
    sudo ip netns exec fw ip address flush dev "$fw_if" || true
    sudo ip netns exec fw ip address add "$fw_cidr" dev "$fw_if"
    sudo ip netns exec fw ip link set "$fw_if" up
    sudo ip netns exec fw ip link set lo up

    # 配置主机侧地址
    sudo ip netns exec "$host_ns" ip address flush dev "$host_if" || true
    sudo ip netns exec "$host_ns" ip address add "$host_cidr" dev "$host_if"
    sudo ip netns exec "$host_ns" ip link set "$host_if" up
    sudo ip netns exec "$host_ns" ip link set lo up

    # 提取网关IP，配置默认路由
    local gw_ip="${fw_cidr%%/*}"
    sudo ip netns exec "$host_ns" ip route del default &>/dev/null || true
    sudo ip netns exec "$host_ns" ip route add default via "$gw_ip"
}

# 连通性检测封装
ping_test() {
    local ns="$1"
    local dest="$2"
    if sudo ip netns exec "$ns" ping -c2 -W1 "$dest" &>/dev/null; then
        echo "✅ $ns 正常可达 $dest"
    else
        echo "❌ $ns 无法连通 $dest，部署异常"
        exit 1
    fi
}

# ========================== 步骤1：环境清理 ==========================
echo "[1/5] 清除旧命名空间与残留veth设备"
# 删除所有命名空间
for ns in "${NS_ARRAY[@]}"; do
    sudo ip netns delete "$ns" &>/dev/null || true
done

# 提取所有veth名称并逐个删除
for line in "${LINK_CFG[@]}"; do
    IFS=',' read -r f h _ _ _ <<< "$line"
    clean_veth "$f"
    clean_veth "$h"
done

# ========================== 步骤2：新建所有命名空间 ==========================
echo "[2/5] 批量创建6个网络命名空间"
for ns in "${NS_ARRAY[@]}"; do
    sudo ip netns add "$ns"
done

# ========================== 步骤3：循环构建全部veth链路 ==========================
echo "[3/5] 逐条创建veth配对、IP配置、路由配置"
for item in "${LINK_CFG[@]}"; do
    build_link "$item"
done

# ========================== 步骤4：开启IP转发 ==========================
echo "[4/5] 开启fw命名空间及宿主机IPv4转发"
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# ========================== 步骤5：自动化连通校验 ==========================
echo "[5/5] 执行网关连通性自检"
ping_test office 10.20.0.1
ping_test guest 10.30.0.1
ping_test dmz    10.40.0.1
ping_test internet 203.0.113.1

# ========================== 部署完成提示 ==========================
echo -e "\n==================== 网络拓扑部署完成 ===================="
echo "下一步操作：sudo ./firewall.sh 加载防火墙NAT与访问控制策略"
echo "如需VPN访问控制，部署对应VPN配置脚本即可"