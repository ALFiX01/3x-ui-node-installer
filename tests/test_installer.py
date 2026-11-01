"""Offline checks. Bash runs the real helpers; external services are fakes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        # Also works on Windows with Git Bash and a regular Python installation.
        command = '"' + sys.executable.replace('\\', '/') + '" "$@"'
        if os.name == "nt":
            command += " | sed 's/\\r$//'"
        (self.work / "python3").write_text(
            '#!/bin/bash\nset -o pipefail\n' + command + '\n',
            encoding="utf-8",
        )
        (self.work / "python3").chmod(0o755)

    def bash(self, body, ok=True, env_extra=None, installer="./install_3xui_node.sh", stdin=None):
        env = os.environ.copy()
        env["PATH"] = str(self.work) + os.pathsep + env["PATH"]
        env.update(env_extra or {})
        script = 'source "' + installer + '"\ncd "' + self.work.name + '"\n'
        script += 'export PATH="$PWD:$PATH"\nhash -r\n'
        script += "systemctl() { :; }; journalctl() { :; }\n"
        script += body if stdin is None else body.rstrip() + " <<'TEST_INPUT'\n" + stdin + "TEST_INPUT\n"
        result = subprocess.run(
            [BASH, "-c", script], cwd=ROOT, env=env,
            text=True, capture_output=True, encoding="utf-8", errors="replace", timeout=120,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def fake_vps(self):
        """Rewrite absolute paths in a test-only copy; never touch the host VPS paths."""
        source = (ROOT / "install_3xui_node.sh").read_text(encoding="utf-8")
        for prefix in ("/usr/local/x-ui", "/root", "/etc", "/var/www", "/run/lock", "/proc/sys/kernel/random"):
            source = source.replace(prefix, "./machine" + prefix)
        (self.work / "installer.sh").write_text(source, encoding="utf-8", newline="\n")
        shutil.copy(ROOT / "tests/fake_system.py", self.work / "fake_system.py")
        for directory in ("root", "run/lock", "proc/sys/kernel/random"):
            (self.work / "machine" / directory).mkdir(parents=True)
        (self.work / "machine/proc/sys/kernel/random/uuid").write_text("12345678-1234-4234-8234-123456789abc\n")
        for command in ("curl", "apt-get", "dig", "ss", "stat", "flock", "nginx", "systemctl", "certbot", "jq", "sleep", "ln", "readlink"):
            script = self.work / command
            script.write_text(f'#!/bin/bash\npython3 fake_system.py {command} "$@"\n', newline="\n")
            script.chmod(0o755)

    def run_main(self, resume=False, fault=None, ok=True):
        return self.bash(
            # Only root/OS and journal output are bypassed; all installation helpers run.
            'unset -f systemctl\nrequire_host() { :; }\nmain ' + ("--resume" if resume else "") + '\n',
            installer="./" + self.work.name + "/installer.sh",
            env_extra={"FAIL_ON": fault or ""}, ok=ok,
            stdin="panel.example.com\ncover.example.com\nadmin@example.com\n",
        )

    def test_full_install_resume_after_each_recoverable_failure(self):
        for fault in ("certificate", "download", "settings", "start-panel", "https", "add-response", "token-check"):
            with self.subTest(fault=fault):
                # Each scenario gets a separate VPS and a new shell process on retry.
                case = InstallerTests()
                case.setUp()
                try:
                    case.fake_vps()
                    failure = case.run_main(fault=fault, ok=False)
                    self.assertTrue((case.work / ("failed-" + fault)).exists(), failure.stdout + failure.stderr)
                    saved = json.loads((case.work / "machine/root/.3xui-node-install/state.json").read_text())
                    case.run_main(resume=True)
                    state_file = case.work / "machine/root/.3xui-node-install/state.json"
                    finished = json.loads(state_file.read_text())
                    self.assertEqual(finished["completed"], "1")
                    for name in ("username", "password", "base", "private", "public", "short", "client_id"):
                        if saved[name]:
                            self.assertEqual(saved[name], finished[name], name)
                    report = (case.work / "machine/root/3xui-node-credentials.txt").read_bytes()
                    case.run_main(resume=True)
                    self.assertEqual(report, (case.work / "machine/root/3xui-node-credentials.txt").read_bytes())
                    self.assertEqual(finished, json.loads(state_file.read_text()))
                    calls = (case.work / "calls.log").read_text().splitlines()
                    for prefix in ("upstream ", "keygen ", "panel-cli setting -getApiToken"):
                        self.assertEqual(sum(x.startswith(prefix) for x in calls), 1, prefix)
                    self.assertEqual(len(json.loads((case.work / "inbounds.json").read_text())), 1)
                finally:
                    case.doCleanups()

    def test_interrupted_upstream_is_not_reinstalled(self):
        self.fake_vps()
        self.run_main(fault="upstream", ok=False)
        r = self.run_main(resume=True, ok=False)
        self.assertIn("Automatic reinstallation is unsafe", r.stderr)
        self.assertEqual(sum(x.startswith("upstream ") for x in (self.work / "calls.log").read_text().splitlines()), 1)

    def test_upstream_download_uses_main_branch(self):
        self.fake_vps()
        self.run_main(fault="download", ok=False)
        calls = (self.work / "calls.log").read_text().splitlines()
        downloads = [x for x in calls if "raw.githubusercontent.com" in x]
        self.assertEqual(len(downloads), 1)
        self.assertIn("https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh", downloads[0])

    def test_unknown_token_is_not_rotated(self):
        self.fake_vps()
        self.run_main(fault="token-output", ok=False)
        r = self.run_main(resume=True, ok=False)
        self.assertIn("refusing to rotate", r.stderr)
        self.assertEqual(sum(x.startswith("panel-cli setting -getApiToken") for x in (self.work / "calls.log").read_text().splitlines()), 1)

    def test_resume_without_state_refused(self):
        self.fake_vps()
        r = self.run_main(resume=True, ok=False)
        self.assertIn("No resumable state", r.stderr)

    def test_fresh_rerun_refused(self):
        self.fake_vps()
        self.run_main(fault="certificate", ok=False)
        r = self.run_main(ok=False)
        self.assertIn("Use --resume", r.stderr)

    def test_lock_contention_stops_before_changes(self):
        self.fake_vps()
        r = self.run_main(fault="lock", ok=False)
        self.assertIn("Another node installation is running", r.stderr)
        self.assertFalse((self.work / "machine/root/.3xui-node-install").exists())
        self.assertEqual(len((self.work / "calls.log").read_text().splitlines()), 1)

    def test_resume_refuses_modified_nginx(self):
        self.fake_vps()
        self.run_main(fault="certificate", ok=False)
        config = self.work / "machine/etc/nginx/sites-available/3xui-node"
        config.write_text("administrator configuration\n")
        r = self.run_main(resume=True, ok=False)
        self.assertIn("configuration changed outside", r.stderr)
        self.assertEqual(config.read_text(), "administrator configuration\n")

    def identity(self):
        return """
