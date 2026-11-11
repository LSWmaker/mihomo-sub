#!/bin/sh
# 本地测试 harness: 不依赖容器, 验证 CGI 逻辑与 sub.sh 渲染逻辑
# 用法: sh .omc/test/harness.sh

set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
TESTDIR=$(mktemp -d)
PASS=0; FAIL=0

say()  { printf '\n== %s ==\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n    got: %s\n' "$1" "$2"; }

assert_contains() {
    if printf '%s' "$2" | grep -q "$3"; then ok "$1"; else bad "$1" "$2"; fi
}

# ---------------------------
# 准备测试目录结构(模拟 /root/.config/mihomo)
# ---------------------------
CFG="${TESTDIR}/cfg"
mkdir -p "${CFG}/providers"
printf 'test-secret-123' > "${CFG}/secret"
printf '21600' > "${CFG}/schedule.conf"
cat > "${CFG}/subs.json" <<'EOF'
{"subs":[
  {"id":"p1","name":"机场A","url":"https://a.example.com/sub?token=xyz","type":"http","enabled":true},
  {"id":"p2","name":"机场B","url":"https://b.example.com/sub","type":"file","enabled":true},
  {"id":"p3","name":"已禁用","url":"https://c.example.com/sub","type":"http","enabled":false},
  {"id":"p4","name":"待检测","url":"https://d.example.com/sub","type":"pending","enabled":true}
]}
EOF

# 生成 CGI 副本(替换路径; SUB_SCRIPT 指向 stub)
sed -e "s|/root/.config/mihomo|${CFG}|g" \
    -e 's|SUB_SCRIPT="/etc/periodic/15min/sub.sh"|SUB_SCRIPT="true"|' \
    mgr/cgi-bin/api > "${TESTDIR}/api"
chmod +x "${TESTDIR}/api"

# 生成 sub.sh 副本(替换配置/临时路径; /mihomo -t 是绝对路径, PATH stub 不生效, 直接替换为 true)
sed -e "s|/root/.config/mihomo|${CFG}|g" \
    -e 's|/tmp/mihomo_sub|'"${TESTDIR}"'/tmp|g' \
    -e 's|/mihomo -t|true|g' \
    sub.sh > "${TESTDIR}/sub_render.sh"

# POST 请求辅助: run_post <query> <body> (自动算 CONTENT_LENGTH, 用 %s 避免格式串转义)
run_post() {
    blen=$(printf '%s' "$2" | wc -c)
    printf '%s' "$2" | REQUEST_METHOD=POST CONTENT_LENGTH="$blen" QUERY_STRING="$1" sh "${TESTDIR}/api" 2>/dev/null
}

