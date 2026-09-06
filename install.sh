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
LEGACY_CONFIG_FILE="$CONFIG_DIR/config"   # pre-multi-instance layout
CONFIG_FILE=""                            # set by use_instance(); plain key=value, never sourced
TELEMT_USERS_FILE="$CONFIG_DIR/telemt-users"  # name=secret, one per line
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_TOML="$TELEMT_CONFIG_DIR/telemt.toml"
STATS_PORT=8888               # container-side stats port; host side is optional
TELEMT_API_PORT=9091          # default; may be overridden by config or user input
TELEMT_API="http://127.0.0.1:${TELEMT_API_PORT}"

# ── Instances ─────────────────────────────────────────────────────────────────
# Two independent slots: one "mtproxy" and one "telemt", each with its own
# config file and container. They can run side by side on different ports.

INSTANCE_TYPES=(mtproxy telemt)

config_file_for() {
    # config_file_for TYPE → path of that instance's config
    echo "${CONFIG_DIR}/config.$1"
}

container_for() {
    [[ "$1" == "mtproxy" ]] && echo "$MTPROXY_CONTAINER" || echo "$TELEMT_CONTAINER"
}

image_for() {
    [[ "$1" == "mtproxy" ]] && echo "$MTPROXY_IMAGE" || echo "$TELEMT_IMAGE"
}

type_label() {
    [[ "$1" == "mtproxy" ]] && echo "Official MTProxy" || echo "Telemt"
}

other_type() {
    [[ "$1" == "mtproxy" ]] && echo "telemt" || echo "mtproxy"
}

instance_installed() { [[ -f "$(config_file_for "$1")" ]]; }

any_instance_installed() {
    local t
    for t in "${INSTANCE_TYPES[@]}"; do
        instance_installed "$t" && return 0
    done
    return 1
}

# Point the config helpers at one instance. Must be called before
# load_config/save_config and before any action touching a container.
use_instance() {
    PROXY_TYPE="$1"
    CONFIG_FILE=$(config_file_for "$PROXY_TYPE")
    CONTAINER_NAME=$(container_for "$PROXY_TYPE")
    IMAGE=$(image_for "$PROXY_TYPE")
}

# Read a single key straight out of another instance's config file.
peek_cfg() {
    # peek_cfg TYPE KEY
    local line
    line=$(grep -m1 "^${2}=" "$(config_file_for "$1")" 2>/dev/null || true)
    echo "${line#*=}"
}

# One-time migration from the old single-instance layout.
migrate_legacy_config() {
    [[ -f "$LEGACY_CONFIG_FILE" ]] || return 0
    local t target
    t=$(grep -m1 '^PROXY_TYPE=' "$LEGACY_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    [[ "$t" == "telemt" ]] || t="mtproxy"
    target=$(config_file_for "$t")
    if [[ -f "$target" ]]; then
        rm -f "$LEGACY_CONFIG_FILE"
    else
        mv "$LEGACY_CONFIG_FILE" "$target"
        chmod 600 "$target"
    fi
    println "${DIM}Migrated existing ${t} config to ${target}${NC}"
}

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
    [[ -n "$CONFIG_FILE" ]] || die "Internal error: no instance selected."
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
        cfg_set SECRET             "$SECRET"
        cfg_set FAKE_TLS           "$FAKE_TLS"
        cfg_set FAKE_TLS_DOMAIN    "$FAKE_TLS_DOMAIN"
        cfg_set MTPROXY_STATS      "$MTPROXY_STATS"
        cfg_set MTPROXY_STATS_PORT "$MTPROXY_STATS_PORT"
    fi
    if [[ "$PROXY_TYPE" == "telemt" ]]; then
        cfg_set TELEMT_DOMAIN        "$TELEMT_DOMAIN"
        cfg_set TELEMT_API_PORT      "$TELEMT_API_PORT"
        cfg_set TELEMT_METRICS       "$TELEMT_METRICS"
        cfg_set TELEMT_METRICS_PORT  "$TELEMT_METRICS_PORT"
    fi
}

