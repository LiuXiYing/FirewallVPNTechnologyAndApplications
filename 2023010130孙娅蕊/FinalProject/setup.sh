#!/bin/bash
# 企业安全网络 第一部分拓扑搭建脚本 setup.sh
# 先清理旧环境（防止重复运行报错）
echo "=== 清理旧网络命名空间 ==="
sudo ip netns del fw 2>/dev/null
sudo ip netns del office 2>/dev/null
sudo ip netns del guest 2>/dev/null
sudo ip netns del dmz 2>/dev/null
sudo ip netns del internet 2>/dev/null
sudo ip netns del remote 2>/dev/null

# 1. 创建6个namespace
echo "=== 创建网络命名空间 ==="
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# 2. 创建office veth
echo "=== 配置office网段 ==="
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# 3. 创建guest veth
echo "=== 配置guest网段 ==="
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# 4. 创建dmz veth
echo "=== 配置DMZ网段 ==="
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# 5. 创建internet外网veth
echo "=== 配置internet外网网段 ==="
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# 6. 配置默认路由
echo "=== 配置各主机默认网关 ==="
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1

# 7. fw开启IP转发
echo "=== 开启防火墙IP转发 ==="
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

echo "===== 拓扑搭建完成，开始连通性测试 ====="
# 连通性测试
echo "1. office ping fw"
sudo ip netns exec office ping -c2 10.20.0.1
echo "2. guest ping fw"
sudo ip netns exec guest ping -c2 10.30.0.1
echo "3. dmz ping fw"
sudo ip netns exec dmz ping -c2 10.40.0.1
echo "4. internet ping fw"
sudo ip netns exec internet ping -c2 203.0.113.1
echo "===== 第一部分搭建结束 ====="
