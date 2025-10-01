FROM dustynv/cuda-python:r36.4.0-cu128-24.04

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl git build-essential redis-tools nginx chromium-browser python3 g++ make \
    ca-certificates fonts-liberation netcat-openbsd pkg-config libssl-dev \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@9.13.0 napi-cli \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# Add Rust to PATH
ENV PATH="/root/.cargo/bin:${PATH}"

# Configure pip for Jetson AI Lab repository
RUN pip3 config set global.extra-index-url https://pypi.jetson-ai-lab.io/jp6/cu129/+simple/

# Clone Firecrawl from official repository
RUN git clone https://github.com/mendableai/firecrawl.git /app/firecrawl

# Build Firecrawl API
WORKDIR /app/firecrawl/apps/api
RUN pnpm install --frozen-lockfile && pnpm run build

# Copy playground HTML
RUN mkdir -p /var/www/html && \
#COPY docker/playground.html /var/www/html/index.html 2>/dev/null || \
    cat > /var/www/html/index.html << 'PLAYHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Firecrawl Playground</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            padding: 40px;
        }
        h1 { color: #2d3748; font-size: 2.5em; margin-bottom: 10px; text-align: center; }
        .subtitle { text-align: center; color: #718096; margin-bottom: 30px; }
        .info-banner {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 30px;
        }
        .tabs { display: flex; gap: 5px; margin-bottom: 30px; border-bottom: 2px solid #e2e8f0; }
        .tab {
            padding: 15px 30px;
            cursor: pointer;
            background: transparent;
            border: none;
            color: #718096;
            font-size: 1em;
            font-weight: 600;
            border-bottom: 3px solid transparent;
        }
        .tab:hover { color: #667eea; }
        .tab.active { color: #667eea; border-bottom-color: #667eea; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .input-group { margin-bottom: 25px; }
        label { display: block; margin-bottom: 8px; font-weight: 600; color: #2d3748; }
        input[type="url"], input[type="number"], textarea {
            width: 100%;
            padding: 12px 15px;
            border: 2px solid #e2e8f0;
            border-radius: 8px;
            font-size: 1em;
        }
        input:focus, textarea:focus { outline: none; border-color: #667eea; }
        textarea { min-height: 100px; font-family: monospace; resize: vertical; }
        .format-options { display: flex; gap: 15px; flex-wrap: wrap; margin-top: 10px; }
        .checkbox-label {
            display: flex;
            align-items: center;
            cursor: pointer;
            padding: 8px 15px;
            border: 2px solid #e2e8f0;
            border-radius: 8px;
        }
        .checkbox-label:hover { border-color: #667eea; background: #f7fafc; }
        .checkbox-label input[type="checkbox"] { width: auto; margin-right: 8px; }
        button {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            padding: 15px 40px;
            border-radius: 8px;
            font-size: 1em;
            font-weight: 600;
            cursor: pointer;
        }
        button:hover { transform: translateY(-2px); box-shadow: 0 10px 20px rgba(102, 126, 234, 0.4); }
        button:disabled { background: #cbd5e0; cursor: not-allowed; transform: none; }
        .loading { text-align: center; padding: 20px; color: #667eea; }
        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #667eea;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 20px auto;
        }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
        .result {
            margin-top: 30px;
            padding: 25px;
            background: #f7fafc;
            border-radius: 10px;
            border-left: 4px solid #667eea;
        }
        pre {
            background: #1a202c;
            color: #a0aec0;
            padding: 20px;
            border-radius: 8px;
            overflow-x: auto;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        .error { background: #fff5f5; border-left: 4px solid #f56565; color: #c53030; padding: 15px; border-radius: 8px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔥 Firecrawl</h1>
        <p class="subtitle">Web Scraping with Ollama AI</p>
        <div class="info-banner">
            <strong>Model:</strong> gpt-oss:20b | <strong>Note:</strong> Extract feature uses Ollama for AI extraction
        </div>
        <div class="tabs">
            <button class="tab active" onclick="switchTab('scrape')">Scrape</button>
            <button class="tab" onclick="switchTab('crawl')">Crawl</button>
            <button class="tab" onclick="switchTab('map')">Map</button>
        </div>
        <div id="scrape-tab" class="tab-content active">
            <div class="input-group">
                <label>URL to Scrape:</label>
                <input type="url" id="scrape-url" placeholder="https://example.com" value="https://www.firecrawl.dev">
            </div>
            <div class="input-group">
                <label>Formats:</label>
                <div class="format-options">
                    <label class="checkbox-label"><input type="checkbox" id="format-markdown" checked> Markdown</label>
                    <label class="checkbox-label"><input type="checkbox" id="format-html"> HTML</label>
                    <label class="checkbox-label"><input type="checkbox" id="format-screenshot"> Screenshot</label>
                </div>
            </div>
            <button onclick="scrapeUrl()">Scrape</button>
        </div>
        <div id="crawl-tab" class="tab-content">
            <div class="input-group">
                <label>URL to Crawl:</label>
                <input type="url" id="crawl-url" placeholder="https://example.com" value="https://www.firecrawl.dev">
            </div>
            <div class="input-group">
                <label>Page Limit:</label>
                <input type="number" id="crawl-limit" value="5" min="1" max="50">
            </div>
            <button onclick="crawlUrl()">Crawl</button>
        </div>
        <div id="map-tab" class="tab-content">
            <div class="input-group">
                <label>URL to Map:</label>
                <input type="url" id="map-url" placeholder="https://example.com" value="https://www.firecrawl.dev">
            </div>
            <button onclick="mapUrl()">Map</button>
        </div>
        <div id="loading" class="loading" style="display:none;">
            <div class="spinner"></div>
            <p>Processing...</p>
        </div>
        <div id="result" class="result" style="display:none;">
            <h3>Result:</h3>
            <pre id="result-content"></pre>
        </div>
    </div>
    <script>
        const API_BASE = window.location.origin;
        function switchTab(tab) {
            document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.getElementById(tab + '-tab').classList.add('active');
            event.target.classList.add('active');
        }
        async function scrapeUrl() {
            const url = document.getElementById('scrape-url').value;
            if (!url) return alert('Enter URL');
            const formats = [];
            if (document.getElementById('format-markdown').checked) formats.push('markdown');
            if (document.getElementById('format-html').checked) formats.push('html');
            if (document.getElementById('format-screenshot').checked) formats.push('screenshot');
            await makeRequest('/v1/scrape', { url, formats });
        }
        async function crawlUrl() {
            const url = document.getElementById('crawl-url').value;
            if (!url) return alert('Enter URL');
            await makeRequest('/v1/crawl', { url, limit: parseInt(document.getElementById('crawl-limit').value) });
        }
        async function mapUrl() {
            const url = document.getElementById('map-url').value;
            if (!url) return alert('Enter URL');
            await makeRequest('/v1/map', { url });
        }
        async function makeRequest(endpoint, body) {
            const loading = document.getElementById('loading');
            const result = document.getElementById('result');
            const content = document.getElementById('result-content');
            loading.style.display = 'block';
            result.style.display = 'none';
            try {
                const response = await fetch(API_BASE + endpoint, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body)
                });
                const data = await response.json();
                loading.style.display = 'none';
                result.style.display = 'block';
                content.textContent = JSON.stringify(data, null, 2);
            } catch (error) {
                loading.style.display = 'none';
                result.style.display = 'block';
                content.innerHTML = '<div class="error">Error: ' + error.message + '</div>';
            }
        }
    </script>
</body>
</html>
PLAYHTML

# Create startup script
RUN cat > /app/start.sh << 'EOF'
#!/bin/bash
set -e

echo "Starting Firecrawl services..."

# Start nginx
nginx -g "daemon off;" &

# Wait for Redis
echo "Waiting for Redis..."
until redis-cli -u ${REDIS_URL:-redis://redis:6379} ping 2>/dev/null; do
  sleep 2
done
echo "Redis connected"

# Start API
cd /app/firecrawl/apps/api
NODE_ENV=production PORT=3002 HOST=0.0.0.0 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/index.js > /app/logs/api.log 2>&1 &

# Wait for API
echo "Waiting for API..."
until nc -z localhost 3002; do sleep 2; done
echo "API ready"

# Start Worker
NODE_ENV=production IS_WORKER_PROCESS=true PORT=3005 \
  PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
  node dist/src/services/queue-worker.js > /app/logs/worker.log 2>&1 &

echo "All services started"
wait
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
EOF

RUN mkdir -p /app/logs

ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=4096" \
    PORT=3002 \
    HOST=0.0.0.0 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s \
    CMD nc -z localhost 80 && nc -z localhost 3002 || exit 1

CMD ["/app/start.sh"]
