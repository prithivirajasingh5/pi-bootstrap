Create a new project. Project name: $ARGUMENTS (optional, short, lowercase, no spaces)

## Step 1 — Get and validate the project name first
If `$ARGUMENTS` is non-empty, use it as the project name. Otherwise ask only:
> "What should the project be named? (lowercase, no spaces, max 40 chars)"

Then immediately validate the name before asking anything else:
- Lowercase letters (a–z), digits (0–9), and hyphens only
- No spaces or uppercase letters
- No longer than 40 characters

If it fails, stop, tell me exactly what is wrong, and ask for a corrected name. Repeat until valid.

## Step 1b — Remaining questions
Only after the name passes validation, ask these one by one:
1. What is this project? (one sentence description)
2. What language/stack will you use?
3. Any key libraries or frameworks?

Wait for all answers before proceeding.

## Step 2 — Check the tools (this Pi has no btrfs snapshots; git and GitHub are the safety net)
`gh` must be signed in, and git-crypt needs the owner's GPG key (the secret key comes from
pi-bootstrap's secrets bundle, question 1/5; the public key alone from `opi-claude/gpg-public.asc` is
enough to create a project, but not to unlock it after a fresh clone).

!gh auth status
!gpg --list-keys 36495943FBDA0DF535B6FBA2E9A09FE2F41B0BFC

If either fails, stop and tell me: `gh` sign-in is a device code you send me (phone-first rule in
~/claude/CLAUDE.md), the key comes from re-running pi-bootstrap's claude-remote.sh.

## Step 3 — Create folder structure
!mkdir -p ~/claude/<PROJECT_NAME>/.claude/commands
!mkdir -p ~/claude/<PROJECT_NAME>/.claude/rules
!mkdir -p ~/claude/<PROJECT_NAME>/.claude/agents
!mkdir -p ~/claude/<PROJECT_NAME>/src
!mkdir -p ~/claude/<PROJECT_NAME>/tests
!mkdir -p ~/claude/<PROJECT_NAME>/docs

## Step 4 — Create .gitignore, .gitattributes and placeholder .env
`.env` is NOT ignored: git-crypt encrypts it instead (see global CLAUDE.md).
`/keys/` is root-anchored so it does not clash with `.git-crypt/keys`.

!cat > ~/claude/<PROJECT_NAME>/.gitignore << 'EOF'
.env.local
CLAUDE.local.md
node_modules/
__pycache__/
*.pyc
.DS_Store
dist/
build/
/keys/
EOF

!echo '/.env filter=git-crypt diff=git-crypt' > ~/claude/<PROJECT_NAME>/.gitattributes
!touch ~/claude/<PROJECT_NAME>/.env

## Step 5 — Write CLAUDE.md using my answers
Write ~/claude/<PROJECT_NAME>/CLAUDE.md using this template,
filling in every section with my actual answers from Step 1:

# Project: <PROJECT_NAME>

## What this is
<my one sentence description>

## Stack
<language, framework, key libraries from my answers>

## Commands
- Run: 
- Test: 
- Lint: 

## Key directories
- `src/` — 
- `tests/` — mirrors src/ structure
- `docs/` — 

## Rules
- Explain what you're about to do before doing it
- Ask before deleting files or irreversible changes
- Every new feature needs a test

## Step 6 — Init git + git-crypt, verify encryption, push
.gitattributes already exists (Step 4), so .env is encrypted from its very first commit.

!git -C ~/claude/<PROJECT_NAME> init -b main
!cd ~/claude/<PROJECT_NAME> && git-crypt init
!cd ~/claude/<PROJECT_NAME> && git-crypt add-gpg-user --trusted 36495943FBDA0DF535B6FBA2E9A09FE2F41B0BFC
!git -C ~/claude/<PROJECT_NAME> add -A
!git -C ~/claude/<PROJECT_NAME> commit -m "chore: initial project scaffold"

Safety gate — must list `.env` as encrypted before pushing:
!cd ~/claude/<PROJECT_NAME> && git-crypt status -e
If `.env` is not listed as encrypted, STOP and tell me; do not push.

Use $HOME, not ~, after `=` (zsh does not expand ~ there):
!gh repo create <PROJECT_NAME> --private --source="$HOME/claude/<PROJECT_NAME>" --push

## Step 7 — Confirm
!gh repo view <PROJECT_NAME>
Tell me the GitHub URL and confirm everything is set up.
