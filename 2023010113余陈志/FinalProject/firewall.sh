
set -euo pipefail

FW_NS="fw"
FW_CMD="sudo ip netns exec ${FW_NS}"

# 网段定义
NET_OFFICE="10.20.0.0/24"
NET_GUEST="10.30.0.0/24"
NET_DMZ="10.40.0.0/24"
IP_DMZ_SERVER="10.40.0.2"
NET_INET_OUT="203.0.113.0/24"
VPN_CLIENT_IP="10.10.10.2"

# veth网卡
IF_OFFICE="veth-fw-office"
IF_GUEST="veth-fw-guest"
IF_DMZ="veth-fw-dmz"
IF_INET="veth-fw-inet"
IF_VPN="veth-fw-remote"

# 业务端口
PORT_WEB="8080"
PORT_SSH="22"

# 限流日志参数
LIMIT_RATE="5/min"
LIMIT_BURST="10"

# ===================== 工具函数封装 =====================
# 清空所有iptables表
clean_iptables() {
    echo ">> 清空filter与nat表原有规则、自定义链"
    ${FW_CMD} iptables -F
    ${FW_CMD} iptables -t nat -F
    ${FW_CMD} iptables -X
    ${FW_CMD} iptables -t nat -X
    # 默认临时放行，后续统一收紧策略
    ${FW_CMD} iptables -P FORWARD ACCEPT
}

