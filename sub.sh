#!/bin/sh

# ---------------------------
# 订阅同步与配置渲染
#
# 架构: 订阅元数据存 subs.json, Clash 格式订阅交给 mihomo 原生
#       proxy-providers 定时拉取(间隔受控, 防止机场封禁), 非 Clash
#       格式经 subconverter 转换为本地 file provider。配置由固定
#       模板渲染, yq 深合并用户覆写(user-merge.yaml), 不再全量
#       重写用户可自定义的字段。
#
# 用法:
#   sub.sh            定时模式(按 interval 节流; 重转换 file 类订阅; 渲染)
#   sub.sh --now      全量同步(分类 pending; 重转换 file 类; 渲染; 强制刷新所有 provider)
#   sub.sh --render   仅渲染并热重载(订阅增删/间隔变更后由 CGI 调用)
# ---------------------------

CONFIG_DIR="/root/.config/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CONFIG_NEW="${CONFIG_DIR}/.config.new"
BASE_FILE="${CONFIG_DIR}/.base.yaml"
LOG_FILE="${CONFIG_DIR}/log.txt"
SUBS_FILE="${CONFIG_DIR}/subs.json"
SCHEDULE_FILE="${CONFIG_DIR}/schedule.conf"
LAST_RUN_FILE="${CONFIG_DIR}/last_run"
UA_FILE="${CONFIG_DIR}/user_agent.txt"
SECRET_FILE="${CONFIG_DIR}/secret"
MERGE_FILE="${CONFIG_DIR}/user-merge.yaml"
PROV_DIR="${CONFIG_DIR}/providers"
TEMP_DIR="/tmp/mihomo_sub"
LOCK_DIR="/tmp/mihomo_sub.lock"
MIHOMO_API="http://127.0.0.1:9090"
HEALTH_URL="http://www.gstatic.com/generate_204"

CR=$(printf '\r')
log=""
refresh_time=$(date +"%Y-%m-%d %H:%M:%S %z")

MODE="cron"
[ "$1" = "--now" ] && MODE="now"
[ "$1" = "--render" ] && MODE="render"

# User-Agent: 从文件读取，默认 clash-verge
if [ -f "${UA_FILE}" ] && [ -s "${UA_FILE}" ]; then
    SUB_UA=$(head -1 "${UA_FILE}")
else
    SUB_UA="clash-verge/v2.5.1"
fi

# ---------------------------
# 日志与退出
# ---------------------------
sub_end() {
    exit_code="${1:-0}"
    log="${log}\n"
    printf "%b" "${log}" >> "${LOG_FILE}"
    # 日志超过 1MB 时只保留最后 50KB
    if [ -f "${LOG_FILE}" ]; then
        log_size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "${log_size}" -gt 1048576 ]; then
            tail -c 51200 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
    rm -rf "${TEMP_DIR}"
    rmdir "${LOCK_DIR}" 2>/dev/null
    exit "${exit_code}"
}

# ---------------------------
# 互斥锁(防止 CGI 手动刷新与定时任务并发写 subs.json/config)
# ---------------------------
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    printf "[%s] 另一个同步任务正在运行, 跳过\n" "${refresh_time}" >> "${LOG_FILE}"
    exit 0
fi

# ---------------------------
# 调度间隔(秒): http 类订阅由内核按此值自动拉取, file 类由本脚本节流
# ---------------------------
INTERVAL=$(head -1 "${SCHEDULE_FILE}" 2>/dev/null)
case "${INTERVAL}" in
    ""|*[!0-9]*) INTERVAL=86400 ;;
esac

SECRET=$(cat "${SECRET_FILE}" 2>/dev/null)
if [ -z "${SECRET}" ]; then
    SECRET="mihomo-sub"
fi

mkdir -p "${TEMP_DIR}" "${PROV_DIR}"

# subs.json 不存在时初始化
if [ ! -f "${SUBS_FILE}" ]; then
    printf '{"subs":[]}' > "${SUBS_FILE}"
fi

