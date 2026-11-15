#!/bin/sh
set -eu

REPO="flamebase/flamebase"
DEFAULT_PREFIX="/usr/local/bin"
DEFAULT_CONFIG_DIR="/etc/flamebase"
DEFAULT_DATA_DIR="/var/lib/flamebase"

SERVICES="auth,flamestore,storage,functions"
MODE=""
VERSION="latest"
PREFIX="$DEFAULT_PREFIX"
ASSUME_YES=0

log_info() {
    printf "\033[32m[INFO]\033[0m %s\n" "$*"
}

log_warn() {
    printf "\033[33m[WARN]\033[0m %s\n" "$*"
}

log_error() {
    printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            log_warn "This installer requires root privileges. Using sudo..."
            SUDO="sudo"
        else
            log_error "Root privileges are required. Please run with sudo or as root."
            exit 1
        fi
    else
        SUDO=""
    fi
}

detect_system() {
    OS="$(uname -s)"
    if [ "$OS" != "Linux" ]; then
        log_error "Flamebase installer only supports Linux. Detected OS: $OS"
        exit 1
    fi

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)
            TARGET_ARCH="x86_64"
            ;;
        aarch64|arm64)
            TARGET_ARCH="aarch64"
            ;;
        *)
            log_error "Unsupported CPU architecture: $ARCH (only x86_64 and aarch64 supported)"
            exit 1
            ;;
    esac
}

parse_flags() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --services)
                SERVICES="$2"
                shift 2
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --prefix)
                PREFIX="$2"
                shift 2
                ;;
            --yes|-y)
                ASSUME_YES=1
                shift 1
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_help
                exit 1
                ;;
        esac
    done
}

print_help() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Options:
  --mode <binary|docker>     Installation method
  --services <svc1,svc2>     Comma-separated list (auth, flamestore, storage, functions)
  --version <tag>            Release version to install (default: latest)
  --prefix <path>            Binary destination directory (default: /usr/local/bin)
  --yes, -y                  Non-interactive mode accepting all defaults
  --help, -h                 Display this help message
EOF
}

prompt_interactive() {
    if [ -z "$MODE" ]; then
        if [ $ASSUME_YES -eq 1 ]; then
            MODE="binary"
        else
            printf "Select installation mode [1=binary, 2=docker] (default: 1): "
            read -r choice </dev/tty || choice="1"
            case "$choice" in
                2|docker) MODE="docker" ;;
                *) MODE="binary" ;;
            esac
        fi
    fi

    if [ -z "$SERVICES" ] && [ $ASSUME_YES -eq 0 ]; then
        printf "Select services to enable (auth,flamestore,storage,functions) [default: all]: "
        read -r s_input </dev/tty || s_input=""
        if [ -n "$s_input" ]; then
            SERVICES="$s_input"
        fi
    fi
}

install_binary_mode() {
    log_info "Installing Flamebase in standalone binary mode..."

    $SUDO mkdir -p "$PREFIX" "$DEFAULT_CONFIG_DIR" "$DEFAULT_DATA_DIR"

    if ! id -u flamebase >/dev/null 2>&1; then
        log_info "Creating dedicated system user: flamebase"
        $SUDO useradd --system --no-create-home --user-group --shell /sbin/nologin flamebase || true
    fi

    $SUDO chown -R flamebase:flamebase "$DEFAULT_DATA_DIR"

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    BASE_URL="https://github.com/${REPO}/releases"
    if [ "$VERSION" = "latest" ]; then
        DOWNLOAD_URL="${BASE_URL}/latest/download"
    else
        DOWNLOAD_URL="${BASE_URL}/download/${VERSION}"
    fi

    BINS_TO_DOWNLOAD="flamebase-console"
    OLD_IFS="$IFS"
    IFS=','
    for svc in $SERVICES; do
        svc_trimmed="$(echo "$svc" | tr -d ' ')"
        case "$svc_trimmed" in
            auth) BINS_TO_DOWNLOAD="$BINS_TO_DOWNLOAD flamebase-auth" ;;
            flamestore) BINS_TO_DOWNLOAD="$BINS_TO_DOWNLOAD flamebase-flamestore" ;;
            storage) BINS_TO_DOWNLOAD="$BINS_TO_DOWNLOAD flamebase-storage" ;;
            functions)
                BINS_TO_DOWNLOAD="$BINS_TO_DOWNLOAD flamebase-functions"
                if ! command -v node >/dev/null 2>&1; then
                    log_warn "Functions service selected, but Node.js was not detected on PATH!"
                fi
                ;;
        esac
    done
    IFS="$OLD_IFS"

    log_info "Fetching checksums..."
    curl -fsSL "${DOWNLOAD_URL}/SHA256SUMS" -o "${TMP_DIR}/SHA256SUMS" || log_warn "Could not fetch SHA256SUMS"

    for bin in $BINS_TO_DOWNLOAD; do
        ARCHIVE="${bin}-${TARGET_ARCH}-linux.tar.gz"
        log_info "Downloading ${ARCHIVE}..."
        curl -fsSL "${DOWNLOAD_URL}/${ARCHIVE}" -o "${TMP_DIR}/${ARCHIVE}"

        if [ -f "${TMP_DIR}/SHA256SUMS" ]; then
            (cd "$TMP_DIR" && grep "$ARCHIVE" SHA256SUMS | sha256sum -c - >/dev/null 2>&1) || {
                log_warn "Checksum verification bypassed for ${ARCHIVE}"
            }
        fi

        tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}"
        $SUDO install -m 755 "${TMP_DIR}/${bin}" "${PREFIX}/${bin}"
        log_info "Installed ${PREFIX}/${bin}"
    done

    if [ ! -f "${DEFAULT_CONFIG_DIR}/config.toml" ]; then
        log_info "Writing default configuration to ${DEFAULT_CONFIG_DIR}/config.toml"
        $SUDO tee "${DEFAULT_CONFIG_DIR}/config.toml" >/dev/null <<EOF
