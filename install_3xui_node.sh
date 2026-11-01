#!/usr/bin/env bash
# Reconstructed from the referenced conversation; not the original attachment.
# Fresh Ubuntu 22.04/24.04 VPS only. Run: sudo bash install_3xui_node.sh
# Requires direct DNS (no CDN proxy) and inbound TCP 80, 443, 8443.
set -Eeuo pipefail
umask 077
stage='Проверка VPS'
step_number=0
diagnostic_service=''
credentials_file=''
state_fields=(panel cover email username password base private public short client_id
    install_started install_done configured token_started inbound_done completed)

# Check the actual output stream: reports and redirected logs stay plain text.
ui_line() {
    local color=$1
    shift
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$*"
    else
        printf '%s\n' "$*"
    fi
}

begin_step() {
    if ((step_number > 0)); then ui_line 32 "  [ OK ] $stage"; fi
    step_number=$1
    stage=$2
    printf '\n'
    ui_line 36 "  [$step_number/10] $stage"
}

# JSON is data, never sourced as shell code. Replace the state atomically.
save_state() {
    local name values=()
    for name in "${state_fields[@]}"; do values+=("${!name}"); done
    python3 - "$state_dir/state.json" "${values[@]}" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
names = 'panel cover email username password base private public short client_id install_started install_done configured token_started inbound_done completed'.split()
data = dict(zip(names, sys.argv[2:]))
data['version'] = 1
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    if os.name == 'posix':
        directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

load_state() {
    local serialized name index=0 values
    serialized=$(python3 - "$state_dir/state.json" <<'PY'
import json, re, sys, uuid
d = json.load(open(sys.argv[1], encoding='utf-8'))
def require(ok):
    if not ok:
        raise SystemExit('Invalid or unsupported installation state; no changes made.')
names = 'panel cover email username password base private public short client_id install_started install_done configured token_started inbound_done completed'.split()
require(d.get('version') == 1)
require(all(isinstance(d.get(n), str) and not any(c in d[n] for c in '\n\r\0') for n in names))
for n, size in [('username', 10), ('password', 24), ('base', 18)]:
    require(re.fullmatch('[0-9a-f]{%d}' % size, d[n]) is not None)
for n in names[10:]:
    require(d[n] in ('0', '1'))
require(d['install_done'] <= d['install_started'] and d['configured'] <= d['install_done'])
require(d['completed'] <= d['inbound_done'] and d['completed'] <= d['token_started'])
if any(d[n] for n in ('private', 'public', 'short', 'client_id')):
    require(all(re.fullmatch('[A-Za-z0-9_-]{43}', d[n]) for n in ('private', 'public')))
    require(re.fullmatch('[0-9a-f]{16}', d['short']) is not None)
    require(str(uuid.UUID(d['client_id'])) == d['client_id'])
require(d['inbound_done'] == '0' or bool(d['private']))
print('\n'.join(d[n] for n in names))
PY
    )
    mapfile -t values <<< "$serialized"
    for name in "${state_fields[@]}"; do
        printf -v "$name" '%s' "${values[index]}"
        index=$((index + 1))
    done
    valid_domain "$panel" && valid_domain "$cover" && [[ "$panel" != "$cover" ]] \
        || die 'Invalid domains in installation state.'
}

# Only the two configurations generated for this installation may be replaced.
managed_nginx() {
    local source=$1 target=${2:-/etc/nginx/sites-available/3xui-node} pending
    [[ ! -L "$target" ]] || die 'Unexpected Nginx configuration symlink.'
    if [[ -e "$target" ]]; then
        cmp -s "$target" "$state_dir/bootstrap.conf" || cmp -s "$target" "$state_dir/https.conf" \
            || die 'Nginx configuration changed outside the installer; inspect it before resuming.'
    fi
    pending=$(mktemp "${target}.XXXXXX")
    install -m 644 "$source" "$pending"
    mv -f -- "$pending" "$target"
}
on_error() {
    local status=$1 line=$2
    trap - ERR
    set +e
    ui_line 31 "  [СТОП] $stage" >&2
    printf '  Строка %s, код выхода %s. Изменения на сервере не отменены.\n' "$line" "$status" >&2
    if [[ -n "${state_dir:-}" && -f "$state_dir/state.json" ]]; then
        printf '\n  После устранения причины продолжите установку:\n  bash install_3xui_node.sh --resume\n' >&2
    fi
    if [[ -n "$credentials_file" && -f "$credentials_file" ]]; then
        printf '\n  Данные панели: %s (доступ только root).\n' "$credentials_file" >&2
    fi
    if [[ -n "$diagnostic_service" ]] && command -v systemctl >/dev/null; then
        systemctl status "$diagnostic_service" --no-pager --full --lines=0 >&2
        if command -v journalctl >/dev/null; then
            journalctl -u "$diagnostic_service" -p warning -n 20 --no-pager >&2
        fi
    fi
    exit "$status"
}
die() { ui_line 31 "  [ОШИБКА] $*" >&2; on_error 1 "${BASH_LINENO[0]}"; }
trap 'on_error "$?" "$LINENO"' ERR

# A successful reload may return before the new HTTPS listener is ready.
# Keep certificate verification enabled and bypass proxy environment variables.
wait_for_http() {
    local label=$1 url=$2 attempt error_file
    shift 2
    error_file=$(mktemp)
    ui_line 36 "  [ .. ] Ожидание: $label"
    for ((attempt=1; attempt<=30; attempt++)); do
        if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 3 \
            "$@" "$url" -o /dev/null 2> "$error_file"; then
            rm -f -- "$error_file"
            ui_line 32 "  [ OK ] $label отвечает"
            return 0
        fi
        if ((attempt < 30)); then sleep 1; fi
    done
    printf '%s: нет ответа после 30 попыток. Последняя ошибка curl:\n' "$label" >&2
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
    'expiryTime': 0, 'subId': uuid.UUID(client_id).hex[:16]}], 'decryption': 'none', 'fallbacks': []}
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
if len(sys.argv) > 5:
    expected = json.load(open(sys.argv[5]))
    es = obj(expected['streamSettings'])
    er = es['realitySettings']
    require(r.get('xver', 0) == er['xver'], 'Existing Reality xver differs from saved configuration')
    settings = obj(x['settings'])
    expected_settings = obj(expected['settings'])
    require(settings.get('decryption') == expected_settings['decryption'] and
            settings.get('fallbacks', []) == expected_settings['fallbacks'],
            'Existing VLESS settings differ from saved configuration')
    require(all(x.get(k) == expected[k] for k in ('total', 'expiryTime')), 'Existing inbound limits differ from saved configuration')
    tcp = obj(stream.get('tcpSettings', {}))
    require(tcp.get('acceptProxyProtocol') == es['tcpSettings']['acceptProxyProtocol'] and
            obj(tcp.get('header', {})).get('type') == es['tcpSettings']['header']['type'],
            'Existing TCP settings differ from saved configuration')
    require(private == er['privateKey'], 'Existing Reality private key differs from saved key')
    require(shorts == er['shortIds'], 'Existing Reality short IDs differ from saved identity')
    require(x.get('listen') == expected['listen'], 'Existing inbound listen address changed')
    ec = obj(expected['settings'])['clients'][0]
    require(all(client.get(k) == ec[k] for k in ('id', 'flow', 'enable', 'subId', 'limitIp', 'totalGB', 'expiryTime')), 'Existing client differs from saved identity')
