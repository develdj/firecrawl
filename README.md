Firecrawl Self-Hosted for Jetson Orin Nano
Self-hosted Firecrawl instance optimized for NVIDIA Jetson Orin Nano with local Ollama integration.

Features
🤖 Local AI: Uses Ollama with gpt-oss:20b model for extraction
🚀 Jetson Optimized: Configured for ARM64 architecture with CUDA support
🔄 Official Repo: Builds directly from mendableai/firecrawl repository
📦 All-in-One: API, Worker, MCP Server, and Playground UI in single container
🎯 Coolify Ready: Deploy via Coolify or docker-compose
Prerequisites
NVIDIA Jetson Orin Nano (8GB+ RAM recommended)
Docker and Docker Compose installed
Ollama running with models:
gpt-oss:20b (LLM)
nomic-embed-text:v1.5 (Embeddings)
Quick Start
Option 1: Deploy with Coolify
Create Redis service in Coolify:
Add new resource → Redis 7-alpine
Name it firecrawl-redis
Create Firecrawl application:
Add new resource → Docker Image / Dockerfile
Select this repository as source
Configure environment variables (see .env.example)
Set environment variables in Coolify:
bash
   REDIS_URL=redis://firecrawl-redis:6379
   OLLAMA_BASE_URL=http://172.17.0.1:11434/api
   MODEL_NAME=gpt-oss:20b
   BULL_AUTH_KEY=your-secure-password
Deploy and access:
Coolify will assign a URL or you can add custom domain
Access playground at root URL
API available at /v1/
Option 2: Deploy with Docker Compose
Clone repository:
bash
   git clone <your-repo-url>
   cd firecrawl-selfhost
Create environment file:
bash
   cp .env.example .env
   nano .env  # Edit configuration
Create required directories:
bash
   mkdir -p logs data docker
Add playground HTML:
bash
   # Copy playground.html to docker/ directory
   cp playground.html docker/
Build and start:
bash
   docker compose build
   docker compose up -d
Access services:
Playground: http://localhost:3004
API: http://localhost:3002
Bull Dashboard: http://localhost:3002/admin/CHANGEME/queues
Directory Structure
.
├── Dockerfile                 # Main container definition
├── docker-compose.yaml        # Orchestration configuration
├── .env.example              # Environment variables template
├── docker/
│   └── playground.html       # Web UI (optional, embedded in Dockerfile)
├── logs/                     # Application logs
└── data/                     # Persistent data
Configuration
Essential Environment Variables
Variable	Default	Description
REDIS_URL	redis://redis:6379	Redis connection string
OLLAMA_BASE_URL	http://172.17.0.1:11434/api	Ollama API endpoint
MODEL_NAME	gpt-oss:20b	LLM model for extraction
MODEL_EMBEDDING_NAME	nomic-embed-text:v1.5	Embedding model
BULL_AUTH_KEY	CHANGEME	Bull dashboard password
MAX_CPU	0.75	CPU usage limit (0.0-1.0)
MAX_RAM	0.75	RAM usage limit (0.0-1.0)
Ollama Connection
The container can connect to Ollama in multiple ways:

Method 1: Docker Gateway (Default)

bash
OLLAMA_BASE_URL=http://172.17.0.1:11434/api
Method 2: Host Network

bash
# In docker-compose.yaml, add to firecrawl service:
network_mode: "host"
# Then use:
OLLAMA_BASE_URL=http://localhost:11434/api
Method 3: Container IP

bash
# Find Ollama container IP:
docker inspect <ollama-container> | grep IPAddress
# Use that IP:
OLLAMA_BASE_URL=http://<ip>:11434/api
API Usage
Scrape a URL
bash
curl -X POST http://localhost:3002/v1/scrape \
  -H 'Content-Type: application/json' \
  -d '{
    "url": "https://example.com",
    "formats": ["markdown", "extract"],
    "extract": {
      "prompt": "Extract the main heading and description"
    }
  }'
Crawl a Website
bash
curl -X POST http://localhost:3002/v1/crawl \
  -H 'Content-Type: application/json' \
  -d '{
    "url": "https://example.com",
    "limit": 10,
    "maxDepth": 2
  }'
Map a Website
bash
curl -X POST http://localhost:3002/v1/map \
  -H 'Content-Type: application/json' \
  -d '{
    "url": "https://example.com"
  }'
Updating
The Dockerfile clones from the official Firecrawl repository, so rebuilding will pull the latest code:

With Docker Compose:

bash
docker compose build --no-cache
docker compose up -d
With Coolify:

Click "Redeploy" in Coolify
Enable "Force Rebuild" option
Monitoring
View Logs
Docker Compose:

