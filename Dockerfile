FROM metacubex/mihomo:v1.19.25

RUN apk add --no-cache jq curl busybox-extras yq

# 安装 metacubexd Web 面板（存到初始化目录，运行时由 init.sh 复制）
RUN wget -O /tmp/metacubexd.tgz https://github.com/MetaCubeX/metacubexd/releases/download/v1.248.7/compressed-dist.tgz && \
    tar -tzf /tmp/metacubexd.tgz > /dev/null 2>&1 || { echo "metacubexd download corrupted"; exit 1; } && \
    mkdir -p /usr/share/mihomo-init/ui && \
    tar -xzf /tmp/metacubexd.tgz -C /usr/share/mihomo-init/ui && \
    rm -rf /tmp/metacubexd.tgz

# 安装 subconverter（多架构支持）
ARG TARGETARCH
ARG TARGETVARIANT
RUN case "${TARGETARCH}${TARGETVARIANT}" in \
        "arm64") \
            SUBCONV_FILE="subconverter_aarch64.tar.gz" ;; \
        "armv7") \
            SUBCONV_FILE="subconverter_armv7.tar.gz" ;; \
        "386") \
            SUBCONV_FILE="subconverter_linux32.tar.gz" ;; \
        "amd64") \
            SUBCONV_FILE="subconverter_linux64.tar.gz" ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}${TARGETVARIANT}"; exit 1 ;; \
    esac && \
    wget -O /tmp/subconverter.tar.gz https://github.com/asdlokj1qpi233/subconverter/releases/download/v0.9.9/${SUBCONV_FILE} && \
    tar -tzf /tmp/subconverter.tar.gz > /dev/null 2>&1 || { echo "subconverter download corrupted"; exit 1; } && \
    tar -xzf /tmp/subconverter.tar.gz -C / && \
    rm -rf /tmp/subconverter.tar.gz

# 初始 mihomo 配置（存到初始化目录，运行时由 init.sh 复制）
RUN echo 'mixed-port: 7890' > /usr/share/mihomo-init/config.yaml && \
    echo 'external-ui: /root/.config/mihomo/ui' >> /usr/share/mihomo-init/config.yaml && \
    echo 'allow-lan: true' >> /usr/share/mihomo-init/config.yaml && \
    echo 'external-controller: 0.0.0.0:9090' >> /usr/share/mihomo-init/config.yaml

# 预下载 GeoIP/GeoSite 数据库，避免启动时在国内直连 GitHub 超时
# busybox wget 不支持 --retry-connrefused，用 shell 循环做重试
RUN for f in geoip.metadb geosite.dat; do \
        ok=false; \
        for i in 1 2 3 4 5; do \
            wget -q -T 60 -O "/usr/share/mihomo-init/${f}" \
                "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${f}" && \
            [ "$(wc -c < "/usr/share/mihomo-init/${f}")" -gt 102400 ] && ok=true && break; \
            echo "retry ${i}/5: ${f}"; \
            sleep 2; \
        done; \
        $ok || { echo "failed to download ${f}"; exit 1; }; \
    done

# 安装管理页面
RUN mkdir -p /usr/share/mihomo-mgr/cgi-bin
COPY mgr/index.html /usr/share/mihomo-mgr/index.html
COPY mgr/cgi-bin/api /usr/share/mihomo-mgr/cgi-bin/api
RUN chmod +x /usr/share/mihomo-mgr/cgi-bin/api

# 安装启动脚本和订阅脚本
COPY init.sh /init.sh
COPY sub.sh /etc/periodic/15min/sub.sh
RUN chmod +x /init.sh /etc/periodic/15min/sub.sh

ENV sub_url=""

EXPOSE 7890 9090 9091

HEALTHCHECK --interval=120s --timeout=10s --retries=3 \
    CMD curl -sf --max-time 5 -H "Authorization: Bearer $(cat /root/.config/mihomo/secret)" \
        http://127.0.0.1:9090/version || exit 1

ENTRYPOINT ["/init.sh"]
