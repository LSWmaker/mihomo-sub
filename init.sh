#!/bin/sh

CONFIG_DIR="/root/.config/mihomo"
INIT_DIR="/usr/share/mihomo-init"
SUBS_FILE="${CONFIG_DIR}/subs.json"
SCHEDULE_FILE="${CONFIG_DIR}/schedule.conf"
SECRET_FILE="${CONFIG_DIR}/secret"
LEGACY_URLS_FILE="${CONFIG_DIR}/sub_urls.txt"

# ---------------------------
# 配置文件初始化
# ---------------------------
mkdir -p "${CONFIG_DIR}"

# 首次运行或空目录挂载时，从内置目录复制初始文件
if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
    cp "${INIT_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
    echo "📄 初始化 mihomo 配置"
fi

if [ ! -d "${CONFIG_DIR}/ui" ] || [ -z "$(ls -A "${CONFIG_DIR}/ui" 2>/dev/null)" ]; then
    mkdir -p "${CONFIG_DIR}/ui"
    cp -a "${INIT_DIR}/ui/." "${CONFIG_DIR}/ui/"
    echo "🎨 初始化 Web 面板"
fi

# 复制预下载的地理库文件（避免启动时直连 GitHub 超时）
# 如果已有文件太小（<100KB，说明损坏），也重新复制
if [ -f "${INIT_DIR}/geoip.metadb" ]; then
    existing_size=$(wc -c < "${CONFIG_DIR}/geoip.metadb" 2>/dev/null || echo 0)
    if [ "${existing_size}" -lt 102400 ]; then
        cp "${INIT_DIR}/geoip.metadb" "${CONFIG_DIR}/geoip.metadb"
        echo "🗺 初始化 GeoIP 数据库"
    fi
fi
if [ -f "${INIT_DIR}/geosite.dat" ]; then
    existing_size=$(wc -c < "${CONFIG_DIR}/geosite.dat" 2>/dev/null || echo 0)
    if [ "${existing_size}" -lt 102400 ]; then
        cp "${INIT_DIR}/geosite.dat" "${CONFIG_DIR}/geosite.dat"
        echo "🗺 初始化 GeoSite 数据库"
    fi
fi

# ---------------------------
# API secret: 首次启动生成随机值，持久化在挂载目录
# 保护 9090 API(面板)与 9091 管理页(CGI 校验 token == secret)
# ---------------------------
if [ ! -s "${SECRET_FILE}" ]; then
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${SECRET_FILE}"
    echo "🔐 已生成 API secret(管理页登录密码, 存于 secret 文件)"
fi

# ---------------------------
# 旧版配置迁移: sub_urls.txt -> subs.json, schedule.conf 档位 -> 秒
# ---------------------------
if [ ! -f "${SUBS_FILE}" ] && [ -f "${LEGACY_URLS_FILE}" ] && [ -s "${LEGACY_URLS_FILE}" ]; then
    echo "📦 迁移旧版订阅列表到 subs.json ..."
    printf '{"subs":[]}' > "${SUBS_FILE}"
    idx=0
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%"$(printf '\r')"}"
        case "${line}" in
            ""|"#"*) continue ;;
        esac
        idx=$((idx + 1))
        jq --arg id "p${idx}" --arg url "${line}" \
            '.subs += [{"id":$id,"name":("订阅 " + $id),"url":$url,"type":"pending","enabled":true}]' \
            "${SUBS_FILE}" > "${SUBS_FILE}.tmp" && mv "${SUBS_FILE}.tmp" "${SUBS_FILE}"
    done < "${LEGACY_URLS_FILE}"
    mv "${LEGACY_URLS_FILE}" "${LEGACY_URLS_FILE}.bak"
    echo "📦 已迁移 ${idx} 个订阅(旧文件保留为 sub_urls.txt.bak)"
fi

if [ ! -f "${SUBS_FILE}" ]; then
    printf '{"subs":[]}' > "${SUBS_FILE}"
fi

# schedule.conf: 统一存刷新间隔秒数(档位下限 6 小时, 防止拉取过频被订阅服务商封禁)
if [ ! -f "${SCHEDULE_FILE}" ] || [ -z "$(head -1 "${SCHEDULE_FILE}" 2>/dev/null)" ]; then
    echo 86400 > "${SCHEDULE_FILE}"
    echo "⏱ 初始化刷新间隔: 每天"
