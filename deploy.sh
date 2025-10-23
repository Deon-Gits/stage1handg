#!/bin/bash

#################################################
# Automated Deployment Script - DevOps Stage 1
# Author: Your Name
# Description: Production-grade deployment automation
#################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_MODE=false
REPO_DIR=""
PROJECT_NAME=""

# Trap errors
trap 'error_handler $? $LINENO' ERR

#################################################
# Helper Functions
#################################################

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

error_handler() {
    local exit_code=$1
    local line_number=$2
    log_error "Script failed at line ${line_number} with exit code ${exit_code}"
    exit "$exit_code"
}

prompt_input() {
    local prompt_text=$1
    local var_name=$2
    local is_secret=${3:-false}
    
    if [ "$is_secret" = true ]; then
        read -sp "${prompt_text}: " input
        echo
    else
        read -p "${prompt_text}: " input
    fi
    
    eval "$var_name='$input'"
}

validate_not_empty() {
    local value=$1
    local field_name=$2
    
    if [ -z "$value" ]; then
        log_error "${field_name} cannot be empty"
        exit 1
    fi
}

#################################################
# Stage 1: Collect Parameters
#################################################

collect_parameters() {
    log_info "========================================="
    log_info "Stage 1: Collecting Deployment Parameters"
    log_info "========================================="
    
    # Git Repository Details
    prompt_input "Enter Git Repository URL" GIT_REPO_URL
    validate_not_empty "$GIT_REPO_URL" "Git Repository URL"
    
    prompt_input "Enter Personal Access Token (PAT)" GIT_PAT true
    validate_not_empty "$GIT_PAT" "Personal Access Token"
    
    prompt_input "Enter Branch Name (default: main)" GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    
    # Remote Server Details
    echo
    log_info "Remote Server Configuration:"
    prompt_input "Enter SSH Username" SSH_USER
    validate_not_empty "$SSH_USER" "SSH Username"
    
    prompt_input "Enter Server IP Address" SERVER_IP
    validate_not_empty "$SERVER_IP" "Server IP"
    
    prompt_input "Enter SSH Password" SSH_PASSWORD true
    validate_not_empty "$SSH_PASSWORD" "SSH Password"
    
    prompt_input "Enter Application Port (internal container port)" APP_PORT
    validate_not_empty "$APP_PORT" "Application Port"
    
    # Validate port is numeric
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
        log_error "Application port must be numeric"
        exit 1
    fi
    
    # Extract project name from repo URL
    PROJECT_NAME=$(basename "$GIT_REPO_URL" .git)
    REPO_DIR="./${PROJECT_NAME}"
    
    log_success "Parameters collected successfully"
    log_info "Project: ${PROJECT_NAME}"
    log_info "Branch: ${GIT_BRANCH}"
    log_info "Server: ${SSH_USER}@${SERVER_IP}"
    log_info "Port: ${APP_PORT}"
}

#################################################
# Stage 2: Clone Repository
#################################################

clone_repository() {
    log_info "========================================="
    log_info "Stage 2: Cloning Repository"
    log_info "========================================="
    
    # Construct authenticated URL
    local auth_url=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")
    
    if [ -d "$REPO_DIR" ]; then
        log_warning "Repository directory already exists. Pulling latest changes..."
        cd "$REPO_DIR"
        git pull origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || {
            log_error "Failed to pull latest changes"
            exit 1
        }
        cd ..
    else
        log_info "Cloning repository..."
        git clone "$auth_url" "$REPO_DIR" >> "$LOG_FILE" 2>&1 || {
            log_error "Failed to clone repository"
            exit 1
        }
    fi
    
    cd "$REPO_DIR"
    git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || {
        log_error "Failed to checkout branch ${GIT_BRANCH}"
        exit 1
    }
    
    log_success "Repository cloned and checked out to branch ${GIT_BRANCH}"
}

#################################################
# Stage 3: Validate Project Structure
#################################################

validate_project() {
    log_info "========================================="
    log_info "Stage 3: Validating Project Structure"
    log_info "========================================="
    
    if [ -f "Dockerfile" ]; then
        log_success "Dockerfile found"
    elif [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
        log_success "docker-compose.yml found"
    else
        log_error "Neither Dockerfile nor docker-compose.yml found in project"
        exit 1
    fi
}

#################################################
# Stage 4: Test SSH Connection
#################################################

test_ssh_connection() {
    log_info "========================================="
    log_info "Stage 4: Testing SSH Connection"
    log_info "========================================="
    
    log_info "Testing connectivity to ${SERVER_IP}..."
    
    # Test with sshpass
    if ! command -v sshpass &> /dev/null; then
        log_info "Installing sshpass for password authentication..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update >> "$LOG_FILE" 2>&1
            sudo apt-get install -y sshpass >> "$LOG_FILE" 2>&1
        elif command -v yum &> /dev/null; then
            sudo yum install -y sshpass >> "$LOG_FILE" 2>&1
        else
            log_error "Cannot install sshpass. Please install it manually."
            exit 1
        fi
    fi
    
    # Test SSH connection
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${SSH_USER}@${SERVER_IP}" "echo 'SSH connection successful'" >> "$LOG_FILE" 2>&1 || {
        log_error "Failed to establish SSH connection"
        exit 1
    }
    
    log_success "SSH connection established successfully"
}