PY
}

reconcile_inbound() {
    local count
    curl -fsS --noproxy '*' --max-time 15 -b "$temp/cookies" \
        "http://127.0.0.1:4772/$base/panel/api/inbounds/list" > "$temp/list.json"
    count=$(python3 - "$temp/list.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
if p.get('success') is not True or not isinstance(p.get('obj'), list):
    raise SystemExit('Panel rejected inbound list request')
print(sum(x.get('port') == 8443 for x in p['obj']))
PY
    )
    if [[ "$count" == 0 ]]; then
        [[ "$inbound_done" == 0 ]] || die 'Previously verified inbound is missing; refusing to recreate it.'
        curl -fsS --noproxy '*' --max-time 20 -b "$temp/cookies" -c "$temp/cookies" \
            -H "X-CSRF-Token: $csrf_token" -H 'Content-Type: application/json' \
            --data-binary "@$state_dir/inbound.json" "http://127.0.0.1:4772/$base/panel/api/inbounds/add" > "$temp/add.json"
        python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("success") is True else "Panel rejected Reality inbound")' "$temp/add.json"
        curl -fsS --noproxy '*' --max-time 15 -b "$temp/cookies" \
            "http://127.0.0.1:4772/$base/panel/api/inbounds/list" > "$temp/list.json"
    fi
    read_inbound "$temp/list.json" "$cover" "$client_id" "$temp/verified.json" "$state_dir/inbound.json"
    inbound_done=1
    save_state
}