else
    old_val=$(head -1 "${SCHEDULE_FILE}")
    case "${old_val}" in
        15min|hourly) echo 21600 > "${SCHEDULE_FILE}" ;;   # 旧文本档位 -> 6 小时
        daily)        echo 86400 > "${SCHEDULE_FILE}" ;;   # 每天保持
        *[!0-9]*)     : ;;                                 # 其他非数字内容不动, sub.sh 会用默认值
        *)
            # 数字值低于档位下限时钳制到 6 小时
            [ "${old_val}" -lt 21600 ] && echo 21600 > "${SCHEDULE_FILE}"
            ;;
    esac
fi

mkdir -p "${CONFIG_DIR}/providers"

# ---------------------------
# 旧版/损坏的 config.yaml 会让 mihomo 反复崩溃(例如 2.x 多订阅合并产物
# 引用不存在的节点)。config.yaml 本就是渲染产物: 启动前先校验,
# 失败则备份并重新渲染(--render 零网络请求, 不依赖任何服务)
# ---------------------------
if [ -f "${CONFIG_DIR}/config.yaml" ]; then
    if ! /mihomo -t -d "${CONFIG_DIR}" >/dev/null 2>&1; then
        cp "${CONFIG_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml.broken"
        echo "⚠ 现有 config.yaml 校验失败(已备份为 config.yaml.broken), 重新渲染..."
        /etc/periodic/15min/sub.sh --render || true
    fi
fi

# ---------------------------
# 启动 mihomo 核心(守护循环: 异常退出 2 秒后自动拉起)
# ---------------------------
echo "🚀 启动 mihomo..."
(
    while :; do
        /mihomo -d "${CONFIG_DIR}"
        echo "⚠ mihomo 异常退出, 2 秒后重启..."
        sleep 2
    done
) &
sleep 2

# 等待 mihomo 就绪(3.0 起 API 带 secret 鉴权, 探测必须带 Bearer, 否则 401 被误判为未就绪)
API_SECRET=$(cat "${SECRET_FILE}" 2>/dev/null)
mihomo_ready=false
for i in $(seq 1 10); do
    if curl -sf --max-time 3 -H "Authorization: Bearer ${API_SECRET}" \
        http://127.0.0.1:9090/version > /dev/null 2>&1; then
        echo "✅ mihomo 已就绪"
        mihomo_ready=true
        break
    fi
    echo "⏳ 等待 mihomo 启动... (${i}/10)"
    sleep 1
done
if ! $mihomo_ready; then
    echo "❌ mihomo 启动超时，退出"
    exit 1
fi

# ---------------------------
# 启动 subconverter（先清缓存再启动）
# ---------------------------
echo "🔄 清理缓存并启动 subconverter..."
for d in /subconverter/cache /tmp/.subconverter_cache; do
    [ -d "${d}" ] && rm -rf "${d}"/* 2>/dev/null || true
done
/subconverter/subconverter &
sleep 2

# ---------------------------
# 等待 subconverter 就绪
# ---------------------------
subc_ready=false
for i in $(seq 1 10); do
    if curl -s -o /dev/null "http://127.0.0.1:25500/version" 2>/dev/null; then
        echo "✅ subconverter 已就绪"
        subc_ready=true
        break
    fi
    echo "⏳ 等待 subconverter 启动... (${i}/10)"
    sleep 1
done
if ! $subc_ready; then
    echo "❌ subconverter 启动超时，退出"
    exit 1
fi

# ---------------------------
# 首次订阅同步(渲染配置并热重载)
# ---------------------------
echo "📡 执行首次订阅同步..."
/etc/periodic/15min/sub.sh --now

# ---------------------------
# 启动管理页面 (busybox httpd)
# disable_auth=true 时关闭管理页密码登录(仅 9091, 9090 API 的 secret 不受影响)
# ---------------------------
case "${disable_auth}" in
    true|1|yes|on)
        echo "🔓 管理页密码登录已关闭(环境变量 disable_auth)"
        ;;
esac
echo "🌐 启动管理页面 http://0.0.0.0:9091"
busybox-extras httpd -h /usr/share/mihomo-mgr -p 9091

# ---------------------------
# 启动 cron
# ---------------------------
echo "⏰ 启动定时任务..."
exec crond -f