#################################################
# Stage 5: Prepare Remote Environment
#################################################

prepare_remote_environment() {
    log_info "========================================="
    log_info "Stage 5: Preparing Remote Environment"
    log_info "========================================="
    
    log_info "Updating system packages..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << 'ENDSSH' >> "$LOG_FILE" 2>&1
        
        # Update system
        sudo apt-get update -y
        
        # Install prerequisites
        sudo apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release \
            software-properties-common
ENDSSH
    
    log_info "Installing Docker..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << 'ENDSSH' >> "$LOG_FILE" 2>&1
        
        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh
        fi
        
        # Add user to docker group
        sudo usermod -aG docker $USER || true
        
        # Start and enable Docker
        sudo systemctl start docker
        sudo systemctl enable docker
ENDSSH
    
    log_info "Installing Docker Compose..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << 'ENDSSH' >> "$LOG_FILE" 2>&1
        
        # Install Docker Compose if not present
        if ! command -v docker-compose &> /dev/null; then
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        fi
ENDSSH
    
    log_info "Installing Nginx..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << 'ENDSSH' >> "$LOG_FILE" 2>&1
        
        # Install Nginx if not present
        if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
            sudo systemctl start nginx
            sudo systemctl enable nginx
        fi
ENDSSH
    
    # Verify installations
    log_info "Verifying installations..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << 'ENDSSH' | tee -a "$LOG_FILE"
        
        echo "Docker version:"
        docker --version
        echo "Docker Compose version:"
        docker-compose --version
        echo "Nginx version:"
        nginx -v
ENDSSH
    
    log_success "Remote environment prepared successfully"
}

#################################################
# Stage 6: Deploy Application
#################################################

deploy_application() {
    log_info "========================================="
    log_info "Stage 6: Deploying Application"
    log_info "========================================="
    
    # Create deployment directory on remote server
    local remote_dir="/home/${SSH_USER}/${PROJECT_NAME}"
    
    log_info "Creating remote deployment directory..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "mkdir -p ${remote_dir}" >> "$LOG_FILE" 2>&1
    
    # Transfer project files
    log_info "Transferring project files to remote server..."
    cd ..
    sshpass -p "$SSH_PASSWORD" rsync -avz --delete \
        -e "ssh -o StrictHostKeyChecking=no" \
        "${REPO_DIR}/" "${SSH_USER}@${SERVER_IP}:${remote_dir}/" >> "$LOG_FILE" 2>&1 || {
        log_error "Failed to transfer files"
        exit 1
    }
    
    # Stop existing containers
    log_info "Stopping existing containers..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << ENDSSH >> "$LOG_FILE" 2>&1
        
        cd ${remote_dir}
        
        # Stop and remove old containers
        docker-compose down 2>/dev/null || true
        docker stop ${PROJECT_NAME} 2>/dev/null || true
        docker rm ${PROJECT_NAME} 2>/dev/null || true
ENDSSH
    
    # Build and run containers
    log_info "Building and starting containers..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << ENDSSH >> "$LOG_FILE" 2>&1
        
        cd ${remote_dir}
        
        # Use docker-compose if available, otherwise use docker build/run
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
            docker-compose build
            docker-compose up -d
        else
            docker build -t ${PROJECT_NAME}:latest .
            docker run -d --name ${PROJECT_NAME} -p ${APP_PORT}:${APP_PORT} ${PROJECT_NAME}:latest
        fi
ENDSSH
    
    # Wait for container to be healthy
    log_info "Waiting for container to be ready..."
    sleep 5
    
    # Verify container is running
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << ENDSSH | tee -a "$LOG_FILE"
        
        echo "Running containers:"
        docker ps
        
        echo "Container logs (last 20 lines):"
        docker logs --tail 20 ${PROJECT_NAME} 2>&1 || docker-compose logs --tail 20 2>&1
ENDSSH
    
    log_success "Application deployed successfully"
}

#################################################
# Stage 7: Configure Nginx
#################################################

