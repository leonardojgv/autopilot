#!/usr/bin/env bash
# autopilot.sh — Resolves one GitHub issue per repo using Claude Code CLI or Codex CLI.
# Called by runner.sh once per repository per poll cycle.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BASE_BRANCH="${DEFAULT_BASE_BRANCH:-dev}"
MAX_CLARIFICATION_ROUNDS="${MAX_CLARIFICATION_ROUNDS:-2}"
AUTOPILOT_AGENT="${AUTOPILOT_AGENT:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
CLAUDE_THINKING="${CLAUDE_THINKING:-medium}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-20}"
CODEX_BIN="${CODEX_BIN:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-medium}"
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-workspace-write}"
CODEX_BYPASS_SANDBOX="${CODEX_BYPASS_SANDBOX:-0}"
VERIFY_COMMANDS_OVERRIDE="${VERIFY_COMMANDS:-}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
STATE_FILE="${STATE_FILE:-$LOG_DIR/state.json}"
DRY_RUN=0
COMMENT_ON_SUCCESS=1
ISSUE_NUMBER=""
PR_NUMBER=""
REPO=""
BASE_BRANCH="$DEFAULT_BASE_BRANCH"
BRANCH_PREFIX=""
AGENT_MODEL_OVERRIDE=""
PROJECT_ROOT=""
LOG_FILE=""
TASK_KIND="issue"
REVIEW_FEEDBACK_UPDATED_AT=""
ISSUE_AUTHOR=""
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ─── logging ─────────────────────────────────────────────────────────────────

_log_base() {
	local level="$1"; shift
	local issue_tag=""
	[[ -n "$ISSUE_NUMBER" ]] && issue_tag=" [#$ISSUE_NUMBER]"
	local line
	line="$(printf '[%s] [%s]%s %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$issue_tag" "$*")"
	printf '%s\n' "$line" >&2
	if [[ -n "$LOG_FILE" ]]; then
		mkdir -p "$(dirname "$LOG_FILE")"
		printf '%s\n' "$line" >> "$LOG_FILE"
	fi
}

log()  { _log_base "INFO" "$*"; }
warn() { _log_base "WARN" "$*"; }
die()  { _log_base "ERROR" "$*"; exit 1; }

# ─── helpers ─────────────────────────────────────────────────────────────────

has() { command -v "$1" >/dev/null 2>&1; }

agent_name() {
	case "$AUTOPILOT_AGENT" in
		claude) printf 'Claude' ;;
		codex) printf 'Codex' ;;
		*) die "Unsupported AUTOPILOT_AGENT: $AUTOPILOT_AGENT (expected: claude or codex)" ;;
	esac
}

resolve_codex_bin() {
	if [[ -n "$CODEX_BIN" ]]; then
		[[ -x "$CODEX_BIN" ]] || die "CODEX_BIN is set but is not executable: $CODEX_BIN"
		printf '%s' "$CODEX_BIN"
		return
	fi

	if has codex; then
		command -v codex
		return
	fi

	local candidate=""
	local -a patterns=(
		"$HOME/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex"
		"$HOME/.vscode/extensions/openai.chatgpt-*/bin/*/codex"
	)

	for pattern in "${patterns[@]}"; do
		while IFS= read -r candidate; do
			[[ -x "$candidate" ]] || continue
			printf '%s' "$candidate"
			return
		done < <(compgen -G "$pattern" || true)
	done

	die "Codex CLI not found. Install it or set CODEX_BIN."
}

slugify() {
	node - "$1" <<'NODE'
const raw = String(process.argv[2] ?? '');
const slug = raw
	.normalize('NFD')
	.replace(/[\u0300-\u036f]/g, '')
	.toLowerCase()
	.replace(/[^a-z0-9]+/g, '-')
	.replace(/^-+|-+$/g, '')
	.slice(0, 48);
process.stdout.write(slug || 'issue');
NODE
}

json_field() {
	node - "$1" "$2" <<'NODE'
const fs = require('node:fs');
const [file, field] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const v = data[field];
if (typeof v === 'string') { process.stdout.write(v); process.exit(0); }
if (v == null) process.exit(0);
process.stdout.write(JSON.stringify(v));
NODE
}

