FROM dustynv/cuda-python:r36.4.0-cu128-24.04

WORKDIR /app

# Install dependencies with Jetson-specific Python package source
RUN apt-get update && apt-get install -y \
    curl git build-essential redis-tools nginx chromium-browser \
    ca-certificates fonts-liberation netcat-openbsd \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@9.13.0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure pip to use Jetson AI Lab repository
RUN pip3 config set global.extra-index-url https://pypi.jetson-ai-lab.io/jp6/cu129/+simple/

# Clone Firecrawl from official repository
RUN git clone https://github.com/mendableai/firecrawl.git /app/firecrawl

# Build Firecrawl API
WORKDIR /app/firecrawl/apps/api
RUN pnpm install --frozen-lockfile && pnpm run build

# Setup MCP server directory
WORKDIR /app/mcp
RUN cat > package.json << 'MCPPKG'
{
  "name": "firecrawl-mcp-server",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "express": "^4.18.2",
    "axios": "^1.6.0"
  }
}
MCPPKG

RUN cat > index.js << 'MCPJS'
const express = require('express');
const axios = require('axios');

const app = express();
app.use(express.json());

const PORT = process.env.MCP_PORT || 3006;
const FIRECRAWL_API_URL = process.env.FIRECRAWL_API_URL || 'http://127.0.0.1:3002';