[general]
data_dir = "${DEFAULT_DATA_DIR}"
log_level = "info"

[auth]
host = "0.0.0.0"
port = 9099

[flamestore]
host = "0.0.0.0"
port = 8080

[storage]
host = "0.0.0.0"
port = 9199

[functions]
host = "0.0.0.0"
port = 5001

[console]
host = "0.0.0.0"
port = 4000
admin_mode = "password"
EOF
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        log_info "Configuring hardened systemd service units..."
        for bin in $BINS_TO_DOWNLOAD; do
            UNIT_FILE="/etc/systemd/system/${bin}.service"
            $SUDO tee "$UNIT_FILE" >/dev/null <<EOF
[Unit]
Description=Flamebase ${bin} service
After=network.target

[Service]
Type=simple
User=flamebase
Group=flamebase
ExecStart=${PREFIX}/${bin} --config ${DEFAULT_CONFIG_DIR}/config.toml
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DEFAULT_DATA_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
            $SUDO systemctl daemon-reload
            $SUDO systemctl enable --now "${bin}.service" || true
            log_info "Started service ${bin}.service"
        done
    fi
}

install_docker_mode() {
    log_info "Installing Flamebase in Docker Compose mode..."

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed. Please install Docker before proceeding."
        exit 1
    fi

    TARGET_DIR="./flamebase"
    mkdir -p "$TARGET_DIR"

    cat <<EOF > "${TARGET_DIR}/.env"
COMPOSE_PROFILES=${SERVICES}
FLAMEBASE_DATA_DIR=/var/lib/flamebase
FLAMEBASE_CONSOLE_PORT=4000
FLAMEBASE_AUTH_PORT=9099
FLAMEBASE_FLAMESTORE_PORT=8080
FLAMEBASE_STORAGE_PORT=9199
FLAMEBASE_FUNCTIONS_PORT=5001
EOF

    curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/installer/docker-compose.yml" -o "${TARGET_DIR}/docker-compose.yml"
    
    log_info "Launching Docker Compose containers..."
    (cd "$TARGET_DIR" && docker compose up -d)
}

print_summary() {
    printf "\n"
    log_info "============================================================"
    log_info " Flamebase Installation Complete!"
    log_info " Console URL: http://localhost:4000/_console/"
    log_info "============================================================"
    printf "\n"
    log_warn "IMPORTANT: Zero default credentials exist."
    log_warn "Create your initial administrator account now:"
    printf "\n"

    if [ "$MODE" = "docker" ]; then
        CMD="docker compose -f ./flamebase/docker-compose.yml exec console flamebase-console admin create admin"
    else
        CMD="${PREFIX}/flamebase-console admin create admin"
    fi

    printf "  Command: %s\n\n" "$CMD"

    if [ $ASSUME_YES -eq 0 ] && [ -t 0 ]; then
        printf "Would you like to run this command now to create an admin? [y/N]: "
        read -r answer </dev/tty || answer="n"
        case "$answer" in
            y|Y|yes|YES)
                if [ "$MODE" = "docker" ]; then
                    docker compose -f ./flamebase/docker-compose.yml exec console flamebase-console admin create admin
                else
                    ${PREFIX}/flamebase-console admin create admin
                fi
                ;;
        esac
    fi
}

main() {
    detect_system
    parse_flags "$@"
    check_root
    prompt_interactive
    if [ "$MODE" = "docker" ]; then
        install_docker_mode
    else
        install_binary_mode
    fi
    print_summary
}

main "$@"
