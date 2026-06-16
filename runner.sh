#!/usr/bin/env bash
# runner.sh — Iterates all repos and runs autopilot.sh for each one.
# Invoked by the systemd timer every POLL_INTERVAL_MINUTES minutes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
REPOS_FILE="$SCRIPT_DIR/repos.txt"
AUTOPILOT="$SCRIPT_DIR/autopilot.sh"

# Load .env
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
REPOS_DIR="${REPOS_DIR:-$SCRIPT_DIR/repos}"
mkdir -p "$LOG_DIR"

RUNNER_LOG="$LOG_DIR/runner.log"
LOCK_FILE="${LOCK_FILE:-$LOG_DIR/runner.lock}"

log() { printf '[runner] [%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$RUNNER_LOG"; }

[[ -x "$AUTOPILOT" ]] || { log "ERROR: autopilot.sh not found or not executable: $AUTOPILOT"; exit 1; }
command -v flock >/dev/null 2>&1 || { log "ERROR: flock is required but was not found in PATH"; exit 1; }

# Never read from the caller's TTY. This prevents background runs from being
# stopped if a child CLI tries to access stdin.
exec </dev/null
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
	log "Another run is already active. Skipping this trigger."
	exit 0
fi

# ─── load repo list ──────────────────────────────────────────────────────────

load_repos() {
	local repos=()
	if [[ -n "${AUTOPILOT_REPOS:-}" ]]; then
		read -ra repos <<< "$AUTOPILOT_REPOS"
	fi
	if [[ -f "$REPOS_FILE" ]]; then
		while IFS= read -r line; do
			line="$(printf '%s' "$line" | tr -d '[:space:]')"
			[[ -z "$line" || "$line" == \#* ]] && continue
			repos+=("$line")
		done < "$REPOS_FILE"
	fi
	printf '%s\n' "${repos[@]}" | sort -u
}

AUTOPILOT_AGENT="${AUTOPILOT_AGENT:-claude}"

# ─── main ────────────────────────────────────────────────────────────────────

mapfile -t REPOS < <(load_repos)

if [[ ${#REPOS[@]} -eq 0 ]]; then
	log "No repos configured. Add them to repos.txt or AUTOPILOT_REPOS in .env"
	exit 0
fi

log "Starting run — ${#REPOS[@]} repo(s) | agent: ${AUTOPILOT_AGENT}"

FAILED=()

for repo in "${REPOS[@]}"; do
	repo_name="$(basename "$repo")"
	repo_dir="$REPOS_DIR/$repo_name"
	repo_log="$LOG_DIR/${repo_name}.log"

	if [[ ! -d "$repo_dir/.git" ]]; then
		log "SKIP $repo — not cloned yet. Run install.sh first."
		continue
	fi

	log "Processing $repo..."

	if "$AUTOPILOT" \
		--repo "$repo" \
		--project-root "$repo_dir" \
		--log-file "$repo_log" \
		"$@"; then
		log "OK $repo"
	else
		log "FAIL $repo (exit $?) — see $repo_log"
		FAILED+=("$repo")
	fi
done

log "Run complete. Failed: ${#FAILED[@]}"
for r in "${FAILED[@]}"; do
	log "  ✗ $r"
done

[[ ${#FAILED[@]} -gt 0 ]] && exit 1
exit 0
