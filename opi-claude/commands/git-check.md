Scan all immediate subdirectories of ~/claude/ that are git repositories and report their sync state against the GitHub remote.

Also include `~/claude-backup` if it exists (on the laptop it holds the `/git-backup` repo; the Pi has none).

Skip any folder that contains a `.local-only` marker file — it is intentionally kept off GitHub. Do not list it in the table.

For each repo found:
1. Run `git fetch` to get the latest remote state
2. Check `git status` for uncommitted local changes
3. Run `git log origin/HEAD..HEAD --oneline` to find commits ahead of remote
4. Run `git log HEAD..origin/HEAD --oneline` to find commits behind remote
5. Check if the repo has a GitHub remote configured at all

Then present a concise summary table or bullet list with one of these states per repo:
- **Up to date** — nothing to do
- **Ahead** (N commits) — needs push
- **Behind** (N commits) — needs pull
- **Uncommitted changes** — list the files so nothing gets lost
- **No remote** — needs GitHub repo creation (private by default)

After the table, list every required action as a numbered list, for example:
1. Pull `claude-backup` (1 commit behind)
2. Commit + push `docker` (2 untracked files: `bin-autox.sh`, `rolling-to-base.sh`)
3. Create private GitHub repo for `new-project`

If there are no actions needed, say "All repos are in sync — nothing to do."

Do not auto-push, auto-pull, or take any action without the user confirming by number (e.g. "1", "2 3", "all").