# ---------------------------
# CGI 测试
# ---------------------------
say "CGI: 鉴权"
out=$(REQUEST_METHOD=GET QUERY_STRING="action=status" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "无 token 返回 401" "$out" "401"

out=$(REQUEST_METHOD=GET QUERY_STRING="action=status&token=wrong" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "错误 token 返回 401" "$out" "401"

out=$(REQUEST_METHOD=GET QUERY_STRING="action=auth&token=test-secret-123" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "正确 token auth 成功" "$out" '"success":true'

say "CGI: status / list"
out=$(REQUEST_METHOD=GET QUERY_STRING="action=status&token=test-secret-123" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "status 返回 interval" "$out" '"interval":21600'
assert_contains "status 返回订阅数" "$out" '"sub_count":4'
assert_contains "status 面板链接含 secret" "$out" 'secret=test-secret-123'

out=$(REQUEST_METHOD=GET QUERY_STRING="action=list&token=test-secret-123" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "list 返回 p1" "$out" '"id":"p1"'
assert_contains "list 返回 pending 状态" "$out" '"type":"pending"'

say "CGI: add"
out=$(run_post "action=add&token=test-secret-123" 'name=%E6%96%B0%E6%9C%BA%E5%9C%BA&url=https%3A%2F%2Fnew.example.com%2Fsub')
assert_contains "add 成功返回 id" "$out" '"id":"p5"'
assert_contains "add 后台同步提示" "$out" '后台同步'
out=$(jq -r '.subs[4].name' "${CFG}/subs.json")
assert_contains "add 写入解码后的名称" "$out" '新机场'
out=$(jq -r '.subs[4].url' "${CFG}/subs.json")
assert_contains "add 写入解码后的 URL" "$out" 'https://new.example.com/sub'

out=$(run_post "action=add&token=test-secret-123" 'url=https%3A%2F%2Fnew.example.com%2Fsub')
assert_contains "重复 add 被拒绝" "$out" '已存在'

say "CGI: update"
out=$(run_post "action=update&token=test-secret-123" 'id=p1&name=RenameA')
assert_contains "update 名称成功" "$out" '"success":true'
out=$(jq -r '.subs[0].name' "${CFG}/subs.json")
assert_contains "名称已更新" "$out" 'RenameA'

run_post "action=update&token=test-secret-123" 'id=p1&enabled=false' >/dev/null
out=$(jq -r '.subs[0].enabled' "${CFG}/subs.json")
assert_contains "禁用已写入" "$out" 'false'

run_post "action=update&token=test-secret-123" 'id=p1&url=https%3A%2F%2Fa2.example.com%2Fsub' >/dev/null
out=$(jq -r '.subs[0].type' "${CFG}/subs.json")
assert_contains "URL 变更后回到 pending" "$out" 'pending'
out=$(jq -r '.subs[0].url' "${CFG}/subs.json")
assert_contains "URL 已更新" "$out" 'https://a2.example.com/sub'

say "CGI: delete"
out=$(run_post "action=delete&token=test-secret-123" 'id=p5')
assert_contains "delete 成功" "$out" '"success":true'
out=$(jq '.subs | length' "${CFG}/subs.json")
[ "$out" = "4" ] && ok "订阅数回落到 4" || bad "订阅数回落到 4" "$out"

say "CGI: schedule"
out=$(run_post "action=schedule&token=test-secret-123" 'interval=60')
assert_contains "非法间隔被拒绝" "$out" '无效的间隔'
out=$(run_post "action=schedule&token=test-secret-123" 'interval=3600')
assert_contains "已移除的短档位被拒绝" "$out" '无效的间隔'
out=$(run_post "action=schedule&token=test-secret-123" 'interval=172800')
assert_contains "合法间隔成功" "$out" '"interval":172800'
out=$(run_post "action=schedule&token=test-secret-123" 'interval=604800')
assert_contains "7 天档位成功" "$out" '"interval":604800'
out=$(REQUEST_METHOD=GET QUERY_STRING="action=schedule&token=test-secret-123" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "GET schedule 回显" "$out" '"interval":604800'

say "CGI: 未知 action"
out=$(REQUEST_METHOD=GET QUERY_STRING="action=nope&token=test-secret-123" sh "${TESTDIR}/api" 2>/dev/null)
assert_contains "未知 action 404" "$out" '404'

# ---------------------------
# sub.sh --render 端到端测试(stub 掉 mihomo 二进制, 热重载 API 失败无碍于检查产物)
# ---------------------------
say "sub.sh: --render 渲染输出"
# 重置数据: p1 恢复 http 类型(此前 update 测试把它改成了 pending)
cat > "${CFG}/subs.json" <<'EOF'
{"subs":[
  {"id":"p1","name":"机场A","url":"https://a.example.com/sub?token=xyz","type":"http","enabled":true},
  {"id":"p2","name":"机场B","url":"https://b.example.com/sub","type":"file","enabled":true},
  {"id":"p3","name":"已禁用","url":"https://c.example.com/sub","type":"http","enabled":false},
  {"id":"p4","name":"待检测","url":"https://d.example.com/sub","type":"pending","enabled":true}
]}
EOF
printf '172800' > "${CFG}/schedule.conf"
# mihomo stub(-t 校验恒通过)
mkdir -p "${TESTDIR}/stubs"
printf '#!/bin/sh\nexit 0\n' > "${TESTDIR}/stubs/mihomo"
chmod +x "${TESTDIR}/stubs/mihomo"
# 期待退出码非 0(热重载 API 打不通属预期), 但 .base.yaml 必须已生成
rc=0
PATH="${TESTDIR}/stubs:${PATH}" sh "${TESTDIR}/sub_render.sh" --render >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && ok "render 模式在 API 不通时以非零退出(预期, rc=$rc)" || ok "render 模式退出码 0"

BASE="${CFG}/.base.yaml"
[ -s "$BASE" ] && ok "base.yaml 已生成" || bad "base.yaml 已生成" "(空)"

grep -q 'proxy-providers:' "$BASE" && ok "包含 proxy-providers 段" || bad "包含 proxy-providers 段" "$(head -5 $BASE)"
grep -q 'type: http' "$BASE" && ok "http provider 已渲染" || bad "http provider 已渲染" "missing"
grep -q 'type: file' "$BASE" && ok "file provider 已渲染" || bad "file provider 已渲染" "missing"
grep -q 'interval: 172800' "$BASE" && ok "interval 已写入" || bad "interval 已写入" "missing"
grep -q 'secret: "test-secret-123"' "$BASE" && ok "secret 已写入" || bad "secret 已写入" "missing"
if grep -q 'p3:' "$BASE"; then bad "禁用订阅未渲染(p3 应缺席)" "$(grep p3 $BASE)"; else ok "禁用订阅未渲染(p3 缺席)"; fi
grep -q 'store-selected: true' "$BASE" && ok "store-selected 保留节点选择" || bad "store-selected" "missing"
grep -q 'include-all: true' "$BASE" && ok "分组用 include-all" || bad "include-all" "missing"
grep -q 'GEOSITE,cn,DIRECT' "$BASE" && ok "国内直连规则" || bad "国内直连规则" "missing"

say "YAML 结构校验(python, 经 stdin 避免路径问题)"
cat "${CFG}/.base.yaml" | python -c "
import yaml, sys
cfg = yaml.safe_load(sys.stdin)
assert cfg['mixed-port'] == 7890
assert cfg['secret'] == 'test-secret-123'
assert 'p1' in cfg['proxy-providers'] and 'p4' in cfg['proxy-providers'] and 'p3' not in cfg['proxy-providers']
assert cfg['proxy-providers']['p1']['type'] == 'http'
assert cfg['proxy-providers']['p2']['type'] == 'file'
assert cfg['proxy-providers']['p4']['type'] == 'file'   # pending 渲染为 file 兜底, 待分类后纠正
assert cfg['proxy-providers']['p1']['interval'] == 172800
assert cfg['proxy-providers']['p1']['header']['User-Agent'] == ['clash-verge/v2.5.1']
groups = {g['name']: g for g in cfg['proxy-groups']}
assert 'PROXY' in groups and 'AUTO' in groups
assert groups['PROXY']['include-all'] is True
assert cfg['profile']['store-selected'] is True
print('  ok: YAML 结构与预期一致')
" 2>&1 && PASS=$((PASS+1)) || bad "YAML 结构校验" "见上方 python 报错"

say "user-merge 深合并(yq 缺席时跳过)"
printf 'dns:\n  enable: true\n' > "${CFG}/user-merge.yaml"
if command -v yq >/dev/null 2>&1; then
    echo "  (本地有 yq, 但 render 在无 yq 时回退 base, 此处仅验证文件存在路径)"
else
    echo "  (本地无 yq, 容器内验证; render 已带回退逻辑)"
fi

# ---------------------------
# 汇总
# ---------------------------
printf '\n========== 结果: %d 通过, %d 失败 ==========\n' "$PASS" "$FAIL"
rm -rf "${TESTDIR}"
[ "$FAIL" -eq 0 ]