# ---------------------------
# 调用 mihomo RESTful API(带 secret)
# ---------------------------
api() {
    # api METHOD PATH [JSON_BODY]
    method="$1"; path="$2"; data="$3"
    if [ -n "${data}" ]; then
        curl -s --max-time 15 -X "${method}" \
            -H "Authorization: Bearer ${SECRET}" \
            -H "Content-Type: application/json" \
            -d "${data}" -o /dev/null -w "%{http_code}" "${MIHOMO_API}${path}"
    else
        curl -s --max-time 15 -X "${method}" \
            -H "Authorization: Bearer ${SECRET}" \
            -o /dev/null -w "%{http_code}" "${MIHOMO_API}${path}"
    fi
}

# ---------------------------
# 定时模式节流检查
# ---------------------------
check_schedule() {
    [ "${MODE}" != "cron" ] && return 0
    if [ -f "${LAST_RUN_FILE}" ]; then
        last=$(cat "${LAST_RUN_FILE}" 2>/dev/null)
        now=$(date +%s)
        if [ -n "${last}" ] && [ $((now - last)) -lt "${INTERVAL}" ]; then
            rm -rf "${TEMP_DIR}"
            rmdir "${LOCK_DIR}" 2>/dev/null
            exit 0
        fi
    fi
}

# ---------------------------
# 分类/更新单个订阅:
#   下载原始内容 -> 含 ^proxies: 存为 http provider,
#   否则经 subconverter 转换存为本地 file provider
# ---------------------------
classify_sub() {
    cid="$1"; curl_url="$2"
    raw="${TEMP_DIR}/${cid}.raw"
    curl_exit=0
    curl -s --max-time 30 -H "User-Agent: ${SUB_UA}" -o "${raw}" "${curl_url}" || curl_exit=$?

    if [ "${curl_exit}" -ne 0 ] || [ ! -s "${raw}" ]; then
        log="${log}Error: 订阅 ${cid} 下载失败\n\t"
        return 1
    fi

    if grep -qE '^proxies:' "${raw}" 2>/dev/null; then
        # 已是 Clash 格式: 直接作为 http provider(内核按 interval 自动更新)
        cp "${raw}" "${PROV_DIR}/${cid}.yaml"
        new_type="http"
        log="${log}订阅 ${cid} 为 Clash 格式, 交给内核自动更新\n\t"
    else
        # 非 Clash 格式: subconverter 转换为本地文件
        encoded_sub_url=$(jq -rn --arg x "${curl_url}" '$x|@uri' 2>/dev/null)
        encoded_ua=$(jq -rn --arg x "${SUB_UA}" '$x|@uri' 2>/dev/null)
        http_code=$(curl -s --max-time 30 -w "%{http_code}" -o "${PROV_DIR}/${cid}.yaml" \
            "http://127.0.0.1:25500/sub?target=clash&url=${encoded_sub_url}&ua=${encoded_ua}")
        if [ "${http_code}" != "200" ] || ! grep -qE '^proxies:' "${PROV_DIR}/${cid}.yaml" 2>/dev/null; then
            log="${log}Error: 订阅 ${cid} 转换失败(响应码 ${http_code})\n\t"
            rm -f "${PROV_DIR}/${cid}.yaml"
            return 1
        fi
        new_type="file"
        log="${log}订阅 ${cid} 经 subconverter 转换为本地 provider\n\t"
    fi

    jq --arg id "${cid}" --arg t "${new_type}" \
        'if (.subs[] | select(.id == $id) | .type) != $t then
            .subs = (.subs | map(if .id == $id then .type = $t else . end))
        else . end' "${SUBS_FILE}" > "${SUBS_FILE}.tmp" && mv "${SUBS_FILE}.tmp" "${SUBS_FILE}"
    return 0
}

