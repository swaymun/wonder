#!/bin/bash
# Copy this Mac's Developer ID Application identity into another Mac's dedicated
# wonder-signing keychain so scripts/release-mac.sh can run there. Run it yourself,
# after scripts/setup-remote-signing.sh:
#   scripts/setup-remote-developer-id.sh mac-mini
# macOS asks once to allow exporting the login Keychain's identities.
set -euo pipefail

host=${1:?usage: scripts/setup-remote-developer-id.sh SSH_HOST}
openssl=$(command -v /opt/homebrew/bin/openssl || command -v openssl)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
export P12_PASSWORD=$(openssl rand -hex 24)

# security can only export every identity; keep just the Developer ID one.
security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$work/all.p12"
"$openssl" pkcs12 -in "$work/all.p12" -nodes -legacy -passin env:P12_PASSWORD -out "$work/all.pem"
python3 - "$work" <<'EOF'
import re, sys
work = sys.argv[1]
blocks = re.findall(r"(Bag Attributes.*?-----END [A-Z ]+-----)", open(f"{work}/all.pem").read(), re.S)
def key_id(block):
    found = re.search(r"localKeyID: ([0-9A-F ]+)", block)
    return found and found.group(1).strip()
certs = [b for b in blocks if "BEGIN CERTIFICATE" in b and "Developer ID Application" in b.split("-----BEGIN")[0]]
if len(certs) != 1:
    sys.exit(f"expected one Developer ID Application certificate, found {len(certs)}")
keys = [b for b in blocks if "PRIVATE KEY" in b and key_id(b) == key_id(certs[0])]
if len(keys) != 1:
    sys.exit("could not find the Developer ID private key")
open(f"{work}/cert.pem", "w").write(certs[0][certs[0].index("-----BEGIN"):] + "\n")
open(f"{work}/key.pem", "w").write(keys[0][keys[0].index("-----BEGIN"):] + "\n")
EOF
"$openssl" pkcs12 -export -legacy -in "$work/cert.pem" -inkey "$work/key.pem" -passout env:P12_PASSWORD \
  -name "Developer ID Application" -out "$work/developer-id.p12"
rm -f "$work/all.p12" "$work/all.pem" "$work/key.pem"

scp -q "$work/developer-id.p12" "$host:/tmp/wonder-developer-id.p12"
# The p12 password travels on stdin; the keychain password is already on the host.
printf '%s\n' "$P12_PASSWORD" | ssh "$host" 'umask 077; python3 -c "
import os, subprocess, sys
p12_password = sys.stdin.readline().strip()
env = dict(line.strip().split(\"=\", 1) for line in open(os.path.expanduser(\"~/.config/wonder/signing.env\")) if \"=\" in line)
keychain = os.path.expanduser(\"~/Library/Keychains/wonder-signing.keychain-db\")
password = env[\"MATCH_KEYCHAIN_PASSWORD\"]
run = lambda *a: subprocess.run(list(a), check=True, stdout=subprocess.DEVNULL)
run(\"security\", \"unlock-keychain\", \"-p\", password, keychain)
run(\"security\", \"import\", \"/tmp/wonder-developer-id.p12\", \"-k\", keychain, \"-P\", p12_password, \"-T\", \"/usr/bin/codesign\")
run(\"security\", \"set-key-partition-list\", \"-S\", \"apple-tool:,apple:,codesign:\", \"-s\", \"-k\", password, keychain)
run(\"security\", \"lock-keychain\", keychain)
"; rm -f /tmp/wonder-developer-id.p12; security find-identity -v -p codesigning ~/Library/Keychains/wonder-signing.keychain-db | grep "Developer ID Application"'

echo "Developer ID Application identity installed on $host."
