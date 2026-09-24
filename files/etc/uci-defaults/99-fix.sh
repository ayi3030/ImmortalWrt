#!/bin/sh
# ════════════════════════════════════════════════════════════════════════════
#  99-fix.sh —— 固件首次启动时运行，用来收紧上游 99-custom.sh 留下的默认值
#
#  为什么需要它：
#    上游 files/etc/uci-defaults/99-custom.sh 第 13 行硬编码了
#        uci set firewall.@zone[1].input='ACCEPT'
#    于是固件一出厂，WAN 入站就是全开的（22 / 7681 / 80 / 8888 / 9090 /
#    7890-7892 / 1080 / 1053 / 8080 / 9443 / 8088 全部对公网可达）。
#    IPv4 侧运营商 CGNAT 还能挡一下，IPv6 侧是真实公网地址 —— 直通。
#    这就是现网 10.0.0.1 上那个 P0 的根：不是谁后来改坏的，是出厂自带。
#
#  执行顺序：
#    uci-defaults 目录按文件名排序执行，'99-custom.sh' < '99-fix.sh'，
#    所以本脚本一定在上游脚本之后跑，能覆盖它的值。
#
#  ⚠️ 本脚本只在【首次启动】跑一次（跑完 OpenWrt 会删掉 /etc/uci-defaults/）。
#     之后你在 LuCI 里怎么改都不会被它覆盖回去。想再跑：
#        sh /etc/uci-defaults/99-fix.sh   （如果文件还在）
# ════════════════════════════════════════════════════════════════════════════

LOGFILE="/etc/config/uci-defaults-log.txt"
echo "===== 99-fix.sh start $(date) =====" >> "$LOGFILE"

# ─────────────────────────────────────────────────────────────
# 1) WAN 入站收回 REJECT —— 本脚本存在的主要理由
#    上游用固定下标 @zone[1]，但 zone 顺序会随固件版本变（比如装了 docker
#    会被 99-custom.sh 追加一个 docker zone）。所以这里按名字遍历，不猜下标。
# ─────────────────────────────────────────────────────────────
i=0
WAN_FIXED=0
while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ]; then
        uci set firewall.@zone[$i].input='REJECT'
        WAN_FIXED=1
        echo "  [1] firewall.@zone[$i](wan).input -> REJECT" >> "$LOGFILE"
    fi
    i=$((i + 1))
done
if [ "$WAN_FIXED" = "0" ]; then
    echo "  [1] ⚠️ 没找到名为 wan 的 zone，跳过（请人工检查 /etc/config/firewall）" >> "$LOGFILE"
fi
uci commit firewall

# ─────────────────────────────────────────────────────────────
# 2) 网页终端只监听 LAN
#    上游 99-custom.sh 执行了 `uci delete ttyd.@ttyd[0].interface`，
#    效果是 ttyd(7681) 在【所有网口】监听。WAN 入站已收回 REJECT，
#    理论上够安全；这里再收一道，属于纵深防御。
# ─────────────────────────────────────────────────────────────
if uci -q get ttyd.@ttyd[0] >/dev/null 2>&1; then
    # ⚠️ 必须写 '@lan'（带 @），绝不能写裸 'lan'。
    #    /etc/init.d/ttyd 里只有 @ 开头才会解析成真实设备名：
    #        [ "${interface::1}" = @ ] && network_get_device device "${interface:1}"
    #    '@lan' → br-lan；裸 'lan' 会被原样传给 ttyd 的 -i 参数，
    #    而 ttyd 的 --interface 要的是网络设备名，找不到就
    #    "Interface lan not found" 直接退出 —— 服务起不来、7681 全不通。
    #    （2026-09-25 首次刷机实测踩到）
    uci set ttyd.@ttyd[0].interface='@lan'
    uci commit ttyd
    /etc/init.d/ttyd restart >/dev/null 2>&1
    echo "  [2] ttyd 限制为 lan（@lan → br-lan）" >> "$LOGFILE"
else
    echo "  [2] 未安装 ttyd，跳过" >> "$LOGFILE"
fi