load_config() {
    # Called after use_instance(); PROXY_TYPE is the fallback if the file lacks it.
    local fallback_type="$PROXY_TYPE"
    PROXY_TYPE=$(cfg_get PROXY_TYPE)
    [[ -n "$PROXY_TYPE" ]] || PROXY_TYPE="$fallback_type"
    PORT=$(cfg_get PORT)
    EXTERNAL_IP=$(cfg_get EXTERNAL_IP)
    IMAGE=$(cfg_get IMAGE)
    CONTAINER_NAME=$(cfg_get CONTAINER_NAME)
    SECRET=$(cfg_get SECRET)
    FAKE_TLS=$(cfg_get FAKE_TLS)
    FAKE_TLS_DOMAIN=$(cfg_get FAKE_TLS_DOMAIN)
    MTPROXY_STATS=$(cfg_get MTPROXY_STATS)
    MTPROXY_STATS_PORT=$(cfg_get MTPROXY_STATS_PORT)
    TELEMT_DOMAIN=$(cfg_get TELEMT_DOMAIN)
    TELEMT_API_PORT=$(cfg_get TELEMT_API_PORT)
    TELEMT_API_PORT="${TELEMT_API_PORT:-9091}"
    TELEMT_METRICS=$(cfg_get TELEMT_METRICS)
    TELEMT_METRICS_PORT=$(cfg_get TELEMT_METRICS_PORT)
    # Recompute derived values / repair configs written by older versions
    TELEMT_API="http://127.0.0.1:${TELEMT_API_PORT}"
    # Configs written before the stats port became optional always published it.
    [[ "$PROXY_TYPE" == "mtproxy" && -z "$MTPROXY_STATS" ]] && MTPROXY_STATS=1
    MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-$STATS_PORT}"
    [[ -n "$CONTAINER_NAME" ]] || CONTAINER_NAME=$(container_for "$PROXY_TYPE")
    [[ -n "$IMAGE" ]]          || IMAGE=$(image_for "$PROXY_TYPE")
}

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

# Raw 16-byte key of an MTProxy secret, with any ee/dd prefix and the
# appended domain stripped. This is the "plain" (unobfuscated) secret.
mtproxy_base_secret() {
    local s="$1"
    case "$s" in
        ee*|dd*) echo "${s:2:32}" ;;
        *)       echo "${s:0:32}" ;;
    esac
}

# ── Port helpers ──────────────────────────────────────────────────────────────
port_used_by_other_instance() {
    # port_used_by_other_instance PORT SELF_TYPE
    local port="$1" other other_port
    other=$(other_type "$2")
    instance_installed "$other" || return 1
    other_port=$(peek_cfg "$other" PORT)
    [[ -n "$other_port" && "$other_port" == "$port" ]]
}