extract_json_block() {
	node - "$1" <<'NODE'
const fs = require('node:fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
const matches = [...text.matchAll(/```json\s*([\s\S]*?)```/g)];
if (matches.length > 0) {
	process.stdout.write(matches[matches.length - 1][1].trim());
	process.exit(0);
}
const m = text.match(/\{[^{}]*"status"[\s\S]*?\}/);
if (m) { process.stdout.write(m[0]); process.exit(0); }
process.stderr.write('No JSON block found in agent output\n');
process.exit(1);
NODE
}

# ─── state management ────────────────────────────────────────────────────────
# State file: $LOG_DIR/state.json
# Schema: { "owner/repo#123": { state, question, asked_at, branch } }

state_key() { printf '%s#%s' "$REPO" "$ISSUE_NUMBER"; }

state_read() {
	local key="$1" field="$2"
	[[ -f "$STATE_FILE" ]] || { printf ''; return; }
	node - "$STATE_FILE" "$key" "$field" <<'NODE'
const fs = require('node:fs');
const [file, key, field] = process.argv.slice(2);
try {
	const db = JSON.parse(fs.readFileSync(file, 'utf8'));
	const entry = db[key];
	if (!entry) process.exit(0);
	const v = field ? entry[field] : JSON.stringify(entry);
	if (v != null) process.stdout.write(String(v));
} catch { process.exit(0); }
NODE
}

state_write() {
	local key="$1"; shift
	mkdir -p "$(dirname "$STATE_FILE")"
	node - "$STATE_FILE" "$key" "$@" <<'NODE'
const fs = require('node:fs');
const [file, key, ...pairs] = process.argv.slice(2);
let db = {};
try { db = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
if (!db[key]) db[key] = {};
for (let i = 0; i < pairs.length; i += 2) db[key][pairs[i]] = pairs[i + 1];
const tmp = file + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
fs.renameSync(tmp, file);
NODE
}

state_delete() {
	local key="$1"
	[[ -f "$STATE_FILE" ]] || return
	node - "$STATE_FILE" "$key" <<'NODE'
const fs = require('node:fs');
const [file, key] = process.argv.slice(2);
let db = {};
try { db = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
delete db[key];
const tmp = file + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
fs.renameSync(tmp, file);
NODE
}

mark_issue_delivered() {
	local key="$1" branch="$2" pr_url="${3:-}"
	state_write "$key" \
		state        "delivered" \
		stage        "delivered" \
		branch       "$branch" \
		pr_url       "$pr_url" \
		delivered_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

state_entries_for_repo() {
	local repo="$1"
	[[ -f "$STATE_FILE" ]] || return 0
	node - "$STATE_FILE" "$repo" <<'NODE'
const fs = require('node:fs');
const [file, repo] = process.argv.slice(2);
let db = {};
try { db = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { process.exit(0); }
for (const [key, entry] of Object.entries(db)) {
	if (!key.startsWith(`${repo}#`)) continue;
	const issueNumber = key.slice(repo.length + 1);
	const row = {
		key,
		issueNumber,
		state: entry.state ?? '',
		branch: entry.branch ?? '',
		prUrl: entry.pr_url ?? '',
		reviewFeedbackHandledAt: entry.review_feedback_handled_at ?? '',
	};
	// tab-separated for bash consumption
	process.stdout.write([
		row.key,
		row.issueNumber,
		row.state,
		row.branch,
		row.prUrl,
		row.reviewFeedbackHandledAt,
	].join('\t') + '\n');
}
NODE
}

# ─── git helpers ─────────────────────────────────────────────────────────────

worktree_is_clean() { [[ -z "$(git -C "$PROJECT_ROOT" status --short)" ]]; }
current_branch() { git -C "$PROJECT_ROOT" branch --show-current; }
current_head() { git -C "$PROJECT_ROOT" rev-parse HEAD; }

branch_has_remote() {
	local branch="$1"
	git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

branch_has_upstream() {
	git -C "$PROJECT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1
}

branch_has_unpushed_commits() {
	local branch="$1"
	local count=0

	if branch_has_upstream; then
		count="$(git -C "$PROJECT_ROOT" rev-list --count '@{upstream}..HEAD')"
	elif branch_has_remote "$branch"; then
		count="$(git -C "$PROJECT_ROOT" rev-list --count "origin/$branch..HEAD")"
	else
		count="$(git -C "$PROJECT_ROOT" rev-list --count "origin/$BASE_BRANCH..HEAD")"
	fi

	[[ "$count" -gt 0 ]]
}

branch_has_commits_against_base() {
	local count=0
	count="$(git -C "$PROJECT_ROOT" rev-list --count "origin/$BASE_BRANCH..HEAD")"
	[[ "$count" -gt 0 ]]
}

ensure_git_identity() {
	local name email

	name="$(git -C "$PROJECT_ROOT" config user.name || true)"
	email="$(git -C "$PROJECT_ROOT" config user.email || true)"

	if [[ -n "$name" && -n "$email" ]]; then
		return
	fi

	name="${GIT_USER_NAME:-Autopilot}"
	email="${GIT_USER_EMAIL:-autopilot@$(hostname -f 2>/dev/null || hostname)}"

	git -C "$PROJECT_ROOT" config user.name "$name"
	git -C "$PROJECT_ROOT" config user.email "$email"
	log "Configured git identity for $PROJECT_ROOT as $name <$email>"
}

ensure_issue_worktree_ready() {
	local branch="$1"

	if worktree_is_clean; then
		prepare_branch "$branch"
		return
	fi

	local current
	current="$(current_branch)"

	if [[ "$current" == "$branch" ]]; then
		log "Resuming existing dirty worktree on branch $branch"
		return
	fi

	die "Worktree is dirty on branch ${current:-<detached>}. Resolve uncommitted changes before running."
}

prepare_branch() {
	local branch="$1"
	if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
		git -C "$PROJECT_ROOT" switch "$branch"
		return
	fi
	if git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
		git -C "$PROJECT_ROOT" fetch origin "$branch" -q
		git -C "$PROJECT_ROOT" switch --track -c "$branch" "origin/$branch"
		return
	fi
	git -C "$PROJECT_ROOT" fetch origin "$BASE_BRANCH" -q
	git -C "$PROJECT_ROOT" switch -c "$branch" "origin/$BASE_BRANCH"
}

cache_resolution_result() {
	local key="$1" result_file="$2" branch="$3"

	state_write "$key" \
		stage                "resolved" \
		branch               "$branch" \
		commit_message       "$(json_field "$result_file" commit_message)" \
		pr_title             "$(json_field "$result_file" pr_title)" \
		pr_body              "$(json_field "$result_file" pr_body)" \
		issue_comment        "$(json_field "$result_file" issue_comment)" \
		verification_summary "$(json_field "$result_file" verification_summary)"
}

# ─── github helpers ──────────────────────────────────────────────────────────

detect_repo() {
	[[ -n "$REPO" ]] && { printf '%s' "$REPO"; return; }
	gh repo view --json nameWithOwner --jq '.nameWithOwner'
}

# Pick the oldest open issue assigned to the authenticated gh user
# that is NOT currently awaiting clarification and was not already delivered.
pick_issue() {
	local gh_user
	gh_user="$(gh api user --jq '.login')"

	local candidates
	candidates="$(gh api "repos/$REPO/issues?state=open&assignee=${gh_user}&sort=created&direction=asc&per_page=50" \
		--jq '[.[] | select(has("pull_request") | not) | .number | tostring]')"

	log "Filtering issues assigned to @${gh_user}..."

	node - "$candidates" "$STATE_FILE" <<'NODE'
const candidates = JSON.parse(process.argv[2]);
let db = {};
try { db = JSON.parse(require('node:fs').readFileSync(process.argv[3], 'utf8')); } catch {}

const repo = process.env.REPO;
for (const num of candidates) {
	const key = `${repo}#${num}`;
	const entry = db[key];
	if (!entry) {
		process.stdout.write(num);
		process.exit(0);
	}
	if (entry.state !== 'awaiting_clarification' && entry.state !== 'delivered') {
		process.stdout.write(num);
		process.exit(0);
	}
}
process.exit(0); // all awaiting or none assigned — nothing to pick
NODE
}

fetch_issue_json() {
	gh issue view "$1" \
		--repo "$REPO" \
		--json number,title,body,author,labels,assignees,comments,url,state \
		>"$2"
}

infer_issue_language() {
	node - "$1" <<'NODE'
const fs = require('node:fs');
const issue = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const text = `${issue.title ?? ''}\n${issue.body ?? ''}`.toLowerCase();
const spanishHints = [
	'hola', 'gracias', 'por favor', 'boton', 'botón', 'actualizar', 'cambiar',
	'quiero', 'necesito', 'issue', 'estilo', 'estilos', 'problema', 'error',
];
const hasSpanishWord = spanishHints.some((word) => text.includes(word));
const hasSpanishChars = /[áéíóúñ¿¡]/.test(text);
process.stdout.write(hasSpanishWord || hasSpanishChars ? 'es' : 'en');
NODE
}

# Returns human comments posted after asked_at (ISO string), excluding bot comments.
fetch_new_human_comments() {
	local issue_num="$1" asked_at="$2"
	gh api "repos/$REPO/issues/${issue_num}/comments" \
		--jq "[.[] | select(.created_at > \"$asked_at\" and (.user.type != \"Bot\")) | .body] | join(\"\n---\n\")"
}

post_issue_comment() {
	local issue_num="$1" body="$2"
	local tmp="$TMP_DIR/gh-comment.md"
	printf '%s\n' "$body" > "$tmp"
	gh issue comment "$issue_num" --repo "$REPO" --body-file "$tmp" >/dev/null
}

post_pr_comment() {
	local pr_num="$1" body="$2"
	local tmp="$TMP_DIR/gh-pr-comment.md"
	printf '%s\n' "$body" > "$tmp"
	gh pr comment "$pr_num" --repo "$REPO" --body-file "$tmp" >/dev/null
}

find_existing_pr_for_branch() {
	local branch="$1"
	gh pr list --repo "$REPO" --state open --head "$branch" --json url --jq '.[0].url // ""'
}

WORKING_LABEL="🤖 working"

ensure_working_label() {
	gh label create "$WORKING_LABEL" \
		--repo "$REPO" \
		--color "0075ca" \
		--description "Autopilot is working on this" \
		2>/dev/null || true
}

add_working_label() {
	local issue_num="$1"
	ensure_working_label
	gh issue edit "$issue_num" --repo "$REPO" --add-label "$WORKING_LABEL" >/dev/null 2>&1 || true
}

remove_working_label() {
	local issue_num="$1"
	gh issue edit "$issue_num" --repo "$REPO" --remove-label "$WORKING_LABEL" >/dev/null 2>&1 || true
}

build_started_pr_review_comment() {
	local language="$1"
	case "$language" in
		es) printf 'Autopilot empezó a trabajar en los comentarios de revisión de esta PR.' ;;
		*)  printf 'Autopilot started working on this pull request review feedback.' ;;
	esac
}

build_fallback_issue_comment() {
	local language="$1"
	case "$language" in
		es) printf 'Autopilot retomó cambios existentes de esta issue y abrió el PR correspondiente.' ;;
		*)  printf 'Autopilot resumed existing work for this issue and opened the corresponding PR.' ;;
	esac
}

build_fallback_pr_comment() {
	local language="$1"
	case "$language" in
		es) printf 'Autopilot aplicó cambios adicionales para responder a la revisión de esta PR.' ;;
		*)  printf 'Autopilot applied follow-up changes to address this pull request review.' ;;
	esac
}