state_dir=$PWD/state; [[ -d "$state_dir" ]] || mkdir -m 700 "$state_dir"
panel=panel.example.com; cover=cover.example.com; email=admin@example.com
username=0123456789; password=012345678901234567890123; base=012345678901234567
private='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
public='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
short=0123456789abcdef; client_id=12345678-1234-4234-8234-123456789abc
install_started=0; install_done=0; configured=0; token_started=0; inbound_done=0; completed=0
csrf_token=test-csrf
temp=$PWD; result=$PWD/report
"""

    def test_domain_validation(self):
        self.bash("""
for domain in example.com sub.example.com xn--e1afmkfd.xn--p1ai; do valid_domain "$domain"; done
for domain in https://example.com a..com -a.com a-.com example.com. localhost; do
    if valid_domain "$domain"; then exit 10; fi
done
""")

    def test_payload_and_link(self):
        r = self.bash(self.identity() + 'make_payload "$cover" "$private" "$public" "$short" "$client_id" payload.json\n')
        payload = json.loads((self.work / "payload.json").read_text())
        self.assertEqual(json.loads(payload["settings"])["clients"][0]["id"], "12345678-1234-4234-8234-123456789abc")
        self.assertIn("cover.example.com:8443?", r.stdout)
        self.assertEqual(json.loads(payload["streamSettings"])["realitySettings"]["privateKey"], "a" * 43)

    def test_state_roundtrip_is_data_not_shell(self):
        self.bash(self.identity() + """
