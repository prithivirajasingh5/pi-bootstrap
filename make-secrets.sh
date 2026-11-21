#!/usr/bin/env bash
# =============================================================================
# make-secrets.sh — create secrets.age, the passphrase-encrypted bundle bootstrap.sh uses
#
# Run in a real terminal (laptop, or the Pi over SSH), from this repo:
#   ./make-secrets.sh [path-to-unlocked-docker-repo]
#
# It bundles three secrets and encrypts them with a passphrase only you see:
#   github-token     a GitHub token for gh: a new Pi signs in to GitHub with it, no code to approve.
#                    Create a classic token (prefilled link below): scopes repo, workflow, read:org.
#   gitcrypt.key     the docker repo's git-crypt key (`git-crypt export-key`)
#   gpg-secret.asc   your GPG secret key: a new Pi unlocks every repo, like the laptop.
# The token and the GPG key have no protection of their own, so the bundle passphrase is all that
# guards them (and the file is public): let age generate a long one and keep it in Google Drive.
#
# Re-running makes a new bundle; revoke the previous token on GitHub afterwards if you replaced it.
# =============================================================================
set -Eeuo pipefail

REPO="prithivirajasingh5/docker"
DOCKER_DIR="${1:-$HOME/claude/docker}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.age"
GPG_KEY=36495943FBDA0DF535B6FBA2E9A09FE2F41B0BFC
TOKEN_URL="https://github.com/settings/tokens/new?description=pi-bootstrap&scopes=repo,workflow,read:org"
OLD_KEY_PREFIX="opi shared (pi-bootstrap"   # deploy keys from bundles made before 2026-11-20

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
[ -d "$DOCKER_DIR/.git" ] || die "$DOCKER_DIR is not the docker repo checkout (pass its path as the first argument)"
[ "$(head -c 9 "$DOCKER_DIR/.env" | tail -c 8)" != "GITCRYPT" ] || die "$DOCKER_DIR is locked; run git-crypt unlock there first"
gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1 || die "your GPG secret key $GPG_KEY is not on this machine"
ok "age $(age --version), $DOCKER_DIR unlocked, GPG key present"

step "1/4  GitHub token for new Pis"
info "Create a classic token (it works from the phone too):"
info "  $TOKEN_URL"
info "  Note: pi-bootstrap. Expiration: your choice (No expiration = never renew; or a year + a reminder)."
info "  Scopes are preselected: repo, workflow, read:org. Generate, copy it, paste it here."
read -r -s -p "    GitHub token (hidden): " token </dev/tty; echo
[ -n "$token" ] || die "no token given"
printf '%s' "$token" > "$TMP/github-token"; unset token
# The header comes from a file (-H @file), so the token never appears in the process list.
printf 'Authorization: Bearer %s\n' "$(cat "$TMP/github-token")" > "$TMP/auth-header"
headers="$(curl -sS -o /dev/null -D - -H @"$TMP/auth-header" https://api.github.com/user | tr -d '\r')"
status="$(awk 'NR==1{print $2}' <<< "$headers")"
[ "$status" = 200 ] || die "GitHub refused the token (HTTP $status)"
scopes="$(awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}' <<< "$headers")"
for need in repo workflow; do
  [[ ", $scopes," == *", $need,"* ]] || die "the token lacks the '$need' scope (has: ${scopes:-none}; use a classic token from the link)"
done
login="$(curl -sS -H @"$TMP/auth-header" https://api.github.com/user | python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])')"
shred -u "$TMP/auth-header"
ok "token works for $login (scopes: $scopes)"

step "2/4  Export the git-crypt and GPG keys"
(cd "$DOCKER_DIR" && git-crypt export-key "$TMP/gitcrypt.key")
[ "$(head -c 9 "$TMP/gitcrypt.key" | tail -c 8)" = "GITCRYPT" ] || die "exported git-crypt key looks wrong"
gpg --batch --export-secret-keys --armor "$GPG_KEY" > "$TMP/gpg-secret.asc" 2>/dev/null
grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$TMP/gpg-secret.asc" || die "could not export GPG secret key $GPG_KEY"
ok "git-crypt key ($(stat -c %s "$TMP/gitcrypt.key") bytes) and GPG key ready"

step "3/4  Encrypt them with your passphrase"
info "age will ask for a passphrase. Recommended: just press Enter and let age generate a strong one."
info "COPY THE PASSPHRASE INTO GOOGLE DRIVE -> CONFIDENTIAL NOW. Without it the bundle is useless."
tar -C "$TMP" -cf "$TMP/bundle.tar" github-token gitcrypt.key gpg-secret.asc
age -p -o "$TMP/secrets.age" "$TMP/bundle.tar"
ok "encrypted ($(stat -c %s "$TMP/secrets.age") bytes)"
info "Prove you saved it: decrypt once with the passphrase from Drive."
for attempt in 1 2 3; do
  if age -d -o "$TMP/check.tar" "$TMP/secrets.age" && cmp -s "$TMP/check.tar" "$TMP/bundle.tar"; then
    ok "round trip OK — the saved passphrase opens the bundle"; break
  fi
  [ "$attempt" -lt 3 ] || die "could not decrypt with the passphrase you entered; secrets.age was not written"
  info "that did not work, try again ($attempt/3)"
done

step "4/4  Write secrets.age"
cp "$TMP/secrets.age" "$OUT"
ok "wrote $OUT"
# Bundles before 2026-11-20 shipped a shared deploy key; the token replaces it.
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  old_ids="$(gh repo deploy-key list -R "$REPO" | awk -F'\t' -v p="$OLD_KEY_PREFIX" 'index($2,p)==1 {print $1"\t"$2}')" || true
  if [ -n "$old_ids" ]; then
    info "shared deploy keys from older bundles are still on $REPO (the token replaces them):"
    printf '%s\n' "$old_ids" | sed 's/^/        /'
    read -r -p "    Delete them from GitHub now? [y/N] " a
    if [[ "${a,,}" =~ ^(y|yes)$ ]]; then
      printf '%s\n' "$old_ids" | cut -f1 | while read -r id; do gh repo deploy-key delete "$id" -R "$REPO" >/dev/null && ok "deleted $id"; done
    fi
  fi
fi

step "Done"
info "Next: commit and push secrets.age (it is encrypted), e.g.:"
info "    git add secrets.age && git commit -m 'Update secrets bundle' && git push"
info "Then test from the Pi any time with:  bootstrap.sh --check-secrets"
info "If this replaced an older token, revoke that one: https://github.com/settings/tokens"