configure_nginx() {
    log_info "========================================="
    log_info "Stage 7: Configuring Nginx Reverse Proxy"
    log_info "========================================="
    
    local nginx_config="/etc/nginx/sites-available/${PROJECT_NAME}"
    
    log_info "Creating Nginx configuration..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << ENDSSH >> "$LOG_FILE" 2>&1
        
        # Create Nginx config
        sudo tee ${nginx_config} > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        
        # Replace placeholder with actual port
        sudo sed -i "s/\${APP_PORT}/${APP_PORT}/g" ${nginx_config}
        
        # Enable site
        sudo ln -sf ${nginx_config} /etc/nginx/sites-enabled/${PROJECT_NAME}
        
        # Remove default site if exists
        sudo rm -f /etc/nginx/sites-enabled/default
        
        # Test configuration
        sudo nginx -t
        
        # Reload Nginx
        sudo systemctl reload nginx
ENDSSH
    
    log_success "Nginx configured successfully"
}

#################################################
# Stage 8: Validate Deployment
#################################################

validate_deployment() {
    log_info "========================================="
    log_info "Stage 8: Validating Deployment"
    log_info "========================================="
    
    # Check Docker service
    log_info "Checking Docker service status..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "sudo systemctl is-active docker" >> "$LOG_FILE" 2>&1 || {
        log_error "Docker service is not running"
        exit 1
    }
    log_success "Docker service is running"
    
    # Check container status
    log_info "Checking container status..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "docker ps | grep -q ${PROJECT_NAME}" >> "$LOG_FILE" 2>&1 || {
        log_error "Container is not running"
        exit 1
    }
    log_success "Container is running"
    
    # Check Nginx status
    log_info "Checking Nginx service status..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "sudo systemctl is-active nginx" >> "$LOG_FILE" 2>&1 || {
        log_error "Nginx service is not running"
        exit 1
    }
    log_success "Nginx service is running"
    
    # Test local connectivity
    log_info "Testing application connectivity on remote server..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}" >> "$LOG_FILE" 2>&1 || {
        log_warning "Direct port access test inconclusive"
    }
    
    # Test Nginx proxy
    log_info "Testing Nginx reverse proxy..."
    local response=$(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" "curl -s -o /dev/null -w '%{http_code}' http://localhost" 2>&1)
    
    if [[ "$response" =~ ^[2-3][0-9][0-9]$ ]]; then
        log_success "Nginx reverse proxy is working (HTTP ${response})"
    else
        log_warning "Nginx proxy returned status: ${response}"
    fi
    
    log_success "Deployment validation completed"
    log_info ""
    log_info "========================================="
    log_success "🎉 DEPLOYMENT SUCCESSFUL! 🎉"
    log_info "========================================="
    log_info "Application URL: http://${SERVER_IP}"
    log_info "Direct Access: http://${SERVER_IP}:${APP_PORT}"
    log_info "Project: ${PROJECT_NAME}"
    log_info "Log file: ${LOG_FILE}"
}

#################################################
# Cleanup Function
#################################################

cleanup_deployment() {
    log_info "========================================="
    log_info "Cleanup Mode: Removing Deployment"
    log_info "========================================="
    
    local remote_dir="/home/${SSH_USER}/${PROJECT_NAME}"
    
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${SERVER_IP}" << ENDSSH >> "$LOG_FILE" 2>&1
        
        cd ${remote_dir}
        
        # Stop and remove containers
        docker-compose down -v 2>/dev/null || true
        docker stop ${PROJECT_NAME} 2>/dev/null || true
        docker rm ${PROJECT_NAME} 2>/dev/null || true
        docker rmi ${PROJECT_NAME}:latest 2>/dev/null || true
        
        # Remove Nginx config
        sudo rm -f /etc/nginx/sites-available/${PROJECT_NAME}
        sudo rm -f /etc/nginx/sites-enabled/${PROJECT_NAME}
        sudo systemctl reload nginx
        
        # Remove project directory
        cd /home/${SSH_USER}
        rm -rf ${remote_dir}
ENDSSH
    
    log_success "Cleanup completed successfully"
    exit 0
}

#################################################
# Main Execution
#################################################

main() {
    clear
    echo -e "${GREEN}"
    echo "========================================="
    echo "   DevOps Stage 1 - Deployment Script   "
    echo "========================================="
    echo -e "${NC}"
    
    log_info "Starting deployment process..."
    log_info "Log file: ${LOG_FILE}"
    echo
    
    # Check for cleanup flag
    if [ "${1:-}" = "--cleanup" ]; then
        CLEANUP_MODE=true
    fi
    
    # Collect parameters
    collect_parameters
    
    # Handle cleanup mode
    if [ "$CLEANUP_MODE" = true ]; then
        cleanup_deployment
    fi
    
    # Execute deployment stages
    clone_repository
    validate_project
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    
    echo
    log_info "Deployment completed successfully!"
    log_info "Check ${LOG_FILE} for detailed logs"
}

# Run main function
main "$@"
