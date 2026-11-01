#!/usr/bin/env bash
# Reconstructed from the referenced conversation; not the original attachment.
# Fresh Ubuntu 22.04/24.04 VPS only. Run: sudo bash install_3xui_node.sh
# Requires direct DNS (no CDN proxy) and inbound TCP 80, 443, 8443.
set -Eeuo pipefail
umask 077
stage='preflight checks'
diagnostic_service=''
credentials_file=''
on_error() {
    local status=$1 line=$2
    trap - ERR
    set +e
    printf 'Installation stopped at line %s during %s (exit %s). Existing changes were not rolled back.\n' "$line" "$stage" "$status" >&2
    if [[ -n "$credentials_file" && -f "$credentials_file" ]]; then
        printf 'Generated panel credentials are saved in %s (root only).\n' "$credentials_file" >&2
    fi
    if [[ -n "$diagnostic_service" ]] && command -v systemctl >/dev/null; then
        systemctl status "$diagnostic_service" --no-pager --full --lines=0 >&2
        if command -v journalctl >/dev/null; then
            journalctl -u "$diagnostic_service" -p warning -n 20 --no-pager >&2
        fi
    fi
    exit "$status"
}
die() { printf 'ERROR: %s\n' "$*" >&2; on_error 1 "${BASH_LINENO[0]}"; }
trap 'on_error "$?" "$LINENO"' ERR

# A successful reload may return before the new HTTPS listener is ready.
# Keep certificate verification enabled and bypass proxy environment variables.
wait_for_http() {
    local label=$1 url=$2 attempt error_file
    shift 2
    error_file=$(mktemp)
    printf 'Waiting for %s...\n' "$label"
    for ((attempt=1; attempt<=30; attempt++)); do
        if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 3 \
            "$@" "$url" -o /dev/null 2> "$error_file"; then
            rm -f -- "$error_file"
            return 0
        fi
        if ((attempt < 30)); then sleep 1; fi
    done
    printf '%s did not become ready after 30 attempts. Last curl error:\n' "$label" >&2
    cat "$error_file" >&2
    rm -f -- "$error_file"
    return 1
}

