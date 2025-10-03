FROM dustynv/cuda-python:r36.4.0-cu128-24.04

WORKDIR /app

# ----------------------------------------------------------
# Install system dependencies
# ----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential python3 make g++ libpq-dev \
    chromium-browser wget gnupg ca-certificates fonts-liberation \
    redis-tools nginx netcat-openbsd libatk-bridge2.0-0 libatk1.0-0 \
    libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libglib2.0-0 \
    libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 \
    libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
    lsb-release xdg-utils postgresql-client psmisc \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------
# Install Node.js 20
# ----------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------
# Install Rust (required for native modules)
# ----------------------------------------------------------
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# ----------------------------------------------------------
# Install pnpm and napi-cli globally
# ----------------------------------------------------------
RUN npm install -g pnpm@9.13.0 @napi-rs/cli

# ----------------------------------------------------------
# Configure pip for Jetson AI Lab repo (for Python deps)
# ----------------------------------------------------------
RUN pip3 config set global.extra-index-url https://pypi.jetson-ai-lab.io/jp6/cu129/+simple/

# ----------------------------------------------------------
# Copy Firecrawl source (use your fork, not upstream)
# ----------------------------------------------------------
COPY . /app/firecrawl

# ----------------------------------------------------------
# Build Firecrawl API
# ----------------------------------------------------------
WORKDIR /app/firecrawl/apps/api

ENV NODE_ENV=development
RUN pnpm install --frozen-lockfile || true
RUN pnpm rebuild || true
RUN pnpm run build
RUN pnpm prune --prod || true

# Patch the queue-worker to not start HTTP server on port 3002
RUN if grep -q "app.listen" dist/src/services/queue-worker.js; then \
    sed -i 's/app\.listen(3002/app.listen(3005/' dist/src/services/queue-worker.js || true; \
    sed -i 's/app\.listen(PORT/app.listen(process.env.WORKER_PORT || 3005/' dist/src/services/queue-worker.js || true; \
    fi

ENV NODE_ENV=production

# ----------------------------------------------------------
# Prepare Playground HTML
# ----------------------------------------------------------
RUN mkdir -p /var/www/html
COPY docker/playground.html /var/www/html/index.html

# ----------------------------------------------------------
# Logs directory
# ----------------------------------------------------------
RUN mkdir -p /app/logs

# ----------------------------------------------------------
# Create worker wrapper script
# ----------------------------------------------------------
RUN cat > /app/firecrawl/apps/api/worker-only.js << 'EOF'
// Worker-only entry point that doesn't start HTTP server
process.env.WORKER_ONLY = 'true';
require('./dist/src/services/queue-worker.js');
EOF

# ----------------------------------------------------------
# Create startup script with proper cleanup
# ----------------------------------------------------------
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting Firecrawl services..."

# Kill any existing processes on ports
echo "Cleaning up existing processes..."
fuser -k 3002/tcp 2>/dev/null || true
fuser -k 3004/tcp 2>/dev/null || true
sleep 2

# Auto-generate DATABASE_URL if not provided
if [ -z "$DATABASE_URL" ]; then
    echo "DATABASE_URL not set, using fallback..."
    export DATABASE_URL="postgresql://firecrawl:firecrawl_password@postgres:5432/firecrawl"
fi

echo "Using DATABASE_URL: ${DATABASE_URL//:*@//:***@}"

# Wait for Postgres
echo "Waiting for PostgreSQL..."
for i in {1..30}; do
    if pg_isready -d "$DATABASE_URL" > /dev/null 2>&1; then
        echo "Postgres ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Postgres not available after 30 attempts"
        exit 1
    fi
    sleep 2
done

# Wait for Redis
echo "Waiting for Redis..."
REDIS_HOST=$(echo ${REDIS_URL:-redis://redis:6379} | sed 's/redis:\/\///' | cut -d: -f1)
REDIS_PORT=$(echo ${REDIS_URL:-redis://redis:6379} | sed 's/.*://' | cut -d/ -f1)

for i in {1..30}; do
    if redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} ping > /dev/null 2>&1; then
        echo "Redis ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Redis not available after 30 attempts"
        exit 1
    fi
    sleep 2
done

cd /app/firecrawl/apps/api

# Start Nginx for playground
echo "Starting Nginx..."
nginx || true

# Start API server
echo "Starting API server..."
node dist/src/index.js > /app/logs/api.log 2>&1 &
API_PID=$!
echo "API PID: $API_PID"

# Wait for API to start
sleep 5

# Check if API is actually running
if ! kill -0 $API_PID 2>/dev/null; then
    echo "API failed to start!"
    cat /app/logs/api.log
    exit 1
fi

echo "API started successfully"

# TEMPORARY: Skip worker startup to test if API works
echo "Skipping worker startup for now (testing API only)"
WORKER_PID=0

# Uncomment these lines once API is confirmed working:
# echo "Starting worker..."
# WORKER_PORT=3005 node dist/src/services/queue-worker.js > /app/logs/worker.log 2>&1 &
# WORKER_PID=$!
# echo "Worker PID: $WORKER_PID"
# sleep 3
# if ! kill -0 $WORKER_PID 2>/dev/null; then
#     echo "Worker failed to start!"
#     cat /app/logs/worker.log
#     exit 1
# fi
# echo "Worker started successfully"

# Cleanup function
cleanup() {
    echo "Shutting down services..."
    kill $API_PID 2>/dev/null || true
    kill $WORKER_PID 2>/dev/null || true
    nginx -s stop 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Keep alive and monitor processes
echo "All services running. Monitoring..."
while true; do
    if ! kill -0 $API_PID 2>/dev/null; then
        echo "API process died!"
        tail -50 /app/logs/api.log
        exit 1
    fi
    if ! kill -0 $WORKER_PID 2>/dev/null; then
        echo "Worker process died!"
        tail -50 /app/logs/worker.log
        exit 1
    fi
    sleep 10
done
EOF

RUN chmod +x /app/start.sh

# ----------------------------------------------------------
# Configure Nginx for Playground on port 3004
# ----------------------------------------------------------
RUN cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 3004;
    server_name _;
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
        proxy_read_timeout 300s;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
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

# ----------------------------------------------------------
# Runtime environment
# ----------------------------------------------------------
ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PORT=3002 \
    HOST=0.0.0.0 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

EXPOSE 3002 3003 3004 3005

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 3002 && nc -z localhost 3004 || exit 1

CMD ["/app/start.sh"]
