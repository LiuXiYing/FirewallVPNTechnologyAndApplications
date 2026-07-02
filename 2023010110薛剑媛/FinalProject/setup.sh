#!/bin/bash
# 企业网络安全架构 - 网络基础搭建脚本

set -e

echo "========================================="
echo "开始搭建企业网络安全架构网络拓扑..."
echo "========================================="

# 清理旧命名空间
echo "1. 清理旧命名空间..."
sudo ip netns del fw 2>/dev/null || true
sudo ip netns del office 2>/dev/null || true
sudo ip netns del guest 2>/dev/null || true
sudo ip netns del dmz 2>/dev/null || true
sudo ip netns del internet 2>/dev/null || true
sudo ip netns del remote 2>/dev/null || true
echo "   ✓ 清理完成"

# 创建6个命名空间
echo "2. 创建6个命名空间..."
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
echo "   ✓ 命名空间创建完成"

# office连接
echo "3. 配置office区域 (10.20.0.0/24)..."
sudo ip link add fw-office type veth peer name office
sudo ip link set fw-office netns fw
sudo ip link set office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev fw-office
sudo ip netns exec fw ip link set fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev office
sudo ip netns exec office ip link set office up
sudo ip netns exec office ip link set lo up
echo "   ✓ office配置完成"

# guest连接
echo "4. 配置guest区域 (10.30.0.0/24)..."
sudo ip link add fw-guest type veth peer name guest
sudo ip link set fw-guest netns fw
sudo ip link set guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev fw-guest
sudo ip netns exec fw ip link set fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev guest
sudo ip netns exec guest ip link set guest up
sudo ip netns exec guest ip link set lo up
echo "   ✓ guest配置完成"

# dmz连接
echo "5. 配置dmz区域 (10.40.0.0/24)..."
sudo ip link add fw-dmz type veth peer name dmz
sudo ip link set fw-dmz netns fw
sudo ip link set dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev fw-dmz
sudo ip netns exec fw ip link set fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev dmz
sudo ip netns exec dmz ip link set dmz up
sudo ip netns exec dmz ip link set lo up
echo "   ✓ dmz配置完成"

# internet连接
echo "6. 配置internet区域 (203.0.113.0/24)..."
sudo ip link add fw-inet type veth peer name inet
sudo ip link set fw-inet netns fw
sudo ip link set inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev fw-inet
sudo ip netns exec fw ip link set fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev inet
sudo ip netns exec internet ip link set inet up
sudo ip netns exec internet ip link set lo up
echo "   ✓ internet配置完成"

# vpn管理网络 (192.168.200.0/24)
echo "7. 配置vpn管理网络 (192.168.200.0/24)..."
sudo ip link add fw-vpn type veth peer name remote
sudo ip link set fw-vpn netns fw
sudo ip link set remote netns remote
sudo ip netns exec fw ip addr add 192.168.200.1/24 dev fw-vpn
sudo ip netns exec fw ip link set fw-vpn up
sudo ip netns exec remote ip addr add 192.168.200.2/24 dev remote
sudo ip netns exec remote ip link set remote up
sudo ip netns exec remote ip link set lo up
echo "   ✓ vpn管理网络配置完成"

# 各区域主机的默认路由指向fw
echo "8. 配置默认路由..."
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 192.168.200.1
echo "   ✓ 路由配置完成"

# fw开启IP转发
echo "9. 开启IP转发..."
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "   ✓ IP转发已开启"

echo "========================================="
echo "✓ 网络拓扑搭建完成！"
echo "========================================="
echo ""
echo "地址规划："
echo "  office  : 10.20.0.0/24  (fw:10.20.0.1, 主机:10.20.0.2)"
echo "  guest   : 10.30.0.0/24  (fw:10.30.0.1, 主机:10.30.0.2)"
echo "  dmz     : 10.40.0.0/24  (fw:10.40.0.1, 主机:10.40.0.2)"
echo "  internet: 203.0.113.0/24 (fw:203.0.113.1, 主机:203.0.113.10)"
echo "  vpn管理 : 192.168.200.0/24 (fw:192.168.200.1, 主机:192.168.200.2)"
echo ""
echo "接口名称："
echo "  fw-office ↔ office"
echo "  fw-guest  ↔ guest"
echo "  fw-dmz    ↔ dmz"
echo "  fw-inet   ↔ inet"
echo "  fw-vpn    ↔ remote"
echo ""

# 连通性测试
echo "========================================="
echo "开始连通性测试..."
echo "========================================="

echo -n "测试1: office → fw (10.20.0.1) ... "
if sudo ip netns exec office ping -c 2 10.20.0.1 &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

echo -n "测试2: guest → fw (10.30.0.1) ... "
if sudo ip netns exec guest ping -c 2 10.30.0.1 &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

echo -n "测试3: dmz → fw (10.40.0.1) ... "
if sudo ip netns exec dmz ping -c 2 10.40.0.1 &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

echo -n "测试4: internet → fw (203.0.113.1) ... "
if sudo ip netns exec internet ping -c 2 203.0.113.1 &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

echo -n "测试5: remote → fw管理 (192.168.200.1) ... "
if sudo ip netns exec remote ping -c 2 192.168.200.1 &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

echo "========================================="
echo "✓ 连通性测试完成！"
echo "========================================="
