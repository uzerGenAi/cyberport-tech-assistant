#!/bin/bash

# 🚀 Comprehensive Development Tools Installation Script
# Installs Docker, kubectl, and eksctl with automatic configuration

set -e  # Exit on any error
chmod +x "$(realpath "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output with emojis
print_header() {
    echo -e "${PURPLE}🎯 $1${NC}"
}

print_status() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_step() {
    echo -e "${CYAN}🔧 $1${NC}"
}

# Fix script permissions first
fix_script_permissions() {
    print_header "Setting Execute Permissions for CloudAge Scripts"
    
    print_step "Fixing permissions for all .sh files in deployment directories..."
    find /home/ec2-user/environment/6_deploy -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
    
    # Specifically ensure key scripts are executable
    chmod +x /home/ec2-user/environment/6_deploy/scripts/setup_dev_tools.sh 2>/dev/null || true
    chmod +x /home/ec2-user/environment/6_deploy/scripts/setup_cognito_auth.sh 2>/dev/null || true
    chmod +x /home/ec2-user/environment/6_deploy/scripts/deploy_stack.sh 2>/dev/null || true
    chmod +x /home/ec2-user/environment/6_deploy/scripts/deploy-frontend.sh 2>/dev/null || true
    chmod +x /home/ec2-user/environment/6_deploy/web-app/webapp.sh 2>/dev/null || true
    chmod +x /home/ec2-user/environment/6_deploy/web-app/update-cognito-config.sh 2>/dev/null || true
    
    print_success "All script permissions fixed!"
}

print_status() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_step() {
    echo -e "${CYAN}🔧 $1${NC}"
}

# Function to detect the Linux distribution
detect_distro() {
    print_step "Detecting Linux distribution..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        DISTRO="rhel"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    else
        print_error "Unable to detect Linux distribution"
        exit 1
    fi
    
    print_success "Detected distribution: $DISTRO"
}

# Function to install Docker on Debian/Ubuntu systems
install_docker_debian() {
    print_step "Installing Docker on Debian/Ubuntu system..."
    
    print_status "Updating package lists..."
    sudo apt update
    
    print_status "Installing Docker dependencies..."
    sudo apt install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        software-properties-common \
        lsb-release
    
    print_status "Adding Docker's GPG key..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$DISTRO/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    print_status "Adding Docker repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    print_status "Installing Docker packages..."
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    print_success "Docker installation completed!"
}

# Function to install Docker on RHEL/CentOS/Fedora systems
install_docker_rhel() {
    print_step "Installing Docker on RHEL/CentOS/Fedora system..."
    
    # Determine package manager
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
    else
        print_error "Neither dnf nor yum found. Cannot proceed."
        exit 1
    fi
    
    print_status "Using package manager: $PKG_MGR"
    
    print_status "Installing Docker dependencies..."
    sudo $PKG_MGR install -y yum-utils device-mapper-persistent-data lvm2
    
    print_status "Adding Docker repository..."
    if [[ "$DISTRO" == "fedora" ]]; then
        sudo $PKG_MGR config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    else
        sudo $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    print_status "Installing Docker packages..."
    sudo $PKG_MGR install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    print_success "Docker installation completed!"
}

# Function to install Docker on Amazon Linux
install_docker_amazon() {
    print_step "Installing Docker on Amazon Linux..."
    
    print_status "Updating system packages..."
    sudo yum update -y
    
    print_status "Installing Docker..."
    sudo yum install -y docker
    
    print_warning "Note: Amazon Linux uses the system Docker package, not Docker CE"
    print_success "Docker installation completed!"
}

# Function to configure Docker with permissions
configure_docker() {
    print_step "Configuring Docker with automatic permission setup..."
    
    print_status "Starting and enabling Docker service..."
    sudo systemctl start docker
    sudo systemctl enable docker
    
    print_status "Adding user $USER to docker group..."
    sudo usermod -aG docker $USER
    
    print_status "Applying Docker socket permission fix..."
    sudo chown root:docker /var/run/docker.sock
    sudo chmod 660 /var/run/docker.sock
    
    print_status "Restarting Docker service..."
    sudo systemctl restart docker
    
    # Wait for Docker to fully restart
    sleep 2
    
    # Re-apply socket permissions after restart
    sudo chown root:docker /var/run/docker.sock
    sudo chmod 660 /var/run/docker.sock
    
    # Install Docker Compose standalone if not already installed
    if ! command -v docker-compose &> /dev/null; then
        print_status "Installing Docker Compose standalone..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        print_success "Docker Compose installed!"
    fi
    
    print_success "Docker configuration completed!"
}

# Function to install kubectl
install_kubectl() {
    print_step "Installing kubectl..."
    
    # Create bin directory if it doesn't exist
    print_status "Creating $HOME/bin directory..."
    mkdir -p $HOME/bin
    
    print_status "Downloading kubectl..."
    curl -O https://s3.eu-central-1.amazonaws.com/amazon-eks/1.31.7/2025-04-17/bin/linux/amd64/kubectl
    curl -O https://s3.eu-central-1.amazonaws.com/amazon-eks/1.31.7/2025-04-17/bin/linux/amd64/kubectl.sha256
    
    print_status "Verifying kubectl checksum..."
    if sha256sum -c kubectl.sha256; then
        print_success "kubectl checksum verification passed"
    else
        print_error "kubectl checksum verification failed"
        exit 1
    fi
    
    print_status "Installing kubectl to $HOME/bin..."
    chmod +x ./kubectl
    cp ./kubectl $HOME/bin/kubectl
    
    # Clean up kubectl files
    rm ./kubectl ./kubectl.sha256
    
    print_success "kubectl installation completed!"
}

