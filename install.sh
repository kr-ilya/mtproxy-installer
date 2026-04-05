#!/bin/bash
set -euo pipefail

# ── Colors & helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

println() { echo -e "$*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
info()    { echo -e "${CYAN}→${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }
header()  { println ""; println "${BOLD}$*${NC}"; println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
sep()     { println "${DIM}────────────────────────────────────────${NC}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
MTPROXY_IMAGE="imilya/mtproxy:latest"
TELEMT_IMAGE="whn0thacked/telemt-docker:latest"
MTPROXY_CONTAINER="mtproxy"
TELEMT_CONTAINER="telemt"
CONFIG_DIR="/etc/mtproxy-installer"
CONFIG_FILE="$CONFIG_DIR/config"          # plain key=value, never sourced
TELEMT_USERS_FILE="$CONFIG_DIR/telemt-users"  # name=secret, one per line
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_TOML="$TELEMT_CONFIG_DIR/telemt.toml"
STATS_PORT=8888
TELEMT_API_PORT=9091          # default; may be overridden by config or user input
TELEMT_API="http://127.0.0.1:${TELEMT_API_PORT}"

# ── Plain key=value config ────────────────────────────────────────────────────
# No shell syntax — values stored and read literally.

cfg_get() {
    # cfg_get KEY  →  prints value or empty string; always exits 0
    local key="$1"
    local line
    line=$(grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null || true)
    # Strip "KEY=" prefix; if key absent, line is empty → echo outputs ""
    echo "${line#*=}"
}

cfg_set() {
    # cfg_set KEY VALUE  →  upsert in CONFIG_FILE
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    else
        echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    : > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    cfg_set PROXY_TYPE    "$PROXY_TYPE"
    cfg_set PORT          "$PORT"
    cfg_set EXTERNAL_IP   "$EXTERNAL_IP"
    cfg_set IMAGE         "$IMAGE"
    cfg_set CONTAINER_NAME "$CONTAINER_NAME"
    if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
        cfg_set SECRET          "$SECRET"
        cfg_set FAKE_TLS        "$FAKE_TLS"
        cfg_set FAKE_TLS_DOMAIN "$FAKE_TLS_DOMAIN"
    fi
    if [[ "$PROXY_TYPE" == "telemt" ]]; then
        cfg_set TELEMT_DOMAIN        "$TELEMT_DOMAIN"
        cfg_set TELEMT_API_PORT      "$TELEMT_API_PORT"
        cfg_set TELEMT_METRICS       "$TELEMT_METRICS"
        cfg_set TELEMT_METRICS_PORT  "$TELEMT_METRICS_PORT"
    fi
}

load_config() {
    PROXY_TYPE=$(cfg_get PROXY_TYPE)
    PORT=$(cfg_get PORT)
    EXTERNAL_IP=$(cfg_get EXTERNAL_IP)
    IMAGE=$(cfg_get IMAGE)
    CONTAINER_NAME=$(cfg_get CONTAINER_NAME)
    SECRET=$(cfg_get SECRET)
    FAKE_TLS=$(cfg_get FAKE_TLS)
    FAKE_TLS_DOMAIN=$(cfg_get FAKE_TLS_DOMAIN)
    TELEMT_DOMAIN=$(cfg_get TELEMT_DOMAIN)
    TELEMT_API_PORT=$(cfg_get TELEMT_API_PORT)
    TELEMT_METRICS=$(cfg_get TELEMT_METRICS)
    TELEMT_METRICS_PORT=$(cfg_get TELEMT_METRICS_PORT)
    # Recompute derived value
    TELEMT_API="http://127.0.0.1:${TELEMT_API_PORT}"
}

config_exists() { [[ -f "$CONFIG_FILE" ]]; }

# ── Secret generation ─────────────────────────────────────────────────────────
gen_hex16() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

gen_fake_tls_secret() {
    local domain="$1"
    local key
    key=$(gen_hex16)
    local domain_hex
    domain_hex=$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')
    echo "ee${key}${domain_hex}"
}

# ── External IP detection ─────────────────────────────────────────────────────
detect_ip() {
    local ip=""
    for svc in ifconfig.me api.ipify.org icanhazip.com; do
        ip=$(curl -sf --max-time 5 "https://$svc" 2>/dev/null || true)
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
    echo ""
}

# ── Container helpers ─────────────────────────────────────────────────────────
container_exists()  { docker inspect "$1" &>/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

status_icon() {
    local name="$1"
    if container_running "$name"; then
        echo "${GREEN}● running${NC}"
    elif container_exists "$name"; then
        echo "${YELLOW}○ stopped${NC}"
    else
        echo "${DIM}✗ not installed${NC}"
    fi
}

stop_and_remove() {
    local name="$1"
    local rm_volumes="${2:-false}"
    if container_exists "$name"; then
        info "Stopping container '$name'..."
        docker stop "$name" &>/dev/null || true
        docker rm   "$name" &>/dev/null || true
    fi
    if [[ "$rm_volumes" == "true" ]]; then
        # Named volume used by official MTProxy
        docker volume rm mtproxy-data &>/dev/null || true
    fi
}

# Verify container is still up a few seconds after docker run.
verify_container() {
    local name="$1"
    info "Verifying container started..."
    local i
    for i in 1 2 3; do
        sleep 1
        if ! container_exists "$name"; then
            println ""
            die "Container '$name' disappeared immediately after start."
        fi
        if container_running "$name"; then
            ok "Container is up."
            return
        fi
    done
    println ""
    warn "Container did not start. Last logs:"
    docker logs --tail=30 "$name" >&2 || true
    die "Container '$name' failed to start. Check logs above."
}

# ── Telemt TOML generator (source of truth: TELEMT_USERS_FILE) ───────────────
# Users file format: one "name=32hexsecret" per line, no shell special chars.

users_file_exists() { [[ -f "$TELEMT_USERS_FILE" ]]; }

users_count() {
    grep -c '.' "$TELEMT_USERS_FILE" 2>/dev/null || echo 0
}

users_get_secret() {
    # users_get_secret NAME
    grep -m1 "^$1=" "$TELEMT_USERS_FILE" 2>/dev/null | cut -d= -f2-
}

users_name_exists() {
    grep -q "^$1=" "$TELEMT_USERS_FILE" 2>/dev/null
}

users_add() {
    local name="$1" secret="$2"
    echo "${name}=${secret}" >> "$TELEMT_USERS_FILE"
    chmod 600 "$TELEMT_USERS_FILE"
}

users_remove() {
    sed -i "/^$1=/d" "$TELEMT_USERS_FILE"
}

users_list_names() {
    cut -d= -f1 "$TELEMT_USERS_FILE" 2>/dev/null
}

# Regenerate telemt.toml from TELEMT_USERS_FILE.
regen_telemt_toml() {
    local port="$1" domain="$2"
    mkdir -p "$TELEMT_CONFIG_DIR"
    # Dir: root-owned, readable by root only
    chmod 750 "$TELEMT_CONFIG_DIR"
    cat > "$TELEMT_TOML" <<TOML
[general]
use_middle_proxy = true

[general.modes]
classic = false
secure = true
tls = true

[server]
port = ${port}
TOML
    if [[ "$TELEMT_METRICS" == "1" ]]; then
        cat >> "$TELEMT_TOML" <<TOML
metrics_port = ${TELEMT_METRICS_PORT}
metrics_whitelist = ["127.0.0.1/32"]
TOML
    fi
    cat >> "$TELEMT_TOML" <<TOML

[server.api]
listen = "127.0.0.1:${TELEMT_API_PORT}"

[censorship]
tls_domain = "${domain}"

[access.users]
TOML
    if users_file_exists; then
        while IFS='=' read -r name secret; do
            [[ -z "$name" || -z "$secret" ]] && continue
            echo "${name} = \"${secret}\"" >> "$TELEMT_TOML"
        done < "$TELEMT_USERS_FILE"
    fi
    chmod 640 "$TELEMT_TOML"
}

# ── Connection link builders ──────────────────────────────────────────────────
telemt_ee_link() {
    local ip="$1" port="$2" domain="$3" secret="$4"
    local domain_hex
    domain_hex=$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')
    echo "tg://proxy?server=${ip}&port=${port}&secret=ee${secret}${domain_hex}"
}

telemt_dd_link() {
    local ip="$1" port="$2" secret="$3"
    echo "tg://proxy?server=${ip}&port=${port}&secret=dd${secret}"
}

# Print both links for a single telemt user (name + secret already known).
print_user_links() {
    local name="$1" secret="$2"
    local ee dd
    ee=$(telemt_ee_link "$EXTERNAL_IP" "$PORT" "$TELEMT_DOMAIN" "$secret")
    dd=$(telemt_dd_link "$EXTERNAL_IP" "$PORT" "$secret")
    println "  ${BOLD}${name}${NC}"
    println "  ${DIM}EE (Fake TLS):${NC} ${GREEN}${ee}${NC}"
    println "  ${DIM}DD (Secure):${NC}   ${GREEN}${dd}${NC}"
    println ""
}

# ── Docker run helpers ────────────────────────────────────────────────────────
run_mtproxy() {
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "${PORT}:${PORT}/tcp" \
        -p "${PORT}:${PORT}/udp" \
        -p "127.0.0.1:${STATS_PORT}:${STATS_PORT}/tcp" \
        -e PORT="${PORT}" \
        -e STATS_PORT="${STATS_PORT}" \
        -e SECRET="${SECRET}" \
        -e EXTERNAL_IP="${EXTERNAL_IP}" \
        -e FAKE_TLS="${FAKE_TLS}" \
        -e FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN}" \
        -v mtproxy-data:/data \
        "${IMAGE}" > /dev/null
}

run_telemt() {
    local extra_ports=()
    if [[ "$TELEMT_METRICS" == "1" ]]; then
        extra_ports+=(-p "127.0.0.1:${TELEMT_METRICS_PORT}:${TELEMT_METRICS_PORT}/tcp")
    fi
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        --user root \
        -p "${PORT}:${PORT}/tcp" \
        -p "127.0.0.1:${TELEMT_API_PORT}:${TELEMT_API_PORT}/tcp" \
        "${extra_ports[@]}" \
        -v "${TELEMT_CONFIG_DIR}:${TELEMT_CONFIG_DIR}" \
        -e RUST_LOG=info \
        "${IMAGE}" "${TELEMT_TOML}" > /dev/null
}

# ── Link display ──────────────────────────────────────────────────────────────
print_mtproxy_links() {
    println ""
    println "  ${BOLD}Server:${NC}  ${EXTERNAL_IP}:${PORT}"
    [[ "$FAKE_TLS" == "1" ]] && println "  ${BOLD}Domain:${NC}  ${FAKE_TLS_DOMAIN}"
    println ""
    local link
    if [[ "$FAKE_TLS" == "1" ]]; then
        link="tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${SECRET}"
    else
        link="tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=dd${SECRET}"
    fi
    println "  ${BOLD}Connection link:${NC}"
    println "  ${GREEN}${link}${NC}"
    println ""
}

print_telemt_links() {
    println ""
    println "  ${BOLD}Server:${NC}  ${EXTERNAL_IP}:${PORT}  (domain: ${TELEMT_DOMAIN})"
    println ""
    if ! users_file_exists || [[ "$(users_count)" -eq 0 ]]; then
        warn "No users configured."
        return
    fi
    while IFS='=' read -r name secret; do
        [[ -z "$name" || -z "$secret" ]] && continue
        print_user_links "$name" "$secret"
    done < "$TELEMT_USERS_FILE"
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Installation flows ────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

install_mtproxy() {
    PROXY_TYPE="mtproxy"
    IMAGE="$MTPROXY_IMAGE"
    CONTAINER_NAME="$MTPROXY_CONTAINER"

    println ""

    # PID limit
    local current_pid_max
    current_pid_max=$(cat /proc/sys/kernel/pid_max)
    if (( current_pid_max > 65535 )); then
        println "${BOLD}PID limit${NC}"
        println "MTProxy may crash if its PID exceeds 65535."
        read -rp "Apply kernel.pid_max=65535? [Y/n]: " _in
        case "${_in,,}" in
            n|no) ok "PID limit skipped" ;;
            *)  echo "kernel.pid_max = 65535" | tee /etc/sysctl.d/99-mtproxy.conf > /dev/null
                sysctl --system > /dev/null
                ok "PID limit applied" ;;
        esac
        println ""
    fi

    # Port
    println "${BOLD}Port${NC}"
    read -rp "Port [443]: " _in
    PORT="${_in:-443}"
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "Invalid port: $PORT"
    ok "Port: $PORT"
    println ""

    # Fake TLS
    println "${BOLD}Fake TLS${NC}"
    println "Disguises traffic as HTTPS. Recommended in censored regions."
    read -rp "Enable Fake TLS? [Y/n]: " _in
    case "${_in,,}" in
        n|no)
            FAKE_TLS=0
            FAKE_TLS_DOMAIN="cloudflare.com"
            SECRET=$(gen_hex16)
            ok "Fake TLS: disabled"
            ;;
        *)
            FAKE_TLS=1
            println ""
            println "${BOLD}Fake TLS domain${NC}"
            println "Pick a popular unblocked domain for SNI masking."
            read -rp "Domain [cloudflare.com]: " _in
            FAKE_TLS_DOMAIN="${_in:-cloudflare.com}"
            SECRET=$(gen_fake_tls_secret "$FAKE_TLS_DOMAIN")
            ok "Fake TLS: enabled (${FAKE_TLS_DOMAIN})"
            ;;
    esac
    println ""

    # External IP
    info "Detecting external IP..."
    EXTERNAL_IP=$(detect_ip)
    [[ -z "$EXTERNAL_IP" ]] && die "Could not detect external IP. Set EXTERNAL_IP manually and re-run."
    ok "External IP: $EXTERNAL_IP"
    println ""

    stop_and_remove "$CONTAINER_NAME"

    info "Pulling ${IMAGE}..."
    docker pull "$IMAGE"
    println ""

    info "Starting container..."
    run_mtproxy
    verify_container "$CONTAINER_NAME"
    save_config

    header "Connection"
    print_mtproxy_links
    println "  Logs:  ${CYAN}docker logs -f ${CONTAINER_NAME}${NC}"
    println "  Re-run this script to manage the proxy."
    println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    println ""
}

install_telemt() {
    PROXY_TYPE="telemt"
    IMAGE="$TELEMT_IMAGE"
    CONTAINER_NAME="$TELEMT_CONTAINER"

    println ""

    # Port
    println "${BOLD}Port${NC}"
    read -rp "Port [443]: " _in
    PORT="${_in:-443}"
    [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "Invalid port: $PORT"
    ok "Port: $PORT"
    println ""

    # API port
    if ! ss -tlnH "sport = :9091" 2>/dev/null | grep -q .; then
        TELEMT_API_PORT=9091
        ok "API port: 9091"
    else
        warn "Port 9091 is already in use."
        read -rp "API port [19091]: " _in
        TELEMT_API_PORT="${_in:-19091}"
        [[ "$TELEMT_API_PORT" =~ ^[0-9]+$ ]] && (( TELEMT_API_PORT >= 1 && TELEMT_API_PORT <= 65535 )) \
            || die "Invalid API port: $TELEMT_API_PORT"
        ok "API port: $TELEMT_API_PORT"
    fi
    TELEMT_API="http://127.0.0.1:${TELEMT_API_PORT}"
    println ""

    # TLS domain
    println "${BOLD}Fake TLS domain${NC}"
    println "Used for SNI masking. Pick a popular unblocked HTTPS site."
    read -rp "Domain [cloudflare.com]: " _in
    TELEMT_DOMAIN="${_in:-cloudflare.com}"
    ok "Domain: $TELEMT_DOMAIN"
    println ""

    # Metrics
    println "${BOLD}Prometheus metrics${NC}"
    println "Expose metrics on localhost for scraping (e.g. by Prometheus/Grafana)."
    read -rp "Enable metrics? [y/N]: " _in
    case "${_in,,}" in
        y|yes)
            TELEMT_METRICS=1
            read -rp "Metrics port [9090]: " _in
            TELEMT_METRICS_PORT="${_in:-9090}"
            [[ "$TELEMT_METRICS_PORT" =~ ^[0-9]+$ ]] && (( TELEMT_METRICS_PORT >= 1 && TELEMT_METRICS_PORT <= 65535 )) \
                || die "Invalid metrics port: $TELEMT_METRICS_PORT"
            ok "Metrics: enabled (127.0.0.1:${TELEMT_METRICS_PORT})"
            ;;
        *)
            TELEMT_METRICS=0
            TELEMT_METRICS_PORT=""
            ok "Metrics: disabled"
            ;;
    esac
    println ""

    # First user
    println "${BOLD}First user${NC}"
    read -rp "Username [user1]: " _in
    local first_user="${_in:-user1}"
    local first_secret
    first_secret=$(gen_hex16)
    ok "User: ${first_user}  secret: ${first_secret}"
    println ""

    # External IP
    info "Detecting external IP..."
    EXTERNAL_IP=$(detect_ip)
    [[ -z "$EXTERNAL_IP" ]] && die "Could not detect external IP."
    ok "External IP: $EXTERNAL_IP"
    println ""

    # Write users file first, then generate TOML from it
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    : > "$TELEMT_USERS_FILE"
    chmod 600 "$TELEMT_USERS_FILE"
    users_add "$first_user" "$first_secret"
    regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
    ok "Config written: $TELEMT_TOML"
    println ""

    stop_and_remove "$CONTAINER_NAME"

    info "Pulling ${IMAGE}..."
    docker pull "$IMAGE"
    println ""

    info "Starting container..."
    run_telemt
    verify_container "$CONTAINER_NAME"
    save_config

    header "Connection"
    print_telemt_links
    println "  Logs:  ${CYAN}docker logs -f ${CONTAINER_NAME}${NC}"
    println "  Re-run this script to manage the proxy."
    println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    println ""
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Management actions ────────────────────────────────────────════════════════
# ══════════════════════════════════════════════════════════════════════════════

action_logs() {
    println ""
    println "  ${DIM}Press Ctrl+C to exit logs${NC}"
    println ""
    docker logs -f --tail=50 "$CONTAINER_NAME"
}

action_update() {
    println ""
    info "Pulling latest image: ${IMAGE}..."
    docker pull "$IMAGE"
    println ""
    info "Restarting container..."
    docker stop "$CONTAINER_NAME" &>/dev/null || true
    docker rm   "$CONTAINER_NAME" &>/dev/null || true
    if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
        run_mtproxy
    else
        run_telemt
    fi
    verify_container "$CONTAINER_NAME"
    ok "Updated and restarted!"
    println ""
}

action_restart() {
    info "Restarting ${CONTAINER_NAME}..."
    docker restart "$CONTAINER_NAME" > /dev/null
    sleep 1
    if ! container_running "$CONTAINER_NAME"; then
        warn "Container did not come back up. Check logs:"
        docker logs --tail=20 "$CONTAINER_NAME" >&2 || true
    else
        ok "Restarted!"
    fi
    println ""
}

action_uninstall() {
    println ""
    warn "This will stop and remove the container and saved config."
    read -rp "Are you sure? [y/N]: " _in
    case "${_in,,}" in
        y|yes) ;;
        *) info "Uninstall cancelled."; return ;;
    esac
    stop_and_remove "$CONTAINER_NAME" true
    rm -f "$CONFIG_FILE" "$TELEMT_USERS_FILE"
    if [[ "$PROXY_TYPE" == "telemt" ]]; then
        read -rp "Remove telemt config dir (${TELEMT_CONFIG_DIR})? [y/N]: " _in
        case "${_in,,}" in
            y|yes) rm -rf "$TELEMT_CONFIG_DIR"; ok "Telemt config dir removed." ;;
            *) ;;
        esac
    fi
    ok "Uninstalled."
    println ""
    exit 0
}

