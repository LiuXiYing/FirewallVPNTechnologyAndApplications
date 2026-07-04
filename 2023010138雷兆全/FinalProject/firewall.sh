#!/bin/bash
set -euo pipefail

# ===================== 全局变量定义（统一修改入口）=====================
NS_NAME="fw"
FW_EXEC="sudo ip netns exec ${NS_NAME}"

# 网段规划
NET_OFFICE="10.20.0.0/24"
NET_GUEST="10.30.0.0/24"
NET_DMZ="10.40.0.0/24"
VPN_CLIENT_IP="10.10.10.2"
DMZ_WEB_SRV="10.40.0.2"

# 虚拟网卡名称
IF_OFFICE="veth-fw-office"
IF_GUEST="veth-fw-guest"
IF_DMZ="veth-fw-dmz"
IF_INET="veth-fw-inet"
IF_VPN="fw"

# 端口定义
PORT_WEB=8080
PORT_SSH=22

# 日志限流参数
LIMIT_RATE="5/min"
LIMIT_BURST=10

# ===================== 函数封装，精简重复代码 =====================
ipt_clear_rules() {
    # 清空 filter 表
    ${FW_EXEC} iptables -F
    ${FW_EXEC} iptables -X
    # 清空 nat 表
    ${FW_EXEC} iptables -t nat -F
    ${FW_EXEC} iptables -t nat -X
}

ipt_set_forward_policy() {
    ${FW_EXEC} iptables -P FORWARD "$1"
}

ipt_log_reject() {
    local in_if=$1
    local out_if=$2
    local log_prefix=$3
    local extra_match="${4:-}"

    ${FW_EXEC} iptables -A FORWARD -i "${in_if}" -o "${out_if}" ${extra_match} \
        -m limit --limit ${LIMIT_RATE} --limit-burst ${LIMIT_BURST} \
        -j LOG --log-prefix "${log_prefix}: " --log-level 4

    ${FW_EXEC} iptables -A FORWARD -i "${in_if}" -o "${out_if}" ${extra_match} -j REJECT
}

ipt_log_tcp_reset_reject() {
    local in_if=$1
    local out_if=$2
    local d_ip=$3
    local d_port=$4
    local log_prefix=$5

    ${FW_EXEC} iptables -A FORWARD -i "${in_if}" -o "${out_if}" -d "${d_ip}" -p tcp --dport ${d_port} \
        -m limit --limit ${LIMIT_RATE} --limit-burst ${LIMIT_BURST} \
        -j LOG --log-prefix "${log_prefix}: " --log-level 4

    ${FW_EXEC} iptables -A FORWARD -i "${in_if}" -o "${out_if}" -d "${d_ip}" -p tcp --dport ${d_port} \
        -j REJECT --reject-with tcp-reset
}

ipt_allow_new_conn() {
    local rule_extra="$1"
    ${FW_EXEC} iptables -A FORWARD ${rule_extra} \
        -m conntrack --ctstate NEW -j ACCEPT
}

# ===================== 主逻辑开始 =====================
echo "[Step 1] 重置命名空间 iptables 所有规则"
ipt_clear_rules
ipt_set_forward_policy ACCEPT

echo "[Step 2] 配置状态防火墙，放行已有连接"
ipt_set_forward_policy DROP
${FW_EXEC} iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "[Step 3] Office 区域访问控制策略"
# Office -> DMZ 8080 放行新建连接
ipt_allow_new_conn "-i ${IF_OFFICE} -o ${IF_DMZ} -s ${NET_OFFICE} -d ${NET_DMZ} -p tcp --dport ${PORT_WEB}"
# Office 访问外网全部放行新建
ipt_allow_new_conn "-i ${IF_OFFICE} -o ${IF_INET}"
# Office -> DMZ SSH 日志 + TCP重置拒绝
${FW_EXEC} iptables -A FORWARD -i ${IF_OFFICE} -o ${IF_DMZ} -s ${NET_OFFICE} -d ${NET_DMZ} -p tcp --dport ${PORT_SSH} \
    -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
${FW_EXEC} iptables -A FORWARD -i ${IF_OFFICE} -o ${IF_DMZ} -s ${NET_OFFICE} -d ${NET_DMZ} -p tcp --dport ${PORT_SSH} \
    -j REJECT --reject-with tcp-reset

