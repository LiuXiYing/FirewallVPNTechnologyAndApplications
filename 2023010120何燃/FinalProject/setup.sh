#!/bin/bash
set -e

echo "=== 期末大作业 第一部分：网络拓扑搭建 ==="

# ---------- 1. 清理旧环境 ----------
echo "[1] 清理旧命名空间..."
for ns in fw office guest dmz internet remote; do
    ip netns del "$ns" 2>/dev/null || true
done
# 若残留 veth 在默认命名空间，也一并清理（通常不需要）
ip link del veth-fw-office 2>/dev/null || true
ip link del veth-fw-guest  2>/dev/null || true
ip link del veth-fw-dmz    2>/dev/null || true
ip link del veth-fw-inet   2>/dev/null || true

# ---------- 2. 创建 6 个命名空间 ----------
echo "[2] 创建命名空间..."
ip netns add fw
ip netns add office
ip netns add guest
ip netns add dmz
ip netns add internet
ip netns add remote

# ---------- 3. 创建 4 对 veth ----------
echo "[3] 创建 veth 对..."
ip link add veth-fw-office type veth peer name veth-office
ip link add veth-fw-guest  type veth peer name veth-guest
ip link add veth-fw-dmz    type veth peer name veth-dmz
ip link add veth-fw-inet   type veth peer name veth-inet

# ---------- 4. 将 veth 端点移入对应命名空间 ----------
echo "[4] 移动 veth 到命名空间..."
ip link set veth-fw-office netns fw
ip link set veth-office    netns office
ip link set veth-fw-guest  netns fw
ip link set veth-guest     netns guest
ip link set veth-fw-dmz    netns fw
ip link set veth-dmz       netns dmz
ip link set veth-fw-inet   netns fw
ip link set veth-inet      netns internet

# ---------- 5. 配置 IP 地址 ----------
echo "[5] 配置 IP 地址..."

# 防火墙 fw 侧
ip netns exec fw ip addr add 10.20.0.1/24    dev veth-fw-office
ip netns exec fw ip addr add 10.30.0.1/24    dev veth-fw-guest
ip netns exec fw ip addr add 10.40.0.1/24    dev veth-fw-dmz
ip netns exec fw ip addr add 203.0.113.1/24  dev veth-fw-inet

# 各区域主机侧
ip netns exec office   ip addr add 10.20.0.2/24     dev veth-office
ip netns exec guest    ip addr add 10.30.0.2/24     dev veth-guest
ip netns exec dmz      ip addr add 10.40.0.2/24     dev veth-dmz
ip netns exec internet ip addr add 203.0.113.10/24  dev veth-inet

# 启用所有命名空间的 lo 接口
echo "[5.1] 启用 loopback 接口..."
for ns in fw office guest dmz internet remote; do
    ip netns exec "$ns" ip link set lo up
done

# ---------- 6. 启用所有 veth 接口 ----------
echo "[6] 启用 veth 接口..."
ip netns exec fw      ip link set veth-fw-office up
ip netns exec office  ip link set veth-office up
ip netns exec fw      ip link set veth-fw-guest up
ip netns exec guest   ip link set veth-guest up
ip netns exec fw      ip link set veth-fw-dmz up
ip netns exec dmz     ip link set veth-dmz up
ip netns exec fw      ip link set veth-fw-inet up
ip netns exec internet ip link set veth-inet up

# ---------- 7. 配置各主机的默认路由 ----------
echo "[7] 配置路由..."
ip netns exec office   ip route add default via 10.20.0.1
ip netns exec guest    ip route add default via 10.30.0.1
ip netns exec dmz      ip route add default via 10.40.0.1
ip netns exec internet ip route add default via 203.0.113.1

# ---------- 8. 开启 fw 的 IP 转发 ----------
echo "[8] 开启 fw 的 IP 转发..."
ip netns exec fw sysctl -w net.ipv4.ip_forward=1

# ---------- 9. 自动连通性验证 ----------
echo "[9] 基础连通性测试..."

test_ping() {
    local ns="$1"
    local target="$2"
    local desc="$3"
    printf "  %-20s -> %-15s : " "$desc" "$target"
    if ip netns exec "$ns" ping -c 2 -W 2 "$target" > /dev/null 2>&1; then
        echo "✓ 通过"
    else
        echo "✗ 失败"
    fi
}

test_ping office   "10.20.0.1"   "office -> fw"
test_ping guest    "10.30.0.1"   "guest  -> fw"
test_ping dmz      "10.40.0.1"   "dmz    -> fw"
test_ping internet "203.0.113.1" "internet->fw"

echo ""
echo "=== 拓扑搭建完成！ ==="