# ---------------------------
# 渲染配置:
#   固定模板 + providers 段 -> .base.yaml
#   yq 深合并 user-merge.yaml(用户覆写, 可自定义 dns/rules 等)
# ---------------------------
render_config() {
    enabled_jsonl="${TEMP_DIR}/enabled.jsonl"
    # 只取可用订阅: pending(未分类, 无数据源)不渲染, 防止 mihomo 启动失败
    jq -c '.subs[] | select(.enabled == true) | select(.type == "http" or .type == "file")' \
        "${SUBS_FILE}" 2>/dev/null > "${enabled_jsonl}"

    ua_json=$(jq -rn --arg x "${SUB_UA}" '$x|@json')

    # 生成 proxy-providers 段
    prov_part="${TEMP_DIR}/providers.part"
    : > "${prov_part}"
    enabled_count=0
    while IFS= read -r sub; do
        cid=$(printf '%s' "${sub}" | jq -r '.id')
        ctype=$(printf '%s' "${sub}" | jq -r '.type')
        # file 类 provider 文件缺失时跳过(转换产物被删/从未生成)
        if [ "${ctype}" = "file" ] && [ ! -f "${PROV_DIR}/${cid}.yaml" ]; then
            log="${log}警告: 订阅 ${cid} 缺少 provider 文件, 本次跳过\n\t"
            continue
        fi
        enabled_count=$((enabled_count + 1))
        curl_url_json=$(printf '%s' "${sub}" | jq -r '.url | @json')
        {
            printf '  %s:\n' "${cid}"
            if [ "${ctype}" = "http" ]; then
                printf '    type: http\n'
                printf '    url: %s\n' "${curl_url_json}"
                printf '    interval: %s\n' "${INTERVAL}"
                printf '    header:\n'
                printf '      User-Agent:\n        - %s\n' "${ua_json}"
            else
                printf '    type: file\n'
            fi
            printf '    path: ./providers/%s.yaml\n' "${cid}"
            printf '    health-check:\n'
            printf '      enable: true\n'
            printf '      lazy: true\n'
            printf '      url: %s\n' "${HEALTH_URL}"
            printf '      interval: 300\n'
        } >> "${prov_part}"
    done < "${enabled_jsonl}"

    # 固定模板
    {
        printf 'mixed-port: 7890\n'
        printf 'allow-lan: true\n'
        printf 'bind-address: "*"\n'
        printf 'external-controller: 0.0.0.0:9090\n'
        printf 'external-ui: /root/.config/mihomo/ui\n'
        printf 'secret: %s\n' "$(jq -rn --arg x "${SECRET}" '$x|@json')"
        printf 'log-level: info\n'
        printf 'profile:\n'
        printf '  store-selected: true\n'
        printf 'geo-auto-update: true\n'
        printf 'geo-update-interval: 168\n'
        # 地理库更新走 jsdelivr 镜像(默认 GitHub release 在国内常被 DNS 污染);
        # 可用 user-merge.yaml 覆盖
        printf 'geox-url:\n'
        printf '  geoip: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb\n'
        printf '  geosite: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat\n'
        printf '  mmdb: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb\n'
        printf '  asn: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb\n'
        if [ "${enabled_count}" -gt 0 ]; then
            printf 'proxy-providers:\n'
            cat "${prov_part}"
        fi
        printf 'proxy-groups:\n'
        if [ "${enabled_count}" -gt 0 ]; then
            printf '  - name: PROXY\n'
            printf '    type: select\n'
            printf '    include-all: true\n'
            printf '  - name: AUTO\n'
            printf '    type: url-test\n'
            printf '    include-all: true\n'
            printf '    url: %s\n' "${HEALTH_URL}"
            printf '    interval: 300\n'
            printf '    tolerance: 50\n'
        else
            printf '  - name: PROXY\n'
            printf '    type: select\n'
            printf '    proxies:\n'
            printf '      - DIRECT\n'
        fi
        printf 'rules:\n'
        printf '  - GEOSITE,private,DIRECT\n'
        printf '  - GEOSITE,cn,DIRECT\n'
        printf '  - GEOIP,private,DIRECT,no-resolve\n'
        printf '  - GEOIP,cn,DIRECT\n'
        printf '  - MATCH,PROXY\n'
    } > "${BASE_FILE}"

    # 与用户覆写合并(yq 深合并, 覆写侧优先; 数组整体替换)
    if [ -s "${MERGE_FILE}" ] && command -v yq >/dev/null 2>&1; then
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            "${BASE_FILE}" "${MERGE_FILE}" > "${CONFIG_NEW}" 2>/dev/null
        if [ $? -ne 0 ] || [ ! -s "${CONFIG_NEW}" ]; then
            log="${log}警告: user-merge.yaml 合并失败, 使用基础配置\n\t"
            cp "${BASE_FILE}" "${CONFIG_NEW}"
        fi
    else
        cp "${BASE_FILE}" "${CONFIG_NEW}"
    fi
    return 0
}

