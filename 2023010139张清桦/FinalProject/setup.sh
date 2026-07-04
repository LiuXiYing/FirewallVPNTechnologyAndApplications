#!/bin/bash
# 企业网络安全架构 - 拓扑搭建脚本
# 作者：你的学号姓名
# 日期：2026-06-30

set -e  # 遇到错误立即退出

echo "=== 开始清理旧环境 ==="
# 清理已有的namespace（确保可重复运行）
for ns in fw office guest dmz internet remote; do
    sudo ip netns delete $ns 2>/dev/null || true
done

echo "=== 创建6个namespace ==="
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

echo "=== 创建veth对并配置IP ==="

# 1. office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# 2. guest连接
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# 3. dmz连接
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# 4. internet连接
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# 5. remote连接（用于VPN，先创建物理连接）
sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote
sudo ip netns exec fw ip addr add 192.0.2.1/24 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
sudo ip netns exec remote ip addr add 192.0.2.2/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

echo "=== 配置路由 ==="
# 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 192.0.2.1

# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

echo "=== 拓扑搭建完成 ==="
echo "可用以下命令验证连通性："
echo "  sudo ip netns exec office ping -c 2 10.20.0.1"
echo "  sudo ip netns exec guest ping -c 2 10.30.0.1"
echo "  sudo ip netns exec dmz ping -c 2 10.40.0.1"
echo "  sudo ip netns exec internet ping -c 2 203.0.113.1"