# Prompt until a valid, non-conflicting port is entered. Sets PORT.
read_port() {
    # read_port SELF_TYPE DEFAULT
    local self="$1" default="$2" p
    while true; do
        read -rp "Port [${default}]: " _in
        p="${_in:-$default}"
        if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            warn "Invalid port: $p"
            continue
        fi
        if port_used_by_other_instance "$p" "$self"; then
            warn "Port ${p} is already used by the $(other_type "$self") instance. Pick another one."
            continue
        fi
        PORT="$p"
        return
    done
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

valid_ipv4() {
    local ip="$1" a b c d o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for o in "$a" "$b" "$c" "$d"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

valid_host() {
    valid_ipv4 "$1" && return 0
    # Not a valid IPv4 — only a hostname is left, so it must contain a letter.
    # (Otherwise "256.1.1.1" or "1.2.3" would sneak through as a "hostname".)
    [[ "$1" =~ [a-zA-Z] ]] || return 1
    # Letters, digits, dots and hyphens; must start and end alphanumeric.
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

# Detect the external IP, then let the user confirm or override it —
# e.g. 127.0.0.1 for a local test install, or a domain name. Sets EXTERNAL_IP.
read_external_ip() {
    local current="${1:-}" detected=""
    if [[ -z "$current" ]]; then
        info "Detecting external IP..."
        detected=$(detect_ip)
        if [[ -n "$detected" ]]; then
            ok "Detected: ${detected}"
        else
            warn "Could not detect the external IP automatically — enter it manually."
        fi
    fi
    local default="${current:-${detected:-127.0.0.1}}"
    println "${DIM}Used in connection links. Enter 127.0.0.1 for a local install${NC}"
    println "${DIM}— the port is then published on loopback only.${NC}"
    while true; do
        read -rp "Server address [${default}]: " _in
        local host="${_in:-$default}"
        if valid_host "$host"; then
            EXTERNAL_IP="$host"
            ok "Server address: $EXTERNAL_IP"
            return
        fi
        warn "Invalid address: ${host}"
    done
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
metrics_whitelist = ["0.0.0.0/0"]
TOML
    fi
    cat >> "$TELEMT_TOML" <<TOML

[server.api]
listen = "0.0.0.0:${TELEMT_API_PORT}"
whitelist = []

[censorship]
tls_domain = "${domain}"

[access.users]
TOML
    if users_file_exists; then
        while IFS='=' read -r _n _s; do
            [[ -z "$_n" || -z "$_s" ]] && continue
            echo "${_n} = \"${_s}\"" >> "$TELEMT_TOML"
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
# A local install (127.x.x.x / localhost) is only reachable from this machine,
# so the proxy port is published on the loopback interface instead of 0.0.0.0.
is_local_install() {
    [[ "$EXTERNAL_IP" == "localhost" || "$EXTERNAL_IP" =~ ^127\. ]]
}

publish_addr() {
    if is_local_install; then echo "127.0.0.1:"; else echo ""; fi
}

run_mtproxy() {
    local bind stats_ports=()
    bind=$(publish_addr)
    # The stats endpoint lives inside the container either way; publishing it
    # on the host is opt-in so it does not occupy a port for nothing.
    if [[ "$MTPROXY_STATS" == "1" ]]; then
        stats_ports+=(-p "127.0.0.1:${MTPROXY_STATS_PORT}:${STATS_PORT}/tcp")
    fi
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "${bind}${PORT}:${PORT}/tcp" \
        -p "${bind}${PORT}:${PORT}/udp" \
        "${stats_ports[@]}" \
        -e PORT="${PORT}" \
        -e STATS_PORT="${STATS_PORT}" \
        -e SECRET="${SECRET}" \
        -e EXTERNAL_IP="${EXTERNAL_IP}" \
        -e FAKE_TLS="${FAKE_TLS}" \
        -e FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN}" \
        -v mtproxy-data:/data \
        --log-driver json-file \
        --log-opt max-size=15m \
        --log-opt max-file=3 \
        "${IMAGE}" > /dev/null
}

run_telemt() {
    local extra_ports=() bind
    bind=$(publish_addr)
    if [[ "$TELEMT_METRICS" == "1" ]]; then
        extra_ports+=(-p "127.0.0.1:${TELEMT_METRICS_PORT}:${TELEMT_METRICS_PORT}/tcp")
    fi
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        --user root \
        -p "${bind}${PORT}:${PORT}/tcp" \
        -p "127.0.0.1:${TELEMT_API_PORT}:${TELEMT_API_PORT}/tcp" \
        "${extra_ports[@]}" \
        -v "${TELEMT_CONFIG_DIR}:${TELEMT_CONFIG_DIR}" \
        -e RUST_LOG=info \
        --log-driver json-file \
        --log-opt max-size=15m \
        --log-opt max-file=3 \
        "${IMAGE}" "${TELEMT_TOML}" > /dev/null
}

# ── Link display ──────────────────────────────────────────────────────────────
print_local_bind_note() {
    is_local_install || return 0
    println "  ${DIM}Local install: port ${PORT} is published on 127.0.0.1 only,${NC}"
    println "  ${DIM}not reachable from outside this machine.${NC}"
}

print_mtproxy_links() {
    println ""
    println "  ${BOLD}Server:${NC}  ${EXTERNAL_IP}:${PORT}"
    [[ "$FAKE_TLS" == "1" ]] && println "  ${BOLD}Domain:${NC}  ${FAKE_TLS_DOMAIN}"
    print_local_bind_note
    println ""
    local base
    base=$(mtproxy_base_secret "$SECRET")
    println "  ${BOLD}Connection links:${NC}"
    if [[ "$FAKE_TLS" == "1" ]]; then
        println "  ${DIM}EE (Fake TLS):${NC} ${GREEN}tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${SECRET}${NC}"
    fi
    println "  ${DIM}DD (Secure):${NC}   ${GREEN}tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=dd${base}${NC}"
    println "  ${DIM}Plain (no obfuscation):${NC}"
    println "  ${GREEN}tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${base}${NC}"
    println ""
}

print_telemt_links() {
    println ""
    println "  ${BOLD}Server:${NC}  ${EXTERNAL_IP}:${PORT}  (domain: ${TELEMT_DOMAIN})"
    print_local_bind_note
    println ""
    if ! users_file_exists || [[ "$(users_count)" -eq 0 ]]; then
        warn "No users configured."
        return
    fi
    while IFS='=' read -r _n _s; do
        [[ -z "$_n" || -z "$_s" ]] && continue
        print_user_links "$_n" "$_s"
    done < "$TELEMT_USERS_FILE"
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Installation flows ────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

install_mtproxy() {
    use_instance mtproxy

    println ""
    if instance_installed telemt; then
        info "Telemt is already installed on port $(peek_cfg telemt PORT) — MTProxy will run alongside it."
        println ""
    fi

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
    local default_port=443
    port_used_by_other_instance 443 mtproxy && default_port=8443
    read_port mtproxy "$default_port"
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

    # Stats endpoint
    println "${BOLD}Stats endpoint${NC}"
    println "Publishes MTProxy statistics on localhost. Rarely needed."
    read -rp "Publish stats port? [y/N]: " _in
    case "${_in,,}" in
        y|yes)
            MTPROXY_STATS=1
            read -rp "Stats port [${STATS_PORT}]: " _in
            MTPROXY_STATS_PORT="${_in:-$STATS_PORT}"
            [[ "$MTPROXY_STATS_PORT" =~ ^[0-9]+$ ]] && (( MTPROXY_STATS_PORT >= 1 && MTPROXY_STATS_PORT <= 65535 )) \
                || die "Invalid stats port: $MTPROXY_STATS_PORT"
            ok "Stats: published on 127.0.0.1:${MTPROXY_STATS_PORT}"
            ;;
        *)
            MTPROXY_STATS=0
            MTPROXY_STATS_PORT=""
            ok "Stats: not published"
            ;;
    esac
    println ""

    # External IP
    println "${BOLD}Server address${NC}"
    read_external_ip
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
    println "  Manage it from the proxy list below (or re-run this script)."
    println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    println ""
}

install_telemt() {
    use_instance telemt

    println ""
    if instance_installed mtproxy; then
        info "MTProxy is already installed on port $(peek_cfg mtproxy PORT) — Telemt will run alongside it."
        println ""
    fi

    # Port
    println "${BOLD}Port${NC}"
    local default_port=443
    port_used_by_other_instance 443 telemt && default_port=8443
    read_port telemt "$default_port"
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
    println "${BOLD}Server address${NC}"
    read_external_ip
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
    println "  Manage it from the proxy list below (or re-run this script)."
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

# Remove everything belonging to the current instance only — the other
# instance's container, config, volume and users file must stay untouched.
wipe_instance() {
    if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
        stop_and_remove "$CONTAINER_NAME" true
    else
        stop_and_remove "$CONTAINER_NAME"
        rm -f "$TELEMT_USERS_FILE"
    fi
    rm -f "$CONFIG_FILE"
}

# Returns 0 when the instance was actually removed, 1 when cancelled.
action_uninstall() {
    println ""
    warn "This will stop and remove the ${PROXY_TYPE} container and its saved config."
    read -rp "Are you sure? [y/N]: " _in
    case "${_in,,}" in
        y|yes) ;;
        *) info "Uninstall cancelled."; return 1 ;;
    esac
    wipe_instance
    if [[ "$PROXY_TYPE" == "telemt" ]]; then
        read -rp "Remove telemt config dir (${TELEMT_CONFIG_DIR})? [y/N]: " _in
        case "${_in,,}" in
            y|yes) rm -rf "$TELEMT_CONFIG_DIR"; ok "Telemt config dir removed." ;;
            *) ;;
        esac
    fi
    ok "Uninstalled."
    println ""
    return 0
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
    while IFS='=' read -r _n _s; do
        [[ -z "$_n" || -z "$_s" ]] && continue
        println "  Secret: ${DIM}${_s}${NC}"
        print_user_links "$_n" "$_s"
    done < "$TELEMT_USERS_FILE"
}

