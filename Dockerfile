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
    # Install chromium browser for ARM64
    chromium-browser \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20.x and pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g pnpm@9.13.0

# Install Puppeteer (better ARM64 support than Playwright)
RUN npm install -g puppeteer@21.0.0

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

# Create a Puppeteer-based browser service
RUN cat > /app/browser-service.js << 'EOF'
const http = require('http');
const puppeteer = require('puppeteer');

const server = http.createServer(async (req, res) => {
  console.log(`Received request: ${req.method} ${req.url}`);
  
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
    return;
  }

  if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Browser service is running (Puppeteer/Chromium)');
    return;
  }

  // Handle browser operations
  try {
    if (req.method === 'POST' && req.url === '/browser/execute') {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', async () => {
        const browser = await puppeteer.launch({
          headless: true,
          executablePath: '/usr/bin/chromium-browser',
          args: [
            '--no-sandbox',
            '--disable-setuid-sandbox',
            '--disable-dev-shm-usage',
            '--disable-gpu',
            '--no-first-run',
            '--no-zygote',
            '--single-process'
          ]
        });
        try {
          const page = await browser.newPage();
          // Process request based on body content
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ status: 'success' }));
        } finally {
          await browser.close();
        }
      });
    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  } catch (error) {
    console.error('Browser service error:', error);
    res.writeHead(500);
    res.end(JSON.stringify({ error: error.message }));
  }
});

const PORT = process.env.PLAYWRIGHT_PORT || 3000;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`Browser service (Puppeteer) listening on port ${PORT}`);
});
EOF

# Configure nginx
RUN cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    root /var/www/html;
    index index.html;
    
    server_name _;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
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
    }
    
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Create supervisor configuration
RUN cat > /etc/supervisor/conf.d/firecrawl.conf << 'EOF'
[supervisord]
nodaemon=true
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/nginx.log
stderr_logfile=/var/log/supervisor/nginx.log
priority=1

[program:browser-service]
command=node /app/browser-service.js
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/browser.log
stderr_logfile=/var/log/supervisor/browser.log
environment=NODE_ENV="production",PLAYWRIGHT_PORT="3000",PUPPETEER_SKIP_CHROMIUM_DOWNLOAD="true"
priority=5

[program:redis-check]
command=/bin/bash -c 'until redis-cli -h ${REDIS_HOST:-redis} ping; do echo "Waiting for Redis..."; sleep 2; done; echo "Redis ready"'
autostart=true
autorestart=false
stdout_logfile=/var/log/supervisor/redis-check.log
stderr_logfile=/var/log/supervisor/redis-check.log
priority=10

[program:firecrawl-worker]
command=node dist/src/services/queue-worker.js
directory=/app/firecrawl/apps/api
autostart=true
autorestart=true
stdout_logfile=/app/logs/worker.log
stderr_logfile=/app/logs/worker-error.log
environment=NODE_ENV="production",IS_WORKER_PROCESS="true",PLAYWRIGHT_MICROSERVICE_URL="http://localhost:3000"
priority=20
startsecs=10

[program:firecrawl-api]
command=node dist/src/index.js
directory=/app/firecrawl/apps/api
autostart=true
autorestart=true
stdout_logfile=/app/logs/api.log
stderr_logfile=/app/logs/api-error.log
environment=NODE_ENV="production",PORT="3002",HOST="0.0.0.0",PLAYWRIGHT_MICROSERVICE_URL="http://localhost:3000"
priority=30
startsecs=10
EOF

# Create a health check script
RUN cat > /app/healthcheck.sh << 'EOF'
#!/bin/bash
# Check if nginx is responding
curl -f http://localhost/health || exit 1
# Check if API is responding
curl -f http://localhost:3002/test || exit 1
# Check if Browser service is responding
curl -f http://localhost:3000/health || exit 1
EOF
RUN chmod +x /app/healthcheck.sh

# Set environment variables
ENV NODE_ENV=production \
    PORT=3002 \
    HOST=0.0.0.0 \
    NUM_WORKERS_PER_QUEUE=8 \
    REDIS_HOST=redis \
    REDIS_URL=redis://redis:6379 \
    REDIS_RATE_LIMIT_URL=redis://redis:6379 \
    USE_DB_AUTHENTICATION=false \
    PLAYWRIGHT_MICROSERVICE_URL=http://localhost:3000 \
    LOGGING_LEVEL=info \
    MAX_RAM=0.95 \
    MAX_CPU=0.95 \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# Expose ports
EXPOSE 80 3002

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /app/healthcheck.sh

# Use supervisor to manage all processes
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