bash
docker compose logs -f firecrawl
Coolify:

Open application in Coolify dashboard
Click "Logs" tab
Check Service Health
bash
# API health
curl http://localhost:3002/v1/test

# Container stats
docker stats firecrawl-app

# Jetson resource usage
sudo tegrastats
Bull Dashboard
Access the queue management dashboard:

http://localhost:3002/admin/<your-bull-auth-key>/queues
Troubleshooting
Ollama Connection Fails
Verify Ollama is accessible:
bash
   curl http://localhost:11434/api/tags
Test from container:
bash
   docker exec -it firecrawl-app curl http://172.17.0.1:11434/api/tags
Check Ollama is listening on all interfaces:
bash
   docker exec -it <ollama-container> env | grep OLLAMA_HOST
   # Should show: OLLAMA_HOST=0.0.0.0
Redis Connection Issues
bash
# Check Redis is running
docker ps | grep redis

# Test Redis connection
docker exec -it firecrawl-redis redis-cli ping

# Check from Firecrawl container
docker exec -it firecrawl-app redis-cli -h redis ping
High Memory Usage
Monitor usage:
bash
   docker stats
   sudo tegrastats
Reduce Node memory limit in .env:
bash
   NODE_OPTIONS=--max-old-space-size=3072
Use a smaller Ollama model:
bash
   MODEL_NAME=deepseek-r1:14b  # or llama3.1:8b
API Not Responding
bash
# Check if services started
docker exec -it firecrawl-app ps aux | grep node

# View startup logs
docker logs firecrawl-app

# Check specific service logs
docker exec -it firecrawl-app cat /app/logs/api.log
docker exec -it firecrawl-app cat /app/logs/worker.log
Performance Optimization
Ollama Model Selection
Model	Size	Speed	Quality	Use Case
gpt-oss:20b	13GB	Slow	Best	Production
deepseek-r1:14b	9GB	Medium	Good	Balanced
llama3.1:8b	4.9GB	Fast	Good	Development
deepseek-r1:1.5b	1.1GB	Very Fast	Basic	Testing
Resource Limits
For Jetson Orin Nano (8GB RAM):

bash
MAX_CPU=0.75
MAX_RAM=0.75
NODE_OPTIONS=--max-old-space-size=3072
For systems with more RAM:

bash
MAX_CPU=0.85
MAX_RAM=0.85
NODE_OPTIONS=--max-old-space-size=6144
Concurrent Jobs
Reduce concurrent jobs in Bull dashboard to prevent memory issues:

Access Bull dashboard
Go to Queue settings
Set concurrency to 2-3
Integration Examples
n8n Workflow
Use Firecrawl in n8n workflows:

json
{
  "method": "POST",
  "url": "http://firecrawl-app:3002/v1/scrape",
  "body": {
    "url": "{{$json.url}}",
    "formats": ["markdown", "extract"]
  }
}
SearXNG Integration
Enable SearXNG for /search endpoint:

bash
SEARXNG_ENDPOINT=http://searxng-container:8080
Ports Reference
Port	Service	Access
3002	API	Internal/External
3003	Bull Dashboard	Internal only
3004	Playground UI	External (via port 80)
3005	Worker	Internal only
3006	MCP Server	Internal only
Security Notes
Change default Bull auth key:
bash
   BULL_AUTH_KEY=<strong-random-password>
Use reverse proxy for production:
Coolify handles this automatically
For manual setup, use Nginx or Traefik
Network isolation:
Keep Redis internal-only
Only expose necessary ports
Regular updates:
bash
   docker compose pull
   docker compose build --no-cache
   docker compose up -d
Backup and Restore
Backup Redis Data
bash
docker exec firecrawl-redis redis-cli BGSAVE
docker cp firecrawl-redis:/data/dump.rdb ./backup/
Backup Volumes
bash
docker run --rm \
  -v firecrawl-selfhost_redis-data:/data \
  -v $(pwd)/backup:/backup \
  alpine tar czf /backup/redis-$(date +%Y%m%d).tar.gz /data
Restore
bash
docker run --rm \
  -v firecrawl-selfhost_redis-data:/data \
  -v $(pwd)/backup:/backup \
  alpine tar xzf /backup/redis-YYYYMMDD.tar.gz -C /
Support
Official Firecrawl Docs: https://docs.firecrawl.dev
GitHub Repository: https://github.com/mendableai/firecrawl
Jetson Forums: https://forums.developer.nvidia.com
License
This deployment configuration is provided as-is. Firecrawl itself is licensed under the terms of the mendableai/firecrawl repository.