action_add_user() {
    println ""
    local name
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

    # Try API first — telemt watches TOML via inotify, so writing the file
    # before the API call would make the user already exist in runtime.
    if container_running "$CONTAINER_NAME"; then
        local api_resp
        api_resp=$(curl -s -X POST "${TELEMT_API}/v1/users" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${name}\",\"secret\":\"${secret}\"}" 2>/dev/null || echo "")
        if echo "$api_resp" | grep -q '"ok":true'; then
            # API succeeded: persist to files so the user survives a restart
            users_add "$name" "$secret"
            regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
            ok "User '${name}' added via API."
        else
            # API failed: write files and restart — inotify will pick up the change
            users_add "$name" "$secret"
            regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
            info "Restarting container..."
            docker restart "$CONTAINER_NAME" > /dev/null
            sleep 1
            ok "User '${name}' added (container restarted)."
        fi
    else
        users_add "$name" "$secret"
        regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
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

    local name
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

    # Try API first for the same reason as add: inotify would remove the user
    # from runtime as soon as we write the TOML, causing a DELETE conflict.
    if container_running "$CONTAINER_NAME"; then
        local api_resp
        api_resp=$(curl -s -X DELETE "${TELEMT_API}/v1/users/${name}" 2>/dev/null || echo "")
        if echo "$api_resp" | grep -q '"ok":true'; then
            users_remove "$name"
            regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
            ok "User '${name}' removed via API."
        else
            users_remove "$name"
            regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
            info "Restarting container..."
            docker restart "$CONTAINER_NAME" > /dev/null
            sleep 1
            ok "User '${name}' removed (container restarted)."
        fi
    else
        users_remove "$name"
        regen_telemt_toml "$PORT" "$TELEMT_DOMAIN"
    fi
    println ""
}

