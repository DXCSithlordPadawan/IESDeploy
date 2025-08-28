#!/bin/bash

# IES Military Database Analyzer Container Deployment Script
# This script creates a containerized deployment of the IES application
# with Traefik reverse proxy and TLS termination

set -e

# Configuration variables
REPO_URL="https://github.com/DXCSithlordPadawan/IES.git"
APP_NAME="ies-military-analyzer"
NETWORK_NAME="ies-network"
TRAEFIK_IP="192.168.0.124"
CERT_SERVER="cert-server.aip.dxc.com"
CERT_SERVER_IP="192.168.0.122"
DOMAIN_NAME="ies-analyzer.local"

echo "🚀 Starting IES Military Database Analyzer deployment..."

# Create project directory
PROJECT_DIR="${APP_NAME}-deployment"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Clone the repository if it doesn't exist
if [ ! -d "IES" ]; then
    echo "📥 Cloning IES repository..."
    git clone "$REPO_URL"
fi

echo "📝 Creating Docker configuration files..."

# Create Dockerfile
cat > Dockerfile << 'EOF'
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy the application
COPY IES/ /app/

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt || \
    pip install --no-cache-dir flask pandas numpy matplotlib seaborn plotly \
    sqlalchemy psycopg2-binary pymongo redis celery gunicorn

# Create necessary directories
RUN mkdir -p /app/logs /app/data /app/static /app/templates

# Set environment variables
ENV FLASK_APP=military_database_analyzer_v3.py
ENV FLASK_ENV=production
ENV PYTHONUNBUFFERED=1

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Run the application with web parameter
CMD ["python", "military_database_analyzer_v3.py", "--web"]
EOF

# Create docker-compose.yml
cat > docker-compose.yml << EOF
version: '3.8'

networks:
  ${NETWORK_NAME}:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16

