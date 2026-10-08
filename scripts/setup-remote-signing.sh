#!/bin/bash
# Prepare another Mac to run the Wonder TestFlight lane over SSH. Run it yourself:
#   scripts/setup-remote-signing.sh mac-mini
# Copies the App Store Connect API key and the two fastlane secrets from this
# Mac's login Keychain without printing them, and creates the remote Match keychain.
set -euo pipefail

host=${1:?usage: scripts/setup-remote-signing.sh SSH_HOST}
config="$HOME/.config/wonder/app-store-connect/upload.json"
key=$(python3 -c 'import json, os, sys; print(os.path.expanduser(json.load(open(sys.argv[1]))["privateKeyPath"]))' "$config")
key_name=$(basename "$key")

match_password=$(security find-generic-password -s wonder-fastlane-match -w)
keychain_password=$(security find-generic-password -s wonder-fastlane-keychain -w)

ssh "$host" 'umask 077; mkdir -p ~/.config/wonder/app-store-connect'
scp -q "$key" "$host:.config/wonder/app-store-connect/$key_name"
python3 - "$config" "$key_name" <<'EOF' | ssh "$host" 'umask 077; cat > ~/.config/wonder/app-store-connect/upload.json'
import json, sys
config = json.load(open(sys.argv[1]))
config["privateKeyPath"] = "~/.config/wonder/app-store-connect/" + sys.argv[2]
print(json.dumps(config, indent=2))
EOF

# Secrets travel on stdin, never on a command line.
printf '%s\n%s\n' "$match_password" "$keychain_password" | ssh "$host" 'umask 077; python3 -c "
import os, subprocess, sys
match, keychain = sys.stdin.read().splitlines()[:2]
home = os.path.expanduser(\"~\")
with open(home + \"/.config/wonder/signing.env\", \"w\") as env:
    env.write(\"MATCH_PASSWORD=\" + match + \"\\n\" + \"MATCH_KEYCHAIN_PASSWORD=\" + keychain + \"\\n\")
path = home + \"/Library/Keychains/wonder-signing.keychain-db\"
if not os.path.exists(path):
    subprocess.run([\"security\", \"create-keychain\", \"-p\", keychain, path], check=True)
    subprocess.run([\"security\", \"set-keychain-settings\", \"-lut\", \"3600\", path], check=True)
"; chmod 600 ~/.config/wonder/app-store-connect/* ~/.config/wonder/signing.env'

# Read-only deploy key so the remote Mac can clone only the Match repository.
ssh "$host" '[ -f ~/.ssh/wonder-signing-deploy ] || ssh-keygen -q -t ed25519 -N "" -C "wonder-signing read-only ($(hostname -s))" -f ~/.ssh/wonder-signing-deploy
grep -q "Host github.com-wonder-signing" ~/.ssh/config 2>/dev/null || printf "\nHost github.com-wonder-signing\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/wonder-signing-deploy\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n" >> ~/.ssh/config
git config --global url."git@github.com-wonder-signing:swaymun/wonder-signing.git".insteadOf https://github.com/swaymun/wonder-signing.git'
public_key=$(ssh "$host" 'cat ~/.ssh/wonder-signing-deploy.pub')
if ! gh repo deploy-key list --repo swaymun/wonder-signing | grep -qF "$host fastlane (read-only)"; then
  key_file=$(mktemp)
  echo "$public_key" > "$key_file"
  gh repo deploy-key add "$key_file" --repo swaymun/wonder-signing --title "$host fastlane (read-only)"
  rm -f "$key_file"
fi
ssh "$host" 'git ls-remote https://github.com/swaymun/wonder-signing.git HEAD >/dev/null' && echo "Match repository reachable from $host."

echo "Prepared $host: API key, upload.json, signing.env, wonder-signing keychain and Match deploy key."
