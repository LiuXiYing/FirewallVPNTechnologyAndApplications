#!/bin/bash
set -e  # 出错即退出

# 清理旧环境
for ns in fw office guest dmz internet remote; do
    sudo ip netns del $ns 2>/dev/null
done

# 删除旧veth对
for veth in veth-fw-office veth-office veth-fw-guest veth-guest veth-fw-dmz veth-dmz veth-fw-inet veth-inet; do
    sudo ip link del $veth 2>/dev/null
done

# 创建namespace
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

# 配置office ↔ fw
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip link set lo up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up
sudo ip netns exec office ip route add default via 10.20.0.1

# 配置guest ↔ fw
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up
sudo ip netns exec guest ip route add default via 10.30.0.1

# 配置dmz ↔ fw
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up
sudo ip netns exec dmz ip route add default via 10.40.0.1

# 配置internet ↔ fw
sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up
sudo ip netns exec internet ip route add default via 203.0.113.1

# 开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo ip netns exec fw sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null

echo "=== 拓扑搭建完成 ==="
sudo ip netns list
echo "=== 验证连通性 ==="
sudo ip netns exec office ping -c 1 10.20.0.1 >/dev/null && echo "office ↔ fw: OK" || echo "office ↔ fw: FAIL"
sudo ip netns exec guest ping -c 1 10.30.0.1 >/dev/null && echo "guest ↔ fw: OK" || echo "guest ↔ fw: FAIL"
sudo ip netns exec dmz ping -c 1 10.40.0.1 >/dev/null && echo "dmz ↔ fw: OK" || echo "dmz ↔ fw: FAIL"
sudo ip netns exec internet ping -c 1 203.0.113.1 >/dev/null && echo "internet ↔ fw: OK" || echo "internet ↔ fw: FAIL"