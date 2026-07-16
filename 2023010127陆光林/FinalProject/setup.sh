#!/bin/bash
# 企业级网络安全架构 - 拓扑搭建脚本
# Kali Linux 适配版

set -e

cleanup() {
    sudo ip -all netns delete 2>/dev/null || true
    sudo pkill -f "http.server" 2>/dev/null || true
    sudo rm -f /tmp/*.key /tmp/*.pub /tmp/*-wg0.conf
}

if [ "$1" == "clean" ]; then
    cleanup
    exit 0
fi

cleanup

# 创建 namespace
for ns in fw office guest dmz internet remote; do
    sudo ip netns add $ns
done

# 创建 veth 对
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office

sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest

sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz

sudo ip link add veth-fw-inet type veth peer name veth-inet
sudo ip link set veth-fw-inet netns fw
sudo ip link set veth-inet netns internet

sudo ip link add veth-fw-remote type veth peer name veth-remote
sudo ip link set veth-fw-remote netns fw
sudo ip link set veth-remote netns remote

# 配置 IP
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
sudo ip netns exec fw ip link set veth-fw-inet up
sudo ip netns exec fw ip addr add 192.0.2.1/24 dev veth-fw-remote
sudo ip netns exec fw ip link set veth-fw-remote up
sudo ip netns exec fw ip link set lo up

sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
sudo ip netns exec dmz ip link set lo up

sudo ip netns exec internet ip addr add 203.0.113.10/24 dev veth-inet
sudo ip netns exec internet ip link set veth-inet up
sudo ip netns exec internet ip link set lo up

sudo ip netns exec remote ip addr add 192.0.2.2/24 dev veth-remote
sudo ip netns exec remote ip link set veth-remote up
sudo ip netns exec remote ip link set lo up

# 配置路由
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 192.0.2.1

# 开启 IP 转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo ip netns exec fw sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null

# 生成 WireGuard 密钥
cd /tmp
umask 077
wg genkey | tee fw.key | wg pubkey > fw.pub
wg genkey | tee remote.key | wg pubkey > remote.pub

FW_PRIV=$(cat fw.key)
REMOTE_PUB=$(cat remote.pub)

# 手动创建 WireGuard 接口（避免 wg-quick 在 namespace 中的问题）
sudo ip netns exec fw ip link add wg0 type wireguard
sudo ip netns exec fw wg set wg0 private-key /tmp/fw.key listen-port 51820
sudo ip netns exec fw wg set wg0 peer $REMOTE_PUB allowed-ips 10.10.10.2/32 persistent-keepalive 25
sudo ip netns exec fw ip addr add 10.10.10.1/24 dev wg0
sudo ip netns exec fw ip link set wg0 up
sudo ip netns exec fw ip route add 10.10.10.0/24 dev wg0 2>/dev/null || true

REMOTE_PRIV=$(cat remote.key)
FW_PUB=$(cat fw.pub)

sudo ip netns exec remote ip link add wg0 type wireguard
sudo ip netns exec remote wg set wg0 private-key /tmp/remote.key
sudo ip netns exec remote wg set wg0 peer $FW_PUB endpoint 192.0.2.1:51820 allowed-ips 10.20.0.0/24,10.40.0.0/24 persistent-keepalive 25
sudo ip netns exec remote ip addr add 10.10.10.2/24 dev wg0
sudo ip netns exec remote ip link set wg0 up
sudo ip netns exec remote ip route add 10.20.0.0/24 dev wg0 2>/dev/null || true
sudo ip netns exec remote ip route add 10.40.0.0/24 dev wg0 2>/dev/null || true

echo "[+] 拓扑搭建完成！"
echo "    接下来执行: sudo bash firewall.sh"