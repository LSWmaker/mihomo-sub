# mihomo-sub

`docker` 部署的 `mihomo` 核心，Web 页面管理订阅，为局域网设备（NAS、Switch 等）提供代理。

> [!WARNING]
> ## 免责声明
>
> 本项目仅供**学习研究**和**技术交流**使用。使用者应当遵守所在国家或地区的法律法规。
>
> - 本项目开发者**不提供**任何代理节点、订阅链接或翻墙服务
> - 使用者自行获取的订阅链接及其内容与开发者**无关**
> - 使用者应确保其使用行为符合当地法律法规，**自行承担**因使用本项目产生的一切后果和风险
> - **严禁**将本项目用于任何违法用途，包括但不限于传播非法信息、侵犯他人知识产权等
> - 本项目不提供任何形式的担保，使用过程中出现的任何问题开发者不承担责任
>
> **使用本项目即表示您已阅读并同意上述声明。**

## 许可

本项目基于 [MIT License](LICENSE) 开源。

## 特性

- **Web 管理页面** — 添加/修改/删除/启停订阅，无需重建容器
- **类客户端体验** — metacubexd 面板操作节点选择、延迟测试、连接查看、模式切换
- **智能订阅接入** — Clash 格式订阅交给 mihomo 内核原生 `proxy-providers` 定时拉取；其他格式经 subconverter 自动转换
- **可调刷新间隔** — 6 小时 ~ 每 7 天（默认每天），防止拉取过频被订阅服务商封禁
- **API 鉴权** — 首次启动生成随机 secret，管理页与代理面板共用，一键登录
- **用户覆写** — `user-merge.yaml` 深合并进生成的配置，自定义 DNS/规则且**不会被订阅刷新冲掉**
- **内核守护** — mihomo 异常退出自动拉起；GeoIP/GeoSite 每周自动更新
- **配置持久化** — 所有状态保存在 `/root/.config/mihomo/`，更新镜像不丢失

## 服务端口

| 端口 | 用途 |
|------|------|
| `7890` | 代理 mixed 端口（HTTP + SOCKS5，供局域网设备使用） |
| `9090` | mihomo API + 代理面板 (`/ui`) |
| `9091` | 订阅管理页面 |

## 部署

### Docker Compose（推荐）

```yaml
services:
  mihomo:
    image: lsw951753/mihomo-sub:latest
    container_name: mihomo-sub
    volumes:
      - ./mihomo-config:/root/.config/mihomo
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "7890:7890"
      - "9090:9090"
      - "9091:9091"
    restart: unless-stopped
```

> 首次启动时容器会自动在 `./mihomo-config` 目录下生成所需的初始文件（包括管理页登录密码）。空目录挂载完全没问题。

### 基础部署

```bash
docker run -d \
  --name mihomo-sub \
  -p 7890:7890 \
  -p 9090:9090 \
  -p 9091:9091 \
  -e TZ=Asia/Shanghai \
  lsw951753/mihomo-sub:latest
```

## 使用

### 首次登录

首次启动自动生成随机访问密码（即 API secret）：

```bash
docker exec mihomo-sub cat /root/.config/mihomo/secret
```

浏览器打开 `http://<服务器IP>:9091`，输入密码登录。

### 管理订阅

1. **添加订阅** — 粘贴订阅 URL，自动检测格式（Clash 直连 / 其他格式自动转换）
2. **修改/启停/删除** — 每条订阅可随时编辑 URL、重命名、临时禁用
3. **刷新间隔** — 6 小时 / 12 小时 / 每天（默认）/ 每 2 天 / 每 3 天 / 每 7 天。间隔过短可能被订阅服务商限流或封禁，档位下限即 6 小时
4. **立即刷新** — 手动触发全量同步
5. **打开面板** — 一键跳转 metacubexd（自动携带 secret，无需手填）

### 代理面板

`http://<服务器IP>:9090/ui` — 节点选择（`PROXY` 手动 / `AUTO` 自动测速）、连接查看、规则命中。

### 局域网设备接入

设备代理指向 `http://<服务器IP>:7890`（HTTP 或 SOCKS5 均可）。默认规则：国内直连、其余走 `PROXY` 分组。

### 自定义配置（覆写）

编辑挂载目录下的 `user-merge.yaml`（不存在则创建），内容会**深合并**进生成的配置（覆盖同名键、数组整体替换），订阅刷新不会冲掉它：

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
  - GEOSITE,cn,DIRECT
  - MATCH,PROXY
```

### 手动执行同步

```bash
docker exec mihomo-sub /etc/periodic/15min/sub.sh --now
```

## 持久化文件

| 文件 | 用途 |
|------|------|
| `subs.json` | 订阅元数据（名称/URL/类型/启停） |
| `schedule.conf` | 刷新间隔秒数（档位: 21600/43200/86400/172800/259200/604800） |
| `secret` | 管理页与 API 的访问密码 |
| `user-merge.yaml` | 用户配置覆写（可选） |
| `providers/` | 订阅缓存与转换产物 |
| `user_agent.txt` | 自定义拉取订阅的 User-Agent（可选，默认 `clash-verge/v2.5.1`） |
| `geoip.metadb` / `geosite.dat` | 地理库（首次自动复制，之后内核每周自动更新） |
| `config.yaml` | mihomo 配置（自动生成，勿手改——改 `user-merge.yaml`） |
| `log.txt` | 同步日志（超 1MB 自动截断） |

## 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `TZ` | 推荐 | 时区，如 `Asia/Shanghai` |
| `sub_url` | 否 | 初始订阅 URL（仅旧版升级首次迁移时使用；之后通过管理页面管理） |

## 从 2.x 升级

挂载目录不变。旧版 `sub_urls.txt` 会自动迁移到 `subs.json`（原文件保留为 `sub_urls.txt.bak`），旧版 `schedule.conf` 档位（`15min`/`hourly`/`daily`）自动换算为秒。

## 常见问题

**Q: 忘记管理页密码？**

```bash
docker exec mihomo-sub cat /root/.config/mihomo/secret
```

**Q: 更新镜像后配置会丢失吗？**

不会。订阅、密码、间隔、覆写全部在挂载目录里。

**Q: 添加订阅后一直显示"待检测"？**

后台同步需要几秒；若长时间不变，查看管理页日志（可能是订阅 URL 无法直连访问，或格式转换失败）。

**Q: 为什么我改了 config.yaml 不生效？**

`config.yaml` 由程序自动生成，任何手动修改都会在下一次同步时被覆盖。请把自定义内容放进 `user-merge.yaml`。

## 源码和仓库

- 源码: `https://github.com/pure-white-ice-cream/mihomo-sub`
- Docker Hub: `https://hub.docker.com/r/purewhiteicecream/mihomo-sub`