# ─────────────────────────────────────────────────────────────
# 3) 清掉不该留在设备上的两个文件
#    pppoe-settings        ：宽带账号密码明文（本工作流已不让它进镜像，这里兜底）
#    custom_router_ip.txt  ：构建时用的后台地址，值已经写进 network 配置了，
#                            留着只会跟着 sysupgrade 备份到处跑
# ─────────────────────────────────────────────────────────────
rm -f /etc/config/pppoe-settings
rm -f /etc/config/custom_router_ip.txt
echo "  [3] 已清理 pppoe-settings / custom_router_ip.txt" >> "$LOGFILE"

# ─────────────────────────────────────────────────────────────
# 4) 时区（上游没设，默认 UTC，日志时间全是错的）
# ─────────────────────────────────────────────────────────────
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system
echo "  [4] 时区 -> Asia/Shanghai" >> "$LOGFILE"

# ─────────────────────────────────────────────────────────────
# 5) 放宽 rpcd / uhttpd 超时 —— 不放开的话，LuCI 里拉镜像必失败
#
#    dockerman 的「拉取镜像」不是走 docker CLI，而是走 ubus RPC
#    （前端 common.js 里 rpc.declare({object:'docker.image', method:'create'})
#      → 后端 /usr/share/rpcd/ucode/docker_rpc.uc → POST /images/create）。
#    rpcd 默认把单次 ubus 调用掐在 30 秒（/etc/config/rpcd 的 timeout）。
#    稍大的镜像拉取必然 >30s → 前端收到超时错误 → 用户看到"拉取失败"，
#    而 docker daemon 其实还在后台拉（实测：报超时后镜像仍出现在列表里）。
#    接着用户去「创建容器」，镜像下拉框里没有目标镜像 → 保存必 400，
#    报 "no command specified" —— 这就是"创建容器不行"的真实成因链。
#
#    2026-09-25 实测数据：CLI 拉 alpine(13.6MB) 14s；走 ubus 拉
#    nginx:alpine(93MB) 20.7s；python:3.12-alpine 在 30s 上限下被掐断，
#    放开到 300s 后正常完成。
#    uhttpd 的 -t（script_timeout，默认 60s）是这条链上更外层的一道，
#    它比 rpcd 大，所以真正的瓶颈是 rpcd 的 30s；两者一并放宽到 300s。
# ─────────────────────────────────────────────────────────────
if uci -q get rpcd.@rpcd[0] >/dev/null 2>&1; then
    uci set rpcd.@rpcd[0].timeout='300'
    uci commit rpcd
fi
if uci -q get uhttpd.main >/dev/null 2>&1; then
    uci set uhttpd.main.script_timeout='300'
    uci commit uhttpd
fi
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/uhttpd restart >/dev/null 2>&1
echo "  [5] rpcd.timeout / uhttpd.script_timeout -> 300s（否则 LuCI 拉镜像超时）" >> "$LOGFILE"

# ─────────────────────────────────────────────────────────────
# 6) 修 quickstart 首页里那个写死的 Docker 链接
#
#    luci-app-quickstart（0.12.7-r1，来自 nas_luci feed）的首页有一张
#    「Docker高级配置」卡片，href 硬编码成
#        /cgi-bin/luci/admin/docker/overview
#    —— 那是 iStoreOS 的约定（iStoreOS 的 dockerman 就挂在顶层 admin/docker）。
#    而 ImmortalWrt 25.12 的 luci-app-dockerman（JS 重写版）把菜单放在
#    「服务 → Dockerman JS」，即 admin/services/dockerman 下。
#    → 照原生菜单跑，这个按钮必然 404（实测 2026-09-25）。
#
#    为什么用 sed 就地改、而不是 files/ 覆盖：
#    index.js 是 498KB 的 Vue 编译产物，放进 git 等于把上游文件冻结；
#    改一处 URL 用 sed 更轻，而且上游哪天改对了（grep 不到）会自动跳过。
# ─────────────────────────────────────────────────────────────
QS=/www/luci-static/quickstart/index.js
if [ -f "$QS" ] && grep -q '/cgi-bin/luci/admin/docker/overview' "$QS"; then
    sed -i 's#/cgi-bin/luci/admin/docker/overview#/cgi-bin/luci/admin/services/dockerman/overview#g' "$QS"
    echo "  [6] quickstart 首页 Docker 链接 -> admin/services/dockerman/overview" >> "$LOGFILE"
else
    echo "  [6] quickstart 无该链接或未安装，跳过" >> "$LOGFILE"
fi

echo "===== 99-fix.sh done =====" >> "$LOGFILE"
exit 0
