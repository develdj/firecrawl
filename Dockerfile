# Use the CUDA-optimized Python base image for Jetson AGX
FROM dustynv/cuda-python:r36.4.0-cu128-24.04

# Set working directory
WORKDIR /app

# Install system dependencies including nginx and chromium
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    redis-tools \
    ca-certificates \
    fonts-liberation \
    libasound2t64 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libc6 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgbm1 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libstdc++6 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    lsb-release \
    wget \
    xdg-utils \
    supervisor \
    nginx \
    chromium-browser \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20.x and pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g pnpm@9.13.0

# Clone Firecrawl repository
RUN git clone https://github.com/develdj/firecrawl.git /app/firecrawl

# Set working directory to Firecrawl API
WORKDIR /app/firecrawl/apps/api

# Install dependencies
RUN pnpm install --frozen-lockfile

# Build the application
RUN pnpm run build

# Install Python dependencies for LLM features
RUN pip install --no-cache-dir \
    --index-url https://pypi.jetson-ai-lab.io/jp6/cu129 \
    --trusted-host pypi.jetson-ai-lab.io \
    openai langchain pydantic httpx python-dotenv || \
    pip install --no-cache-dir \
    openai langchain pydantic httpx python-dotenv

# Create necessary directories
RUN mkdir -p /app/logs /app/data /var/log/supervisor /var/www/html

# Copy playground.html to nginx directory
COPY playground.html /var/www/html/index.html

# Create browser service for port 3000 (internal only)
RUN cat > /app/browser-service.js << 'EOF'
const http = require('http');

const server = http.createServer(async (req, res) => {
  console.log(`Browser service received: ${req.method} ${req.url}`);
  
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Browser service ready on port 3000');
});

// MUST listen on port 3000 for Firecrawl compatibility
server.listen(3000, '0.0.0.0', () => {
  console.log('Browser service (playwright stub) listening on port 3000');
});
EOF

# Configure nginx to listen on port 80 (will be mapped to 3004 externally)
RUN cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.html;
    
    server_name _;
    
    # Serve playground UI
    location / {
        try_files $uri $uri/ =404;
    }
    
    # Proxy API requests to Firecrawl API on port 3002
    location /v1/ {
        proxy_pass http://localhost:3002/v1/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
    
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Create supervisor configuration with all services
RUN cat > /etc/supervisor/conf.d/firecrawl.conf << 'EOF'
[supervisord]
nodaemon=true
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

# Nginx serves playground on port 80 (mapped to 3004 externally)
[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/nginx.log
stderr_logfile=/var/log/supervisor/nginx.log
priority=1

# Browser service on port 3000 (internal only)
[program:browser-service]
command=node /app/browser-service.js
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/browser.log
stderr_logfile=/var/log/supervisor/browser.log
environment=NODE_ENV="production"
priority=5

[program:redis-check]
command=/bin/bash -c 'until redis-cli -h ${REDIS_HOST:-redis} ping; do echo "Waiting for Redis..."; sleep 2; done; echo "Redis ready"'
autostart=true
autorestart=false
stdout_logfile=/var/log/supervisor/redis-check.log
stderr_logfile=/var/log/supervisor/redis-check.log
priority=10

# Worker process on port 3005
[program:firecrawl-worker]
command=node dist/src/services/queue-worker.js
directory=/app/firecrawl/apps/api
autostart=true
autorestart=true
stdout_logfile=/app/logs/worker.log
stderr_logfile=/app/logs/worker-error.log
environment=NODE_ENV="production",IS_WORKER_PROCESS="true",PLAYWRIGHT_MICROSERVICE_URL="http://localhost:3000",PUPPETEER_EXECUTABLE_PATH="/usr/bin/chromium-browser",PORT="3005",WORKER_PORT="3005"
priority=20
startsecs=10

# API on port 3002 (exposed externally)
[program:firecrawl-api]
command=node dist/src/index.js
directory=/app/firecrawl/apps/api
autostart=true
autorestart=true
stdout_logfile=/app/logs/api.log
stderr_logfile=/app/logs/api-error.log
environment=NODE_ENV="production",PORT="3002",HOST="0.0.0.0",PLAYWRIGHT_MICROSERVICE_URL="http://localhost:3000",PUPPETEER_EXECUTABLE_PATH="/usr/bin/chromium-browser"
priority=30
startsecs=10
EOF

# Create health check script
RUN cat > /app/healthcheck.sh << 'EOF'
#!/bin/bash
# Check nginx (port 80 internal, 3004 external)
curl -f http://localhost/health || exit 1
# Check API (port 3002)
curl -f http://localhost:3002/test || exit 1
# Check browser service (port 3000 internal)
curl -f http://localhost:3000/health || exit 1
# Check worker if it exposes port 3005
curl -f http://localhost:3005/health || true  # Don't fail if worker doesn't have health endpoint
EOF
RUN chmod +x /app/healthcheck.sh

# Set environment variables
ENV NODE_ENV=production \
    PORT=3002 \
    HOST=0.0.0.0 \
    WORKER_PORT=3005 \
    NUM_WORKERS_PER_QUEUE=8 \
    REDIS_HOST=redis \
    REDIS_URL=redis://redis:6379 \
    REDIS_RATE_LIMIT_URL=redis://redis:6379 \
    USE_DB_AUTHENTICATION=false \
    PLAYWRIGHT_MICROSERVICE_URL=http://localhost:3000 \
    LOGGING_LEVEL=info \
    MAX_RAM=0.95 \
    MAX_CPU=0.95 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Expose API, nginx, and worker ports
EXPOSE 3002 80 3005

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /app/healthcheck.sh

# Start all services with supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