# Reuse the last saved plaintext token instead of rotating it on every report.
ensure_node_token() {
    api_token=''
    if [[ -f "$state_dir/api-token-output" ]]; then
        api_token=$(awk '/^apiToken: / {sub(/^apiToken: /, ""); token=$0} END {print token}' "$state_dir/api-token-output")
    fi
    if [[ -z "$api_token" ]]; then
        [[ "$token_started" == 0 ]] || die 'Token creation was interrupted. Inspect API Tokens in the panel; refusing to rotate an unknown token.'
        token_started=1
        save_state
        /usr/local/x-ui/x-ui setting -getApiToken > "$state_dir/api-token-output"
        api_token=$(awk '/^apiToken: / {sub(/^apiToken: /, ""); token=$0} END {print token}' "$state_dir/api-token-output")
    fi
    [[ -n "$api_token" && "$api_token" != *[[:space:]]* ]] || die 'Could not obtain API token. Panel credentials are still saved.'
    if ! curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
        -H "Authorization: Bearer $api_token" \
        "http://127.0.0.1:4772/$base/panel/api/server/status" > "$temp/token-check.json"; then
        die 'Saved API token was rejected or the panel API is unavailable. No token was rotated; check API Tokens in the panel.'
    fi
    jq -e '.success == true' "$temp/token-check.json" >/dev/null \
        || die 'Panel API status check failed. No saved token was rotated.'
}

print_details() {
    printf '\n'
    ui_line 36 '  --------------------------------------------------------'
    ui_line 36 '  NEW-NODE / ДАННЫЕ ПОДКЛЮЧЕНИЯ'
    ui_line 36 '  --------------------------------------------------------'
    printf '\n'
    ui_line 36 '1. ВХОД В ПАНЕЛЬ'
    printf 'Panel: https://%s/%s/\nUsername: %s\nPassword: %s\n' "$panel" "$base" "$username" "$password"
    printf '\n'
    ui_line 36 '2. ДОБАВЛЕНИЕ НОДЫ В ОСНОВНУЮ 3X-UI'
    printf '%s\n' 'Заполните эти поля в разделе «Ноды» основной панели:'
    printf 'Name: node-%s\nScheme: https\nAddress: %s\nPort: 443\nBasePath: /%s/\n' "$panel" "$panel" "$base"
    printf 'apiToken: %s\n' "$api_token"
    printf '%s\n' 'Enable: true' 'TLS verification: verify' 'Allow private address: false' 'Inbound sync mode: all'
    printf 'Panel API URL: https://%s/%s/panel/api/\n' "$panel" "$base"
    printf '%s\n' 'Адрес вводится без https:// и пути; BasePath — с / по краям.'
    printf '%s\n' 'Для связи между панелями используется порт 443. SSH, логин и пароль панели для API не нужны.'
    printf '\n'
    ui_line 36 '3. КЛИЕНТСКОЕ ПОДКЛЮЧЕНИЕ VLESS REALITY'
    printf 'Server address: %s\nReality port: 8443\nProtocol: VLESS\nTransport: TCP\nSecurity: Reality\nFlow: xtls-rprx-vision\n' "$cover"
    printf 'SNI: %s\nTarget: %s:443\nFingerprint: firefox\n' "$cover" "$cover"
    printf 'UUID: %s\nPublic key: %s\nShort ID: %s\n' "$client_id" "$public" "$short"
    printf '\nVLESS link:\n%s\n' "$link"
    printf '\n'
    ui_line 36 '4. ПРОВЕРКИ И ХРАНЕНИЕ'
    printf '%s\n' 'Параметры подключения и API проверены локально на VPS.'
    ui_line 33 '[ ! ] Доступ с основной панели и работа реального VLESS-клиента требуют отдельной проверки.'
    printf 'Saved to: %s (root only)\n' "$result"
}

