#!/bin/bash
# 实验第一部分拓扑搭建脚本 setup.sh

# ====================== 前置清理 ======================
sudo ip netns del fw 2>/dev/null
sudo ip netns del office 2>/dev/null
sudo ip netns del guest 2>/dev/null
sudo ip netns del dmz 2>/dev/null
sudo ip netns del internet 2>/dev/null
sudo ip netns del remote 2>/dev/null
sudo ip link del veth-fw-office 2>/dev/null
sudo ip link del veth-office 2>/dev/null
sudo ip link del veth-fw-guest 2>/dev/null
sudo ip link del veth-guest 2>/dev/null
sudo ip link del veth-fw-dmz 2>/dev/null
sudo ip link del veth-dmz 2>/dev/null
sudo ip link del veth-fw-inet 2>/dev/null
sudo ip link del veth-inet 2>/dev/null
sudo ip link del veth-fw-vpn 2>/dev/null
sudo ip link del veth-vpn 2>/dev/null

# ====================== 创建namespace ======================
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# ====================== veth配对配置 ======================
# office区域
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest访客网veth完整配置
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# dmz服务区veth完整配置
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# internet模拟外网veth完整配置
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# remote远程VPN客户端veth完整配置
sudo ip link add veth-fw-vpn type veth peer name veth-vpn
sudo ip link set veth-fw-vpn netns fw
sudo ip link set veth-vpn netns remote
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev veth-fw-vpn
sudo ip netns exec fw ip link set veth-fw-vpn up
sudo ip netns exec remote ip addr add 10.10.10.2/24 dev veth-vpn
sudo ip netns exec remote ip link set veth-vpn up
sudo ip netns exec remote ip link set lo up

# ====================== 路由&IP转发 ======================
# 各区域主机默认路由
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
# 外网、远程主机补充默认路由
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 10.10.10.1
# 开启防火墙IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

# ====================== 连通性测试 ======================
echo "==========1. office ping 网关fw=========="
sudo ip netns exec office ping -c 3 10.20.0.1
echo "==========2. guest ping 网关fw=========="
sudo ip netns exec guest ping -c 3 10.30.0.1
echo "==========3. dmz ping 网关fw=========="
sudo ip netns exec dmz ping -c 3 10.40.0.1
echo "==========4. internet ping 网关fw=========="
sudo ip netns exec internet ping -c 3 203.0.113.1
echo "==========5. remote ping 网关fw=========="
sudo ip netns exec remote ping -c 3 10.10.10.1
echo "拓扑搭建+连通测试全部完成"
