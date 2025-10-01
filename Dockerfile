# Stage 1: Builder
FROM dustynv/cuda-python:r36.4.0-cu128-24.04 AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl git build-essential python3 g++ make \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@9.13.0

# Clone Firecrawl and build API
RUN git clone https://github.com/mendableai/firecrawl.git /build/firecrawl
WORKDIR /build/firecrawl/apps/api
RUN pnpm install --shamefully-hoist && pnpm run build

# Stage 2: Runtime
FROM dustynv/cuda-python:r36.4.0-cu128-24.04

WORKDIR /app

# Install runtime dependencies including Chromium for ARM64
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium-browser curl wget gnupg ca-certificates fonts-liberation \
    redis-tools nginx python3 netcat-openbsd libatk-bridge2.0-0 libatk1.0-0 \
    libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libglib2.0-0 \
    libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 \
    libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
    lsb-release wget xdg-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy Firecrawl build artifacts from builder
COPY --from=builder /build/firecrawl /app/firecrawl

# Install pnpm & napi-cli for runtime
RUN npm install -g pnpm napi-cli

# Install Rust (optional, if your app uses native Rust modules)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Configure pip for Jetson AI Lab repo
RUN pip3 config set global.extra-index-url https://pypi.jetson-ai-lab.io/jp6/cu129/+simple/

# Clone Firecrawl
RUN git clone https://github.com/mendableai/firecrawl.git /app/firecrawl

# Build Firecrawl API
WORKDIR /app/firecrawl/apps/api
RUN pnpm install --frozen-lockfile && pnpm run build

# Prepare HTML playground
RUN mkdir -p /var/www/html
COPY docker/playground.html /var/www/html/index.html

# Create startup script
RUN mkdir -p /app/logs
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e
echo "Starting Firecrawl services..."
nginx -g "daemon off;" &
echo "Waiting for Redis..."
until redis-cli -u ${REDIS_URL:-redis://redis:6379} ping 2>/dev/null; do sleep 2; done
echo "Redis connected"
cd /app/firecrawl/apps/api
NODE_ENV=production PORT=3002 HOST=0.0.0.0 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/index.js > /app/logs/api.log 2>&1 &
echo "Waiting for API..."
until nc -z localhost 3002; do sleep 2; done
echo "API ready"
NODE_ENV=production IS_WORKER_PROCESS=true PORT=3005 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/services/queue-worker.js > /app/logs/worker.log 2>&1 &
echo "All services started"
wait
EOF
RUN chmod +x /app/start.sh

# Configure nginx
RUN cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80;
    root /var/www/html;
    client_max_body_size 50M;

    location / {
        try_files $uri $uri/ =404;
    }

    location /v1/ {
        proxy_pass http://127.0.0.1:3002/v1/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }

    location /admin/ {
        proxy_pass http://127.0.0.1:3002/admin/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
}
EOF

ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PORT=3002 \
    HOST=0.0.0.0 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s \
    CMD nc -z localhost 80 && nc -z localhost 3002 || exit 1

CMD ["/app/start.sh"]
