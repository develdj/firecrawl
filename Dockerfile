FROM dustynv/cuda-python:r36.4.0-cu128-24.04

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential python3 make g++ libpq-dev \
    chromium-browser wget gnupg ca-certificates fonts-liberation \
    redis-tools nginx netcat-openbsd libatk-bridge2.0-0 libatk1.0-0 \
    libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libglib2.0-0 \
    libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 \
    libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
    lsb-release xdg-utils postgresql-client \
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

# Install dependencies including dev dependencies for build
# We need NODE_ENV=development to get TypeScript and other build tools
ENV NODE_ENV=development
RUN pnpm install --frozen-lockfile || true

# Rebuild native modules
RUN pnpm rebuild || true

# Build the application
RUN pnpm run build

# Clean dev dependencies and reinstall only production deps
RUN pnpm prune --prod || true

# Switch back to production environment
ENV NODE_ENV=production

# Prepare HTML playground
RUN mkdir -p /var/www/html
COPY docker/playground.html /var/www/html/index.html

# Create logs directory
RUN mkdir -p /app/logs

# Create startup script with DATABASE_URL auto-detection
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting Firecrawl services..."

# Check if DATABASE_URL is set, if not construct it from DB_ variables
if [ -z "$DATABASE_URL" ]; then
    echo "DATABASE_URL not set, constructing from DB_ variables..."
    
    # Use DB_ environment variables if they exist
    if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] && [ -n "$DB_NAME" ]; then
        DB_PORT=${DB_PORT:-5432}
        export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
        echo "Constructed DATABASE_URL from DB_ variables"
    else
        # Fallback to auto-detection
        echo "DB_ variables not found, attempting auto-detection..."
        
        POSTGRES_HOST=""
        
        # Check common postgres container names
        for name in postgres postgres-swk4w8gkc0kwogccc8gw0k48-081110613209 postgresql; do
            if getent hosts $name > /dev/null 2>&1; then
                POSTGRES_HOST=$name
                echo "Found PostgreSQL at: $POSTGRES_HOST"
                break
            fi
        done
        
        # Default if not found
        if [ -z "$POSTGRES_HOST" ]; then
            POSTGRES_HOST="10.0.7.2"
            echo "Using fallback PostgreSQL host: $POSTGRES_HOST"
        fi
        
        export DATABASE_URL="postgresql://firecrawl:firecrawl_password@${POSTGRES_HOST}:5432/firecrawl"
    fi
fi

echo "Using DATABASE_URL: ${DATABASE_URL//:*@//:***@}"

# Test database connection with better error handling
echo "Testing database connection..."
DB_HOST=$(echo $DATABASE_URL | sed 's/.*@//' | cut -d: -f1)
DB_PORT=$(echo $DATABASE_URL | sed 's/.*@//' | cut -d: -f2 | cut -d/ -f1)
DB_USER=$(echo $DATABASE_URL | sed 's/.*:\/\///' | cut -d: -f1)
DB_PASSWORD=$(echo $DATABASE_URL | sed 's/.*:\/\///' | cut -d: -f2 | cut -d@ -f1)
DB_NAME=$(echo $DATABASE_URL | sed 's/.*\///')

echo "Connecting to PostgreSQL at ${DB_HOST}:${DB_PORT} as user ${DB_USER}"

for i in {1..30}; do
    if PGPASSWORD=$DB_PASSWORD psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" > /dev/null 2>&1; then
        echo "Database connection successful!"
        break
    else
        if [ $i -eq 30 ]; then
            echo "Failed to connect to database after 30 attempts"
            echo "Connection details: host=$DB_HOST port=$DB_PORT user=$DB_USER database=$DB_NAME"
            exit 1
        fi
        echo "Waiting for database to be ready... (attempt $i/30)"
        sleep 2
    fi
done

# Wait for Redis
echo "Waiting for Redis..."
REDIS_HOST=$(echo ${REDIS_URL:-redis://redis:6379} | sed 's/redis:\/\///' | cut -d: -f1)
REDIS_PORT=$(echo ${REDIS_URL:-redis://redis:6379} | sed 's/.*://' | cut -d/ -f1)

for i in {1..30}; do
    if redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} ping 2>/dev/null; do
        echo "Redis connected"
        break
    else
        if [ $i -eq 30 ]; then
            echo "Failed to connect to Redis after 30 attempts"
            exit 1
        fi
        echo "Redis not ready, waiting... (attempt $i/30)"
        sleep 2
    fi
done

cd /app/firecrawl/apps/api

# Export all environment variables for the Node processes
export NODE_ENV="${NODE_ENV:-production}"
export PORT="${PORT:-3002}"
export HOST="${HOST:-0.0.0.0}"
export REDIS_URL="${REDIS_URL:-redis://redis:6379}"
export REDIS_RATE_LIMIT_URL="${REDIS_RATE_LIMIT_URL:-redis://redis:6379}"
export BULL_AUTH_KEY="${BULL_AUTH_KEY:-your-secure-password}"
export USE_DB_AUTHENTICATION="${USE_DB_AUTHENTICATION:-false}"
export PUPPETEER_EXECUTABLE_PATH="${PUPPETEER_EXECUTABLE_PATH:-/usr/bin/chromium-browser}"

# Start API server
echo "Starting API server with DATABASE_URL=${DATABASE_URL//:*@//:***@}"
node dist/src/index.js > /app/logs/api.log 2>&1 &
API_PID=$!

# Wait for API to be ready
echo "Waiting for API to start..."
for i in {1..60}; do
    if nc -z localhost 3002; then
        echo "API ready on port 3002"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "API failed to start after 60 seconds"
        echo "Last 50 lines of API log:"
        tail -50 /app/logs/api.log
        exit 1
    fi
    sleep 2
done

# Start worker process
echo "Starting worker process..."
IS_WORKER_PROCESS=true node dist/src/services/queue-worker.js > /app/logs/worker.log 2>&1 &
WORKER_PID=$!

echo "All services started successfully"
echo "API PID: $API_PID"
echo "Worker PID: $WORKER_PID"
echo "Nginx serving on port 80"

# Monitor processes
while true; do
    if ! kill -0 $API_PID 2>/dev/null; then
        echo "API process died! Last log entries:"
        tail -20 /app/logs/api.log
        exit 1
    fi
    if ! kill -0 $WORKER_PID 2>/dev/null; then
        echo "Worker process died! Last log entries:"
        tail -20 /app/logs/worker.log
        exit 1
    fi
    sleep 10
done

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