action_reconfigure() {
    println ""
    if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
        # ── MTProxy reconfigure ───────────────────────────────────────────────
        println "${BOLD}Port${NC} ${DIM}(current: ${PORT})${NC}"
        local old_port="$PORT"
        read_port mtproxy "$PORT"
        local new_port="$PORT"
        PORT="$old_port"

        println ""
        println "${BOLD}Server address${NC} ${DIM}(current: ${EXTERNAL_IP})${NC}"
        local old_ip="$EXTERNAL_IP"
        read_external_ip "$EXTERNAL_IP"
        local new_ip="$EXTERNAL_IP"
        EXTERNAL_IP="$old_ip"

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
        local stats_cur="not published"; [[ "$MTPROXY_STATS" == "1" ]] && stats_cur="published on 127.0.0.1:${MTPROXY_STATS_PORT}"
        local stats_default="N"; [[ "$MTPROXY_STATS" == "1" ]] && stats_default="Y"
        println "${BOLD}Stats endpoint${NC} ${DIM}(current: ${stats_cur})${NC}"
        read -rp "Publish stats port? [${stats_default}]: " _in
        local new_stats new_stats_port
        case "${_in,,}" in
            n|no) new_stats=0; new_stats_port="" ;;
            y|yes|"")
                if [[ "$stats_default" == "N" && -z "$_in" ]]; then
                    new_stats=0; new_stats_port=""
                else
                    new_stats=1
                    local sp_default="${MTPROXY_STATS_PORT:-$STATS_PORT}"
                    read -rp "Stats port [${sp_default}]: " _in
                    new_stats_port="${_in:-$sp_default}"
                    [[ "$new_stats_port" =~ ^[0-9]+$ ]] && (( new_stats_port >= 1 && new_stats_port <= 65535 )) \
                        || { warn "Invalid stats port."; return; }
                fi
                ;;
            *) new_stats=0; new_stats_port="" ;;
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

        PORT="$new_port"; EXTERNAL_IP="$new_ip"; FAKE_TLS="$new_fake_tls"
        FAKE_TLS_DOMAIN="$new_domain"; SECRET="$new_secret"
        MTPROXY_STATS="$new_stats"; MTPROXY_STATS_PORT="$new_stats_port"
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
        local old_port="$PORT"
        read_port telemt "$PORT"
        local new_port="$PORT"
        PORT="$old_port"

        println ""
        println "${BOLD}Server address${NC} ${DIM}(current: ${EXTERNAL_IP})${NC}"
        local old_ip="$EXTERNAL_IP"
        read_external_ip "$EXTERNAL_IP"
        local new_ip="$EXTERNAL_IP"
        EXTERNAL_IP="$old_ip"

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

        PORT="$new_port"; EXTERNAL_IP="$new_ip"; TELEMT_DOMAIN="$new_domain"
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
    use_instance "$1"
    load_config
    while true; do
        local st info_line
        st=$(status_icon "$CONTAINER_NAME")
        info_line="${PROXY_TYPE}  |  port ${PORT}"
        if [[ "$PROXY_TYPE" == "mtproxy" ]]; then
            if [[ "$MTPROXY_STATS" == "1" ]]; then
                info_line+="  |  stats 127.0.0.1:${MTPROXY_STATS_PORT}"
            else
                info_line+="  |  ${DIM}stats off${NC}"
            fi
        fi
        if [[ "$PROXY_TYPE" == "telemt" ]]; then
            if [[ "$TELEMT_METRICS" == "1" ]]; then
                info_line+="  |  metrics 127.0.0.1:${TELEMT_METRICS_PORT}"
            else
                info_line+="  |  ${DIM}metrics off${NC}"
            fi
        fi
        info_line+="  |  $(echo -e "$st")"
        header "$(type_label "$PROXY_TYPE") — Manage"
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
        println "  b) Back  ${DIM}(proxy list)${NC}"
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
                warn "This will stop the ${PROXY_TYPE} container, wipe its config and reinstall from scratch."
                read -rp "Continue? [y/N]: " _in
                case "${_in,,}" in
                    y|yes)
                        local t="$PROXY_TYPE"
                        wipe_instance
                        install_instance "$t"
                        return
                        ;;
                    *) ;;
                esac
                ;;
            8) if action_uninstall; then return; fi ;;
            b|B) return ;;
            q|Q) exit 0 ;;
            *) warn "Unknown option." ;;
        esac
    done
}

