# The web (Windows) version of JouleSketch in a container.
#
#   docker build -t joulesketch .
#   docker run -p 8080:80 joulesketch      → http://localhost:8080
#
# Three steps: Swift compiles the shared code to WebAssembly, Node builds the
# page, and nginx serves the finished files. Only the last step ends up in
# the image, so it's small.

# 1. The shared Swift code → WebAssembly. The Wasm SDK must match the
#    toolchain version exactly.
FROM swift:6.4 AS swift
# Downloaded with curl and checked here, since `swift sdk install <url>`
# crashes inside the container; installing the local file works.
RUN swift --version \
    && curl -fsSL -o /tmp/wasm.artifactbundle.tar.gz \
       https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz \
    && echo "f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d  /tmp/wasm.artifactbundle.tar.gz" | sha256sum -c - \
    && swift sdk install /tmp/wasm.artifactbundle.tar.gz \
    && swift sdk list \
    && rm /tmp/wasm.artifactbundle.tar.gz
WORKDIR /src
COPY Package.swift Package.resolved* ./
COPY JouleSketch ./JouleSketch
COPY Web/Bridge ./Web/Bridge
RUN swift package --swift-sdk swift-6.4.0-RELEASE_wasm --allow-writing-to-package-directory \
    js -c release --product JouleWeb --output Web/app/core

# 2. The page around it.
FROM node:22-alpine AS web
WORKDIR /src/Web/app
COPY Web/app/package*.json ./
RUN npm install --no-audit --no-fund
COPY Web/app ./
COPY --from=swift /src/Web/app/core ./core
RUN npm run build

# 3. A small web server with just the finished site.
FROM nginx:alpine
COPY Web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web /src/Web/app/dist /usr/share/nginx/html
EXPOSE 80
