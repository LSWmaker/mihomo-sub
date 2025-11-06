# mihomo_sub

- docker 部署的 mihomo 核心, 每小时更新和转换订阅

## 部署示例
``` yml
services:
  mihomo:
    image: purewhiteicecream/mihomo_sub:latest
    container_name: mihomo_sub
    volumes:
      - /opt/mihomo_sub:/root/.config/mihomo
    environment:
      - "TZ=Asia/Shanghai"
      - "sub_url=https://这里换成你的订阅地址"
    ports:
     - "7890:7890"
     - "9090:9090"
```