# 基础连接跟踪放行（已有连接/关联连接）
allow_established() {
    echo ">> 配置状态检测放行规则"
    ${FW_CMD} iptables -P FORWARD DROP
    ${FW_CMD} iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

# 通用：匹配流量 日志+拒绝
log_and_reject() {
    local in_if="$1"
    local out_if="$2"
    local log_tag="$3"
    local extra_filter="$4"
    local reject_opt="${5:-}"

    local rule_base="-A FORWARD -i ${in_if} -o ${out_if} ${extra_filter}"
    # 限流日志
    ${FW_CMD} iptables ${rule_base} \
        -m limit --limit ${LIMIT_RATE} --limit-burst ${LIMIT_BURST} \
        -j LOG --log-prefix "[${log_tag}] " --log-level 4
    # 拒绝丢弃
    if [[ -n "${reject_opt}" ]]; then
        ${FW_CMD} iptables ${rule_base} -j REJECT ${reject_opt}
    else
        ${FW_CMD} iptables ${rule_base} -j REJECT
    fi
}

# 通用：允许新建TCP端口流量
allow_new_tcp_port() {
    local in_if="$1"
    local out_if="$2"
    local src_net="$3"
    local dst_net="$4"
    local dport="$5"
    ${FW_CMD} iptables -A FORWARD -i ${in_if} -o ${out_if} \
        -s ${src_net} -d ${dst_net} -p tcp --dport ${dport} \
        -m conntrack --ctstate NEW -j ACCEPT
}

# 网段SNAT伪装出外网
add_snat_masq() {
    local src_subnet="$1"
    ${FW_CMD} iptables -t nat -A POSTROUTING -s ${src_subnet} -o ${IF_INET} -j MASQUERADE
}

# 外网DNAT映射内网服务器端口
add_dnat_port() {
    local ext_port="$1"
    local dst_ip="$2"
    local dst_port="$3"
    ${FW_CMD} iptables -t nat -A PREROUTING -i ${IF_INET} -p tcp --dport ${ext_port} \
        -j DNAT --to-destination ${dst_ip}:${dst_port}
}


rule_office_zone() {
    echo "[阶段1] Office区域访问控制策略"
    # Office访问DMZ 8080放行
    allow_new_tcp_port "${IF_OFFICE}" "${IF_DMZ}" "${NET_OFFICE}" "${NET_DMZ}" "${PORT_WEB}"
    # Office直连外网全部放行
    ${FW_CMD} iptables -A FORWARD -i ${IF_OFFICE} -o ${IF_INET} -m conntrack --ctstate NEW -j ACCEPT
    # Office访问DMZ SSH日志+阻断
    log_and_reject "${IF_OFFICE}" "${IF_DMZ}" "OFFICE_DMZ_SSH" \
        "-s ${NET_OFFICE} -d ${NET_DMZ} -p tcp --dport ${PORT_SSH}" \
        "--reject-with tcp-reset"
}

rule_guest_zone() {
    echo "[阶段2] Guest访客隔离策略"
    # Guest仅允许访问外网
    ${FW_CMD} iptables -A FORWARD -i ${IF_GUEST} -o ${IF_INET} -m conntrack --ctstate NEW -j ACCEPT
    # Guest访问Office 日志拦截
    log_and_reject "${IF_GUEST}" "${IF_OFFICE}" "GUEST_TO_OFFICE" ""
    # Guest访问DMZ 日志拦截
    log_and_reject "${IF_GUEST}" "${IF_DMZ}" "GUEST_TO_DMZ" ""
}

rule_dmz_out() {
    echo "[阶段3] DMZ访问外网放行"
    ${FW_CMD} iptables -A FORWARD -i ${IF_DMZ} -o ${IF_INET} -m conntrack --ctstate NEW -j ACCEPT
}

rule_vpn_remote() {
    echo "[阶段4] VPN远程客户端权限控制"
    # VPN访问Office全通
    ${FW_CMD} iptables -A FORWARD -i ${IF_VPN} -o ${IF_OFFICE} \
        -s ${VPN_CLIENT_IP} -d ${NET_OFFICE} -m conntrack --ctstate NEW -j ACCEPT
    # VPN访问DMZ 8080放行
    ${FW_CMD} iptables -A FORWARD -i ${IF_VPN} -o ${IF_DMZ} \
        -s ${VPN_CLIENT_IP} -d ${IP_DMZ_SERVER} -p tcp --dport ${PORT_WEB} -m conntrack --ctstate NEW -j ACCEPT
    # VPN访问DMZ SSH拦截
    log_and_reject "${IF_VPN}" "${IF_DMZ}" "VPN_DMZ_SSH" \
        "-s ${VPN_CLIENT_IP} -d ${IP_DMZ_SERVER} -p tcp --dport ${PORT_SSH}" \
        "--reject-with tcp-reset"
    # VPN其余未匹配流量统一日志拦截
    ${FW_CMD} iptables -A FORWARD -i ${IF_VPN} \
        -m limit --limit ${LIMIT_RATE} --limit-burst ${LIMIT_BURST} \
        -j LOG --log-prefix "[VPN_DENY_OTHER] " --log-level 4
    ${FW_CMD} iptables -A FORWARD -i ${IF_VPN} -j REJECT
}

rule_nat_translate() {
    echo "[阶段5] SNAT外网出口 + DNAT端口映射"
    # 三个内网段SNAT伪装
    add_snat_masq "${NET_OFFICE}"
    add_snat_masq "${NET_GUEST}"
    add_snat_masq "${NET_DMZ}"
    # 外网8080映射DMZ服务器
    add_dnat_port "${PORT_WEB}" "${IP_DMZ_SERVER}" "${PORT_WEB}"
    # DNAT配套放行转发
    ${FW_CMD} iptables -A FORWARD -i ${IF_INET} -o ${IF_DMZ} \
        -d ${IP_DMZ_SERVER} -p tcp --dport ${PORT_WEB} -m conntrack --ctstate NEW -j ACCEPT
}

rule_inet_deny_internal() {
    echo "[阶段6] 拦截外网主动访问内网业务区"
    # 外网访问Office拦截
    log_and_reject "${IF_INET}" "${IF_OFFICE}" "INET_BLOCK_OFFICE" ""
    # 外网访问Guest拦截
    log_and_reject "${IF_INET}" "${IF_GUEST}" "INET_BLOCK_GUEST" ""
    # 外网访问DMZ SSH拦截
    log_and_reject "${IF_INET}" "${IF_DMZ}" "INET_DMZ_SSH_BLOCK" \
        "-d ${IP_DMZ_SERVER} -p tcp --dport ${PORT_SSH}" \
        "--reject-with tcp-reset"
}

# ===================== 主执行入口 =====================
main() {
    echo "==================== 开始加载fw命名空间防火墙规则 ===================="
    clean_iptables
    allow_established

    rule_office_zone
    rule_guest_zone
    rule_dmz_out
    rule_vpn_remote
    rule_nat_translate
    rule_inet_deny_internal

    echo -e "\n==================== 全部防火墙规则写入完成 ===================="
    echo "===== FORWARD 转发规则列表 ====="
    ${FW_CMD} iptables -L FORWARD -n -v --line-numbers
    echo -e "\n===== NAT 转换规则列表 ====="
    ${FW_CMD} iptables -t nat -L -n -v --line-numbers
}

# 启动主逻辑
main