email='admin+$(touch PWNED)@example.com'
save_state
password=changed; private=changed; client_id=changed; email=changed
load_state
[[ $password == 012345678901234567890123 && $private == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
[[ $client_id == 12345678-1234-4234-8234-123456789abc && ! -e PWNED ]]
""")

    def test_corrupt_state_rejected(self):
        r = self.bash(self.identity() + 'save_state\nprintf "{}" > "$state_dir/state.json"\nload_state\n', ok=False)
        self.assertIn("Invalid or unsupported installation state", r.stderr)

    def test_future_state_rejected(self):
        r = self.bash(self.identity() + "save_state\npython3 -c 'import json; p=\"state/state.json\"; d=json.load(open(p)); d[\"version\"]=99; json.dump(d,open(p,\"w\"))'\nload_state\n", ok=False)
        self.assertIn("Invalid or unsupported installation state", r.stderr)

    def test_empty_reality_identity_roundtrip(self):
        self.bash(self.identity() + """
private=''; public=''; short=''; client_id=''
save_state
private=changed
load_state
[[ -z "$private" && -z "$client_id" && $install_started == 0 ]]
""")

    def test_managed_file_refuses_foreign_configuration(self):
        r = self.bash(self.identity() + """
printf 'bootstrap\n' > "$state_dir/bootstrap.conf"
printf 'https\n' > "$state_dir/https.conf"
printf 'foreign\n' > nginx.conf
managed_nginx "$state_dir/bootstrap.conf" "$PWD/nginx.conf"
""", ok=False)
        self.assertIn("configuration", r.stderr)
        self.assertEqual((self.work / "nginx.conf").read_text(), "foreign\n")

    def test_managed_file_can_retry_transition(self):
        self.bash(self.identity() + """
printf 'bootstrap\n' > "$state_dir/bootstrap.conf"
printf 'https\n' > "$state_dir/https.conf"
managed_nginx "$state_dir/bootstrap.conf" "$PWD/nginx.conf"
managed_nginx "$state_dir/https.conf" "$PWD/nginx.conf"
managed_nginx "$state_dir/https.conf" "$PWD/nginx.conf"
cmp nginx.conf "$state_dir/https.conf"
""")

    def inbound_setup(self):
        return self.identity() + """
make_payload "$cover" "$private" "$public" "$short" "$client_id" "$state_dir/inbound.json" > "$state_dir/link"
[[ -f server.json ]] || python3 -c 'import json; json.dump({"success":True,"obj":[]},open("server.json","w"))'
curl() {
    case "${*: -1}" in
        */inbounds/list) cat server.json ;;
        */inbounds/add)
            echo add >> mutations
            python3 -c 'import json; p=json.load(open("state/inbound.json")); json.dump({"success":True,"obj":[p]},open("server.json","w"))'
            if [[ ${lose_reply:-0} == 1 ]]; then return 28; fi
            printf '{"success":true}' ;;
        *) return 99 ;;
    esac
}
"""

    def test_lost_add_response_reuses_inbound(self):
        self.bash(self.inbound_setup() + 'save_state\nlose_reply=1\nreconcile_inbound\n', ok=False)
        self.bash(self.inbound_setup() + 'load_state\nreconcile_inbound\n[[ $(wc -l < mutations) == 1 ]]\n')

    def test_changed_key_refused_without_mutation(self):
        r = self.bash(self.inbound_setup() + """
