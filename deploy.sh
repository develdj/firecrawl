#!/bin/bash
# Deploy Firecrawl for Jetson Orin AGX

set -e

echo "🔥 Firecrawl Deployment Script"
echo "=============================="

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Clean up any existing deployment
echo "Cleaning up existing deployment..."
docker compose down --remove-orphans 2>/dev/null || true
docker volume rm firecrawl_redis-data 2>/dev/null || true

# Create .env if it doesn't exist
if [ ! -f .env ]; then
    echo "Creating .env file..."
    cat > .env << 'EOF'
# Firecrawl Environment Configuration
USE_DB_AUTHENTICATION=false
TEST_API_KEY=test-api-key-jetson
OPENAI_API_KEY=ollama
OPENAI_BASE_URL=http://host.docker.internal:11434/v1
LLM_MODEL=llama3.2
SEARXNG_URL=http://host.docker.internal:8888
LOGGING_LEVEL=info
EOF
fi

# Build the image
echo ""
echo "Building Docker image..."
docker build -t firecrawl-jetson:latest -f Dockerfile . || {
    echo -e "${RED}Build failed!${NC}"
    exit 1
}

echo -e "${GREEN}✓ Image built successfully${NC}"

# Start services
echo ""
echo "Starting services..."
docker compose up -d || {
    echo -e "${RED}Failed to start services!${NC}"
    exit 1
}

# Wait for services
echo ""
echo "Waiting for services to be ready..."
sleep 15

# Check health
echo ""
echo "Checking service health..."

# Check Redis
if docker exec $(docker ps -qf "name=redis") redis-cli ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Redis is healthy${NC}"
else
    echo -e "${RED}✗ Redis failed${NC}"
fi

# Check API
if curl -s -f http://localhost:3002/test > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Firecrawl API is healthy${NC}"
else
    echo -e "${YELLOW}⚠ API is still starting...${NC}"
fi

# Check Playwright
if curl -s -f http://localhost:3050 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Playwright service is healthy${NC}"
else
    echo -e "${YELLOW}⚠ Playwright is still starting...${NC}"
fi

echo ""
echo "🚀 Deployment Complete!"
echo "====================="
echo ""
echo "Services:"
echo "- Firecrawl API: http://localhost:3002"
echo "- Bull Dashboard: http://localhost:3003"
echo "- Playwright: http://localhost:3050"
echo ""
echo "Test with:"
echo 'curl -X POST http://localhost:3002/v1/scrape \'
echo '  -H "Content-Type: application/json" \'
echo '  -H "Authorization: Bearer test-api-key-jetson" \'
echo '  -d "{\"url\": \"https://example.com\"}"'
echo ""
echo "View logs: docker compose logs -f firecrawl"
echo "Stop: docker compose down"