fetch_new_human_pr_comments() {
	local pr_num="$1" asked_at="$2"
	gh api "repos/$REPO/issues/${pr_num}/comments" \
		--jq "[.[] | select(.created_at > \"$asked_at\" and (.user.type != \"Bot\")) | .body] | join(\"\n---\n\")"
}

fetch_pr_review_feedback() {
	local pr_num="$1" out="$2"
	local query_file="$TMP_DIR/pr-review-query.graphql"
	cat >"$query_file" <<'EOF'
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number
      url
      title
      state
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          comments(first: 100) {
            nodes {
              id
              body
              createdAt
              updatedAt
              author { login }
            }
          }
        }
      }
      reviews(first: 100) {
        nodes {
          id
          state
          body
          submittedAt
          author { login }
        }
      }
    }
  }
}
EOF

	gh api graphql \
		-F query="@${query_file}" \
		-F owner="${REPO%%/*}" \
		-F repo="${REPO##*/}" \
		-F number="$pr_num" >"$out"
}

review_feedback_latest_timestamp() {
	local feedback_file="$1"
	node - "$feedback_file" <<'NODE'
const fs = require('node:fs');
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const pr = payload.data?.repository?.pullRequest;
const stamps = [];
for (const thread of pr?.reviewThreads?.nodes ?? []) {
	for (const comment of thread?.comments?.nodes ?? []) {
		if (comment?.updatedAt) stamps.push(comment.updatedAt);
		else if (comment?.createdAt) stamps.push(comment.createdAt);
	}
}
for (const review of pr?.reviews?.nodes ?? []) {
	if (review?.submittedAt) stamps.push(review.submittedAt);
}
stamps.sort();
process.stdout.write(stamps[stamps.length - 1] ?? '');
NODE
}

