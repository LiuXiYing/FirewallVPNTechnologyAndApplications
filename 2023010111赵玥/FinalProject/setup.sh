#!/bin/bash

echo "========== 第一部分：网络规划与基础搭建（修复版）=========="

echo "[1/5] 清理旧环境..."
# 先删网桥，避免其上挂接的 veth 造成 Device or resource busy
sudo ip link del br-inet 2>/dev/null || true
# 删除命名空间（veth 对会级联删除）
for ns in fw office guest dmz internet remote; do
  sudo ip netns del $ns 2>/dev/null || true
done
# 清理可能残留的 veth 接口，保证脚本可重复运行
for iface in v-fw-off v-off v-fw-gst v-gst v-fw-dmz v-dmz v-fw-inet v-inet v-rem v-fw-bridge v-inet-bridge v-rem-bridge; do
  sudo ip link del $iface 2>/dev/null || true
done
sudo rm -f fw.key fw.pub remote.key remote.pub 2>/dev/null

echo "[2/5] 创建6个namespace..."
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote

echo "[3/5] 创建br-inet网桥..."
sudo ip link add br-inet type bridge
sudo ip link set br-inet up

echo "[4/5] 创建veth对并配置（短接口名，避免15字符限制）..."

# --- office ---
sudo ip link add v-fw-off type veth peer name v-off
sudo ip link set v-fw-off netns fw
sudo ip link set v-off netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev v-fw-off
sudo ip netns exec fw ip link set v-fw-off up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev v-off
sudo ip netns exec office ip link set v-off up
sudo ip netns exec office ip link set lo up

# --- guest ---
sudo ip link add v-fw-gst type veth peer name v-gst
sudo ip link set v-fw-gst netns fw
sudo ip link set v-gst netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev v-fw-gst
sudo ip netns exec fw ip link set v-fw-gst up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev v-gst
sudo ip netns exec guest ip link set v-gst up
sudo ip netns exec guest ip link set lo up

# --- dmz ---
sudo ip link add v-fw-dmz type veth peer name v-dmz
sudo ip link set v-fw-dmz netns fw
sudo ip link set v-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev v-fw-dmz
sudo ip netns exec fw ip link set v-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev v-dmz
sudo ip netns exec dmz ip link set v-dmz up
sudo ip netns exec dmz ip link set lo up

# --- fw internet（通过网桥）---
sudo ip link add v-fw-inet type veth peer name v-fw-bridge
sudo ip link set v-fw-inet netns fw
sudo ip link set v-fw-bridge master br-inet
sudo ip link set v-fw-bridge up
sudo ip netns exec fw ip addr add 203.0.113.1/24 dev v-fw-inet
sudo ip netns exec fw ip link set v-fw-inet up
sudo ip netns exec fw ip link set lo up

# --- internet（通过网桥）---
sudo ip link add v-inet type veth peer name v-inet-bridge
sudo ip link set v-inet netns internet
sudo ip link set v-inet-bridge master br-inet
sudo ip link set v-inet-bridge up
sudo ip netns exec internet ip addr add 203.0.113.10/24 dev v-inet
sudo ip netns exec internet ip link set v-inet up
sudo ip netns exec internet ip link set lo up

# --- remote（通过网桥）---
sudo ip link add v-rem type veth peer name v-rem-bridge
sudo ip link set v-rem netns remote
sudo ip link set v-rem-bridge master br-inet
sudo ip link set v-rem-bridge up
sudo ip netns exec remote ip addr add 203.0.113.20/24 dev v-rem
sudo ip netns exec remote ip link set v-rem up
sudo ip netns exec remote ip link set lo up

echo "[5/5] 配置路由和IP转发..."
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1
sudo ip netns exec internet ip route add default via 203.0.113.1
sudo ip netns exec remote ip route add default via 203.0.113.1
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1

echo ""
echo "=== 验证连通性 ==="
echo "--- office ping fw ---"
sudo ip netns exec office ping -c 2 10.20.0.1
echo "--- guest ping fw ---"
sudo ip netns exec guest ping -c 2 10.30.0.1
echo "--- dmz ping fw ---"
sudo ip netns exec dmz ping -c 2 10.40.0.1
echo "--- internet ping fw ---"
sudo ip netns exec internet ping -c 2 203.0.113.1
echo "--- remote ping fw ---"
sudo ip netns exec remote ping -c 2 203.0.113.1

echo ""
echo "[Bonus] 在 dmz 启动测试服务（8080 / 22 占位）..."
# 仅作为占位进程，验证 DNAT 路径；实际服务由 dmz 上手动启动
sudo ip netns exec dmz bash -c 'nohup python3 -m http.server 8080 >/tmp/dmz-8080.log 2>&1 &'
sudo ip netns exec dmz bash -c 'nohup python3 -m http.server 22   >/tmp/dmz-22.log   2>&1 &'

echo ""
echo "[Bonus] 生成 WireGuard 密钥对（fw / remote）..."
umask 077
[ -f fw.key ]     || wg genkey | tee fw.key     | wg pubkey > fw.pub
[ -f remote.key ] || wg genkey | tee remote.key | wg pubkey > remote.pub
chmod 600 fw.key fw.pub remote.key remote.pub
echo "fw.key     = $(cat fw.key)"
echo "remote.key = $(cat remote.key)"

echo ""
echo "========== 第一部分完成！=========="
echo "接口名（fw侧）：v-fw-off, v-fw-gst, v-fw-dmz, v-fw-inet"
echo "接口名（remote侧）：v-rem"
echo "提示：将 fw.key 填入 vpn-fw.conf 的 PrivateKey，"
echo "      将 remote.pub 填入 vpn-fw.conf 的 PublicKey；"
echo "      将 remote.key 填入 vpn-remote.conf 的 PrivateKey，"
echo "      将 fw.pub 填入 vpn-remote.conf 的 PublicKey。"