app.post('/scrape', async (req, res) => {
  try {
    const response = await axios.post(`${FIRECRAWL_API_URL}/v1/scrape`, req.body);
    res.json(response.data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/crawl', async (req, res) => {
  try {
    const response = await axios.post(`${FIRECRAWL_API_URL}/v1/crawl`, req.body);
    res.json(response.data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.listen(PORT, () => {
  console.log(`MCP Server running on port ${PORT}`);
});
MCPJS

RUN npm install --production

# Create playground HTML
RUN mkdir -p /var/www/html
RUN cat > /var/www/html/index.html << 'PLAYHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Firecrawl Local Playground</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        h1 {
            color: #333;
            border-bottom: 2px solid #ff6b6b;
            padding-bottom: 10px;
        }
        .port-info {
            background: #e8f4f8;
            padding: 15px;
            border-radius: 5px;
            margin-bottom: 20px;
            font-size: 14px;
        }
        .input-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 5px;
            font-weight: bold;
            color: #555;
        }
        input, textarea {
            width: 100%;
            padding: 10px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 16px;
        }
        textarea {
            min-height: 100px;
            font-family: monospace;
        }
        button {
            background: #ff6b6b;
            color: white;
            border: none;
            padding: 12px 30px;
            border-radius: 5px;
            font-size: 16px;
            cursor: pointer;
            margin-right: 10px;
        }
        button:hover {
            background: #ff5252;
        }
        .result {
            margin-top: 30px;
            padding: 20px;
            background: #f8f8f8;
            border-radius: 5px;
            border: 1px solid #e0e0e0;
        }
        pre {
            white-space: pre-wrap;
            word-wrap: break-word;
            background: #282c34;
            color: #abb2bf;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
        }
        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            border-bottom: 2px solid #eee;
        }
        .tab {
            padding: 10px 20px;
            cursor: pointer;
            border-bottom: 3px solid transparent;
        }
        .tab.active {
            border-bottom-color: #ff6b6b;
            color: #ff6b6b;
        }
        .tab-content {
            display: none;
        }
        .tab-content.active {
            display: block;
        }
        .format-options {
            display: flex;
            gap: 15px;
            margin: 10px 0;
        }
        .format-options label {
            display: flex;
            align-items: center;
            font-weight: normal;
            margin-bottom: 0;
        }
        .format-options input[type="checkbox"] {
            width: auto;
            margin-right: 5px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔥 Firecrawl Playground</h1>
        <div class="port-info">
            <strong>Ollama Model:</strong> gpt-oss:20b | <strong>Embeddings:</strong> nomic-embed-text:v1.5
        </div>
        <div class="tabs">
            <div class="tab active" onclick="switchTab('scrape')">Scrape</div>
            <div class="tab" onclick="switchTab('crawl')">Crawl</div>
            <div class="tab" onclick="switchTab('map')">Map</div>
        </div>
        <div id="scrape-tab" class="tab-content active">
            <div class="input-group">
                <label for="scrape-url">URL to Scrape:</label>
                <input type="url" id="scrape-url" placeholder="https://example.com" value="https://www.firecrawl.dev">
            </div>
            <div class="input-group">
                <label>Formats:</label>
                <div class="format-options">
                    <label><input type="checkbox" id="format-markdown" checked> Markdown</label>
                    <label><input type="checkbox" id="format-extract"> Extract (LLM)</label>
                    <label><input type="checkbox" id="format-screenshot"> Screenshot</label>
                </div>
            </div>
            <div class="input-group" id="extract-options" style="display:none;">
                <label for="extract-prompt">Extract Prompt:</label>
                <textarea id="extract-prompt" placeholder="What to extract...">Extract the company name, main services, and contact information</textarea>
            </div>
            <button onclick="scrapeUrl()">Scrape URL</button>
        </div>
        <div id="crawl-tab" class="tab-content">
            <div class="input-group">
                <label for="crawl-url">URL to Crawl:</label>
                <input type="url" id="crawl-url" placeholder="https://example.com" value="https://www.firecrawl.dev">
            </div>
            <div class="input-group">
                <label for="crawl-limit">Page Limit:</label>
                <input type="number" id="crawl-limit" value="5" min="1" max="50">
            </div>
            <button onclick="crawlUrl()">Start Crawl</button>
        </div>
        <div id="map-tab" class="tab-content">
            <div class="input-group">
                <label for="map-url">URL to Map:</label>
                <input type="url" id="map-url" placeholder="https://example.com" value="https://www.firecrawl.dev">
            </div>
            <button onclick="mapUrl()">Map Website</button>
        </div>
        <div id="result" class="result" style="display:none;">
            <h3>Result:</h3>
            <pre id="result-content"></pre>
        </div>
    </div>
    <script>
        const API_BASE = window.location.origin;
        document.getElementById('format-extract').addEventListener('change', function() {
            document.getElementById('extract-options').style.display = this.checked ? 'block' : 'none';
        });
        function switchTab(tab) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.getElementById(tab + '-tab').classList.add('active');
            event.target.classList.add('active');
        }
        async function scrapeUrl() {
            const url = document.getElementById('scrape-url').value;
            if (!url) return alert('Enter a URL');
            const formats = [];
            if (document.getElementById('format-markdown').checked) formats.push('markdown');
            if (document.getElementById('format-extract').checked) formats.push('extract');
            if (document.getElementById('format-screenshot').checked) formats.push('screenshot');
            const body = { url, formats };
            if (formats.includes('extract')) {
                body.extract = { prompt: document.getElementById('extract-prompt').value };
            }
            await makeRequest('/v1/scrape', body);
        }
        async function crawlUrl() {
            const url = document.getElementById('crawl-url').value;
            if (!url) return alert('Enter a URL');
            await makeRequest('/v1/crawl', { url, limit: parseInt(document.getElementById('crawl-limit').value) });
        }
        async function mapUrl() {
            const url = document.getElementById('map-url').value;
            if (!url) return alert('Enter a URL');
            await makeRequest('/v1/map', { url });
        }
        async function makeRequest(endpoint, body) {
            const result = document.getElementById('result');
            const content = document.getElementById('result-content');
            try {
                const response = await fetch(API_BASE + endpoint, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body)
                });
                const data = await response.json();
                result.style.display = 'block';
                content.textContent = JSON.stringify(data, null, 2);
            } catch (error) {
                result.style.display = 'block';
                content.textContent = 'Error: ' + error.message;
            }
        }
    </script>
</body>
</html>
PLAYHTML

# Create startup script optimized for Coolify
RUN cat > /app/start.sh << 'STARTEOF'
#!/bin/bash
set -e

echo "Starting Firecrawl for Coolify deployment..."

# Start nginx
nginx -g "daemon off;" &

# Wait for Redis
echo "Waiting for Redis..."
until redis-cli -u ${REDIS_URL:-redis://redis:6379} ping 2>/dev/null; do
  sleep 2
done

# Start API
cd /app/firecrawl/apps/api
NODE_ENV=production PORT=3002 HOST=0.0.0.0 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/index.js &

# Wait for API
echo "Waiting for API..."
until nc -z localhost 3002; do sleep 2; done

# Start Worker
NODE_ENV=production IS_WORKER_PROCESS=true PORT=3005 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/services/queue-worker.js &

# Start MCP
cd /app/mcp
NODE_ENV=production MCP_PORT=3006 \
  FIRECRAWL_API_URL=http://127.0.0.1:3002 \
  node index.js &

echo "All services started!"
wait
STARTEOF

RUN chmod +x /app/start.sh

# Configure nginx for Coolify (single port)
RUN cat > /etc/nginx/sites-available/default << 'NGINXEOF'
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
NGINXEOF

RUN mkdir -p /app/logs

ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PORT=3002 \
    HOST=0.0.0.0 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s \
    CMD nc -z localhost 80 && nc -z localhost 3002 || exit 1

CMD ["/app/start.sh"]
