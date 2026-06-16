#!/usr/bin/env bash
# install.sh — VPS bootstrap for the autopilot system.
# Idempotent: safe to run multiple times.
# Reads config from .env in the same directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
REPOS_FILE="$SCRIPT_DIR/repos.txt"

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARN: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
ok()   { printf '[install]  ✓ %s\n' "$*"; }
skip() { printf '[install]  · %s (already present)\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

run_as_root() {
	[[ $EUID -eq 0 ]] && "$@" || sudo "$@"
}

# ─── load .env ───────────────────────────────────────────────────────────────

load_env() {
	[[ -f "$ENV_FILE" ]] || die ".env not found. Copy .env.example to .env and fill it in."
	# shellcheck source=/dev/null
	set -a; source "$ENV_FILE"; set +a
	log "Loaded config from $ENV_FILE"
}

# ─── OS detection ────────────────────────────────────────────────────────────

detect_family() {
	if [[ -f /etc/os-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
		case "${ID:-}" in
			ubuntu|debian|pop|linuxmint|kali) printf 'debian' ;;
			rhel|centos|fedora|rocky|almalinux) printf 'rhel' ;;
			arch|manjaro) printf 'arch' ;;
			*) printf 'unknown' ;;
		esac
	elif [[ "$(uname)" == "Darwin" ]]; then
		printf 'macos'
	else
		printf 'unknown'
	fi
}

FAMILY="$(detect_family)"

pkg_update() {
	case "$FAMILY" in
		debian) run_as_root apt-get update -qq ;;
		rhel)   run_as_root dnf makecache -q 2>/dev/null || run_as_root yum makecache -q ;;
		arch)   run_as_root pacman -Sy --noconfirm ;;
		macos)  has brew || die "Homebrew required. Install from https://brew.sh" ;;
	esac
}

pkg_install() {
	case "$FAMILY" in
		debian) run_as_root apt-get install -y -qq "$@" ;;
		rhel)   run_as_root dnf install -y -q "$@" 2>/dev/null || run_as_root yum install -y -q "$@" ;;
		arch)   run_as_root pacman -S --noconfirm --needed "$@" ;;
		macos)  brew install "$@" ;;
		*)      die "Unsupported OS. Install manually: $*" ;;
	esac
}

# ─── tool installers ─────────────────────────────────────────────────────────

install_git() {
	has git && { skip "git $(git --version | awk '{print $3}')"; return; }
	log "Installing git..."
	pkg_install git
	ok "git installed"
}

install_curl() {
	has curl && { skip "curl"; return; }
	pkg_install curl
	ok "curl installed"
}

install_node() {
	if has node; then
		local major
		major="$(node --version | cut -c2- | cut -d. -f1)"
		[[ "$major" -ge 18 ]] && { skip "node $(node --version)"; return; }
		warn "node $(node --version) too old — upgrading via NodeSource..."
	fi
	log "Installing Node.js LTS..."
	case "$FAMILY" in
		debian)
			curl -fsSL https://deb.nodesource.com/setup_lts.x | run_as_root bash -
			pkg_install nodejs
			;;
		rhel)
			curl -fsSL https://rpm.nodesource.com/setup_lts.x | run_as_root bash -
			pkg_install nodejs
			;;
		arch)   pkg_install nodejs npm ;;
		macos)  brew install node ;;
		*)      die "Install Node.js >=18 manually then re-run." ;;
	esac
	ok "node $(node --version) installed"
}

install_gh() {
	has gh && { skip "gh $(gh --version | head -1 | awk '{print $3}')"; return; }
	log "Installing GitHub CLI..."
	case "$FAMILY" in
		debian)
			curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
				| run_as_root dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
			run_as_root chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
			echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
				| run_as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
			run_as_root apt-get update -qq
			pkg_install gh
			;;
		rhel)
			run_as_root dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
				|| run_as_root yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
			pkg_install gh
			;;
		arch)   pkg_install github-cli ;;
		macos)  brew install gh ;;
		*)      die "Install gh manually from https://cli.github.com" ;;
	esac
	ok "gh $(gh --version | head -1 | awk '{print $3}') installed"
}

install_claude() {
	has claude && { skip "claude $(claude --version 2>/dev/null | head -1 || echo '')"; return; }
	log "Installing Claude Code CLI..."
	has npm || die "npm required. Ensure Node.js is installed first."
	run_as_root npm install -g @anthropic-ai/claude-code --quiet
	ok "claude CLI installed"
}

install_codex() {
	has codex && { skip "codex $(codex --version 2>/dev/null | head -1 || echo '')"; return; }
	log "Installing Codex CLI..."
	has npm || die "npm required. Ensure Node.js is installed first."
	run_as_root npm install -g @openai/codex --quiet
	ok "codex CLI installed"
}

# ─── auth ────────────────────────────────────────────────────────────────────

auth_gh() {
	log "Checking GitHub CLI auth..."
	if [[ -n "${GH_TOKEN:-}" ]]; then
		echo "$GH_TOKEN" | gh auth login --with-token 2>/dev/null || true
	fi
	if gh auth status >/dev/null 2>&1; then
		local user
		user="$(gh api user --jq '.login' 2>/dev/null || echo 'unknown')"
		ok "gh authenticated as $user"
	else
		warn "gh is not authenticated."
		log "Run: gh auth login"
		log "Or set GH_TOKEN in .env"
	fi
}