# ---------------------------
# 应用配置: 内核语法校验 -> 与现有配置比较 -> 热重载
# ---------------------------
apply_config() {
    # 语法校验, 防止坏配置(尤其用户覆写)导致内核无法启动
    if ! /mihomo -t -d "${CONFIG_DIR}" -f "${CONFIG_NEW}" >/dev/null 2>&1; then
        log="${log}Error: 生成的配置未通过内核校验, 保留旧配置\n\t"
        rm -f "${CONFIG_NEW}"
        sub_end 1
    fi

    if cmp -s "${CONFIG_NEW}" "${CONFIG_FILE}"; then
        rm -f "${CONFIG_NEW}"
        log="${log}配置无变化, 跳过重载\n\t"
        return 0
    fi

    mv "${CONFIG_NEW}" "${CONFIG_FILE}"
    code=$(api PUT "/configs?force=true" '{"path":"","payload":""}')
    if [ "${code}" != "204" ]; then
        log="${log}Error: 配置热重载失败, 响应码 ${code}\n\t"
        sub_end 1
    fi
    log="${log}配置已生成并热重载 ✅\n\t"
}

# ---------------------------
# 强制内核刷新 provider(http 类立即拉取订阅, file 类重读本地文件)
# ---------------------------
refresh_provider() {
    cid="$1"
    code=$(api PUT "/providers/proxies/${cid}")
    if [ "${code}" = "204" ] || [ "${code}" = "200" ]; then
        log="${log}provider ${cid} 已刷新\n\t"
    else
        log="${log}警告: provider ${cid} 刷新失败(响应码 ${code})\n\t"
    fi
}

# =========================================================
# 主流程
# =========================================================
check_schedule

log="${log}[${refresh_time}] \n\t同步开始(模式: ${MODE})...\n\t"

# 清除 subconverter 缓存
for d in /subconverter/cache /tmp/.subconverter_cache; do
    [ -d "${d}" ] && rm -rf "${d}"/* 2>/dev/null || true
done

# 遍历订阅: pending 需分类, file 类需重转换(http 类由内核自管, 脚本不重复拉取)
# 注意: 循环用输入重定向(非管道), 保证在当前 shell 执行, classify_sub
#       内的 log 追加不会因子 shell 丢失
# render 模式是纯渲染(增删/改名后调用), 不产生网络请求
if [ "${MODE}" != "render" ]; then
    jq -c '.subs[]' "${SUBS_FILE}" 2>/dev/null > "${TEMP_DIR}/all.jsonl"
    while IFS= read -r sub; do
        cid=$(printf '%s' "${sub}" | jq -r '.id')
        ctype=$(printf '%s' "${sub}" | jq -r '.type // "pending"')
        cenabled=$(printf '%s' "${sub}" | jq -r '.enabled')
        curl_url=$(printf '%s' "${sub}" | jq -r '.url')

        [ "${cenabled}" != "true" ] && continue

        need_classify=false
        if [ "${ctype}" = "pending" ]; then
            need_classify=true
        elif [ "${ctype}" = "file" ]; then
            # file 类订阅必须由脚本周期性重新转换(内核不会拉取)
            need_classify=true
        fi

        if $need_classify; then
            classify_sub "${cid}" "${curl_url}"
        fi
    done < "${TEMP_DIR}/all.jsonl"
fi

render_config
apply_config

# 强制刷新 providers:
#   now 模式(手动/添加后): 全部 provider 立即拉取/重读
#   cron 模式: 仅 file 类需要通知内核重读文件(http 类由内核按 interval 自管)
jq -c '.subs[] | select(.enabled == true) | select(.type == "http" or .type == "file")' \
    "${SUBS_FILE}" 2>/dev/null > "${TEMP_DIR}/active.jsonl"
while IFS= read -r sub; do
    cid=$(printf '%s' "${sub}" | jq -r '.id')
    ctype=$(printf '%s' "${sub}" | jq -r '.type // "pending"')
    case "${MODE}" in
        now) refresh_provider "${cid}" ;;
        cron) [ "${ctype}" = "file" ] && refresh_provider "${cid}" ;;
    esac
done < "${TEMP_DIR}/active.jsonl"

# 记录最后运行时间
date +%s > "${LAST_RUN_FILE}"

log="${log}同步完成 ✅\n\t"
sub_end 0