reconcile_inbound
python3 -c 'import json; p="server.json"; d=json.load(open(p)); s=json.loads(d["obj"][0]["streamSettings"]); s["realitySettings"]["privateKey"]="z"*43; d["obj"][0]["streamSettings"]=json.dumps(s); json.dump(d,open(p,"w"))'
reconcile_inbound
""", ok=False)
        self.assertIn("key", r.stderr.lower())
        self.assertEqual((self.work / "mutations").read_text(), "add\n")

    def test_deleted_verified_inbound_not_recreated(self):
        r = self.bash(self.inbound_setup() + 'inbound_done=1\nreconcile_inbound\n', ok=False)
        self.assertIn("refusing to recreate", r.stderr)
        self.assertFalse((self.work / "mutations").exists())

    def test_duplicate_inbounds_refused(self):
        r = self.bash(self.inbound_setup() + """
python3 -c 'import json; p=json.load(open("state/inbound.json")); json.dump({"success":True,"obj":[p,p]},open("server.json","w"))'
reconcile_inbound
""", ok=False)
        self.assertIn("exactly one inbound", r.stderr)
        self.assertFalse((self.work / "mutations").exists())

    def test_rejected_list_does_not_create_inbound(self):
        r = self.bash(self.inbound_setup() + """
printf '{"success":false,"obj":[]}' > server.json
reconcile_inbound
""", ok=False)
        self.assertIn("Panel rejected inbound list request", r.stderr)
        self.assertFalse((self.work / "mutations").exists())

    def test_inbound_object_settings_supported(self):
        self.bash(self.inbound_setup() + """
python3 -c 'import json; p=json.load(open("state/inbound.json")); p["settings"]=json.loads(p["settings"]); p["streamSettings"]=json.loads(p["streamSettings"]); json.dump({"success":True,"obj":[p]},open("server.json","w"))'
reconcile_inbound
[[ ! -e mutations ]]
""")

    def test_invalid_payload_key_rejected(self):
        r = self.bash(self.identity() + 'make_payload "$cover" bad "$public" "$short" "$client_id" payload.json\n', ok=False)
        self.assertIn("Invalid Xray private key", r.stderr)
        self.assertFalse((self.work / "payload.json").exists())

    def test_changed_inbound_limits_or_tcp_refused(self):
        self.bash(self.inbound_setup())
        original = json.loads((self.work / "state/inbound.json").read_text())
        for field in ("total", "expiryTime", "acceptProxyProtocol", "header"):
            with self.subTest(field=field):
                payload = json.loads(json.dumps(original))
                if field in ("total", "expiryTime"):
                    payload[field] = 1
                else:
                    stream = json.loads(payload["streamSettings"])
                    stream["tcpSettings"][field] = True if field == "acceptProxyProtocol" else {"type": "http"}
                    payload["streamSettings"] = json.dumps(stream)
                (self.work / "server.json").write_text(json.dumps({"success": True, "obj": [payload]}))
                r = self.bash(self.inbound_setup() + 'reconcile_inbound\n', ok=False)
                self.assertIn("saved configuration", r.stderr)
                self.assertFalse((self.work / "mutations").exists())

    def test_changed_reality_xver_or_vless_settings_refused(self):
        self.bash(self.inbound_setup())
        original = json.loads((self.work / "state/inbound.json").read_text())
        for field, value in (("xver", 1), ("decryption", "invalid"),
                             ("fallbacks", [{"dest": 8080}])):
            with self.subTest(field=field):
                payload = json.loads(json.dumps(original))
                if field == "xver":
                    stream = json.loads(payload["streamSettings"])
                    stream["realitySettings"][field] = value
                    payload["streamSettings"] = json.dumps(stream)
                else:
                    settings = json.loads(payload["settings"])
                    settings[field] = value
                    payload["settings"] = json.dumps(settings)
                (self.work / "server.json").write_text(json.dumps({"success": True, "obj": [payload]}))
                r = self.bash(self.inbound_setup() + 'reconcile_inbound\n', ok=False)
                self.assertIn("saved configuration", r.stderr)
                self.assertFalse((self.work / "mutations").exists())


if __name__ == "__main__":
    unittest.main()
