# Changelog

## [3.0.0] — 2026-11-11

### 重构：proxy-providers 架构（类客户端形态）

- **依赖升级**：mihomo v1.19.25 → v1.19.33，metacubexd v1.248.7 → v1.274.6

- **Clash 格式订阅直连内核**：不再下载-提取-合并，交给 mihomo 原生 `proxy-providers` 按 interval 自动拉取 + 健康检查，拉取频率精确可控（防机场封禁）
- **订阅管理升级**：增删改查、启停、重命名、改 URL（subs.json 元数据），全部 Web 页面完成
- **刷新间隔档位**：6 小时 ~ 每 7 天六档白名单（默认每天），改完立即生效（重新渲染 provider interval）；旧值低于下限自动钳制
- **API secret 鉴权**：首次启动生成随机 secret；9090 API 与 9091 管理页共用，面板一键登录（setup 深链接）；管理页密码可用环境变量 `disable_auth=true` 关闭（9090 API 保护不受影响）
- **用户覆写**：`user-merge.yaml` 经 yq 深合并进生成配置，DNS/规则自定义不再被订阅刷新冲掉
- **内核守护**：mihomo 异常退出 2 秒自动拉起；配置写入前过 `/mihomo -t` 校验，坏覆写不再能搞挂内核
- **GeoIP/GeoSite 每周自动更新**（geo-auto-update），不再冻结在构建期
- **默认规则**：GEOSITE/GEOIP 国内直连 + MATCH,PROXY；`PROXY`（手动）/`AUTO`（url-test）双分组；`store-selected` 记住面板选择
- **旧版自动迁移**：sub_urls.txt → subs.json（保留 .bak），schedule 档位 → 秒
- **本地测试 harness**：CGI 全 action + 渲染产物断言（`.omc/test/harness.sh`），不依赖 docker

### 修复

- CGI `add` jq 表达式变量名错误（$url 未定义导致添加订阅必然失败）
- `--render` 模式不再触发订阅下载（纯渲染，零网络请求）
- sub.sh 循环改输入重定向，子 shell 丢失日志的问题
- CGI 参数提取支持首参数（action= 在首位时解析失败）

---

## [2.0.0] — 2026-05-29

### 新增

- **Web 管理页面**（`:9091`）：订阅增删、定时刷新配置、一键手动刷新、日志查看、跳转 metacubexd 面板
- **多订阅支持**：自动合并多个订阅的节点和规则
- **定时刷新**：支持每 15 分钟、每小时、每天三种调度
- **手动刷新**：管理页面一键触发，带 30 秒防重复冷却
- **配置持久化**：空挂载目录自动补全初始文件，更新镜像不丢配置
- **容器启动检测**：mihomo 和 subconverter 启动超时自动退出
- **日志自动截断**：超 1MB 只保留最新 50KB
- **HEALTHCHECK**：每 2 分钟检查 mihomo API 可用性
- **下载完整性校验**：构建时验证 tgz 压缩包完整性
- **MIT License** + 免责声明

### 修复

- `printf "%b"` 改为 `printf "%s"`，防止订阅数据中的转义序列破坏 YAML
- Windows 换行符（`\r`）自动去除
- subconverter UA 参数失效问题：curl 直接下载，按需走 subconverter 兜底
- 配置重载失败静默忽略 bug（`sub_exit_code` → `reload_exit_code`）
- 错误路径 `exit 0` → 正确传递退出码
- 多架构构建默认 case 不再静默降级

### 变更

- **Dockerfile**：新增 busybox-extras、EXPOSE 9091、架构严格匹配
- **环境变量**：移除已废弃的 `config_url`
- **CI/CD**：PR 仅构建不推送、login-action v3、README 自动同步到 Docker Hub、GHA 缓存加速

---

## [1.x] — 2026-05-28 及更早

- Docker 化 mihomo + subconverter + metacubexd
- 单订阅环境变量配置
- 每日 cron 订阅更新
- 多架构构建支持
- GitHub Actions 自动构建推送