valid_domain() {
    local label
    [[ ${#1} -le 253 && "$1" == *.* && "$1" != *..* && "$1" != *[!a-z0-9.-]* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$1"
    [[ "$1" != *. && "${labels[-1]}" =~ [a-z] ]] || return 1
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
}

# Kept separate so the JSON and link can be checked without installing anything.
make_payload() {
    python3 - "$@" <<'PY'
import json, re, sys, urllib.parse, uuid
domain, private, public, short, client_id, output = sys.argv[1:]
assert re.fullmatch(r'[A-Za-z0-9_-]{43}', private), 'Invalid Xray private key: expected 43 base64url characters'
assert re.fullmatch(r'[A-Za-z0-9_-]{43}', public), 'Invalid Xray public key: check the x25519 output format'
assert re.fullmatch(r'[0-9a-f]{16}', short)
assert str(uuid.UUID(client_id)) == client_id
settings = {'clients': [{'id': client_id, 'flow': 'xtls-rprx-vision',
    'email': 'node-client', 'enable': True, 'limitIp': 0, 'totalGB': 0,
    'expiryTime': 0, 'subId': uuid.uuid4().hex[:16]}], 'decryption': 'none', 'fallbacks': []}
stream = {'network': 'tcp', 'security': 'reality', 'tcpSettings': {'acceptProxyProtocol': False,
    'header': {'type': 'none'}}, 'realitySettings': {'show': False,
    'target': domain + ':443', 'xver': 0, 'serverNames': [domain],
    'privateKey': private, 'shortIds': [short],
    'settings': {'publicKey': public, 'fingerprint': 'firefox', 'serverName': domain,
                 'spiderX': '/'}}}
payload = {'remark': 'VLESS Reality', 'enable': True, 'listen': '0.0.0.0',
    'port': 8443, 'protocol': 'vless', 'total': 0, 'expiryTime': 0,
    'settings': json.dumps(settings), 'streamSettings': json.dumps(stream),
    'sniffing': json.dumps({'enabled': True, 'destOverride': ['http', 'tls', 'quic'],
                            'metadataOnly': False, 'routeOnly': False})}
with open(output, 'w', encoding='utf-8') as f:
    json.dump(payload, f)
query = urllib.parse.urlencode({'type': 'tcp', 'security': 'reality', 'encryption': 'none',
    'flow': 'xtls-rprx-vision', 'sni': domain, 'fp': 'firefox', 'pbk': public,
    'sid': short, 'spx': '/'})
print(f'vless://{client_id}@{domain}:8443?{query}#VLESS-Reality')
PY
}

# Cookie-based POST requests, including login, require a session CSRF token.
panel_login() {
    local url=$1 user=$2 pass=$3 cookies=$4
    csrf_token=$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
        -b "$cookies" -c "$cookies" "$url/csrf-token" | python3 -c '
import json, sys
p = json.load(sys.stdin)
token = p.get("obj")
assert p.get("success") is True and isinstance(token, str) and token
print(token)
')
    curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
        -b "$cookies" -c "$cookies" -H "X-CSRF-Token: $csrf_token" \
        --data-urlencode "username=$user" --data-urlencode "password=$pass" \
        "$url/login"
}

# Panel versions return nested settings as either JSON strings or objects.
read_inbound() {
    python3 - "$@" <<'PY'
import json, re, sys, uuid
def require(ok, message):
    if not ok:
        raise SystemExit(message)
def obj(value):
    if isinstance(value, str):
        value = json.loads(value)
    require(isinstance(value, dict), 'Expected a settings object or JSON object string')
    return value
response = json.load(open(sys.argv[1]))
require(response.get('success') is True, 'Panel rejected inbound list request')
items = [x for x in response['obj'] if x['port'] == 8443]
require(len(items) == 1, 'Expected exactly one inbound on port 8443')
x = items[0]
require(x.get('protocol') == 'vless' and x.get('enable') is True, 'Inbound must be enabled VLESS')
stream = obj(x['streamSettings'])
require(stream.get('security') == 'reality' and stream.get('network') == 'tcp', 'Expected TCP Reality inbound')
r = obj(stream['realitySettings'])
require(r.get('target') == sys.argv[2] + ':443' and r.get('serverNames') == [sys.argv[2]], 'Existing Reality domain does not match this recovery')
require(obj(r['settings']).get('fingerprint') == 'firefox', 'Unexpected Reality fingerprint')
clients = obj(x['settings'])['clients']
require(len(clients) == 1, 'Expected one client; refusing to choose or modify clients')
client = clients[0]
require(client.get('flow') == 'xtls-rprx-vision', 'Unexpected client flow')
client_id = client['id']
require(str(uuid.UUID(client_id)) == client_id, 'Invalid client UUID')
if sys.argv[3]:
    require(client_id == sys.argv[3], 'Panel returned a different client UUID')
private = r.get('privateKey', '')
require(re.fullmatch(r'[A-Za-z0-9_-]{43}', private) is not None, 'Missing or invalid existing private key')
shorts = r.get('shortIds', [])
require(len(shorts) == 1 and re.fullmatch(r'[0-9a-f]{16}', shorts[0]) is not None, 'Unexpected Reality short IDs')
with open(sys.argv[4], 'w') as output:
    json.dump({'private': private, 'short': shorts[0], 'client_id': client_id}, output)
PY
}

# Reuse the last saved plaintext token instead of rotating it on every report.
ensure_node_token() {
    api_token=$(awk '/^apiToken: / {sub(/^apiToken: /, ""); token=$0} END {print token}' "$result")
    if [[ -z "$api_token" ]]; then
        /usr/local/x-ui/x-ui setting -getApiToken > "$temp/api-token-output"
        api_token=$(awk '/^apiToken: / {sub(/^apiToken: /, ""); token=$0} END {print token}' "$temp/api-token-output")
        [[ -n "$api_token" && "$api_token" != *[[:space:]]* ]] || die 'Could not obtain API token. Panel credentials are still saved.'
        # Preserve a new token immediately, even if validation/reporting fails.
        printf '\napiToken: %s\n' "$api_token" >> "$result"
    fi
    if ! curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
        -H "Authorization: Bearer $api_token" \
        "http://127.0.0.1:4772/$base/panel/api/server/status" > "$temp/token-check.json"; then
        die 'Saved API token was rejected or the panel API is unavailable. No token was rotated; check API Tokens in the panel.'
    fi
    jq -e '.success == true' "$temp/token-check.json" >/dev/null \
        || die 'Panel API status check failed. No saved token was rotated.'
}

print_details() {
    printf '\n%s\n' '============================================================'
    printf '%s\n' '                     ДАННЫЕ 3X-UI'
    printf '%s\n\n' '============================================================'
    printf '%s\n' '1. ВХОД В ПАНЕЛЬ'
    printf 'Panel: https://%s/%s/\nUsername: %s\nPassword: %s\n' "$panel" "$base" "$username" "$password"
    printf '\n%s\n' '2. ДОБАВЛЕНИЕ НОДЫ В ОСНОВНУЮ 3X-UI'
    printf '%s\n' 'Заполните эти поля в разделе «Ноды» основной панели:'
    printf 'Name: node-%s\nScheme: https\nAddress: %s\nPort: 443\nBasePath: /%s/\n' "$panel" "$panel" "$base"
    printf 'apiToken: %s\n' "$api_token"
    printf '%s\n' 'Enable: true' 'TLS verification: verify' 'Allow private address: false' 'Inbound sync mode: all'
    printf 'Panel API URL: https://%s/%s/panel/api/\n' "$panel" "$base"
    printf '%s\n' 'Адрес вводится без https:// и пути; BasePath — с / по краям.'
    printf '%s\n' 'Для связи между панелями используется порт 443. SSH, логин и пароль панели для API не нужны.'
    printf '\n%s\n' '3. КЛИЕНТСКОЕ ПОДКЛЮЧЕНИЕ VLESS REALITY'
    printf 'Server address: %s\nReality port: 8443\nProtocol: VLESS\nTransport: TCP\nSecurity: Reality\nFlow: xtls-rprx-vision\n' "$cover"
    printf 'SNI: %s\nTarget: %s:443\nFingerprint: firefox\n' "$cover" "$cover"
    printf 'UUID: %s\nPublic key: %s\nShort ID: %s\n' "$client_id" "$public" "$short"
    printf '\nVLESS link:\n%s\n' "$link"
    printf '\n%s\n' '4. ПРОВЕРКИ И ХРАНЕНИЕ'
    printf '%s\n' 'Параметры подключения и API проверены локально на VPS.'
    printf '%s\n' 'Доступ с основной панели и работа реального VLESS-клиента требуют отдельной проверки.'
    printf 'Saved to: %s (root only)\n' "$result"
}

save_details() {
    local report_file
    report_file=$(mktemp "${result}.XXXXXX")
    chmod 600 "$report_file"
    print_details > "$report_file"
    mv -f -- "$report_file" "$result"
}

main() {
    [[ $EUID -eq 0 ]] || die 'Run as root: sudo bash install_3xui_node.sh'
    source /etc/os-release
    [[ "$ID" == ubuntu && ( "$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04 ) ]] || die 'Ubuntu 22.04 or 24.04 required.'
    [[ ! -e /usr/local/x-ui && ! -e /etc/x-ui/x-ui.db ]] || die 'Existing 3x-ui found. This script only supports a fresh VPS.'
    [[ ! -e /etc/nginx ]] || die 'Existing Nginx configuration found. Use a fresh VPS.'
    command -v systemctl >/dev/null || die 'systemd required.'
    [[ ! -e /root/3xui-node-credentials.txt ]] || die 'Saved credentials already exist. Inspect the previous installation before continuing.'
    printf 'Use two domains with DNS A records pointing directly to this VPS. Disable CDN proxy.\n'
    local panel cover email
    read -r -p 'Panel domain: ' panel
    read -r -p 'Camouflage domain (Reality SNI/Target): ' cover
    panel=${panel,,}; cover=${cover,,}
    valid_domain "$panel" && valid_domain "$cover" || die 'Invalid domain. Use ASCII/punycode names without https:// or paths.'
    [[ "$panel" != "$cover" ]] || die 'The two domains must differ.'
    read -r -p "Email for Let's Encrypt: " email
    [[ "$email" == *@*.* && "$email" != -* && "$email" != *[[:space:]]* ]] || die 'Invalid email.'
    export DEBIAN_FRONTEND=noninteractive
    stage='installing prerequisites'
    apt-get update
    apt-get install -y ca-certificates curl dnsutils openssl python3 jq iproute2
    local port
    for port in 80 443 8443 4772; do
        [[ -z "$(ss -H -ltn "sport = :$port")" ]] || die "TCP port $port is already in use."
    done
    stage='checking DNS'
    local ipv4 domain records address
    ipv4=$(curl -4fsS --retry 2 --connect-timeout 10 --max-time 20 https://api.ipify.org)
    python3 -c 'import ipaddress,sys; assert ipaddress.IPv4Address(sys.argv[1]).is_global' "$ipv4"
    for domain in "$panel" "$cover"; do
        records=$(dig +short A "$domain" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/')
        [[ -n "$records" ]] || die "No DNS A record for $domain."
        while read -r address; do
            [[ "$address" == "$ipv4" ]] || die "$domain resolves to $address instead of VPS $ipv4."
        done <<< "$records"
        # This installer deliberately serves IPv4 only. Do not leave broken AAAA.
        [[ -z "$(dig +short AAAA "$domain" | awk '/:/')" ]] || die "Remove AAAA records for $domain before using this IPv4 installer."
    done
    printf 'DNS checks passed. Certificate issuance will check public HTTP access.\n'
    stage='installing and configuring Nginx'
    diagnostic_service=nginx
    apt-get install -y nginx certbot fail2ban
    install -d -m 755 /var/www/3xui-acme /var/www/3xui-cover
    printf '%s\n' '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Welcome</title><h1>Welcome</h1><p>This website is online.</p></html>' > /var/www/3xui-cover/index.html
    chmod 644 /var/www/3xui-cover/index.html
    cat > /etc/nginx/sites-available/3xui-node <<EOF
server {
    listen 80;
    server_name $panel $cover;
    location /.well-known/acme-challenge/ { root /var/www/3xui-acme; }
    location / { return 404; }
}
EOF
    chmod 644 /etc/nginx/sites-available/3xui-node
    ln -s /etc/nginx/sites-available/3xui-node /etc/nginx/sites-enabled/3xui-node
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 8443/tcp
    fi
    stage="issuing certificates"
    for domain in "$panel" "$cover"; do
        certbot certonly --non-interactive --agree-tos --email "$email" \
            --webroot -w /var/www/3xui-acme --cert-name "$domain" -d "$domain"
    done
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nnginx -t && systemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/3xui-nginx
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/3xui-nginx
    systemctl enable --now certbot.timer

    local username password base
    # Global because EXIT cleanup can run after main has returned on an error.
    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    username=$(openssl rand -hex 5)
    password=$(openssl rand -hex 12)
    base=$(openssl rand -hex 9)
    local result=/root/3xui-node-credentials.txt
    # Preserve the intended login before the installer or later checks can fail.
    {
        printf 'Panel: https://%s/%s/\nUsername: %s\nPassword: %s\n' "$panel" "$base" "$username" "$password"
        printf 'Installation may be incomplete; use these credentials after the panel is configured.\n'
    } > "$result"
    chmod 600 "$result"
    credentials_file=$result
    stage='installing and starting 3x-ui'
    diagnostic_service=x-ui
    # Fetch to a file and check syntax before executing; do not pipe network data to bash.
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 \
        https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh -o "$temp/install.sh"
    bash -n "$temp/install.sh"
    XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none \
        XUI_USERNAME="$username" XUI_PASSWORD="$password" XUI_WEB_BASE_PATH="$base" \
        XUI_PANEL_PORT=4772 XUI_ENABLE_FAIL2BAN=true bash "$temp/install.sh"
    systemctl stop x-ui
    /usr/local/x-ui/x-ui setting -username "$username" -password "$password" \
        -port 4772 -webBasePath "/$base/" -listenIP 127.0.0.1
    systemctl enable --now x-ui
    wait_for_http '3x-ui on loopback' "http://127.0.0.1:4772/$base/"
    ss -H -ltn 'sport = :4772' | grep -q '127.0.0.1:4772' || die 'Panel is not listening on loopback.'
    [[ -z "$(ss -H -ltn 'sport = :4772' | grep -v '127.0.0.1:4772')" ]] || die 'Unexpected public panel listener.'
    stage='configuring and checking HTTPS'
    diagnostic_service=nginx
    cat > /etc/nginx/sites-available/3xui-node <<EOF
server {
    listen 80;
    server_name $panel $cover;
    location /.well-known/acme-challenge/ { root /var/www/3xui-acme; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $panel;
    ssl_certificate /etc/letsencrypt/live/$panel/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$panel/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location /$base/ {
        proxy_pass http://127.0.0.1:4772;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
    location / { return 404; }
}
server {
    listen 443 ssl http2;
    server_name $cover;
    ssl_certificate /etc/letsencrypt/live/$cover/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$cover/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/3xui-cover;
    index index.html;
}
EOF
    nginx -t
    systemctl reload nginx
    wait_for_http 'Panel HTTPS' "https://$panel/$base/" --resolve "$panel:443:127.0.0.1"
    wait_for_http 'Camouflage HTTPS' "https://$cover/" --resolve "$cover:443:127.0.0.1"

    stage='configuring and checking Reality'
    diagnostic_service=x-ui
    local xray keys private public short client_id link i
    xray=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' -print -quit)
    [[ -n "$xray" && -x "$xray" ]] || die 'Xray binary not found.'
    keys=$("$xray" x25519)
    private=$(printf '%s\n' "$keys" | awk -F': *' '/^Private[Kk]ey:|^Private key:/ {print $2}')
    public=$(printf '%s\n' "$keys" | awk -F': *' '/^Public[Kk]ey:|^Public key:|^Password( \(PublicKey\))?:/ {print $2}')
    short=$(openssl rand -hex 8)
    client_id=$(cat /proc/sys/kernel/random/uuid)
    link=$(make_payload "$cover" "$private" "$public" "$short" "$client_id" "$temp/inbound.json")
    panel_login "http://127.0.0.1:4772/$base" "$username" "$password" "$temp/cookies" > "$temp/login.json"
    jq -e '.success == true' "$temp/login.json" >/dev/null || die 'Panel login failed.'
    curl -fsS --noproxy '*' --max-time 20 -b "$temp/cookies" -c "$temp/cookies" \
        -H "X-CSRF-Token: $csrf_token" -H 'Content-Type: application/json' \
        --data-binary "@$temp/inbound.json" "http://127.0.0.1:4772/$base/panel/api/inbounds/add" > "$temp/add.json"
    jq -e '.success == true' "$temp/add.json" >/dev/null || die 'Panel rejected Reality inbound.'
    curl -fsS --noproxy '*' --max-time 15 -b "$temp/cookies" \
        "http://127.0.0.1:4772/$base/panel/api/inbounds/list" > "$temp/list.json"
    read_inbound "$temp/list.json" "$cover" "$client_id" "$temp/verified.json"
    for i in {1..20}; do
        if [[ -n "$(ss -H -ltn 'sport = :8443')" ]]; then break; fi
        sleep 1
    done
    [[ -n "$(ss -H -ltn 'sport = :8443')" ]] || die 'Xray has not opened port 8443. Check journalctl -u x-ui.'
    stage='starting Fail2ban'
    diagnostic_service=fail2ban
    systemctl enable --now fail2ban
    stage='saving connection details'
    diagnostic_service=x-ui
    local api_token
    ensure_node_token
    save_details
    cat "$result"

    rm -rf -- "$temp"
    trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