auth_claude() {
	log "Checking Claude CLI auth..."
	if claude auth status >/dev/null 2>&1; then
		ok "claude already authenticated"
		return
	fi
	log "Starting claude login flow..."
	claude auth login
	ok "claude login complete"
}

auth_codex() {
	log "Checking Codex CLI auth..."
	if codex login status >/dev/null 2>&1; then
		ok "codex already authenticated"
		return
	fi

	log "Starting Codex login flow..."
	codex login --device-auth
	ok "codex login complete"
}

# ─── repo setup (idempotent) ─────────────────────────────────────────────────

load_repo_list() {
	local repos=()

	# From .env variable
	if [[ -n "${AUTOPILOT_REPOS:-}" ]]; then
		read -ra repos <<< "$AUTOPILOT_REPOS"
	fi

	# From repos.txt
	if [[ -f "$REPOS_FILE" ]]; then
		while IFS= read -r line; do
			line="$(printf '%s' "$line" | tr -d '[:space:]')"
			[[ -z "$line" || "$line" == \#* ]] && continue
			repos+=("$line")
		done < "$REPOS_FILE"
	fi

	# Deduplicate
	printf '%s\n' "${repos[@]}" | sort -u
}

clone_repos() {
	local repos_dir="${REPOS_DIR:-$SCRIPT_DIR/repos}"
	mkdir -p "$repos_dir"

	mapfile -t repos < <(load_repo_list)

	if [[ ${#repos[@]} -eq 0 ]]; then
		warn "No repos defined. Add them to repos.txt or AUTOPILOT_REPOS in .env"
		return
	fi

	for repo in "${repos[@]}"; do
		local name
		name="$(basename "$repo")"
		local dest="$repos_dir/$name"

		if [[ -d "$dest/.git" ]]; then
			log "Updating $repo..."
			git -C "$dest" fetch --all -q
			skip "$repo (already cloned at $dest)"
		else
			log "Cloning $repo into $dest..."
			gh repo clone "$repo" "$dest" -- --quiet
			ok "Cloned $repo"
		fi

		# Ensure autopilot.sh is accessible and executable
		local ap="$SCRIPT_DIR/autopilot.sh"
		[[ -f "$ap" ]] && chmod +x "$ap"
	done
}

# ─── systemd service ─────────────────────────────────────────────────────────

install_systemd_service() {
	has systemctl || { warn "systemd not available — skipping service setup."; return; }

	local poll="${POLL_INTERVAL_MINUTES:-10}"
	local runner="$SCRIPT_DIR/runner.sh"
	local log_dir="${LOG_DIR:-$SCRIPT_DIR/logs}"
	local service_name="autopilot"
	local run_service_name="${service_name}-run"
	local systemctl_bin
	systemctl_bin="$(command -v systemctl)"

	mkdir -p "$log_dir"
	chmod +x "$runner" 2>/dev/null || true

	# launcher service: returns immediately after asking systemd to start the
	# tracked runner service in the background.
	run_as_root tee /etc/systemd/system/${service_name}.service >/dev/null <<EOF
[Unit]
Description=GitHub Issue Autopilot Launcher
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$systemctl_bin start --no-block ${run_service_name}.service
EOF

	# tracked runner service: owns the actual execution lifecycle.
	run_as_root tee /etc/systemd/system/${run_service_name}.service >/dev/null <<EOF
[Unit]
Description=GitHub Issue Autopilot Runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$SCRIPT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$runner
StandardInput=null
EOF

	# systemd timer unit
	run_as_root tee /etc/systemd/system/${service_name}.timer >/dev/null <<EOF
[Unit]
Description=GitHub Issue Autopilot — every ${poll} minutes
Requires=${service_name}.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=${poll}min
Unit=${service_name}.service

[Install]
WantedBy=timers.target
EOF

	run_as_root systemctl daemon-reload
	run_as_root systemctl enable ${run_service_name}.service >/dev/null 2>&1 || true
	run_as_root systemctl enable --now ${service_name}.timer
	ok "systemd timer enabled (every ${poll} min)"
	log "Status: systemctl status ${service_name}.timer"
	log "Live run status: systemctl status ${run_service_name}.service"
}

# ─── preflight ───────────────────────────────────────────────────────────────

preflight() {
	log "Preflight check..."
	local pass=1
	for bin in git node gh claude codex; do
		if has "$bin"; then
			ok "$bin: $(command -v "$bin")"
		else
			warn "MISSING: $bin"
			pass=0
		fi
	done
	[[ "$pass" -eq 1 ]] || die "Some tools missing. Review warnings above."
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
	log "=== Autopilot installer ==="

	load_env

	log "--- System dependencies ---"
	[[ $EUID -ne 0 ]] && ! has sudo && die "Run as root or install sudo."
	pkg_update
	install_curl
	install_git
	install_node

	log "--- CLI tools ---"
	install_gh
	install_claude
	install_codex

	log "--- Auth ---"
	auth_gh
	auth_claude
	auth_codex

	log "--- Repos ---"
	clone_repos

	log "--- Service ---"
	install_systemd_service

	log "--- Preflight ---"
	preflight

	log ""
	log "=== Done ==="
	log "Logs: ${LOG_DIR:-$SCRIPT_DIR/logs}/"
	log "Repos: ${REPOS_DIR:-$SCRIPT_DIR/repos}/"
	log "Service: systemctl status autopilot.timer"
}

main "$@"