install_instance() {
    case "$1" in
        mtproxy) install_mtproxy ;;
        telemt)  install_telemt ;;
    esac
}

# One line per instance slot: settings + container state, or "not installed".
instance_summary() {
    local t="$1"
    if ! instance_installed "$t"; then
        echo "${DIM}not installed${NC}"
        return
    fi
    local extra=""
    if [[ "$t" == "telemt" ]]; then
        extra="  |  domain $(peek_cfg telemt TELEMT_DOMAIN)"
    elif [[ "$(peek_cfg mtproxy FAKE_TLS)" == "1" ]]; then
        extra="  |  domain $(peek_cfg mtproxy FAKE_TLS_DOMAIN)"
    fi
    echo "port $(peek_cfg "$t" PORT)${extra}  |  $(status_icon "$(container_for "$t")")"
}

menu_main() {
    while true; do
        header "MTProxy Installer"
        println "  ${DIM}Both proxies can run side by side on different ports.${NC}"
        println ""
        println "  1) Official MTProxy  ${DIM}(imilya/mtproxy — battle-tested, single secret)${NC}"
        println "     $(instance_summary mtproxy)"
        println "  2) Telemt            ${DIM}(Rust, Fake TLS, multi-user, hot reload)${NC}"
        println "     $(instance_summary telemt)"
        println "  q) Quit"
        println ""
        println "  ${DIM}Pick an installed proxy to manage it, or a free slot to install it.${NC}"
        println ""
        read -rp "Choice: " choice
        local t=""
        case "$choice" in
            1) t="mtproxy" ;;
            2) t="telemt" ;;
            q|Q) exit 0 ;;
            *) warn "Unknown option."; continue ;;
        esac
        if instance_installed "$t"; then
            menu_manage "$t"
        else
            install_instance "$t"
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# ── Entry point ───────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

command -v docker &>/dev/null || die "Docker is required but not installed."

migrate_legacy_config

if ! any_instance_installed; then
    ok "Docker found"
    println ""
fi

menu_main