review_feedback_is_actionable() {
	local feedback_file="$1" gh_user="$2" handled_at="${3:-}"
	node - "$feedback_file" "$gh_user" "$handled_at" <<'NODE'
const fs = require('node:fs');
const [file, ghUser, handledAt] = process.argv.slice(2);
const payload = JSON.parse(fs.readFileSync(file, 'utf8'));
const pr = payload.data?.repository?.pullRequest;
const handledMs = handledAt ? Date.parse(handledAt) : 0;
const newerThanHandled = (iso) => !handledMs || (Date.parse(iso || 0) > handledMs);

for (const thread of pr?.reviewThreads?.nodes ?? []) {
	if (thread?.isResolved || thread?.isOutdated) continue;
	const comments = thread?.comments?.nodes ?? [];
	const latest = comments[comments.length - 1];
	if (!latest) continue;
	if (latest.author?.login === ghUser) continue;
	if (newerThanHandled(latest.updatedAt || latest.createdAt)) {
		process.stdout.write('1');
		process.exit(0);
	}
}

for (const review of pr?.reviews?.nodes ?? []) {
	if (review?.state !== 'CHANGES_REQUESTED') continue;
	if (!String(review?.body ?? '').trim()) continue;
	if (review.author?.login === ghUser) continue;
	if (newerThanHandled(review.submittedAt)) {
		process.stdout.write('1');
		process.exit(0);
	}
}

process.stdout.write('0');
NODE
}

pick_pr_review_task() {
	local gh_user="$1"
	local feedback_file="" latest_feedback="" actionable=""

	while IFS=$'\t' read -r key issue_num state branch pr_url handled_at; do
		[[ -n "$key" ]] || continue
		[[ "$state" == "delivered" ]] || continue
		[[ -n "$pr_url" && -n "$branch" ]] || continue

		local pr_num="${pr_url##*/}"
		local pr_state=""
		pr_state="$(gh pr view "$pr_num" --repo "$REPO" --json state --jq '.state' 2>/dev/null || true)"
		[[ "$pr_state" == "OPEN" ]] || continue

		feedback_file="$TMP_DIR/pr-review-${pr_num}.json"
		fetch_pr_review_feedback "$pr_num" "$feedback_file" || continue
		actionable="$(review_feedback_is_actionable "$feedback_file" "$gh_user" "$handled_at")"
		latest_feedback="$(review_feedback_latest_timestamp "$feedback_file")"

		# Also check regular (non-review-thread) PR comments
		if [[ "$actionable" != "1" ]]; then
			local since="${handled_at:-1970-01-01T00:00:00Z}"
			local latest_comment_ts=""
			latest_comment_ts="$(
				gh api "repos/$REPO/issues/${pr_num}/comments" \
					--jq "[.[] | select(.created_at > \"$since\" and .user.type != \"Bot\")] | sort_by(.created_at) | last | .created_at // \"\""
			)"
			if [[ -n "$latest_comment_ts" && "$latest_comment_ts" != "null" ]]; then
				actionable="1"
				if [[ -z "$latest_feedback" || "$latest_comment_ts" > "$latest_feedback" ]]; then
					latest_feedback="$latest_comment_ts"
				fi
			fi
		fi

		[[ "$actionable" == "1" ]] || continue

		printf '%s\t%s\t%s\t%s\n' "$issue_num" "$pr_num" "$branch" "$latest_feedback"
		return 0
	done < <(state_entries_for_repo "$REPO")

	return 1
}

infer_branch_prefix() {
	node - "$1" <<'NODE'
const fs = require('node:fs');
const issue = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const labels = (issue.labels ?? []).map(l => String(l?.name ?? '').toLowerCase());
const has = (...n) => n.some(x => labels.includes(x));
let p = 'fix';
if (has('enhancement','feature','feat')) p = 'feat';
else if (has('refactor')) p = 'refactor';
else if (has('ci')) p = 'ci';
else if (has('test','tests')) p = 'test';
else if (has('perf','performance')) p = 'perf';
else if (has('build')) p = 'build';
else if (has('chore','docs','documentation','maintenance')) p = 'chore';
process.stdout.write(p);
NODE
}

detect_verify_commands() {
	if [[ -n "$VERIFY_COMMANDS_OVERRIDE" ]]; then
		printf '%s' "$VERIFY_COMMANDS_OVERRIDE"
		return
	fi

	local pkg_json="$PROJECT_ROOT/package.json"
	[[ -f "$pkg_json" ]] || return 0
	node - "$pkg_json" <<'NODE'
const fs = require('node:fs');
const pkg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const scripts = pkg.scripts ?? {};
const pm = String(pkg.packageManager ?? '');
let runner = pm.startsWith('bun@') ? 'bun run' : pm.startsWith('pnpm@') ? 'pnpm' : pm.startsWith('yarn@') ? 'yarn' : 'npm run';
const want = ['format','lint','check','test:unit'];
process.stdout.write(want.filter(s => s in scripts).map(s => `${runner} ${s}`).join('\n'));
NODE
}