# ── Telemt user management ────────────────────────────────────────────────────
action_list_users() {
    if ! users_file_exists || [[ "$(users_count)" -eq 0 ]]; then
        warn "No users configured."
        return
    fi
    println ""
    println "  ${BOLD}Users${NC}"
    sep
    while IFS='=' read -r name secret; do
        [[ -z "$name" || -z "$secret" ]] && continue
        println "  Secret: ${DIM}${secret}${NC}"
        print_user_links "$name" "$secret"
    done < "$TELEMT_USERS_FILE"
}

action_add_user() {
    println ""
    read -rp "Username: " name
    [[ -z "$name" ]] && warn "Name cannot be empty." && return
    # Restrict to safe characters to prevent TOML injection
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "Username must contain only letters, digits, _ or -."
        return
    fi
    if users_name_exists "$name"; then
        warn "User '${name}' already exists."
        return
    fi

    read -rp "Secret (leave blank to generate): " secret_in
    local secret
    if [[ -z "$secret_in" ]]; then
        secret=$(gen_hex16)
        ok "Generated secret: ${secret}"
    else
        if ! [[ "$secret_in" =~ ^[0-9a-fA-F]{32}$ ]]; then
            warn "Secret must be exactly 32 hex characters."
            return
        fi
        secret="$secret_in"
    fi

    users_add "$name" "$secret"
    regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"

    # Hot-reload via API (no restart needed if API accepts it)
    if container_running "$CONTAINER_NAME"; then
        local api_resp
        api_resp=$(curl -sf -X POST "${TELEMT_API}/v1/users" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${name}\",\"secret\":\"${secret}\"}" 2>/dev/null || echo "")
        if echo "$api_resp" | grep -q '"ok":true'; then
            ok "User '${name}' added via API (no restart needed)."
        else
            info "API unavailable — restarting container..."
            docker restart "$CONTAINER_NAME" > /dev/null
            sleep 1
            ok "User '${name}' added (container restarted)."
        fi
    fi

    println ""
    print_user_links "$name" "$secret"
}

