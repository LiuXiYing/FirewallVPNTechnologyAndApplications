#!/bin/bash
set -euo pipefail
clean_env() {
    local ns_list=("fw" "office" "guest" "dmz" "internet" "remote")
    local veth_list=("veth-fw-office" "veth-fw-guest" "veth-fw-dmz" "veth-fw-inet")
    for ns in "${ns_list[@]}"; do
        sudo ip netns del "${ns}" 2>/dev/null || true
    done
    for dev in "${veth_list[@]}"; do
        sudo ip link del "${dev}" 2>/dev/null || true
    done
    echo "旧网络环境清理完毕"
}

# 执行前置清理
clean_env

# 任务1.1：创建6个namespace
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# 任务1.2：office连接
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
# 配置IP地址
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# dmz
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

# 补齐internet外网
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

# 任务1.3：配置路由和IP转发
# 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec internet ip route add default via 203.0.113.1

# 任务1.4：验证基础连通性
echo "===== 连通性测试开始 ====="
# office应该能ping通fw
sudo ip netns exec office ping -c 2 10.20.0.1
# guest应该能ping通fw
sudo ip netns exec guest ping -c 2 10.30.0.1
# dmz应该能ping通fw
sudo ip netns exec dmz ping -c 2 10.40.0.1
# internet应该能ping通fw
sudo ip netns exec internet ping -c 2 203.0.113.1
echo "===== 拓扑搭建全部完成 ====="