save_details() {
    local report_file
    report_file=$(mktemp "${result}.XXXXXX")
    chmod 600 "$report_file"
    print_details > "$report_file"
    mv -f -- "$report_file" "$result"
}

require_host() {
    [[ $EUID -eq 0 ]] || die 'Run as root: sudo bash install_3xui_node.sh'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "$ID" == ubuntu && ( "$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04 ) ]] || die 'Ubuntu 22.04 or 24.04 required.'
    command -v systemctl >/dev/null || die 'systemd required.'
}

install_panel() {
    if [[ "$install_done" == 0 ]]; then
        [[ "$install_started" == 0 ]] || die 'Upstream installation was interrupted; inspect /usr/local/x-ui and journalctl -u x-ui. Automatic reinstallation is unsafe.'
        [[ ! -e /usr/local/x-ui && ! -e /etc/x-ui/x-ui.db ]] || die 'Unexpected 3x-ui installation; refusing to overwrite it.'
        curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 \
            https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh -o "$temp/install.sh"
        bash -n "$temp/install.sh"
        install_started=1
        save_state
        XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none \
            XUI_USERNAME="$username" XUI_PASSWORD="$password" XUI_WEB_BASE_PATH="$base" \
            XUI_PANEL_PORT=4772 XUI_ENABLE_FAIL2BAN=true bash "$temp/install.sh"
        install_done=1
        save_state
    fi
    [[ -x /usr/local/x-ui/x-ui && -s /etc/x-ui/x-ui.db ]] || die 'Saved 3x-ui installation is missing or incomplete.'
    if [[ "$configured" == 0 ]]; then
        systemctl stop x-ui
        /usr/local/x-ui/x-ui setting -username "$username" -password "$password" \
            -port 4772 -webBasePath "/$base/" -listenIP 127.0.0.1
        configured=1
        save_state
    fi
    systemctl enable --now x-ui
    wait_for_http '3x-ui on loopback' "http://127.0.0.1:4772/$base/"
    ss -H -ltn 'sport = :4772' | grep -q '127.0.0.1:4772' || die 'Panel is not listening on loopback.'
    [[ -z "$(ss -H -ltn 'sport = :4772' | grep -v '127.0.0.1:4772')" ]] || die 'Unexpected public panel listener.'
}

print_banner() {
    ui_line 36 '  --------------------------------------------------------'
    cat <<'BANNER'

 _   _ _____ __        __      _   _  ___  ____  _____
| \ | | ____|\ \      / /     | \ | |/ _ \|  _ \| ____|
|  \| |  _|   \ \ /\ / /______|  \| | | | | | | |  _|
| |\  | |___   \ V  V /|______| |\  | |_| | |_| | |___
|_| \_|_____|   \_/\_/        |_| \_|\___/|____/|_____|

  Установка ноды 3x-ui / Ubuntu 22.04 и 24.04
  Nginx / Let's Encrypt / VLESS Reality

BANNER
    ui_line 36 '  --------------------------------------------------------'
}

main() {
    local resume=0
    case "${1:-}" in
        --resume) resume=1 ;;
        --help|-h) printf 'Usage: bash install_3xui_node.sh [--resume]\n'; return 0 ;;
        '') ;;
        *) die 'Unknown argument. Usage: bash install_3xui_node.sh [--resume]' ;;
    esac
    [[ $# -le 1 ]] || die 'Too many arguments.'
    print_banner
    begin_step 1 'Проверка VPS и параметров установки'
    require_host
    # Prevent concurrent installers, including a fresh run racing --resume.
    exec 9>/run/lock/3xui-node-install.lock
    flock -n 9 || die 'Another node installation is running.'
    state_dir=/root/.3xui-node-install
    local result=/root/3xui-node-credentials.txt
    local panel cover email username password base private='' public='' short='' client_id=''
    local install_started=0 install_done=0 configured=0 token_started=0 inbound_done=0 completed=0
    if [[ "$resume" == 1 ]]; then
        [[ -d "$state_dir" && ! -L "$state_dir" ]] || die 'No resumable state. Legacy installations cannot be adopted automatically.'
        [[ $(stat -c '%u:%a' "$state_dir") == 0:700 ]] || die 'Installation state directory must be owned by root with mode 700.'
        [[ -f "$state_dir/state.json" && ! -L "$state_dir/state.json" ]] || die 'Missing or unsafe installation state file.'
        [[ $(stat -c '%u:%a' "$state_dir/state.json") == 0:600 ]] || die 'Installation state file must be owned by root with mode 600.'
        load_state
        ui_line 36 "  [ .. ] Продолжение установки: $panel / $cover"
        printf '  Сохранённые параметры будут проверены повторно.\n'
    else
        [[ ! -e "$state_dir" && ! -L "$state_dir" ]] || die 'Installation state already exists. Use --resume.'
        [[ ! -e /usr/local/x-ui && ! -e /etc/x-ui/x-ui.db ]] || die 'Existing 3x-ui found. This script only supports a fresh VPS.'
        [[ ! -e /etc/nginx ]] || die 'Existing Nginx configuration found. Use a fresh VPS.'
        [[ ! -e "$result" && ! -L "$result" ]] || die 'Saved credentials already exist. Inspect the previous installation before continuing.'
        printf '\n  Настройка ноды\n\n'
        printf '  Укажите два разных домена без https://, порта и пути.\n'
        printf '  A-записи должны указывать на VPS; CDN-прокси отключите.\n\n'
        read -r -p '  Домен панели       > ' panel
        read -r -p '  Домен маскировки   > ' cover
        panel=${panel,,}; cover=${cover,,}
        valid_domain "$panel" && valid_domain "$cover" || die 'Invalid domain. Use ASCII/punycode names without https:// or paths.'
        [[ "$panel" != "$cover" ]] || die 'The two domains must differ.'
        read -r -p '  Email сертификатов > ' email
        [[ "$email" == *@*.* && "$email" != -* && "$email" != *[[:space:]]* ]] || die 'Invalid email.'
    fi
    export DEBIAN_FRONTEND=noninteractive
    begin_step 2 'Установка необходимых пакетов'
    apt-get update
    apt-get install -y ca-certificates curl dnsutils openssl python3 jq iproute2 util-linux
    local port
    if [[ "$resume" == 0 ]]; then
        for port in 80 443 8443 4772; do
            [[ -z "$(ss -H -ltn "sport = :$port")" ]] || die "TCP port $port is already in use."
        done
        username=$(openssl rand -hex 5)
        password=$(openssl rand -hex 12)
        base=$(openssl rand -hex 9)
        mkdir -m 700 "$state_dir"
        save_state
    fi
    # Global because EXIT cleanup may run after main has returned.
    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    [[ ! -L "$result" ]] || die 'Unexpected credentials file symlink.'
    if [[ ! -e "$result" ]]; then
        {
            printf 'Panel: https://%s/%s/\nUsername: %s\nPassword: %s\n' "$panel" "$base" "$username" "$password"
            printf 'Installation may be incomplete; use --resume after resolving the error.\n'
        } > "$result"
        chmod 600 "$result"
    fi
    credentials_file=$result
    begin_step 3 'Проверка DNS'
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
        ui_line 32 "  [ OK ] $domain указывает на VPS $ipv4"
    done
    ui_line 36 '  [ .. ] Публичный HTTP-доступ будет проверен при выпуске сертификатов.'
    begin_step 4 'Установка и настройка Nginx'
    diagnostic_service=nginx
    apt-get install -y nginx certbot fail2ban
    install -d -m 755 /var/www/3xui-acme /var/www/3xui-cover
    cat > /var/www/3xui-cover/index.html <<'COVER_HTML'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>Вход в личный кабинет</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #ececf1; background: #0e0f12; }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    body { margin: 0; min-width: 280px; min-height: 100vh; min-height: 100svh; display: flex; flex-direction: column; }
    button, input { font: inherit; }
    .site-header { padding: 28px 40px; display: flex; align-items: center; gap: 11px; }
    .brand-mark { width: 32px; height: 32px; border-radius: 10px; background: #91cbb2; display: grid; place-items: center; color: #11271e; }
    .brand-name { font-size: 15px; font-weight: 650; letter-spacing: -.3px; }
    main { flex: 1; display: grid; place-items: center; padding: 32px 20px 64px; }
    .card { width: 100%; max-width: 420px; padding: 38px; background: #191a20; border: 1px solid #30323c; border-radius: 20px; box-shadow: 0 12px 40px #00000033; }
    .entry-icon { width: 48px; height: 48px; display: grid; place-items: center; border: 1px solid #30323c; border-radius: 14px; color: #91cbb2; margin-bottom: 26px; }
    h1 { font-size: 30px; font-weight: 650; letter-spacing: -1px; line-height: 1.2; margin: 0 0 10px; }
    .intro { color: #b0b2bf; font-size: 14px; line-height: 1.6; margin: 0 0 30px; }
    .field { margin-bottom: 20px; }
    label { display: block; font-size: 13px; font-weight: 600; margin-bottom: 9px; }
    .input-wrap { position: relative; }
    input { display: block; width: 100%; height: 48px; padding: 0 14px; color: #ececf1; background: #191a20; border: 1px solid #50535f; border-radius: 9px; outline: none; transition: border-color .15s, box-shadow .15s; }
    input::placeholder { color: #a0a3b1; opacity: 1; }
    input:focus { border-color: #91cbb2; box-shadow: 0 0 0 3px #91cbb226; }
    input[aria-invalid="true"] { border-color: #ee998f; }
    #password { padding-right: 52px; }
    .show-password { position: absolute; right: 3px; top: 3px; width: 44px; height: 42px; display: grid; place-items: center; border: 0; background: transparent; border-radius: 6px; color: #b0b2bf; cursor: pointer; }
    .show-password:hover { background: #0e0f12; color: #91cbb2; }
    button:focus-visible { outline: 3px solid #91cbb2; outline-offset: 3px; }
    .error { color: #ee998f; font-size: 13px; line-height: 1.5; margin: -4px 0 18px; }
    .submit { width: 100%; min-height: 48px; display: flex; align-items: center; justify-content: center; gap: 12px; padding: 12px 18px; border: 1px solid #91cbb2; border-radius: 9px; color: #11271e; background: #91cbb2; font-weight: 600; font-size: 14px; cursor: pointer; transition: background .15s; }
    .submit:hover { background: #a4d8c1; }
    .submit:active { background: #7cb99f; }
    .access-note { margin: 26px 0 0; padding-top: 23px; border-top: 1px solid #30323c; color: #a6a8b7; font-size: 12px; line-height: 1.6; text-align: center; }
    footer { padding: 0 20px 26px; text-align: center; color: #a6a8b7; font-size: 12px; }
    svg { display: block; flex-shrink: 0; }
    @media (max-width: 480px) { .site-header { padding: 22px 24px; } main { padding: 20px 16px 40px; } .card { padding: 28px 24px; border-radius: 16px; } h1 { font-size: 28px; } }
    @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
  </style>
</head>
<body>
  <header class="site-header">
    <span class="brand-mark" aria-hidden="true">
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M5 18V6h6a6 6 0 0 1 0 12H5Z"/><path d="M9 6v12"/></svg>
    </span>
    <span class="brand-name">Личный кабинет</span>
  </header>
  <main>
    <section class="card" aria-labelledby="title">
      <div class="entry-icon" aria-hidden="true">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M4 12h11m-4-4 4 4-4 4"/></svg>
      </div>
      <h1 id="title">С возвращением</h1>
      <p class="intro">Введите свои данные, чтобы войти<br>в личный кабинет.</p>
      <form id="login-form" method="post">
        <div class="field">
          <label for="username">Логин</label>
          <input id="username" type="text" placeholder="Введите логин" autocomplete="off" autocapitalize="none" spellcheck="false" required>
        </div>
        <div class="field">
          <label for="password">Пароль</label>
          <div class="input-wrap">
            <input id="password" type="password" placeholder="Введите пароль" autocomplete="off" required>
            <button class="show-password" id="show-password" type="button" aria-label="Показать пароль" aria-pressed="false" aria-controls="password" hidden>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg>
            </button>
          </div>
        </div>
        <p id="login-error" class="error" role="alert" hidden>Неверный логин или пароль. Проверьте данные и попробуйте снова.</p>
        <button class="submit" id="submit" type="submit" disabled>
          Войти
          <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14m-5-5 5 5-5 5"/></svg>
        </button>
        <noscript><p class="error">Для входа включите JavaScript в браузере.</p></noscript>
      </form>
      <p class="access-note">Доступ только для пользователей<br>с существующей учётной записью.</p>
    </section>
  </main>
  <footer>Личный кабинет · Доступ по приглашению</footer>
  <script>
    const form = document.getElementById('login-form');
    const username = document.getElementById('username');
    const password = document.getElementById('password');
    const toggle = document.getElementById('show-password');
    const error = document.getElementById('login-error');
    // Cover page only: no authentication requests or credential storage.
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      error.hidden = false;
      for (const input of [username, password]) {
        input.setAttribute('aria-invalid', 'true');
        input.setAttribute('aria-describedby', 'login-error');
      }
      password.value = '';
      password.focus();
    });
    form.addEventListener('input', () => {
      error.hidden = true;
      for (const input of [username, password]) {
        input.removeAttribute('aria-invalid');
        input.removeAttribute('aria-describedby');
      }
    });
    toggle.addEventListener('click', () => {
      const visible = password.type === 'password';
      password.type = visible ? 'text' : 'password';
      toggle.setAttribute('aria-pressed', String(visible));
      toggle.setAttribute('aria-label', visible ? 'Скрыть пароль' : 'Показать пароль');
    });
    toggle.hidden = false;
    document.getElementById('submit').disabled = false;
  </script>
</body>
</html>
COVER_HTML
    chmod 644 /var/www/3xui-cover/index.html
    cat > "$temp/bootstrap.conf" <<EOF
server {
    listen 80;
    server_name $panel $cover;
    location /.well-known/acme-challenge/ { root /var/www/3xui-acme; }
    location / { return 404; }
}
EOF
    # Templates below are generated from the persisted identity on every run.
    render_https > "$temp/https.conf"
    local template pending
    for template in bootstrap.conf https.conf; do
        if [[ -e "$state_dir/$template" ]]; then
            cmp -s "$temp/$template" "$state_dir/$template" || die 'Saved Nginx template differs from installation state.'
        else
            pending=$(mktemp "$state_dir/${template}.XXXXXX")
            install -m 600 "$temp/$template" "$pending"
            mv -f -- "$pending" "$state_dir/$template"
        fi
    done
    if [[ ! -e /etc/nginx/sites-available/3xui-node ]] || ! cmp -s /etc/nginx/sites-available/3xui-node "$state_dir/https.conf"; then
        managed_nginx "$state_dir/bootstrap.conf"
    fi
    if [[ -L /etc/nginx/sites-enabled/3xui-node ]]; then
        [[ $(readlink /etc/nginx/sites-enabled/3xui-node) == /etc/nginx/sites-available/3xui-node ]] || die 'Unexpected Nginx site link.'
    else
        [[ ! -e /etc/nginx/sites-enabled/3xui-node ]] || die 'Unexpected Nginx enabled site.'
        ln -s /etc/nginx/sites-available/3xui-node /etc/nginx/sites-enabled/3xui-node
    fi
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 8443/tcp
    fi
    begin_step 5 "Выпуск сертификатов Let's Encrypt"
    for domain in "$panel" "$cover"; do
        certbot certonly --non-interactive --agree-tos --keep-until-expiring --email "$email" \
            --webroot -w /var/www/3xui-acme --cert-name "$domain" -d "$domain"
    done
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nnginx -t && systemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/3xui-nginx
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/3xui-nginx
    systemctl enable --now certbot.timer

    begin_step 6 'Установка и запуск 3x-ui'
    diagnostic_service=x-ui
    install_panel
    begin_step 7 'Настройка и проверка HTTPS'
    diagnostic_service=nginx
    managed_nginx "$state_dir/https.conf"
    nginx -t
    systemctl reload nginx
    wait_for_http 'Panel HTTPS' "https://$panel/$base/" --resolve "$panel:443:127.0.0.1"
    wait_for_http 'Camouflage HTTPS' "https://$cover/" --resolve "$cover:443:127.0.0.1"

    begin_step 8 'Настройка и проверка VLESS Reality'
    diagnostic_service=x-ui
    local xray keys link i
    xray=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' -print -quit)
    [[ -n "$xray" && -x "$xray" ]] || die 'Xray binary not found.'
    if [[ -z "$private" ]]; then
        keys=$("$xray" x25519)
        private=$(printf '%s\n' "$keys" | awk -F': *' '/^Private[Kk]ey:|^Private key:/ {print $2}')
        public=$(printf '%s\n' "$keys" | awk -F': *' '/^Public[Kk]ey:|^Public key:|^Password( \(PublicKey\))?:/ {print $2}')
        short=$(openssl rand -hex 8)
        client_id=$(cat /proc/sys/kernel/random/uuid)
        # Validate all generated values before saving any identity or calling the API.
        make_payload "$cover" "$private" "$public" "$short" "$client_id" "$temp/inbound.json" >/dev/null
        save_state
    fi
    link=$(make_payload "$cover" "$private" "$public" "$short" "$client_id" "$temp/inbound.json")
    mv -f -- "$temp/inbound.json" "$state_dir/inbound.json"
    panel_login "http://127.0.0.1:4772/$base" "$username" "$password" "$temp/cookies" > "$temp/login.json"
    jq -e '.success == true' "$temp/login.json" >/dev/null || die 'Panel login failed.'
    reconcile_inbound
    for ((i=0; i<20; i++)); do
        if [[ -n "$(ss -H -ltn 'sport = :8443')" ]]; then break; fi
        sleep 1
    done
    [[ -n "$(ss -H -ltn 'sport = :8443')" ]] || die 'Xray has not opened port 8443. Check journalctl -u x-ui.'
    begin_step 9 'Запуск Fail2ban'
    diagnostic_service=fail2ban
    systemctl enable --now fail2ban
    begin_step 10 'Проверка API и сохранение реквизитов'
    diagnostic_service=x-ui
    local api_token
    ensure_node_token
    save_details
    # shellcheck disable=SC2034 # Serialized indirectly through state_fields.
    completed=1
    save_state
    ui_line 32 "  [ OK ] $stage"
    printf '\n'
    ui_line 32 '  [ OK ] Установка NEW-NODE завершена'
    print_details
    ui_line 33 '  [ ! ] Не публикуйте пароль, API-токен и VLESS-ссылку.'

    rm -rf -- "$temp"
    trap - EXIT
}

render_https() {
    cat <<EOF
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