action_remove_user() {
    println ""
    if ! users_file_exists || [[ "$(users_count)" -eq 0 ]]; then
        warn "No users configured."
        return
    fi

    println "  ${BOLD}Current users:${NC}"
    while IFS='=' read -r n _; do
        println "    - $n"
    done < "$TELEMT_USERS_FILE"
    println ""

    read -rp "Username to remove: " name
    [[ -z "$name" ]] && return

    if ! users_name_exists "$name"; then
        warn "User '${name}' not found."
        return
    fi

    if [[ "$(users_count)" -eq 1 ]]; then
        warn "Cannot remove the last user. Add another user first."
        return
    fi

    users_remove "$name"
    regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"

    # Hot-reload via API
    if container_running "$CONTAINER_NAME"; then
        local api_resp
        api_resp=$(curl -sf -X DELETE "${TELEMT_API}/v1/users/${name}" 2>/dev/null || echo "")
        if echo "$api_resp" | grep -q '"ok":true'; then
            ok "User '${name}' removed via API."
        else
            info "API unavailable — restarting container..."
            docker restart "$CONTAINER_NAME" > /dev/null
            sleep 1
            ok "User '${name}' removed (container restarted)."
        fi
    fi
    println ""
}

action_reconfigure() {
    println ""
    if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
        # ── MTProxy reconfigure ───────────────────────────────────────────────
        println "${BOLD}Port${NC} ${DIM}(current: ${PORT})${NC}"
        read -rp "Port [${PORT}]: " _in
        local new_port="${_in:-${PORT}}"
        [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )) \
            || { warn "Invalid port."; return; }

        println ""
        local fake_tls_default="N"; [[ "$FAKE_TLS" == "1" ]] && fake_tls_default="Y"
        println "${BOLD}Fake TLS${NC} ${DIM}(current: $([ "$FAKE_TLS" == "1" ] && echo enabled || echo disabled))${NC}"
        read -rp "Enable Fake TLS? [${fake_tls_default}]: " _in
        local new_fake_tls new_domain new_secret
        case "${_in,,}" in
            n|no) new_fake_tls=0; new_domain="cloudflare.com" ;;
            y|yes|"")
                if [[ "$fake_tls_default" == "N" && -z "$_in" ]]; then
                    new_fake_tls=0; new_domain="cloudflare.com"
                else
                    new_fake_tls=1
                    println ""
                    println "${BOLD}Fake TLS domain${NC} ${DIM}(current: ${FAKE_TLS_DOMAIN})${NC}"
                    read -rp "Domain [${FAKE_TLS_DOMAIN}]: " _in
                    new_domain="${_in:-${FAKE_TLS_DOMAIN}}"
                fi
                ;;
            *) new_fake_tls=0; new_domain="cloudflare.com" ;;
        esac

        println ""
        read -rp "Regenerate secret? (links will change) [y/N]: " _in
        case "${_in,,}" in
            y|yes)
                if [[ "$new_fake_tls" == "1" ]]; then
                    new_secret=$(gen_fake_tls_secret "$new_domain")
                else
                    new_secret=$(gen_hex16)
                fi
                ok "New secret generated."
                ;;
            *) new_secret="$SECRET"; ok "Keeping current secret." ;;
        esac

        PORT="$new_port"; FAKE_TLS="$new_fake_tls"
        FAKE_TLS_DOMAIN="$new_domain"; SECRET="$new_secret"
        save_config
        info "Restarting container..."
        stop_and_remove "$CONTAINER_NAME"
        run_mtproxy
        verify_container "$CONTAINER_NAME"
        header "Connection Links"
        print_mtproxy_links

    else
        # ── Telemt reconfigure ────────────────────────────────────────────────
        println "${BOLD}Port${NC} ${DIM}(current: ${PORT})${NC}"
        read -rp "Port [${PORT}]: " _in
        local new_port="${_in:-${PORT}}"
        [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )) \
            || { warn "Invalid port."; return; }

        println ""
        println "${BOLD}Fake TLS domain${NC} ${DIM}(current: ${TELEMT_DOMAIN})${NC}"
        read -rp "Domain [${TELEMT_DOMAIN}]: " _in
        local new_domain="${_in:-${TELEMT_DOMAIN}}"

        println ""
        local metrics_cur="disabled"; [[ "$TELEMT_METRICS" == "1" ]] && metrics_cur="enabled on port ${TELEMT_METRICS_PORT}"
        local metrics_default="N"; [[ "$TELEMT_METRICS" == "1" ]] && metrics_default="Y"
        println "${BOLD}Prometheus metrics${NC} ${DIM}(current: ${metrics_cur})${NC}"
        read -rp "Enable metrics? [${metrics_default}]: " _in
        local new_metrics new_metrics_port
        case "${_in,,}" in
            n|no) new_metrics=0; new_metrics_port="" ;;
            y|yes|"")
                if [[ "$metrics_default" == "N" && -z "$_in" ]]; then
                    new_metrics=0; new_metrics_port=""
                else
                    new_metrics=1
                    local mp_default="${TELEMT_METRICS_PORT:-9090}"
                    read -rp "Metrics port [${mp_default}]: " _in
                    new_metrics_port="${_in:-${mp_default}}"
                    [[ "$new_metrics_port" =~ ^[0-9]+$ ]] && (( new_metrics_port >= 1 && new_metrics_port <= 65535 )) \
                        || { warn "Invalid metrics port."; return; }
                fi
                ;;
            *) new_metrics=0; new_metrics_port="" ;;
        esac

        PORT="$new_port"; TELEMT_DOMAIN="$new_domain"
        TELEMT_METRICS="$new_metrics"; TELEMT_METRICS_PORT="$new_metrics_port"
        save_config
        regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
        info "Restarting container..."
        stop_and_remove "$CONTAINER_NAME"
        run_telemt
        verify_container "$CONTAINER_NAME"
        header "Connection Links"
        print_telemt_links
    fi
    println ""
}

