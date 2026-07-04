#!/bin/bash

set -e

echo "========== 删除旧环境 =========="

for ns in office guest dmz internet remote fw
do
    sudo ip netns del $ns 2>/dev/null || true
done

echo "========== 创建namespace =========="

sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

echo "========== 创建Office连接 =========="

sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

echo "========== 创建Guest连接 =========="

sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest

echo "========== 创建DMZ连接 =========="

sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz

echo "========== 创建Internet连接 =========="

sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet

echo "========== 配置IP =========="

# office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office

# guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest

# dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz

# internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet

echo "========== 启动接口 =========="

sudo ip netns exec fw ip link set lo up
sudo ip netns exec office ip link set lo up
sudo ip netns exec guest ip link set lo up
sudo ip netns exec dmz ip link set lo up
sudo ip netns exec internet ip link set lo up

sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec fw ip link set veth-fw-inet up

sudo ip netns exec office ip link set veth-office up
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec internet ip link set veth-inet up

echo "========== 默认路由 =========="

sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1

echo "========== 开启IP转发 =========="

sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

echo
echo "========== 连通性测试 =========="

sudo ip netns exec office ping -c 2 10.20.0.1
sudo ip netns exec guest ping -c 2 10.30.0.1
sudo ip netns exec dmz ping -c 2 10.40.0.1
sudo ip netns exec internet ping -c 2 203.0.113.1

echo
echo "基础拓扑搭建完成。"