# Function to install eksctl
install_eksctl() {
    print_step "Installing eksctl..."
    
    # Detect architecture and platform
    ARCH=amd64
    PLATFORM=$(uname -s)_$ARCH
    
    print_status "Detected platform: $PLATFORM"
    
    print_status "Downloading eksctl..."
    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
    
    print_status "Verifying eksctl checksum..."
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check
    
    if [ $? -eq 0 ]; then
        print_success "eksctl checksum verification passed"
    else
        print_error "eksctl checksum verification failed"
        exit 1
    fi
    
    print_status "Extracting and installing eksctl..."
    tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp
    rm eksctl_$PLATFORM.tar.gz
    
    print_status "Moving eksctl to /usr/local/bin (requires sudo)..."
    sudo mv /tmp/eksctl /usr/local/bin
    
    print_success "eksctl installation completed!"
}

# Function to configure PATH
configure_path() {
    print_step "Configuring PATH environment..."
    
    # Update PATH in bashrc if not already present
    if ! grep -q 'export PATH=$HOME/bin:$PATH' ~/.bashrc; then
        echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
        print_success "Added $HOME/bin to PATH in ~/.bashrc"
    else
        print_status "$HOME/bin already in PATH in ~/.bashrc"
    fi
    
    # Also add to current session
    export PATH=$HOME/bin:$PATH
    
    print_success "PATH configuration completed!"
    print_status "Current PATH includes: $PATH"
    
    # Verify kubectl is accessible
    if command -v kubectl &> /dev/null; then
        print_success "kubectl is now accessible in PATH"
    else
        print_warning "kubectl not yet accessible, will be available after PATH activation"
    fi
}

# Function to verify all installations
verify_installations() {
    print_header "🔍 Verifying All Installations"
    
    # Verify kubectl
    if [ -f "$HOME/bin/kubectl" ]; then
        KUBECTL_VERSION=$($HOME/bin/kubectl version --client --short 2>/dev/null || $HOME/bin/kubectl version --client 2>/dev/null || echo "kubectl installed")
        print_success "kubectl installed: $KUBECTL_VERSION"
    else
        print_error "kubectl installation failed - file not found"
        return 1
    fi
    
    # Verify eksctl
    if command -v eksctl &> /dev/null; then
        EKSCTL_VERSION=$(eksctl version)
        print_success "eksctl installed: $EKSCTL_VERSION"
    else
        print_error "eksctl installation failed"
        return 1
    fi
    
    # Verify Docker
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        print_success "Docker installed: $DOCKER_VERSION"
        
        # Test Docker without sudo
        print_status "Testing Docker without sudo..."
        if timeout 30 docker run hello-world &> /dev/null; then
            print_success "Docker is working without sudo!"
        else
            print_warning "Docker test failed or timed out. Group membership will be activated shortly."
        fi
    else
        print_error "Docker installation failed"
        return 1
    fi
    
    # Verify Docker Compose
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version)
        print_success "Docker Compose installed: $COMPOSE_VERSION"
    fi
}

# Main installation function
main() {
    print_header "🚀 Development Tools Installation Script"
    echo ""
    print_status "This script will install:"
    echo "  🐳 Docker (with automatic configuration)"
    echo "  ⚓ kubectl (Kubernetes CLI)"
    echo "  🔧 eksctl (EKS CLI)"
    echo ""
    
    # Fix script permissions first
    fix_script_permissions
    echo ""
    
    detect_distro
    
    # Install Docker based on distribution
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            install_docker_debian
            ;;
        rhel|centos|rocky|almalinux)
            install_docker_rhel
            ;;
        fedora)
            install_docker_rhel
            ;;
        amzn)
            install_docker_amazon
            ;;
        *)
            print_warning "Unsupported distribution for automatic Docker installation: $DISTRO"
            print_status "Please install Docker manually or use Docker's convenience script:"
            print_status "curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh"
            exit 1
            ;;
    esac
    
    # Configure Docker
    configure_docker
    
    # Install kubectl and eksctl
    install_kubectl
    install_eksctl
    
    # Configure PATH
    configure_path
    
    # Verify installations
    verify_installations
    
    # Final success message with activation instructions
    final_setup
}

# Function to handle final setup and activation
final_setup() {
    echo ""
    print_header "🎉 Installation Complete!"
    echo ""
    print_success "All development tools have been successfully installed!"
    echo ""
    print_status "📋 What was installed:"
    echo "  🐳 Docker - Container platform"
    echo "  ⚓ kubectl - Kubernetes command-line tool"
    echo "  🔧 eksctl - Amazon EKS command-line tool"
    echo ""
    
    echo ""
    print_header "🚀 ACTIVATION REQUIRED"
    echo ""
    print_status "To use the tools immediately, run these commands:"
    echo ""
    echo -e "${GREEN}source ~/.bashrc${NC}"
    echo -e "${GREEN}newgrp docker${NC}"
    echo ""
    print_status "Or run this single command:"
    echo ""
    echo -e "${GREEN}source ~/.bashrc && newgrp docker${NC}"
    echo ""
    print_status "💡 After running the commands above, verify with:"
    echo "  kubectl version --client"
    echo "  eksctl version" 
    echo "  docker --version"
    echo "  docker run hello-world"
    echo ""
    print_warning "Note: 'newgrp docker' starts a new shell with Docker access."
    print_status "Type 'exit' to return to the original shell if needed."
    echo ""
    print_success "Happy coding! 🚀"
    
    # Clean up any temporary files
    rm -f /tmp/activate_dev_tools.sh /tmp/activate_tools.sh 2>/dev/null || true
}

# Run the main function
main "$@"
