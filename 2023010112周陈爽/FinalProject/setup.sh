#!/bin/bash
# 网络规划与基础搭建 可重复执行脚本

set -e

echo "=========================================="
echo "企业级网络安全架构 - 拓扑搭建脚本"
echo "=========================================="

# 步骤1：清理旧环境，保证脚本可重复运行
echo "清理旧环境..."

# 1.1 先删除所有namespace（自动清理内部所有接口）
echo "清理旧namespace..."
sudo ip netns del fw 2>/dev/null || true
sudo ip netns del office 2>/dev/null || true
sudo ip netns del guest 2>/dev/null || true
sudo ip netns del dmz 2>/dev/null || true
sudo ip netns del internet 2>/dev/null || true
sudo ip netns del remote 2>/dev/null || true

# 1.2 清理残留的veth设备（防止上一次运行异常中断后遗留）
echo "清理旧veth设备..."
sudo ip link del veth-fw-office 2>/dev/null || true
sudo ip link del veth-fw-guest 2>/dev/null || true
sudo ip link del veth-fw-dmz 2>/dev/null || true
sudo ip link del veth-fw-inet 2>/dev/null || true
sudo ip link del veth-fw-remote 2>/dev/null || true
sudo ip link del veth-office 2>/dev/null || true
sudo ip link del veth-guest 2>/dev/null || true
sudo ip link del veth-dmz 2>/dev/null || true
sudo ip link del veth-inet 2>/dev/null || true
sudo ip link del veth-remote 2>/dev/null || true

# 等待系统同步
sleep 1

# 步骤2：创建6个网络命名空间
echo "创建6个网络命名空间..."
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

################### office网段 10.20.0.0/24 ###################
echo "配置 office 网络..."
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

################### guest网段 10.30.0.0/24 ###################
echo "配置 guest 网络..."
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

################### dmz网段 10.40.0.0/24 ###################
echo "配置 dmz 网络..."
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

################### internet网段 203.0.113.0/24 ###################
echo "配置 internet 网络..."
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

################### remote/vpn网段 10.10.10.0/24 ###################
echo "配置 remote/VPN 网络..."
sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
sudo ip netns exec remote ip addr add 10.10.10.2/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

# 任务1.4：配置各区域默认路由，所有主机网关指向防火墙fw
echo "配置默认路由..."
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 10.10.10.1

# 防火墙开启IPv4路由转发
echo "开启IP转发..."
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

echo ""
echo "=========================================="
echo "连通性测试"
echo "=========================================="

# 任务1.5：连通性测试
echo ""
echo "===== office 连通 fw (10.20.0.1) ====="
sudo ip netns exec office ping -c 2 10.20.0.1 -W 1

echo ""
echo "===== guest 连通 fw (10.30.0.1) ====="
sudo ip netns exec guest ping -c 2 10.30.0.1 -W 1

echo ""
echo "===== dmz 连通 fw (10.40.0.1) ====="
sudo ip netns exec dmz ping -c 2 10.40.0.1 -W 1

echo ""
echo "===== internet 连通 fw (203.0.113.1) ====="
sudo ip netns exec internet ping -c 2 203.0.113.1 -W 1

echo ""
echo "===== remote 连通 fw (10.10.10.1) ====="
sudo ip netns exec remote ping -c 2 10.10.10.1 -W 1

echo ""
echo "=========================================="
echo "拓扑搭建完成！所有连通性测试通过。"
echo "=========================================="