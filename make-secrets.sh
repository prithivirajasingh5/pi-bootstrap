#!/usr/bin/env bash
# =============================================================================
# make-secrets.sh — create secrets.age, the passphrase-encrypted bundle bootstrap.sh uses
#
# Run on the laptop, in a real terminal, from this repo:   ./make-secrets.sh [path-to-unlocked-docker-repo]
#
# It bundles two keys and encrypts them with a passphrase only you see:
#   deploy_key / deploy_key.pub  a NEW shared GitHub deploy key (read-write, docker repo only)
#   gitcrypt.key                 the docker repo's git-crypt key (`git-crypt export-key`)
# then registers the new deploy key on GitHub and shreds every plaintext copy.
#
# Safety: the encrypted file is public, so its security is the passphrase. Let age generate one
# (press Enter at its prompt) and store it in Google Drive -> Confidential before continuing.
# Re-running rotates: new deploy key + new bundle; it offers to delete the previous shared key.
# =============================================================================
set -Eeuo pipefail

REPO="prithivirajasingh5/docker"
DOCKER_DIR="${1:-$HOME/claude/docker}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.age"
TITLE_PREFIX="opi shared (pi-bootstrap"

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"; chmod 700 "$TMP"
cleanup() { find "$TMP" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

step "Checks"
[ -t 0 ] || die "run this in an interactive terminal (age asks for the passphrase there)"
command -v age >/dev/null || die "age is not installed: sudo apt install age"
command -v git-crypt >/dev/null || die "git-crypt is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
[ -d "$DOCKER_DIR/.git" ] || die "$DOCKER_DIR is not the docker repo checkout (pass its path as the first argument)"
[ "$(head -c 9 "$DOCKER_DIR/.env" | tail -c 8)" != "GITCRYPT" ] || die "$DOCKER_DIR is locked; run git-crypt unlock there first"
ok "age $(age --version), gh logged in, $DOCKER_DIR unlocked"

step "1/4  Generate the shared deploy key and export the git-crypt key"
ssh-keygen -q -t ed25519 -N "" -C "opi shared deploy key (pi-bootstrap $(date +%F))" -f "$TMP/deploy_key"
(cd "$DOCKER_DIR" && git-crypt export-key "$TMP/gitcrypt.key")
[ "$(head -c 9 "$TMP/gitcrypt.key" | tail -c 8)" = "GITCRYPT" ] || die "exported git-crypt key looks wrong"
ok "deploy key $(ssh-keygen -lf "$TMP/deploy_key.pub" | awk '{print $2}') and git-crypt key ($(stat -c %s "$TMP/gitcrypt.key") bytes) ready"

step "2/4  Encrypt them with your passphrase"
info "age will ask for a passphrase. Recommended: just press Enter and let age generate a strong one."
info "COPY THE PASSPHRASE INTO GOOGLE DRIVE -> CONFIDENTIAL NOW. Without it the bundle is useless."
tar -C "$TMP" -cf "$TMP/bundle.tar" deploy_key deploy_key.pub gitcrypt.key
age -p -o "$TMP/secrets.age" "$TMP/bundle.tar"
ok "encrypted ($(stat -c %s "$TMP/secrets.age") bytes)"

step "3/4  Prove you saved it: decrypt once with the passphrase from Drive"
for attempt in 1 2 3; do
  if age -d -o "$TMP/check.tar" "$TMP/secrets.age" && cmp -s "$TMP/check.tar" "$TMP/bundle.tar"; then
    ok "round trip OK — the saved passphrase opens the bundle"; break
  fi
  [ "$attempt" -lt 3 ] || die "could not decrypt with the passphrase you entered; nothing was registered or written"
  info "that did not work, try again ($attempt/3)"
done

step "4/4  Register the deploy key on GitHub and write secrets.age"
old_ids="$(gh repo deploy-key list -R "$REPO" | awk -F'\t' -v p="$TITLE_PREFIX" 'index($2,p)==1 {print $1"\t"$2}')" || true
gh repo deploy-key add "$TMP/deploy_key.pub" --allow-write --title "$TITLE_PREFIX $(date +%F))" -R "$REPO" >/dev/null
ok "added deploy key \"$TITLE_PREFIX $(date +%F))\" (read-write) to $REPO"
cp "$TMP/secrets.age" "$OUT"
ok "wrote $OUT"
if [ -n "$old_ids" ]; then
  info "previous shared deploy key(s) found (the old secrets.age used them):"
  printf '%s\n' "$old_ids" | sed 's/^/        /'
  read -r -p "    Delete them from GitHub now? [y/N] " a
  if [[ "${a,,}" =~ ^(y|yes)$ ]]; then
    printf '%s\n' "$old_ids" | cut -f1 | while read -r id; do gh repo deploy-key delete "$id" -R "$REPO" >/dev/null && ok "deleted $id"; done
  fi
fi

step "Done"
info "Next: commit and push secrets.age (it is encrypted), e.g.:"
info "    git add secrets.age && git commit -m 'Update secrets bundle' && git push"
info "Then test from the Pi any time with:  bootstrap.sh --check-secrets"
