#!/bin/bash

# Build and Deploy Firecrawl on Jetson Orin AGX
# This script builds the Docker image and manages the deployment

set -e

echo "🔥 Firecrawl Jetson Deployment Script"
echo "===================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if .env file exists
if [ ! -f .env ]; then
    echo -e "${YELLOW}Warning: .env file not found. Creating from example...${NC}"
    cp .env.example .env
    echo -e "${GREEN}Created .env file. Please update it with your configuration.${NC}"
fi

# Function to check if Ollama is accessible
check_ollama() {
    echo "Checking Ollama connectivity..."
    if curl -s http://192.168.1.81:11434/api/tags > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Ollama is accessible at 192.168.1.81:11434${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Ollama is not accessible at 192.168.1.81:11434${NC}"
        echo "  Make sure Ollama is running and accessible from Docker containers"
        return 1
    fi
}

# Function to check if SearXNG is accessible
check_searxng() {
    echo "Checking SearXNG connectivity..."
    if curl -s http://192.168.1.81:8888 > /dev/null 2>&1; then
        echo -e "${GREEN}✓ SearXNG is accessible at 192.168.1.81:8888${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ SearXNG is not accessible at 192.168.1.81:8888${NC}"
        echo "  Search functionality will be limited"
        return 1
    fi
}

# Check external services
echo ""
echo "Checking external services..."
echo "----------------------------"
check_ollama
check_searxng

# Check if services are already running
echo ""
echo "Checking for existing services..."
if $COMPOSE_CMD ps | grep -q "Up"; then
    echo "Found existing services. Stopping them..."
    $COMPOSE_CMD down
    sleep 5
fi

# Build Docker image
echo ""
echo "Building Docker image..."
echo "----------------------"
docker build -t firecrawl-jetson:latest -f Dockerfile .

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Docker image built successfully${NC}"
else
    echo -e "${RED}✗ Docker image build failed${NC}"
    exit 1
fi

# Start services
echo ""
echo "Starting services..."
echo "------------------"

# Check if we should use docker-compose or docker compose
if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

# Start the services
$COMPOSE_CMD up -d

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Services started successfully${NC}"
else
    echo -e "${RED}✗ Failed to start services${NC}"
    exit 1
fi

# Wait for services to be ready
echo ""
echo "Waiting for services to be ready..."
sleep 10

# Check service health
echo ""
echo "Checking service health..."
echo "------------------------"

# Check Redis
REDIS_CONTAINER=$(docker ps -qf "name=redis")
if [ -n "$REDIS_CONTAINER" ]; then
    if docker exec $REDIS_CONTAINER redis-cli ping > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Redis is healthy${NC}"
    else
        echo -e "${RED}✗ Redis is not responding${NC}"
    fi
else
    echo -e "${RED}✗ Redis container not found${NC}"
fi

# Check Firecrawl API
if curl -s http://localhost:3002/test > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Firecrawl API is healthy${NC}"
else
    echo -e "${YELLOW}⚠ Firecrawl API is still starting up...${NC}"
fi

# Display service URLs
echo ""
echo "🚀 Deployment Complete!"
echo "====================="
echo ""
echo "Service URLs:"
echo "- Firecrawl API: http://localhost:3002"
echo "- Bull Board (Queue Monitor): http://localhost:3003"
echo "- Playwright Service: http://localhost:3000"
echo ""
echo "Test the API with:"
echo 'curl -X POST http://localhost:3002/v1/scrape \\'
echo '  -H "Content-Type: application/json" \\'
echo '  -H "Authorization: Bearer test-api-key-jetson" \\'
echo '  -d "{\"url\": \"https://example.com\"}"'
echo ""
echo "View logs with:"
echo "$COMPOSE_CMD logs -f firecrawl-api"
echo ""
echo "Stop services with:"
echo "$COMPOSE_CMD down"
