#!/usr/bin/env bash
# ==============================================================================
# macOS Setup Script for Local Kubernetes DevOps Lab
# Supports: macOS (Apple Silicon arm64 / Intel x86_64) with OrbStack
#
# This script installs all required CLI tools and configures the environment
# to run the full DevOps platform (k3d + Jenkins + ArgoCD + SonarQube +
# Vault + Consul + PostgreSQL + OpenObserve) on macOS using OrbStack's
# Docker-compatible socket (no Podman required).
#
# Prerequisites (manual):
#   1. OrbStack installed and running: https://orbstack.dev
#      (Free for personal use; replaces Docker Desktop and Podman on macOS)
#   2. Homebrew installed: https://brew.sh
# ==============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}==>${NC} $*"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }

echo -e "${BOLD}${CYAN}========================================================${NC}"
echo -e "${BOLD}${CYAN}   macOS DevOps Lab Setup (OrbStack + k3d)             ${NC}"
echo -e "${BOLD}${CYAN}========================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# 0. Verify Prerequisites
# ------------------------------------------------------------------------------
info "Verifying prerequisites..."

if ! command -v brew &>/dev/null; then
  echo "ERROR: Homebrew is not installed."
  echo "       Install it from https://brew.sh then re-run this script."
  exit 1
fi
success "Homebrew found: $(brew --version | head -1)"

# Check OrbStack / Docker socket
if [ ! -S /var/run/docker.sock ] && [ ! -S "$HOME/.orbstack/run/docker.sock" ]; then
  echo "ERROR: Neither /var/run/docker.sock nor ~/.orbstack/run/docker.sock found."
  echo "       Please install and start OrbStack: https://orbstack.dev"
  exit 1
fi

# Prefer OrbStack socket
if [ -S "$HOME/.orbstack/run/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.orbstack/run/docker.sock"
  success "OrbStack Docker socket detected: $HOME/.orbstack/run/docker.sock"
else
  success "Docker socket detected: /var/run/docker.sock"
fi

# Quick Docker connectivity test
if ! docker info &>/dev/null; then
  echo "ERROR: Cannot connect to Docker daemon. Is OrbStack running?"
  exit 1
fi
success "Docker daemon reachable ($(docker info --format '{{.ServerVersion}}'))"

echo ""

# ------------------------------------------------------------------------------
# 1. Install CLI Tools via Homebrew
# ------------------------------------------------------------------------------
info "Installing CLI tools via Homebrew..."

BREW_PKGS=(k3d helm mkcert kubectl)
for pkg in "${BREW_PKGS[@]}"; do
  if brew list "$pkg" &>/dev/null; then
    success "$pkg already installed ($(brew info --json "$pkg" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["installed"][0]["version"] if d[0]["installed"] else "?")' 2>/dev/null || echo '?'))"
  else
    info "Installing $pkg..."
    brew install "$pkg"
    success "$pkg installed"
  fi
done

# jq is used by several scripts
if ! command -v jq &>/dev/null; then
  info "Installing jq..."
  brew install jq
  success "jq installed"
else
  success "jq already installed"
fi

echo ""

# ------------------------------------------------------------------------------
# 2. Shell Environment (DOCKER_HOST)
# ------------------------------------------------------------------------------
info "Configuring shell environment..."

SHELL_RC="$HOME/.zshrc"
[ -n "${BASH_VERSION:-}" ] && SHELL_RC="$HOME/.bashrc"

DOCKER_EXPORT_LINE='export DOCKER_HOST="unix://$HOME/.orbstack/run/docker.sock"'
if ! grep -qF 'DOCKER_HOST' "$SHELL_RC" 2>/dev/null; then
  echo "" >> "$SHELL_RC"
  echo "# OrbStack Docker socket (macOS DevOps Lab)" >> "$SHELL_RC"
  echo "$DOCKER_EXPORT_LINE" >> "$SHELL_RC"
  success "Added DOCKER_HOST to $SHELL_RC"
else
  warn "DOCKER_HOST already set in $SHELL_RC — skipping"
fi

# Export for the remainder of this session
export DOCKER_HOST="unix://$HOME/.orbstack/run/docker.sock"

echo ""

# ------------------------------------------------------------------------------
# 3. *.localhost DNS Resolution (macOS-specific)
# ------------------------------------------------------------------------------
info "Configuring *.localhost DNS resolution..."

# macOS does NOT auto-resolve *.localhost to 127.0.0.1 like Linux does.
# We use /etc/resolver/localhost (macOS DNS resolver feature) instead of
# editing /etc/hosts for every subdomain.
RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="$RESOLVER_DIR/localhost"

if [ -f "$RESOLVER_FILE" ] && grep -q "nameserver 127.0.0.1" "$RESOLVER_FILE" 2>/dev/null; then
  success "macOS *.localhost resolver already configured"
else
  info "Creating $RESOLVER_FILE (requires sudo)..."
  sudo mkdir -p "$RESOLVER_DIR"
  sudo tee "$RESOLVER_FILE" > /dev/null <<'EOF'
# Resolve all *.localhost names to 127.0.0.1
# This file is read by macOS's mDNSResponder for the .localhost TLD.
nameserver 127.0.0.1
port 53
EOF
  success "Created $RESOLVER_FILE"
  warn "You may need to flush the DNS cache: sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
fi

echo ""

# ------------------------------------------------------------------------------
# 4. mkcert — Install Local Root CA
# ------------------------------------------------------------------------------
info "Setting up mkcert local root CA..."

mkcert -install
success "mkcert root CA installed in system and browser trust stores"
warn "Completely close and reopen your browser for TLS certificates to be trusted."

echo ""

# ------------------------------------------------------------------------------
# 5. Helm Repositories
# ------------------------------------------------------------------------------
info "Adding Helm chart repositories..."

helm repo add hashicorp   https://helm.releases.hashicorp.com        2>/dev/null || true
helm repo add jenkins     https://charts.jenkins.io                   2>/dev/null || true
helm repo add argo        https://argoproj.github.io/argo-helm        2>/dev/null || true
helm repo add sonarqube   https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
helm repo add openobserve https://charts.openobserve.ai               2>/dev/null || true
helm repo add fluent      https://fluent.github.io/helm-charts        2>/dev/null || true
helm repo update
success "Helm repositories updated"

echo ""

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
echo -e "${BOLD}${GREEN}========================================================${NC}"
echo -e "${BOLD}${GREEN}  macOS setup complete! Next steps:                    ${NC}"
echo -e "${BOLD}${GREEN}========================================================${NC}"
echo ""
echo "  1. Generate TLS certificates:"
echo "     make generate-certs"
echo ""
echo "  2. Create the k3d cluster (using macOS config):"
echo "     make cluster-up"
echo ""
echo "  3. Deploy all platform services:"
echo "     make create-tls-secret"
echo "     make deploy-all"
echo ""
echo "  Services will be available at:"
echo "     https://jenkins.localhost   (admin / admin123)"
echo "     https://argocd.localhost    (admin / admin123)"
echo "     https://sonar.localhost     (admin / admin)"
echo "     https://vault.localhost/ui  (token: root)"
echo "     https://consul.localhost/ui"
echo "     https://openobserve.localhost"
echo ""
