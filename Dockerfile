# Use the CUDA-optimized Python base image for Jetson AGX
FROM dustynv/cuda-python:r36.4.0-cu128-24.04

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    redis-tools \
    ca-certificates \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libc6 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgbm1 \
    libgcc1 \
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

# Install Python dependencies for LLM features (if needed)
RUN pip install --no-cache-dir \
    openai \
    langchain \
    pydantic \
    httpx \
    python-dotenv

# Create necessary directories
RUN mkdir -p /app/logs /app/data

# Set environment variables
ENV NODE_ENV=production \
    PORT=3002 \
    HOST=0.0.0.0 \
    NUM_WORKERS_PER_QUEUE=8 \
    REDIS_URL=redis://redis:6379 \
    REDIS_RATE_LIMIT_URL=redis://redis:6379 \
    USE_DB_AUTHENTICATION=false \
    PLAYWRIGHT_MICROSERVICE_URL=http://playwright-service:3000 \
    LOGGING_LEVEL=info \
    MAX_RAM=0.95 \
    MAX_CPU=0.95

# Expose port
EXPOSE 3002

# Create a startup script
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting Firecrawl API..."

# Wait for Redis to be ready
until redis-cli -h redis ping; do
  echo "Waiting for Redis..."
  sleep 2
done

echo "Redis is ready!"

# Start the workers in background
cd /app/firecrawl/apps/api
pnpm run workers &

# Give workers time to start
sleep 5

# Start the API server
pnpm run start:production
EOF

RUN chmod +x /app/start.sh

# Run the startup script
CMD ["/app/start.sh"]
