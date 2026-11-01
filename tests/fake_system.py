"""Stateful fake VPS used only by the offline integration tests."""
import json
import os
from pathlib import Path
import sys


ROOT = Path("machine")
command, *args = sys.argv[1:]
with open("calls.log", "a", encoding="utf-8") as log:
    log.write(command + " " + " ".join(args) + "\n")


def fail(point):
    marker = Path("failed-" + point.replace("/", "_"))
    if os.environ.get("FAIL_ON") == point and (point == "https" or not marker.exists()):
        marker.touch()
        raise SystemExit(28)


def write(path, content, executable=False):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8", newline="\n")
    if executable:
        p.chmod(0o755)


if command == "apt-get":
    fail("packages")
    if "nginx" in args:
        for path in ("etc/nginx/sites-available", "etc/nginx/sites-enabled"):
            (ROOT / path).mkdir(parents=True, exist_ok=True)
elif command == "dig":
    if "A" in args:
        print("8.8.8.8")
elif command == "ss":
    if (ROOT / "etc/x-ui/x-ui.db").exists():
        if "sport = :4772" in args:
            print("LISTEN 0 128 127.0.0.1:4772 0.0.0.0:*")
        elif "sport = :8443" in args and Path("inbounds.json").exists():
            print("LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*")
elif command == "stat":
    # Windows Git Bash does not implement Unix ownership/modes; main still checks them.
    print("0:700" if Path(args[-1]).is_dir() else "0:600")
elif command == "ln":
    # The test-only path rewrite makes the target relative; anchor it to this VPS.
    os.symlink(Path(args[-2]).absolute(), args[-1])
    Path("link-target.txt").write_text(args[-2])
elif command == "readlink":
    print(Path("link-target.txt").read_text())
elif command == "flock":
    fail("lock")
elif command == "nginx":
    fail("nginx-test")
elif command == "systemctl":
    if "x-ui" in args and "enable" in args:
        fail("start-panel")
elif command == "certbot":
    fail("certificate")
    domain = args[args.index("--cert-name") + 1]
    write(f"etc/letsencrypt/live/{domain}/fullchain.pem", "fake certificate")
    write(f"etc/letsencrypt/live/{domain}/privkey.pem", "fake private key")
elif command == "upstream":
    write("usr/local/x-ui/x-ui", '#!/bin/bash\npython3 fake_system.py panel-cli "$@"\n', True)
    write("usr/local/x-ui/bin/xray-linux-amd64", '#!/bin/bash\npython3 fake_system.py keygen "$@"\n', True)
    write("etc/x-ui/x-ui.db", "fake sqlite")
    Path("login.json").write_text(json.dumps({k: os.environ[k] for k in ("XUI_USERNAME", "XUI_PASSWORD", "XUI_WEB_BASE_PATH")}))
    fail("upstream")
elif command == "panel-cli":
    if "-getApiToken" in args:
        Path("token.txt").write_text("saved-api-token")
        fail("token-output")
        print("apiToken: saved-api-token")
    else:
        fail("settings")
elif command == "keygen":
    print("PrivateKey: " + "a" * 43)
    print("PublicKey: " + "b" * 43)
elif command == "jq":
    p = json.loads(Path(args[-1]).read_text())
    if p.get("success") is not True:
        raise SystemExit(1)
elif command == "curl":
    url = next(x for x in args if x.startswith(("http://", "https://")))
    output = None
    if url == "https://api.ipify.org":
        output = "8.8.8.8"
    elif "raw.githubusercontent.com" in url:
        fail("download")
        output = "#!/bin/bash\npython3 fake_system.py upstream\n"
    elif url.endswith("/csrf-token"):
        output = json.dumps({"success": True, "obj": "fake-csrf"})
    elif url.endswith("/login"):
        login = json.loads(Path("login.json").read_text())
        expected = ["username=" + login["XUI_USERNAME"], "password=" + login["XUI_PASSWORD"]]
        output = json.dumps({"success": all(x in args for x in expected)})
    elif url.endswith("/inbounds/list"):
        entries = json.loads(Path("inbounds.json").read_text()) if Path("inbounds.json").exists() else []
        output = json.dumps({"success": True, "obj": entries})
    elif url.endswith("/inbounds/add"):
        payload = json.loads(Path(args[args.index("--data-binary") + 1][1:]).read_text())
        entries = json.loads(Path("inbounds.json").read_text()) if Path("inbounds.json").exists() else []
        entries.append(payload)
        Path("inbounds.json").write_text(json.dumps(entries))
        fail("add-response")
        output = '{"success":true}'
    elif url.endswith("/server/status"):
        fail("token-check")
        output = json.dumps({"success": "Authorization: Bearer " + Path("token.txt").read_text() in args})
    else:
        if "--resolve" in args:
            fail("https")
        output = "OK"
    if "-o" in args:
        path = args[args.index("-o") + 1]
        if path != "/dev/null":
            Path(path).write_text(output, encoding="utf-8", newline="\n")
    else:
        print(output, end="")
elif command in ("journalctl", "sleep"):
    pass
else:
    raise SystemExit("Unexpected fake command: " + command)