# ── Menus ─────────────────────────────────────────────────────────────────────
menu_users() {
    while true; do
        header "User Management"
        println "  1) List users + links"
        println "  2) Add user"
        println "  3) Remove user"
        println "  b) Back"
        println ""
        read -rp "Choice: " choice
        case "$choice" in
            1) action_list_users ;;
            2) action_add_user ;;
            3) action_remove_user ;;
            b|B) return ;;
            *) warn "Unknown option." ;;
        esac
    done
}

menu_manage() {
    load_config
    while true; do
        local st info_line
        st=$(status_icon "$CONTAINER_NAME")
        info_line="${PROXY_TYPE}  |  port ${PORT}"
        if [[ "$PROXY_TYPE" == "telemt" ]]; then
            if [[ "$TELEMT_METRICS" == "1" ]]; then
                info_line+="  |  metrics 127.0.0.1:${TELEMT_METRICS_PORT}"
            else
                info_line+="  |  ${DIM}metrics off${NC}"
            fi
        fi
        info_line+="  |  $(echo -e "$st")"
        header "MTProxy Manager"
        println "  ${info_line}"
        println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        println "  1) Show connection links"
        println "  2) View logs"
        println "  3) Update  ${DIM}(pull latest & restart)${NC}"
        if [[ "$PROXY_TYPE" == "telemt" ]]; then
            println "  4) Manage users"
        fi
        println "  5) Reconfigure  ${DIM}(change settings, keep users & secrets)${NC}"
        println "  6) Restart"
        println "  7) Reinstall    ${DIM}(full reset)${NC}"
        println "  8) Uninstall"
        println "  q) Quit"
        println ""
        read -rp "Choice: " choice
        case "$choice" in
            1)
                header "Connection Links"
                if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
                    print_mtproxy_links
                else
                    print_telemt_links
                fi
                ;;
            2) action_logs ;;
            3) action_update ;;
            4)
                if [[ "$PROXY_TYPE" == "telemt" ]]; then
                    menu_users
                else
                    warn "Unknown option."
                fi
                ;;
            5) action_reconfigure ;;
            6) action_restart ;;
            7)
                warn "This will stop the container, wipe config and reinstall from scratch."
                read -rp "Continue? [y/N]: " _in
                case "${_in,,}" in
                    y|yes)
                        stop_and_remove "$CONTAINER_NAME"
                        rm -f "$CONFIG_FILE" "$TELEMT_USERS_FILE"
                        menu_install
                        return
                        ;;
                    *) ;;
                esac
                ;;
            8) action_uninstall ;;
            q|Q) exit 0 ;;
            *) warn "Unknown option." ;;
        esac
    done
}

menu_install() {
    header "MTProxy Installer"
    println "  1) Official MTProxy  ${DIM}(imilya/mtproxy — battle-tested, single secret)${NC}"
    println "  2) Telemt            ${DIM}(Rust, Fake TLS, multi-user, hot reload)${NC}"
    println "  q) Quit"
    println ""
    read -rp "Choice: " choice
    case "$choice" in
        1) install_mtproxy ;;
        2) install_telemt ;;
        q|Q) exit 0 ;;
        *) warn "Unknown option."; menu_install ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Entry point ───────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

command -v docker &>/dev/null || die "Docker is required but not installed."

if config_exists; then
    menu_manage
else
    ok "Docker found"
    println ""
    menu_install
fi