services:
  # IES Application
  ${APP_NAME}:
    build: .
    container_name: ${APP_NAME}
    restart: unless-stopped
    networks:
      - ${NETWORK_NAME}
    environment:
      - FLASK_ENV=production
      - FLASK_APP=military_database_analyzer_v3.py
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
      - ./config:/app/config
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP_NAME}.rule=Host(\`${DOMAIN_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${APP_NAME}.tls=true"
      - "traefik.http.routers.${APP_NAME}.tls.certresolver=dxc-resolver"
      - "traefik.http.services.${APP_NAME}.loadbalancer.server.port=8000"
      - "traefik.http.routers.${APP_NAME}-insecure.rule=Host(\`${DOMAIN_NAME}\`)"
      - "traefik.http.routers.${APP_NAME}-insecure.entrypoints=web"
      - "traefik.http.routers.${APP_NAME}-insecure.middlewares=redirect-to-https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.permanent=true"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  # Traefik Reverse Proxy
  traefik:
    image: traefik:v3.0
    container_name: traefik-proxy
    restart: unless-stopped
    networks:
      ${NETWORK_NAME}:
        ipv4_address: 172.20.0.124
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"  # Traefik dashboard
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik:/etc/traefik:ro
      - ./certificates:/etc/certificates:ro
      - ./acme:/acme
    command:
      - "--api.dashboard=true"
      - "--api.debug=true"
      - "--log.level=INFO"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.dxc-resolver.acme.httpchallenge=true"
      - "--certificatesresolvers.dxc-resolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.dxc-resolver.acme.email=admin@dxc.com"
      - "--certificatesresolvers.dxc-resolver.acme.storage=/acme/acme.json"
      - "--certificatesresolvers.dxc-resolver.acme.caserver=${CERT_SERVER}"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(\`traefik.${DOMAIN_NAME}\`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls=true"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=auth"
      - "traefik.http.middlewares.auth.basicauth.users=admin:$$apr1$$8eO1Z7/s$$4KNhKlP2W1S6gNCUNiIFg1"

volumes:
  acme:

EOF

# Create Traefik configuration directory and files
mkdir -p traefik/dynamic
mkdir -p certificates
mkdir -p acme
mkdir -p data logs config

# Create Traefik static configuration
cat > traefik/traefik.yml << EOF
# Static configuration
api:
  dashboard: true
  debug: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  dxc-resolver:
    acme:
      httpChallenge:
        entryPoint: web
      email: admin@dxc.com
      storage: /acme/acme.json
      caServer: https://${CERT_SERVER}/acme/directory

log:
  level: INFO
  filePath: "/var/log/traefik.log"

accessLog:
  filePath: "/var/log/access.log"
EOF

# Create dynamic Traefik configuration
cat > traefik/dynamic/dynamic.yml << EOF
# Dynamic configuration
http:
  middlewares:
    default-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        customFrameOptionsValue: SAMEORIGIN
        customRequestHeaders:
          X-Forwarded-Proto: https

    secure-headers:
      headers:
        accessControlAllowMethods:
          - GET
          - OPTIONS
          - PUT
          - POST
        accessControlMaxAge: 100
        hostsProxyHeaders:
          - "X-Forwarded-Host"
        referrerPolicy: "same-origin"

tls:
  options:
    default:
      sslProtocols:
        - "TLSv1.2"
        - "TLSv1.3"
      minVersion: "VersionTLS12"
      cipherSuites:
        - "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
        - "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
        - "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
        - "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256"
      curvePreferences:
        - "CurveP521"
        - "CurveP384"
EOF

# Create application configuration
cat > config/app_config.py << 'EOF'
import os

# Flask configuration
class Config:
    SECRET_KEY = os.environ.get('SECRET_KEY') or 'your-secret-key-change-this'
    DEBUG = False
    TESTING = False
    
    # Database configuration
    DATABASE_URL = os.environ.get('DATABASE_URL', 'sqlite:///military_analyzer.db')
    
    # Logging
    LOG_LEVEL = 'INFO'
    LOG_FILE = '/app/logs/application.log'
    
    # Security
    WTF_CSRF_ENABLED = True
    WTF_CSRF_TIME_LIMIT = None
    
    # File uploads
    MAX_CONTENT_LENGTH = 500 * 1024 * 1024  # 500MB max file size
    UPLOAD_FOLDER = '/app/data/uploads'
    
    # Network configuration
    HOST = '0.0.0.0'
    PORT = 8000
    
class ProductionConfig(Config):
    DEBUG = False
    
class DevelopmentConfig(Config):
    DEBUG = True
    
class TestingConfig(Config):
    TESTING = True
    WTF_CSRF_ENABLED = False

config = {
    'development': DevelopmentConfig,
    'production': ProductionConfig,
    'testing': TestingConfig,
    'default': ProductionConfig
}
EOF

# Create environment file
cat > .env << EOF
# Environment variables
COMPOSE_PROJECT_NAME=${APP_NAME}
FLASK_ENV=production
FLASK_APP=military_database_analyzer_v3.py
SECRET_KEY=your-super-secret-key-change-this-in-production
DATABASE_URL=sqlite:///military_analyzer.db

# Network configuration
TRAEFIK_IP=${TRAEFIK_IP}
CERT_SERVER=${CERT_SERVER}
CERT_SERVER_IP=${CERT_SERVER_IP}
DOMAIN_NAME=${DOMAIN_NAME}
EOF

# Create deployment script
cat > deploy.sh << 'EOF'
#!/bin/bash

echo "🚀 Deploying IES Military Database Analyzer..."

# Load environment variables
set -a
source .env
set +a

# Create necessary directories with proper permissions
mkdir -p data logs config certificates acme
chmod 755 data logs config
chmod 600 acme

# Set ACME file permissions
touch acme/acme.json
chmod 600 acme/acme.json

# Build and start services
echo "🏗️  Building application container..."
docker-compose build --no-cache

echo "🌐 Starting services..."
docker-compose up -d

echo "⏳ Waiting for services to be ready..."
sleep 30

# Check service health
echo "🔍 Checking service status..."
docker-compose ps

echo "✅ Deployment complete!"
echo ""
echo "🌐 Application URLs:"
echo "   HTTP:  http://${DOMAIN_NAME}"
echo "   HTTPS: https://${DOMAIN_NAME}"
echo "   Traefik Dashboard: https://traefik.${DOMAIN_NAME}"
echo ""
echo "📋 To check logs:"
echo "   Application: docker-compose logs ${APP_NAME}"
echo "   Traefik: docker-compose logs traefik"
echo ""
echo "🛠️  To manage the deployment:"
echo "   Stop: docker-compose down"
echo "   Restart: docker-compose restart"
echo "   Update: git pull && docker-compose build --no-cache && docker-compose up -d"
EOF

chmod +x deploy.sh

# Create management scripts
cat > manage.sh << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "🚀 Starting IES services..."
        docker-compose up -d
        ;;
    stop)
        echo "🛑 Stopping IES services..."
        docker-compose down
        ;;
    restart)
        echo "🔄 Restarting IES services..."
        docker-compose restart
        ;;
    logs)
        if [ -n "$2" ]; then
            docker-compose logs -f "$2"
        else
            docker-compose logs -f
        fi
        ;;
    update)
        echo "🔄 Updating IES application..."
        git pull
        docker-compose build --no-cache
        docker-compose up -d
        ;;
    status)
        echo "📊 Service Status:"
        docker-compose ps
        ;;
    shell)
        docker-compose exec ${APP_NAME} /bin/bash
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|logs|update|status|shell}"
        echo ""
        echo "Commands:"
        echo "  start   - Start all services"
        echo "  stop    - Stop all services"
        echo "  restart - Restart all services"
        echo "  logs    - Show logs (add service name for specific service)"
        echo "  update  - Update and rebuild application"
        echo "  status  - Show service status"
        echo "  shell   - Access application shell"
        exit 1
        ;;
esac
EOF

chmod +x manage.sh

# Create README
cat > README.md << EOF
# IES Military Database Analyzer - Container Deployment

This deployment creates a containerized version of the IES Military Database Analyzer with Traefik reverse proxy and TLS termination.

## Quick Start

1. Run the deployment:
   \`\`\`bash
   ./deploy.sh
   \`\`\`

2. Access the application:
   - HTTP: http://${DOMAIN_NAME}
   - HTTPS: https://${DOMAIN_NAME}
   - Traefik Dashboard: https://traefik.${DOMAIN_NAME}

## Management

Use the management script for common operations:

\`\`\`bash
./manage.sh start     # Start services
./manage.sh stop      # Stop services  
./manage.sh restart   # Restart services
./manage.sh logs      # View logs
./manage.sh update    # Update application
./manage.sh status    # Check status
./manage.sh shell     # Access container shell
\`\`\`

## Configuration

- Application config: \`config/app_config.py\`
- Environment variables: \`.env\`
- Traefik config: \`traefik/\`
- Docker Compose: \`docker-compose.yml\`

## Network Configuration

- Traefik Proxy: ${TRAEFIK_IP}:80/443
- Certificate Server: ${CERT_SERVER_IP}
- Application Network: 172.20.0.0/16
- Accessible from: 192.168.0.0/24 network

## Logs and Data

- Application logs: \`logs/\`
- Application data: \`data/\`
- Certificates: \`certificates/\`
- ACME data: \`acme/\`

## Troubleshooting

1. Check service status:
   \`\`\`bash
   docker-compose ps
   \`\`\`

2. View logs:
   \`\`\`bash
   docker-compose logs -f
   \`\`\`

3. Test connectivity:
   \`\`\`bash
   curl -k https://${DOMAIN_NAME}/health
   \`\`\`
EOF

echo "✅ All configuration files created successfully!"
echo ""
echo "📁 Project structure:"
find . -type f -name "*.yml" -o -name "*.sh" -o -name "*.py" -o -name "Dockerfile" -o -name "README.md" | sort
echo ""
echo "🚀 To deploy the application:"
echo "   cd $PROJECT_DIR"
echo "   ./deploy.sh"
echo ""
echo "📝 Don't forget to:"
echo "   1. Update the SECRET_KEY in .env"
echo "   2. Configure DNS or hosts file for ${DOMAIN_NAME}"
echo "   3. Ensure certificate server (${CERT_SERVER_IP}) is accessible"
echo "   4. Verify network routing to Traefik (${TRAEFIK_IP})"