ensure_closes_reference() {
	local num="$1" body="$2"
	[[ "$body" =~ (Closes|Fixes|Resolves)[[:space:]]+#$num ]] && { printf '%s' "$body"; return; }
	printf 'Closes #%s\n\n%s' "$num" "$body"
}

build_fallback_resolution_metadata() {
	local issue_title="$1" issue_language="$2"
	local commit_subject=""
	local pr_title=""
	local pr_body=""
	local issue_comment=""
	local verification_summary=""

	commit_subject="$(git -C "$PROJECT_ROOT" log -1 --pretty=%s 2>/dev/null || true)"
	[[ -n "$commit_subject" ]] || commit_subject="chore: resume autopilot delivery for issue #$ISSUE_NUMBER"
	pr_title="$commit_subject"
	pr_body="$(printf '## Summary\n- resume autopilot delivery for existing branch work\n- publish the pending pull request for issue #%s\n\nCloses #%s\n' "$ISSUE_NUMBER" "$ISSUE_NUMBER")"
	issue_comment="$(build_fallback_issue_comment "$issue_language")"
	verification_summary="Reused an existing clean branch state and resumed delivery without rerunning the agent. Existing repository checks were not rerun during fallback delivery."

	printf '%s\037%s\037%s\037%s\037%s' "$commit_subject" "$pr_title" "$pr_body" "$issue_comment" "$verification_summary"
}

deliver_resolution() {
	local key="$1" branch="$2" commit_message="$3" pr_title="$4" pr_body="$5" issue_comment="$6" verification_summary="$7"
	local pr_url="" existing_pr=""

	pr_body="$(ensure_closes_reference "$ISSUE_NUMBER" "$pr_body")"

	log "Verification: $verification_summary"
	ensure_git_identity

	if ! worktree_is_clean; then
		git -C "$PROJECT_ROOT" add -A
		git -C "$PROJECT_ROOT" commit -m "$commit_message"
		state_write "$key" stage "committed" commit_sha "$(current_head)"
	fi

	if branch_has_unpushed_commits "$branch" || ! branch_has_remote "$branch"; then
		git -C "$PROJECT_ROOT" push -u origin "$branch"
		state_write "$key" stage "pushed" commit_sha "$(current_head)"
	fi

	if ! branch_has_commits_against_base; then
		log "No commits between $BASE_BRANCH and $branch; skipping PR creation"
		mark_issue_delivered "$key" "$branch"
		return 0
	fi

	existing_pr="$(find_existing_pr_for_branch "$branch")"
	if [[ -n "$existing_pr" ]]; then
		pr_url="$existing_pr"
	else
		local pr_body_file="$TMP_DIR/pr-body.md"
		local pr_error_file="$TMP_DIR/pr-create.err"
		printf '%s\n' "$pr_body" > "$pr_body_file"
		if ! pr_url="$(
			gh pr create \
				--repo "$REPO" \
				--base "$BASE_BRANCH" \
				--head "$branch" \
				--title "$pr_title" \
				--body-file "$pr_body_file" \
				2>"$pr_error_file"
		)"; then
			if grep -q "No commits between" "$pr_error_file" 2>/dev/null; then
				log "No commits between $BASE_BRANCH and $branch on GitHub; skipping PR creation"
				mark_issue_delivered "$key" "$branch"
				return 0
			fi
			die "Failed to create PR: $(tr '\n' ' ' < "$pr_error_file")"
		fi
	fi

	[[ -n "$pr_url" ]] || die "PR URL is empty after delivery."
	state_write "$key" stage "pr_opened" pr_url "$pr_url"
	log "PR opened: $pr_url"

	if [[ "$COMMENT_ON_SUCCESS" -eq 1 && "$(state_read "$key" issue_comment_posted)" != "1" ]]; then
		if [[ "$TASK_KIND" == "pr_review" && -n "$PR_NUMBER" ]]; then
			post_pr_comment "$PR_NUMBER" "$(printf '%s\n\nPR: %s\n' "$issue_comment" "$pr_url")"
		else
			remove_working_label "$ISSUE_NUMBER"
			post_issue_comment "$ISSUE_NUMBER" "$(printf '%s\n\nPR: %s\n' "$issue_comment" "$pr_url")"
			[[ -n "$ISSUE_AUTHOR" ]] && gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-assignee "$ISSUE_AUTHOR" >/dev/null 2>&1 || true
		fi
		state_write "$key" issue_comment_posted "1"
		log "Issue comment posted"
	fi

	mark_issue_delivered "$key" "$branch" "$pr_url"
	if [[ "$TASK_KIND" == "pr_review" && -n "$REVIEW_FEEDBACK_UPDATED_AT" ]]; then
		state_write "$key" review_feedback_handled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	fi
}

resume_from_checkpoint() {
	local key="$1" branch="$2"
	local stage commit_message pr_title pr_body issue_comment verification_summary pr_url=""

	stage="$(state_read "$key" stage)"
	[[ -n "$stage" ]] || return 1

	pr_url="$(state_read "$key" pr_url)"
	if [[ -z "$pr_url" ]]; then
		pr_url="$(find_existing_pr_for_branch "$branch")"
		[[ -n "$pr_url" ]] && state_write "$key" stage "pr_opened" pr_url "$pr_url"
	fi

	if [[ -n "$pr_url" && "$(state_read "$key" issue_comment_posted)" == "1" ]]; then
		log "Checkpoint already completed with PR $pr_url"
		mark_issue_delivered "$key" "$branch" "$pr_url"
		return 0
	fi

	case "$stage" in
		resolved|committed|pushed|pr_opened)
			commit_message="$(state_read "$key" commit_message)"
			pr_title="$(state_read "$key" pr_title)"
			pr_body="$(state_read "$key" pr_body)"
			issue_comment="$(state_read "$key" issue_comment)"
			verification_summary="$(state_read "$key" verification_summary)"

			if [[ -n "$pr_url" && "$(state_read "$key" issue_comment_posted)" != "1" && -n "$issue_comment" ]]; then
				if [[ "$TASK_KIND" == "pr_review" && -n "$PR_NUMBER" ]]; then
					post_pr_comment "$PR_NUMBER" "$(printf '%s\n\nPR: %s\n' "$issue_comment" "$pr_url")"
				else
					post_issue_comment "$ISSUE_NUMBER" "$(printf '%s\n\nPR: %s\n' "$issue_comment" "$pr_url")"
				fi
				state_write "$key" issue_comment_posted "1"
				log "Issue comment posted from checkpoint"
				mark_issue_delivered "$key" "$branch" "$pr_url"
				if [[ "$TASK_KIND" == "pr_review" && -n "$REVIEW_FEEDBACK_UPDATED_AT" ]]; then
					state_write "$key" review_feedback_handled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
				fi
				return 0
			fi

			[[ -n "$commit_message" && -n "$pr_title" && -n "$pr_body" ]] || return 1
			log "Resuming from checkpoint stage: $stage"
			deliver_resolution "$key" "$branch" "$commit_message" "$pr_title" "$pr_body" "$issue_comment" "$verification_summary"
			return 0
			;;
	esac

	return 1
}

# ─── agent runners ───────────────────────────────────────────────────────────

write_output_schema() {
	local schema_file="$1"

	cat >"$schema_file" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "status": {
      "type": "string",
      "enum": ["resolved", "needs_user_input", "failed"]
    },
    "issue_language": {
      "type": "string"
    },
    "summary": {
      "type": "string"
    },
    "question_for_user": {
      "type": "string"
    },
    "issue_comment": {
      "type": "string"
    },
    "commit_message": {
      "type": "string"
    },
    "pr_title": {
      "type": "string"
    },
    "pr_body": {
      "type": "string"
    },
    "verification_summary": {
      "type": "string"
    }
  },
  "required": [
    "status",
    "issue_language",
    "summary",
    "question_for_user",
    "issue_comment",
    "commit_message",
    "pr_title",
    "pr_body",
    "verification_summary"
  ]
}
EOF
}

