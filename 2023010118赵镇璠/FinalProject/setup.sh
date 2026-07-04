#!/bin/bash
set -e

# 获取脚本所在目录（用于生成项目目录下的配置文件）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 清理旧环境
for ns in fw office guest dmz internet remote; do
    ip netns del $ns 2>/dev/null || true
done
sleep 0.5

# 1. 创建6个namespace并启用lo
for ns in fw office guest dmz internet remote; do
    ip netns add $ns
    ip netns exec $ns ip link set lo up
done

# 2. office veth
ip link add veth-fw-office type veth peer name veth-office
ip link set veth-fw-office netns fw
ip link set veth-office netns office
ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
ip netns exec fw ip link set veth-fw-office up
ip netns exec office ip link set veth-office up

# 3. guest veth
ip link add veth-fw-guest type veth peer name veth-guest
ip link set veth-fw-guest netns fw
ip link set veth-guest netns guest
ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
ip netns exec fw ip link set veth-fw-guest up
ip netns exec guest ip link set veth-guest up

# 4. dmz veth
ip link add veth-fw-dmz type veth peer name veth-dmz
ip link set veth-fw-dmz netns fw
ip link set veth-dmz netns dmz
ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
ip netns exec fw ip link set veth-fw-dmz up
ip netns exec dmz ip link set veth-dmz up

# 5. internet veth (fw -> internet)
ip link add veth-fw-inet type veth peer name veth-inet
ip link set veth-fw-inet netns fw
ip link set veth-inet netns internet
ip netns exec fw ip addr add 203.0.113.1/24 dev veth-fw-inet
ip netns exec fw ip link set veth-fw-inet up

# 6. remote internet veth (remote -> internet)
ip link add veth-inet-remote type veth peer name veth-remote-inet
ip link set veth-inet-remote netns internet
ip link set veth-remote-inet netns remote
ip netns exec remote ip addr add 203.0.113.20/24 dev veth-remote-inet
ip netns exec remote ip link set veth-remote-inet up

# 7. 在internet namespace中创建bridge，模拟互联网交换机
ip netns exec internet ip link add br0 type bridge
ip netns exec internet ip link set veth-inet master br0
ip netns exec internet ip link set veth-inet-remote master br0
ip netns exec internet ip addr add 203.0.113.10/24 dev br0
ip netns exec internet ip link set br0 up
ip netns exec internet ip link set veth-inet up
ip netns exec internet ip link set veth-inet-remote up

# 8. 生成WireGuard密钥对
mkdir -p /tmp/wg
ip netns exec fw wg genkey > /tmp/wg/fw.key
ip netns exec fw wg pubkey < /tmp/wg/fw.key > /tmp/wg/fw.pub
ip netns exec remote wg genkey > /tmp/wg/remote.key
ip netns exec remote wg pubkey < /tmp/wg/remote.key > /tmp/wg/remote.pub

FW_PRIVATE_KEY=$(cat /tmp/wg/fw.key)
REMOTE_PRIVATE_KEY=$(cat /tmp/wg/remote.key)
FW_PUBLIC_KEY=$(cat /tmp/wg/fw.pub)
REMOTE_PUBLIC_KEY=$(cat /tmp/wg/remote.pub)

# 9. 生成wg0.conf配置文件
mkdir -p /etc/wireguard/fw /etc/wireguard/remote

cat > /etc/wireguard/fw/wg0.conf <<EOF
[Interface]
Address = 10.10.10.1/24
PrivateKey = ${FW_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${REMOTE_PUBLIC_KEY}
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
EOF

cat > /etc/wireguard/remote/wg0.conf <<EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = ${REMOTE_PRIVATE_KEY}

[Peer]
PublicKey = ${FW_PUBLIC_KEY}
Endpoint = 203.0.113.1:51820
AllowedIPs = 10.20.0.0/24,10.40.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/fw/wg0.conf /etc/wireguard/remote/wg0.conf

# 9.1 同时生成项目目录下的提交用配置文件（带真实密钥）
cp /etc/wireguard/fw/wg0.conf "${SCRIPT_DIR}/vpn-fw.conf"
cp /etc/wireguard/remote/wg0.conf "${SCRIPT_DIR}/vpn-remote.conf"
chmod 600 "${SCRIPT_DIR}/vpn-fw.conf" "${SCRIPT_DIR}/vpn-remote.conf"

# 10. 各区域默认路由
ip netns exec office ip route add default via 10.20.0.1
ip netns exec guest ip route add default via 10.30.0.1
ip netns exec dmz ip route add default via 10.40.0.1
ip netns exec internet ip route add default via 203.0.113.1
ip netns exec remote ip route add default via 203.0.113.1

# 11. 开启IP转发
ip netns exec fw sysctl -w net.ipv4.ip_forward=1

# 12. 启动WireGuard隧道
ip netns exec fw wg-quick up /etc/wireguard/fw/wg0.conf
ip netns exec remote wg-quick up /etc/wireguard/remote/wg0.conf

echo "网络基础环境 + VPN 隧道搭建完成！"
echo "验证命令："
echo "  ip netns exec fw wg show"
echo "  ip netns exec remote wg show"
echo "  ip netns exec remote ping -c 2 10.20.0.2"
echo "  ip netns exec remote ping -c 2 10.40.0.2"
