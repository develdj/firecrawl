FROM dustynv/cuda-python:r36.4.0-cu128-24.04

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential python3 g++ make \
    chromium-browser wget gnupg ca-certificates fonts-liberation \
    redis-tools nginx netcat-openbsd libatk-bridge2.0-0 libatk1.0-0 \
    libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libglib2.0-0 \
    libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 \
    libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
    lsb-release xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Rust (required for native modules)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install pnpm and napi-cli globally
RUN npm install -g pnpm@9.13.0 @napi-rs/cli

# Configure pip for Jetson AI Lab repo
RUN pip3 config set global.extra-index-url https://pypi.jetson-ai-lab.io/jp6/cu129/+simple/

# Clone Firecrawl
RUN git clone https://github.com/mendableai/firecrawl.git /app/firecrawl

# Build Firecrawl API
WORKDIR /app/firecrawl/apps/api

# Install dependencies with proper native module support
# Skip optional msgpackr-extract to avoid compilation issues
RUN pnpm install --frozen-lockfile --ignore-scripts || true
RUN pnpm rebuild || true
RUN pnpm run build

# Prepare HTML playground
RUN mkdir -p /var/www/html
COPY docker/playground.html /var/www/html/index.html

# Create logs directory
RUN mkdir -p /app/logs

# Create startup script
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting Firecrawl services..."

# Start nginx in background
nginx -g "daemon off;" &

# Wait for Redis
echo "Waiting for Redis..."
REDIS_HOST=$(echo $REDIS_URL | sed 's/redis:\/\///' | cut -d: -f1)
REDIS_PORT=$(echo $REDIS_URL | sed 's/redis:\/\///' | cut -d: -f2 | cut -d/ -f1)
until redis-cli -h ${REDIS_HOST:-redis} -p ${REDIS_PORT:-6379} ping 2>/dev/null; do 
    echo "Redis not ready, waiting..."
    sleep 2
done
echo "Redis connected"

cd /app/firecrawl/apps/api

# Start API server
echo "Starting API server..."
NODE_ENV=production \
  PORT=3002 \
  HOST=0.0.0.0 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/index.js > /app/logs/api.log 2>&1 &

API_PID=$!

# Wait for API to be ready
echo "Waiting for API..."
for i in {1..60}; do
    if nc -z localhost 3002; then
        echo "API ready"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "API failed to start"
        cat /app/logs/api.log
        exit 1
    fi
    sleep 2
done

# Start worker process
echo "Starting worker process..."
NODE_ENV=production \
  IS_WORKER_PROCESS=true \
  PORT=3005 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/services/queue-worker.js > /app/logs/worker.log 2>&1 &

WORKER_PID=$!

echo "All services started successfully"
echo "API PID: $API_PID"
echo "Worker PID: $WORKER_PID"

# Monitor processes
while true; do
    if ! kill -0 $API_PID 2>/dev/null; then
        echo "API process died!"
        cat /app/logs/api.log
        exit 1
    fi
    if ! kill -0 $WORKER_PID 2>/dev/null; then
        echo "Worker process died!"
        cat /app/logs/worker.log
        exit 1
    fi
    sleep 10
done
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
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 120s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }
    
    location /admin/ {
        proxy_pass http://127.0.0.1:3002/admin/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# Set environment variables
ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PORT=3002 \
    HOST=0.0.0.0 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

EXPOSE 80 3002 3003 3005

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 80 && nc -z localhost 3002 || exit 1

CMD ["/app/start.sh"]