write_prompt() {
	local out="$1" issue_json="$2" branch="$3" clarification="$4" verify_cmds="$5" review_feedback_json="${6:-}"

	cat >"$out" <<EOF
You are an autonomous software agent working in repository $REPO.

## Rules
- Work only on the assigned task context below. Do not open, list, or modify any other issue or PR.
- Do NOT commit, push, or open PRs — the shell script handles that.
- Do NOT modify files outside the repository working tree.
- All commit messages, PR titles, and PR bodies must be written in English.
- Write \`question_for_user\` and \`issue_comment\` in the user's language.
- \`issue_comment\` means:
  - for issue tasks: the comment to post on the issue
  - for PR review tasks: the comment to post on the pull request discussion
- Before implementing anything, reason about whether the issue is clear enough to act on.
  - If the issue has concrete specs (a specific bug, a clear feature, explicit values to change): implement directly.
  - If the issue is vague in a way that would lead to guessing (e.g. "make it look modern", "improve UX",
    "update X" with no criteria): return status="needs_user_input" with a focused question.
  - Do NOT ask for clarification about implementation details you can infer from the codebase.
  - Do NOT ask for clarification when the issue is specific enough to act on.
- Run the verification commands listed below before declaring the issue resolved.
  If a command is not applicable, explain why in \`verification_summary\`.
- Your final message must end with a JSON block (no extra text after it) using the schema below.

## Context
- Working directory: $PROJECT_ROOT
- Branch created by the shell script: $branch
- Base branch: $BASE_BRANCH
- Task type: $TASK_KIND
- Source issue: #$ISSUE_NUMBER
$( [[ "$TASK_KIND" == "pr_review" ]] && printf -- "- Pull request under review: #%s\n" "$PR_NUMBER" )
- Verification commands to run:
$(printf '%s\n' "$verify_cmds" | sed 's/^/  /')

## Issue payload
$(cat "$issue_json")

$( if [[ -n "$review_feedback_json" && -f "$review_feedback_json" ]]; then
	printf '## Pull request review feedback\n%s\n' "$(cat "$review_feedback_json")"
fi )

## Clarification from operator
${clarification:-<none>}

## Output schema
Output a JSON block at the very end of your response, exactly like this:

\`\`\`json
{
  "status": "resolved" | "needs_user_input" | "failed",
  "issue_language": "<language tag, e.g. en or es>",
  "summary": "<concise outcome>",
  "question_for_user": "<clarification question, or empty string>",
  "issue_comment": "<comment to post on the issue in its language>",
  "commit_message": "<conventional commit in English>",
  "pr_title": "<concise English PR title>",
  "pr_body": "<English PR body including Closes #$ISSUE_NUMBER>",
  "verification_summary": "<what checks you ran and their result>"
}
\`\`\`
EOF
}

run_claude() {
	local prompt_file="$1"
	local result_file="$2"
	local raw_file="$TMP_DIR/claude-raw.txt"

	local args=(--print --allowedTools "Bash,Edit,Write,Read,Glob,Grep,LS" --effort "$CLAUDE_THINKING")
	[[ -n "$CLAUDE_MODEL" ]] && args+=(--model "$CLAUDE_MODEL")

	log "Running claude (model: ${CLAUDE_MODEL:-default}, effort: ${CLAUDE_THINKING}, timeout: ${CLAUDE_TIMEOUT_MINUTES}m)..."

	local timeout_secs=$(( CLAUDE_TIMEOUT_MINUTES * 60 ))
	local exit_code=0
	(cd "$PROJECT_ROOT" && timeout "$timeout_secs" claude "${args[@]}" < "$prompt_file") > "$raw_file" 2>&1 || exit_code=$?

	if grep -qi "session limit\|rate.limit\|too many request" "$raw_file" 2>/dev/null; then
		warn "Claude session limit reached — will retry next cycle."
		exit 0
	fi

	if [[ $exit_code -eq 124 ]]; then
		die "Claude timed out after ${CLAUDE_TIMEOUT_MINUTES} minutes."
	elif [[ $exit_code -ne 0 ]]; then
		die "Claude exited with code $exit_code. Raw: $(tail -20 "$raw_file")"
	fi

	extract_json_block "$raw_file" > "$result_file" \
		|| die "Could not extract JSON from claude output. Raw: $(tail -20 "$raw_file")"
}

run_codex() {
	local prompt_file="$1"
	local result_file="$2"
	local schema_file="$TMP_DIR/output-schema.json"
	local sandbox_label=""

	write_output_schema "$schema_file"

	local -a args=(exec --cd "$PROJECT_ROOT")

	if [[ "$CODEX_BYPASS_SANDBOX" == "1" ]]; then
		args+=(--dangerously-bypass-approvals-and-sandbox)
		sandbox_label="bypass"
	else
		args+=(--sandbox "$CODEX_SANDBOX_MODE")
		sandbox_label="$CODEX_SANDBOX_MODE"
	fi

	args+=(
		--config "model_reasoning_effort=\"${CODEX_REASONING_EFFORT}\""
		--skip-git-repo-check
		--output-schema "$schema_file"
		--output-last-message "$result_file"
		--color never
	)

	[[ -n "$CODEX_MODEL" ]] && args+=(--model "$CODEX_MODEL")
	args+=(-)

	log "Running codex (model: ${CODEX_MODEL:-default}, reasoning: ${CODEX_REASONING_EFFORT}, sandbox: ${sandbox_label})..."

	if ! "$CODEX_BIN" "${args[@]}" < "$prompt_file"; then
		die "Codex exited with a non-zero status."
	fi
}

run_agent() {
	case "$AUTOPILOT_AGENT" in
		claude) run_claude "$@" ;;
		codex)  run_codex "$@" ;;
	esac
}

# ─── args ────────────────────────────────────────────────────────────────────

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --issue <number>         Target a specific issue number.
  --repo <owner/name>      GitHub repository slug.
  --base <branch>          Base branch. Default: $DEFAULT_BASE_BRANCH
  --branch-prefix <pfx>    Override branch prefix.
  --agent <claude|codex>   Override the configured agent. Default: $AUTOPILOT_AGENT
  --model <name>           Override the selected agent model.
  --project-root <path>    Local path to the cloned repo.
  --log-file <path>        Append structured log to this file.
  --dry-run                Print selected issue/branch and exit.
  --no-issue-comment       Skip posting a comment on the issue.
  -h, --help               Show this help.
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--issue)            ISSUE_NUMBER="${2:-}"; shift 2 ;;
			--repo)             REPO="${2:-}"; shift 2 ;;
			--base)             BASE_BRANCH="${2:-}"; shift 2 ;;
			--branch-prefix)    BRANCH_PREFIX="${2:-}"; shift 2 ;;
			--agent)            AUTOPILOT_AGENT="${2:-}"; shift 2 ;;
			--model)            AGENT_MODEL_OVERRIDE="${2:-}"; shift 2 ;;
			--project-root)     PROJECT_ROOT="${2:-}"; shift 2 ;;
			--log-file)         LOG_FILE="${2:-}"; shift 2 ;;
			--dry-run)          DRY_RUN=1; shift ;;
			--no-issue-comment) COMMENT_ON_SUCCESS=0; shift ;;
			-h|--help)          usage; exit 0 ;;
			*)                  die "Unknown argument: $1" ;;
		esac
	done
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
	parse_args "$@"
	agent_name >/dev/null

	if [[ -n "$AGENT_MODEL_OVERRIDE" ]]; then
		case "$AUTOPILOT_AGENT" in
			claude) CLAUDE_MODEL="$AGENT_MODEL_OVERRIDE" ;;
			codex)  CODEX_MODEL="$AGENT_MODEL_OVERRIDE" ;;
		esac
	fi

	has gh     || die "gh not found"
	has git    || die "git not found"
	has node   || die "node not found"

	gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
	local gh_user
	gh_user="$(gh api user --jq '.login')"

	case "$AUTOPILOT_AGENT" in
		claude)
			has claude || die "claude not found"
			claude auth status >/dev/null 2>&1 || die "claude not authenticated. Run: claude auth login"
			;;
		codex)
			CODEX_BIN="$(resolve_codex_bin)"
			"$CODEX_BIN" login status >/dev/null 2>&1 || die "codex not authenticated. Run: codex login"
			;;
	esac

	[[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT="$(pwd)"
	[[ -d "$PROJECT_ROOT/.git" ]] || die "Not a git repository: $PROJECT_ROOT"

	export REPO
	REPO="$(detect_repo)"

	# ── pick task ───────────────────────────────────────────────────────────

	local review_task=""
	if [[ -z "$ISSUE_NUMBER" ]]; then
		review_task="$(pick_pr_review_task "$gh_user" || true)"
	fi

	local preselected_branch=""
	if [[ -n "$review_task" ]]; then
		TASK_KIND="pr_review"
		IFS=$'\t' read -r ISSUE_NUMBER PR_NUMBER preselected_branch REVIEW_FEEDBACK_UPDATED_AT <<< "$review_task"
	fi

	if [[ -z "$ISSUE_NUMBER" ]]; then
		ISSUE_NUMBER="$(pick_issue)"
	fi

	[[ -z "$ISSUE_NUMBER" || "$ISSUE_NUMBER" == "null" ]] \
		&& { log "No actionable open issues in $REPO. Nothing to do."; exit 0; }

	local key
	key="$(state_key)"

	local issue_json="$TMP_DIR/issue.json"
	fetch_issue_json "$ISSUE_NUMBER" "$issue_json"

	local issue_title
	issue_title="$(json_field "$issue_json" title)"
	local issue_language
	issue_language="$(infer_issue_language "$issue_json")"
	ISSUE_AUTHOR="$(node -e "const a=JSON.parse(require('fs').readFileSync('$issue_json','utf8')); process.stdout.write(a.author?.login||'')")"
	log "Issue: #$ISSUE_NUMBER — $issue_title"

	# ── check if resuming from awaiting_clarification ────────────────────────

	local clarification=""
	local rounds=0

	local current_state
	current_state="$(state_read "$key" state)"

	if [[ "$current_state" == "awaiting_pr_clarification" ]]; then
		TASK_KIND="pr_review"
		PR_NUMBER="$(state_read "$key" pr_number)"
		preselected_branch="$(state_read "$key" branch)"
		local asked_at
		asked_at="$(state_read "$key" asked_at)"
		local new_comments
		new_comments="$(fetch_new_human_pr_comments "$PR_NUMBER" "$asked_at")"

		if [[ -z "$new_comments" ]]; then
			log "Awaiting human response on PR #$PR_NUMBER — skipping this cycle."
			exit 0
		fi

		log "Human responded on PR #$PR_NUMBER — resuming with clarification."
		clarification="$new_comments"
		rounds=1
		state_delete "$key"
	elif [[ "$current_state" == "awaiting_clarification" ]]; then
		local asked_at
		asked_at="$(state_read "$key" asked_at)"
		local new_comments
		new_comments="$(fetch_new_human_comments "$ISSUE_NUMBER" "$asked_at")"

		if [[ -z "$new_comments" ]]; then
			log "Awaiting human response on issue #$ISSUE_NUMBER — skipping this cycle."
			exit 0
		fi

		log "Human responded on issue #$ISSUE_NUMBER — resuming with clarification."
		clarification="$new_comments"
		rounds=1
		state_delete "$key"
	fi

	# ── setup branch ────────────────────────────────────────────────────────

	[[ -z "$BRANCH_PREFIX" ]] && BRANCH_PREFIX="$(infer_branch_prefix "$issue_json")"
	local branch="${preselected_branch:-${BRANCH_PREFIX}/$(slugify "$(json_field "$issue_json" title)")}"
	local review_feedback_file=""
	if [[ "$TASK_KIND" == "pr_review" && -n "$PR_NUMBER" ]]; then
		review_feedback_file="$TMP_DIR/pr-review-${PR_NUMBER}.json"
		fetch_pr_review_feedback "$PR_NUMBER" "$review_feedback_file"
	fi
	local verify_cmds
	verify_cmds="$(detect_verify_commands || true)"

	log "Agent: $(agent_name) | Branch: $branch | Base: $BASE_BRANCH | Root: $PROJECT_ROOT"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Dry run — exiting."
		exit 0
	fi

	ensure_issue_worktree_ready "$branch"

	local existing_pr=""
	existing_pr="$(find_existing_pr_for_branch "$branch")"
	if [[ "$TASK_KIND" == "issue" && -n "$existing_pr" && worktree_is_clean ]]; then
		log "Existing PR already open for $branch: $existing_pr"
		mark_issue_delivered "$key" "$branch" "$existing_pr"
		exit 0
	fi

	if [[ "$TASK_KIND" == "issue" && "$(state_read "$key" started_comment_posted)" != "1" ]]; then
		add_working_label "$ISSUE_NUMBER"
		state_write "$key" started_comment_posted "1" branch "$branch"
		log "Working label added to issue #$ISSUE_NUMBER"
	elif [[ "$TASK_KIND" == "pr_review" && "$(state_read "$key" pr_review_started_at)" != "$REVIEW_FEEDBACK_UPDATED_AT" ]]; then
		post_pr_comment "$PR_NUMBER" "$(build_started_pr_review_comment "$issue_language")"
		state_write "$key" pr_review_started_at "$REVIEW_FEEDBACK_UPDATED_AT" branch "$branch" pr_number "$PR_NUMBER"
		log "Started-work comment posted on PR #$PR_NUMBER"
	fi

	if [[ "$TASK_KIND" == "issue" ]] && resume_from_checkpoint "$key" "$branch"; then
		exit 0
	fi

	if [[ "$TASK_KIND" == "issue" ]] && worktree_is_clean && [[ "$(current_branch)" == "$branch" ]] && branch_has_commits_against_base && { branch_has_remote "$branch" || branch_has_unpushed_commits "$branch"; }; then
		local fallback_blob fallback_commit_message fallback_pr_title fallback_pr_body fallback_issue_comment fallback_verification_summary
		fallback_blob="$(build_fallback_resolution_metadata "$issue_title" "$issue_language")"
		IFS=$'\037' read -r fallback_commit_message fallback_pr_title fallback_pr_body fallback_issue_comment fallback_verification_summary <<< "$fallback_blob"
		state_write "$key" \
			stage                "resolved" \
			branch               "$branch" \
			commit_message       "$fallback_commit_message" \
			pr_title             "$fallback_pr_title" \
			pr_body              "$fallback_pr_body" \
			issue_comment        "$fallback_issue_comment" \
			verification_summary "$fallback_verification_summary"
		log "Resuming delivery from existing clean branch state on $branch"
		deliver_resolution "$key" "$branch" "$fallback_commit_message" "$fallback_pr_title" "$fallback_pr_body" "$fallback_issue_comment" "$fallback_verification_summary"
		exit 0
	fi

	# ── agent loop ──────────────────────────────────────────────────────────

	local attempt=1
	local result_file=""

	while true; do
		local prompt_file="$TMP_DIR/prompt-${attempt}.txt"
		result_file="$TMP_DIR/result-${attempt}.json"

		write_prompt "$prompt_file" "$issue_json" "$branch" "$clarification" "$verify_cmds" "$review_feedback_file"
		run_agent "$prompt_file" "$result_file"

		local status summary
		status="$(json_field "$result_file" status)"
		summary="$(json_field "$result_file" summary)"
		log "$(agent_name) status: $status — $summary"

		case "$status" in
			resolved) break ;;

			needs_user_input)
				if (( rounds >= MAX_CLARIFICATION_ROUNDS )); then
					die "$(agent_name) needs clarification after $MAX_CLARIFICATION_ROUNDS rounds. Aborting."
				fi
				worktree_is_clean \
					|| die "$(agent_name) modified files while requesting clarification. Inspect $branch manually."

				local question
				question="$(json_field "$result_file" question_for_user)"
				log "Clarification needed: $question"

				# Post question as comment on the issue
				if [[ "$TASK_KIND" == "pr_review" ]]; then
					post_pr_comment "$PR_NUMBER" \
						"$(printf '**Autopilot needs clarification before proceeding:**\n\n%s' "$question")"
					log "Question posted as comment on PR #$PR_NUMBER"
				else
					post_issue_comment "$ISSUE_NUMBER" \
						"$(printf '**Autopilot needs clarification before proceeding:**\n\n%s' "$question")"
					log "Question posted as comment on issue #$ISSUE_NUMBER"
				fi

				# Save state so next cycle knows to look for a response
				state_write "$key" \
					state    "$([[ "$TASK_KIND" == "pr_review" ]] && printf 'awaiting_pr_clarification' || printf 'awaiting_clarification')" \
					question "$question" \
					branch   "$branch" \
					pr_number "$PR_NUMBER" \
					asked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

				log "Issue #$ISSUE_NUMBER marked as awaiting_clarification in state.json"
				exit 0
				;;

			failed)
				die "$(agent_name) reported failure: ${summary:-no summary}"
				;;
			*)
				die "Unexpected $(agent_name) status: $status"
				;;
		esac
	done

	# ── commit + PR ─────────────────────────────────────────────────────────

	[[ -f "$result_file" ]] || die "No result file produced."
	if worktree_is_clean; then
		if [[ "$TASK_KIND" == "pr_review" ]]; then
			log "$(agent_name) reviewed PR feedback but made no code changes. Marking as handled."
			state_write "$key" review_feedback_handled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			exit 0
		fi
		die "$(agent_name) reported success but made no changes."
	fi

	cache_resolution_result "$key" "$result_file" "$branch"
	deliver_resolution \
		"$key" \
		"$branch" \
		"$(json_field "$result_file" commit_message)" \
		"$(json_field "$result_file" pr_title)" \
		"$(json_field "$result_file" pr_body)" \
		"$(json_field "$result_file" issue_comment)" \
		"$(json_field "$result_file" verification_summary)"
}

main "$@"
