# mihomo-sub

Docker 化的 mihomo（clash meta）代理方案：类客户端（Clash Verge 形态）的 Web 管理页面 + metacubexd 代理面板 + 订阅定时刷新，为局域网设备提供代理。

## 项目结构

```
├── Dockerfile              # 镜像构建，多架构支持 (amd64/arm64/armv7/386)
├── init.sh                 # 容器 ENTRYPOINT，初始化 + 守护 + 启动所有服务
├── sub.sh                  # 订阅同步/分类/配置渲染脚本（cron 每 15 分钟 + CGI 触发）
├── mgr/
│   ├── index.html          # 管理页面 (暗色主题，单文件，:9091，token 登录)
│   └── cgi-bin/
│       └── api             # CGI API 后端 (busybox-extras httpd)
├── test/harness.sh         # 本地逻辑测试（不依赖 docker）
├── .github/workflows/
│   └── docker-image.yml    # CI/CD 多架构构建推送
└── README.md
```

## 服务端口

| 端口 | 服务 | 说明 |
|------|------|------|
| 7890 | mihomo mixed proxy | HTTP + SOCKS，局域网设备接这里 |
| 9090 | mihomo API / metacubexd WebUI | `/ui` 代理面板，Bearer secret 鉴权 |
| 9091 | busybox-extras httpd | 管理页面 + CGI API，token=secret |

## 核心架构（proxy-providers 模式）

订阅不由脚本全量下载合并——**Clash 格式订阅交给 mihomo 原生 `proxy-providers` 按 interval 自动拉取**（内核行为，节流可控）；非 Clash 格式由 sub.sh 经 subconverter 转换为本地 file provider。`config.yaml` 由固定模板渲染 + `user-merge.yaml` 深合并（yq），用户自定义永不丢失。

### 容器启动 (init.sh)

```
初始化配置（空挂载补全、secret 生成、sub_urls.txt→subs.json 迁移、schedule 档位→秒）
  → mihomo 守护循环（while 拉起，崩溃 2s 重启）→ 等待就绪
  → subconverter → 等待就绪
  → sub.sh --now 首次同步
  → httpd :9091 → exec crond -f
```

### 订阅同步/渲染 (sub.sh)

```
锁(/tmp/mihomo_sub.lock, 防并发) → check_schedule（cron 模式按 interval 节流）
  ├─ --now / cron 模式: pending 订阅分类下载(含 ^proxies: 判定)；file 类重新转换
  ├─ --render 模式: 纯渲染，零网络请求（增删/改名/改间隔后 CGI 调用）
  → render_config: 模板 + providers 段 → .base.yaml → yq 深合并 user-merge.yaml
  → apply_config: /mihomo -t 语法校验 → cmp 相同跳过 → PUT :9090/configs 热重载
  → --now: PUT /providers/proxies/:id 强制刷新；cron: 仅 file 类
  → 记录 last_run
```

### 管理页面 CGI API（除 `config` 探针外均需 token == secret；环境变量 `disable_auth=true` 可关闭管理页鉴权——仅 9091，9090 API 的 secret 不受影响）

| action | method | 说明 |
|--------|--------|------|
| `config` | GET | 免鉴权探针：`{"auth_required":bool}`，前端据此决定是否展示登录层 |
| `auth` | GET | 校验 token（登录探针） |
| `status` | GET | 订阅数、间隔、最后刷新、面板一键登录 URL |
| `list` | GET | 订阅列表（id/name/url/type/enabled） |
| `add` | POST | 添加订阅（body: name,url），后台 --now 同步 |
| `update` | POST | 修改名称/URL/启停（body: id,name,url,enabled）；URL 变更回 pending |
| `delete` | POST | 删除订阅（body: id）+ 清理 provider 文件 |
| `refresh` | GET | 后台触发 sub.sh --now |
| `schedule` | GET/POST | 查看/修改刷新间隔（秒，白名单档位） |
| `logs` | GET | 最近 100 行日志 |
| `panel` | — | （并入 status 的 panel_url） |

### 订阅类型（subs.json）

- `http`：Clash 格式，内核 proxy-providers(type:http) 按 interval 自动拉取
- `file`：其他格式，sub.sh 定期经 subconverter 转换到 `providers/<id>.yaml`（type:file）
- `pending`：待分类（渲染时兜底为 file 类型）

## 配置文件（/root/.config/mihomo/）

| 文件 | 写方 | 说明 |
|------|------|------|
| `subs.json` | CGI | 订阅元数据（jq 维护） |
| `schedule.conf` | CGI | 刷新间隔秒数（21600/43200/86400/172800/259200/604800，默认 86400） |
| `secret` | init.sh | API/管理页密码（首次随机生成 32 hex） |
| `user-merge.yaml` | 用户 | 配置覆写，yq 深合并进生成配置 |
| `providers/` | sub.sh | 订阅缓存/转换产物（<id>.yaml） |
| `user_agent.txt` | 手动创建 | 拉取订阅的 UA，默认 `clash-verge/v2.5.1` |
| `geoip.metadb` / `geosite.dat` | Dockerfile/init.sh | 预下载 + 内核每周 auto-update |
| `config.yaml` | sub.sh | 渲染产物（模板+providers+user-merge），勿手改 |
| `log.txt` / `last_run` | sub.sh | 日志（1MB 截断）/ 节流时间戳 |
| `sub_urls.txt.bak` | init.sh | 旧版订阅列表迁移备份 |

## 依赖版本

| 组件 | 版本 | 来源 |
|------|------|------|
| mihomo | v1.19.33 | metacubex/mihomo 基础镜像 |
| metacubexd | v1.274.6 | MetaCubeX releases |
| subconverter | v0.9.9 | asdlokj1qpi233 fork |
| yq | Alpine | 用户覆写深合并（mikefarah v4） |
| busybox-extras | Alpine | httpd CGI 服务 |

## 本地测试

```bash
sh test/harness.sh    # CGI 全 action + render 产物 + YAML 结构断言，无需 docker
```

## 注意事项

- **`printf '%s'` 不用 `%b`（配置内容）** — 渲染全部 `%s`，防订阅数据字面量 `\n` 被转义；仅日志写盘用 `%b`
- **while 循环必须用输入重定向而非管道** — sub.sh 的循环体在子 shell 中会丢 `log` 变量追加（BusyBox ash 管道 fork）
- **URL/YAML 字符串安全** — 写入 YAML 的 URL/UA/secret 一律经 `jq -rn --arg … '$x|@json'` 输出 JSON 字符串
- **subconverter 的 `ua` 参数不生效** — fork 始终用 curl UA，sub.sh 自己 curl 直下再判断格式
- **手动 `--now` 会重置 `last_run`** — 定时刷新被推迟一个完整周期（设计使然，防封）
- **`--render` 模式零网络请求** — 仅重渲染+热重载，供增删改名/改间隔后调用
- **config.yaml 是渲染产物** — 用户自定义一律走 `user-merge.yaml`；yq 缺席或合并失败自动回退 base 配置
- **CHMOD 必须** — CGI 脚本必须有执行权限，Dockerfile 中已 `chmod +x`
