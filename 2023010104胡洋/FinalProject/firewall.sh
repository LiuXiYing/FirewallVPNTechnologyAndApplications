#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 sudo 运行：sudo bash $0" >&2
  exit 1
fi

# 简化重复命令
FW="ip netns exec fw iptables"

# ========== 清空旧规则，支持重复执行 ==========
$FW -F
$FW -t nat -F
$FW -X || true
$FW -t nat -X || true

# 默认策略：INPUT/OUTPUT放行方便调试，FORWARD全局拒绝（最小权限）
$FW -P INPUT ACCEPT
$FW -P OUTPUT ACCEPT
$FW -P FORWARD DROP

# ========== 1. 状态检测：允许回程/关联流量（必须放在最前） ==========
$FW -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ========== 2. Office办公区访问控制 ==========
# 允许office访问DMZ 8080 Web服务
$FW -A FORWARD -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# 禁止office SSH连接DMZ，先记录日志再拒绝
$FW -A FORWARD -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
$FW -A FORWARD -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 -j REJECT --reject-with tcp-reset

# 允许办公网访问外网
$FW -A FORWARD -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== 3. Guest访客区隔离策略 ==========
# 访客访问办公网：日志+拒绝
$FW -A FORWARD -i veth-fw-guest -o veth-fw-office \
  -s 10.30.0.0/24 -d 10.20.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
$FW -A FORWARD -i veth-fw-guest -o veth-fw-office \
  -s 10.30.0.0/24 -d 10.20.0.0/24 -j REJECT

# 访客访问DMZ：日志+拒绝
$FW -A FORWARD -i veth-fw-guest -o veth-fw-dmz \
  -s 10.30.0.0/24 -d 10.40.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
$FW -A FORWARD -i veth-fw-guest -o veth-fw-dmz \
  -s 10.30.0.0/24 -d 10.40.0.0/24 -j REJECT

# 访客仅允许访问互联网
$FW -A FORWARD -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== 4. DMZ服务器区策略 ==========
# DMZ可主动访问外网用于系统更新
$FW -A FORWARD -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== 5. VPN远程员工访问控制 ==========
# VPN允许访问办公网段
$FW -A FORWARD -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW -j ACCEPT

# VPN允许访问DMZ 8080网站
$FW -A FORWARD -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# VPN禁止访问DMZ 22端口SSH，记录日志
$FW -A FORWARD -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4
$FW -A FORWARD -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 -j REJECT --reject-with tcp-reset

# 【优化新增】禁止VPN客户端访问互联网，违规打日志
$FW -A FORWARD -i wg0 -o veth-fw-inet \
  -s 10.10.10.2 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-TO-INTERNET: " --log-level 4
$FW -A FORWARD -i wg0 -o veth-fw-inet -s 10.10.10.2 -j REJECT

# VPN其余所有未授权流量统一拦截并限流日志
$FW -A FORWARD -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: " --log-level 4
$FW -A FORWARD -i wg0 -j REJECT

# ========== 6. 外网Internet入站访问控制 ==========
# 放行DNAT后的外网访问DMZ 8080
$FW -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW -j ACCEPT

# 外网禁止SSH连接DMZ
$FW -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4
$FW -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 22 -j REJECT --reject-with tcp-reset

# 外网禁止访问办公内网
$FW -A FORWARD -i veth-fw-inet -o veth-fw-office \
  -d 10.20.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
$FW -A FORWARD -i veth-fw-inet -o veth-fw-office \
  -d 10.20.0.0/24 -j REJECT

# 外网禁止访问访客网段
$FW -A FORWARD -i veth-fw-inet -o veth-fw-guest \
  -d 10.30.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4
$FW -A FORWARD -i veth-fw-inet -o veth-fw-guest \
  -d 10.30.0.0/24 -j REJECT

# ========== 7. NAT地址转换规则 ==========
# 7.1 SNAT：内网、访客、DMZ访问互联网自动伪装公网地址
$FW -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# 7.2 DNAT：外网访问防火墙公网8080端口，转发至DMZ 10.40.0.2:8080
$FW -t nat -A PREROUTING -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# ========== 执行完成提示 ==========
cat <<'MSG'
[OK] 防火墙与NAT规则已全部加载完成。
查看转发过滤规则：
  sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
查看SNAT/DNAT转换规则:
  sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
MSG