echo "[Step 4] Guest 访客网络隔离策略"
# Guest 允许访问外网
ipt_allow_new_conn "-i ${IF_GUEST} -o ${IF_INET}"
# Guest 访问 Office 日志限流 + 拒绝
ipt_log_reject ${IF_GUEST} ${IF_OFFICE} "GUEST-TO-OFFICE"
# Guest 访问 DMZ 日志限流 + 拒绝
ipt_log_reject ${IF_GUEST} ${IF_DMZ} "GUEST-TO-DMZ"

echo "[Step 4.5] DMZ 区域访问外网放行"
ipt_allow_new_conn "-i ${IF_DMZ} -o ${IF_INET}"

echo "[Step 5] VPN 客户端远程访问控制"
# VPN 允许访问 Office 网段
ipt_allow_new_conn "-i ${IF_VPN} -o ${IF_OFFICE} -s ${VPN_CLIENT_IP} -d ${NET_OFFICE}"
# VPN 访问 DMZ 8080 放行
ipt_allow_new_conn "-i ${IF_VPN} -o ${IF_DMZ} -s ${VPN_CLIENT_IP} -d ${DMZ_WEB_SRV} -p tcp --dport ${PORT_WEB}"
# VPN 访问 DMZ SSH 日志+阻断
${FW_EXEC} iptables -A FORWARD -i ${IF_VPN} -o ${IF_DMZ} -s ${VPN_CLIENT_IP} -d ${DMZ_WEB_SRV} -p tcp --dport ${PORT_SSH} \
    -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4
${FW_EXEC} iptables -A FORWARD -i ${IF_VPN} -o ${IF_DMZ} -s ${VPN_CLIENT_IP} -d ${DMZ_WEB_SRV} -p tcp --dport ${PORT_SSH} \
    -j REJECT --reject-with tcp-reset
# VPN 其余流量默认日志+全部拒绝
${FW_EXEC} iptables -A FORWARD -i ${IF_VPN} \
    -m limit --limit ${LIMIT_RATE} --limit-burst ${LIMIT_BURST} \
    -j LOG --log-prefix "VPN-DENY: " --log-level 4
${FW_EXEC} iptables -A FORWARD -i ${IF_VPN} -j REJECT

echo "[Step 6] SNAT 上网 + 外网 DNAT 端口映射配置"
# 三个内网网段 MASQUERADE 上网
${FW_EXEC} iptables -t nat -A POSTROUTING -s ${NET_OFFICE} -o ${IF_INET} -j MASQUERADE
${FW_EXEC} iptables -t nat -A POSTROUTING -s ${NET_GUEST} -o ${IF_INET} -j MASQUERADE
${FW_EXEC} iptables -t nat -A POSTROUTING -s ${NET_DMZ} -o ${IF_INET} -j MASQUERADE
# 外网入站 DNAT 8080 转到 DMZ 服务器
${FW_EXEC} iptables -t nat -A PREROUTING -i ${IF_INET} -p tcp --dport ${PORT_WEB} \
    -j DNAT --to-destination ${DMZ_WEB_SRV}:${PORT_WEB}
# 放行 DNAT 对应的转发流量
ipt_allow_new_conn "-i ${IF_INET} -o ${IF_DMZ} -d ${DMZ_WEB_SRV} -p tcp --dport ${PORT_WEB}"

echo "[Step 7] 拦截外网主动访问内网各区域"
# 外网访问 Office
ipt_log_reject ${IF_INET} ${IF_OFFICE} "INET-TO-OFFICE"
# 外网访问 Guest
ipt_log_reject ${IF_INET} ${IF_GUEST} "INET-TO-GUEST"
# 外网访问 DMZ SSH 单独日志+TCP重置拒绝
ipt_log_tcp_reset_reject ${IF_INET} ${IF_DMZ} ${DMZ_WEB_SRV} ${PORT_SSH} "INET-TO-DMZ-SSH"

echo -e "\n==================== 防火墙规则加载完成 ===================="
echo "---------------- FORWARD 转发规则 ----------------"
${FW_EXEC} iptables -L FORWARD -n -v --line-numbers
echo -e "\n---------------- NAT 地址转换规则 ----------------"
${FW_EXEC} iptables -t nat -L -n -v --line-numbers