#!/usr/bin/env bash
# =============================================================================
# git_flow.sh  v2.2.0 - AUTOSAR & GitLab workflow assistant for main + nested repos
#
#   * Run from your Main Repo root (or inside any component) with no arguments for
#     the interactive workspace dashboard & menu, OR script it via flags.
#   * Automatically handles:
#       - Seeing all changes & unpushed commits across Main Repo and all components
#       - Running 'git fetch --all' (including in .repo if present)
#       - Finding 'develop' on the remote (even when 'git branch' does not list it),
#         checking out local 'develop', and pulling latest changes before branching
#       - Enforcing <JIRA-ID>-<title> or <feature|bugfix|hotfix>/<JIRA-ID>-<title>
#       - Enforcing "<JIRA-ID>: <description>" commit messages (and fixing manual commits)
#       - Interactive selective file staging (pick individual files if not staging all)
#       - Pushing with 'git push --set-upstream' and creating/opening GitLab MRs
#
# Exit codes:
#   0 ok | 2 usage | 3 component/base not found or ambiguous | 4 repo state
#   5 network/auth | 6 protected branch blocked | 7 git operation failed
#   8 pushed OK but MR auto-creation failed | 130 aborted by user
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  echo "git_flow.sh requires bash (run: bash git_flow.sh)" >&2
  exit 2
fi
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "git_flow.sh must be executed, not sourced:  ./git_flow.sh --help" >&2
  return 2
fi

set -Eeuo pipefail

readonly VERSION="3.0.0"
readonly EX_USAGE=2 EX_NOTFOUND=3 EX_STATE=4 EX_NETWORK=5 EX_PROTECTED=6 EX_GIT=7 EX_MR=8 EX_ABORT=130

# ------------------------------------------------------------ configuration ---
BASE_BRANCH="${GIT_FLOW_BASE:-develop}"
DEFAULT_REMOTE="${GIT_FLOW_REMOTE:-origin}"
REMOTE="$DEFAULT_REMOTE"
REMOTE_EXPLICIT=false
if [[ -n "${GIT_FLOW_REMOTE:-}" ]]; then REMOTE_EXPLICIT=true; fi
JIRA_PATTERN="${GIT_FLOW_JIRA_PATTERN:-[A-Z][A-Z0-9_]*-[0-9]+}"
JIRA_URL="${GIT_FLOW_JIRA_URL:-}"
EXTRA_PROTECTED="${GIT_FLOW_PROTECTED:-}"
MAX_DEPTH="${GIT_FLOW_MAX_DEPTH:-10}"
EXCLUDE_DIRS=".repo node_modules build out dist target .venv venv __pycache__ .cache .gradle .idea .vscode .tox .mypy_cache .next ${GIT_FLOW_EXCLUDES:-}"
JIRA_REGEX="^${JIRA_PATTERN}\$"
BRANCH_REGEX="^((feature|bugfix|hotfix)/)?${JIRA_PATTERN}-.+\$"

# ------------------------------------------------------------------- state ----
ORIG_DIR="$PWD"
WORKSPACE_ROOT="$PWD"
SELF="$0"
DRY_RUN=false; YES=false; NONINTERACTIVE=false; USE_COLOR=true
NO_FETCH=false; FORCE=false; STAGE_ALL=false; MODEL_ONLY=false; AUTO_STASH=false; CARRY_CHANGES=false; CARRY_FLAG=false; JIRA_FROM_BRANCH=false; DRAFT=false
DO_BRANCH=false; DO_COMMIT=false; DO_PUSH=false; DO_MR=false; DO_MRTEXT=false
DO_SYNC=false; DO_STATUS=false; DO_HEALTH=false; DO_WIZARD=false; DO_UNDO=false; DO_UPDATE=false; DO_DISCARD=false
COMPONENT=""; JIRA_ID=""; LAST_JIRA_ID=""; BRANCH_TYPE=""; DESC=""; COMMIT_MSG=""
ASSIGNEE="${GIT_FLOW_ASSIGNEE:-}"; REVIEWER="${GIT_FLOW_REVIEWER:-}"
LAST_ASSIGNEE="$ASSIGNEE"; LAST_REVIEWER="$REVIEWER"; MR_PEOPLE_PROMPTED=false
REPO_DIR=""; MULTI_REPOS=(); CUR_BRANCH=""; DETACHED=false
BRANCH_NAME=""; SANITIZED=""
STASH_CREATED=false; STASH_MSG=""; SIM_COMMIT=false; MR_FAILED=false
HAS_STAGED=false; FORMATTED_MSG=""; PUSH_URL=""; MR_TITLE=""; MR_BODY=""; MR_TOOL=""
MR_CREATED_VIA_PUSH=false; MR_MODE=""
LOGFILE=""; REPLY_VAL=""; PICKED=""
MATCHES=(); PRUNE_ARGS=()

# ---------------------------------------------------------------- output ------
C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""
setup_colors() {
  if [[ "$USE_COLOR" == true && -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'; C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  fi
}
info() { printf '%s\n' "${C_CYAN}[..]${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}[!!]${C_RESET} $*" >&2; }
hint() { printf '%s\n' "     ${C_DIM}->${C_RESET} $*" >&2; }
step() { printf '\n%s\n' "${C_BOLD}==> $*${C_RESET}"; }

die() {
  local code="$1" msg="$2" h
  shift 2
  printf '%s\n' "${C_RED}[ERR]${C_RESET} $msg" >&2
  for h in "$@"; do
    if [[ -n "$h" ]]; then hint "$h"; fi
  done
  exit "$code"
}

# ------------------------------------------------------ traps / cleanup ------
on_error() {
  local rc="$1" line="$2" cmd="$3"
  trap - ERR
  printf '%s\n' "${C_RED}[ERR]${C_RESET} Unexpected failure (exit $rc) at line $line: $cmd" >&2
  hint "Preview safely with --dry-run, or trace with: bash -x $SELF <same args>"
  exit 1
}
cleanup() {
  local rc=$?
  trap - EXIT INT TERM ERR
  cd "$ORIG_DIR" 2>/dev/null || true
  if [[ -n "$LOGFILE" ]]; then rm -f "$LOGFILE" 2>/dev/null || true; fi
  if [[ "$STASH_CREATED" == true ]]; then
    printf '\n%s\n' "${C_YELLOW}[!!] Your uncommitted changes are safe in a stash:${C_RESET} \"$STASH_MSG\"" >&2
    hint "Inspect: git stash list   |   Restore: git stash pop" >&2
  fi
  if [[ $rc -ne 0 && $rc -ne $EX_ABORT ]]; then
    printf '%s\n' "${C_DIM}Nothing was force-pushed or deleted. Re-run with --dry-run to preview.${C_RESET}" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'die $EX_ABORT "Interrupted by user - no further commands were run."' INT TERM
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# -------------------------------------------------------------- utilities -----
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
fmt_cmd() { local o; o=$(printf '%q ' "$@"); printf '%s' "${o% }"; }
dry_echo() { printf '%s\n' "  ${C_YELLOW}[dry-run]${C_RESET} would run: $(fmt_cmd "$@")"; }

try() {
  if $DRY_RUN; then dry_echo "$@"; return 0; fi
  local rc=0
  "$@" || rc=$?
  return $rc
}
run() {
  local rc=0
  try "$@" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "$EX_GIT" "Command failed (exit $rc): $(fmt_cmd "$@")" \
      "Read the git output above, fix the cause, then re-run (add --dry-run to preview)."
  fi
}
run_logged() {
  local rc=0
  : >"$LOGFILE"
  if $DRY_RUN; then dry_echo "$@"; return 0; fi
  "$@" >"$LOGFILE" 2>&1 || rc=$?
  cat "$LOGFILE"
  return $rc
}

yn() { if [[ "$1" == true ]]; then printf 'y'; else printf 'n'; fi; }
confirm() {
  local q="$1" def="$2" auto="$3" ans pr
  if $NONINTERACTIVE; then
    if [[ "$auto" == y ]]; then return 0; else return 1; fi
  fi
  if [[ "$def" == y ]]; then pr="[Y/n]"; else pr="[y/N]"; fi
  read -r -p "$q $pr: " ans || die "$EX_ABORT" "Input closed - aborting."
  ans="${ans:-$def}"
  if [[ "$ans" =~ ^[Yy] ]]; then return 0; else return 1; fi
}
prompt() {
  local text="$1" def="${2:-}" ans
  if $NONINTERACTIVE; then return 1; fi
  if [[ -n "$def" ]]; then
    read -r -p "$text [$def]: " ans || die "$EX_ABORT" "Input closed - aborting."
    ans="${ans:-$def}"
  else
    read -r -p "$text: " ans || die "$EX_ABORT" "Input closed - aborting."
  fi
  REPLY_VAL=$(trim "$ans")
  return 0
}
pick_from_list() {
  local pr="$1" item i=1 n sel
  shift
  local -a items=("$@")
  n=${#items[@]}
  for item in "${items[@]}"; do
    printf '  [%d] %s\n' "$i" "$item"
    i=$((i + 1))
  done
  while true; do
    read -r -p "$pr (1-$n, q to quit): " sel || die "$EX_ABORT" "Input closed - aborting."
    if [[ "$sel" == [qQ]* ]]; then die "$EX_ABORT" "Cancelled."; fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le "$n" ]]; then
      PICKED="${items[$((sel - 1))]}"
      return 0
    fi
    warn "Please enter a number between 1 and $n."
  done
}

usage() {
  cat <<EOF
git_flow.sh v$VERSION - AUTOSAR & GitLab workflow assistant for main + nested component repos

USAGE
  ./git_flow.sh [options]        (no action flag => workspace dashboard + interactive menu)

ACTIONS
  --wizard               One-command full workflow: Branch + Commit + Push + MR
  --health               Compact workspace health summary (changed, ahead, detached, on develop)
  --status               Show branch, modified files & unpushed commits across all workspace repos
  --sync                 Run fetch --all + checkout develop + pull across all workspace repos
  --branch               Fetch, update develop, and create branch for Jira task (supports -c can,dcm)
                         (implied when --jira / --type / --desc are given alone)
  -m, --commit "<msg>"   Commit; "<JIRA-ID>: " prefix is added automatically
  -p, --push             Push current branch (--set-upstream) + print MR hand-off text
      --mr               Push and auto-create the MR/PR (removes source branch on merge in GitLab)
      --mr-text          Only print/copy the MR title + description
      --undo-commit      Safely undo the last UNPUSHED commit (keeps all file changes intact)
      --update           Update current work branch with latest origin/develop (conflict-checked)
      --discard          Safely discard unwanted file changes (saves a git stash backup first)

INPUTS
  -c, --component <name|path>   Component repo folder (or pick interactively from Main Repo)
  -j, --jira <ID>               Jira task ID, e.g. OSKDC33837-14809
      --jira-from-branch        Auto-extract Jira ID from current branch name (or changed files)
  -t, --type <type>             none | feature | bugfix | hotfix (default: none -> PROJ-123-title)
  -d, --desc "<text>"           Branch title / short description (required)
  -b, --base <branch>           Base/target branch               (default: $BASE_BRANCH)
  -r, --remote <name>           Remote name                      (default: $REMOTE)
  -a, --assignee <cdsid>        GitLab Assignee CDS ID (e.g. jfernan1)
      --reviewer <cdsid(s)>     GitLab Reviewer CDS ID(s) (e.g. rkumar2 or "rkumar2,asmith3")

BEHAVIOUR
  -n, --dry-run     Show every mutating command without running it
  -y, --yes         Non-interactive: never prompt, use safe defaults
      --carry       Carry uncommitted changes onto the new branch (without stashing)
      --stash       Auto-stash tracked changes before creating a branch
      --all         Stage everything when nothing is staged (git add -A)
      --model-only  Stage only Rhapsody model files (*.rpwx, *.sbsx, *.rpy), skipping .bak/.tmp/generated
      --draft       Create the MR/PR as draft
      --no-fetch    Skip 'git fetch' (offline work; push will still need network)
      --force       Bypass branch-name / Jira-mismatch / sensitive-file checks
                    (never bypasses protected-branch blocking)
      --no-color    Disable colours
  -h, --help        This help        --version   Print version

EXAMPLES
  ./git_flow.sh                                         # workspace dashboard + guided menu
  ./git_flow.sh --status                                # see all changes across all components
  ./git_flow.sh --sync                                  # fetch --all + checkout develop + pull all
  ./git_flow.sh -c dcm --branch -j PROJ-123 -d "fix can parser"
  ./git_flow.sh -c dcm --commit "handle empty frame" --all --push --mr
EOF
}

# ------------------------------------------------------------- arg parsing ----
need_value() {
  if [[ $# -lt 2 || "$2" == -* ]]; then
    die "$EX_USAGE" "Option $1 requires a value." "See: $SELF --help"
  fi
}
parse_args() {
  local -a args=()
  local a
  for a in "$@"; do
    if [[ "$a" == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)       usage; exit 0 ;;
      --version)       echo "$VERSION"; exit 0 ;;
      -n|--dry-run)    DRY_RUN=true ;;
      -y|--yes)        YES=true ;;
      -c|--component)  need_value "$@"; COMPONENT="$2"; shift ;;
      -j|--jira)       need_value "$@"; JIRA_ID="$2"; shift ;;
      -t|--type)       need_value "$@"; BRANCH_TYPE="$(lower "$2")"; shift ;;
      -d|--desc)       need_value "$@"; DESC="$2"; shift ;;
      -b|--base)       need_value "$@"; BASE_BRANCH="$2"; shift ;;
      -r|--remote)     need_value "$@"; REMOTE="$2"; DEFAULT_REMOTE="$2"; REMOTE_EXPLICIT=true; shift ;;
      -a|--assignee)   need_value "$@"; ASSIGNEE="$2"; LAST_ASSIGNEE="$2"; shift ;;
      --reviewer)      need_value "$@"; REVIEWER="$2"; LAST_REVIEWER="$2"; shift ;;
      -m|--commit)     DO_COMMIT=true
                       if [[ $# -ge 2 && "$2" != -* ]]; then COMMIT_MSG="$2"; shift; fi ;;
      -p|--push)       DO_PUSH=true ;;
      --branch)        DO_BRANCH=true ;;
      --mr)            DO_MR=true ;;
      --mr-text)       DO_MRTEXT=true ;;
      --sync)          DO_SYNC=true ;;
      --status)        DO_STATUS=true ;;
      --health)        DO_HEALTH=true ;;
      --wizard)        DO_WIZARD=true ;;
      --undo|--undo-commit) DO_UNDO=true ;;
      --update)        DO_UPDATE=true ;;
      --discard)       DO_DISCARD=true ;;
      --draft)         DRAFT=true ;;
      --all)           STAGE_ALL=true ;;
      --model-only)    MODEL_ONLY=true ;;
      --carry)         CARRY_FLAG=true ;;
      --jira-from-branch) JIRA_FROM_BRANCH=true ;;
      --stash)         AUTO_STASH=true ;;
      --no-fetch)      NO_FETCH=true ;;
      --force)         FORCE=true ;;
      --no-color)      USE_COLOR=false ;;
      *) die "$EX_USAGE" "Unknown option: $1" "See: $SELF --help" ;;
    esac
    shift
  done
  if [[ -n "$BRANCH_TYPE" ]]; then
    case "$BRANCH_TYPE" in
      direct|jira) BRANCH_TYPE="none" ;;
    esac
    case "$BRANCH_TYPE" in
      none|feature|bugfix|hotfix) ;;
      *) die "$EX_USAGE" "Invalid --type '$BRANCH_TYPE'." "Allowed: none (direct Jira ID), feature, bugfix, hotfix" ;;
    esac
  fi
  if $YES || [[ ! -t 0 ]]; then NONINTERACTIVE=true; fi
}

MENU_MODE=false
determine_mode() {
  if $DO_MR && ! $DO_WIZARD; then DO_PUSH=true; fi
  if ! $DO_BRANCH && ! $DO_COMMIT && ! $DO_PUSH && ! $DO_MRTEXT && ! $DO_SYNC && ! $DO_STATUS && ! $DO_HEALTH && ! $DO_WIZARD && ! $DO_UNDO && ! $DO_UPDATE && ! $DO_DISCARD; then
    if [[ -n "$JIRA_ID$DESC$BRANCH_TYPE" ]] || $JIRA_FROM_BRANCH; then
      DO_BRANCH=true
    elif $NONINTERACTIVE; then
      die "$EX_USAGE" "No action given and no terminal available for the menu." \
        "Use one of: --wizard | --health | --status | --sync | --branch | --commit \"msg\" | --push | --mr-text | --undo-commit | --update | --discard" "See: $SELF --help"
    else
      MENU_MODE=true
    fi
  fi
  if $DO_BRANCH && { $DO_COMMIT || $DO_PUSH || $DO_MRTEXT || $DO_SYNC || $DO_STATUS || $DO_HEALTH || $DO_WIZARD || $DO_UNDO || $DO_UPDATE || $DO_DISCARD; }; then
    die "$EX_USAGE" "--branch cannot be combined with other action flags (use --wizard for branch + commit + push in one go)."
  fi
  if $DO_MRTEXT && { $DO_COMMIT || $DO_PUSH; }; then
    die "$EX_USAGE" "--mr-text cannot be combined with --commit/--push/--mr."
  fi
}

# -------------------------------------------------- component discovery ------
build_prune_args() {
  PRUNE_ARGS=()
  local d first=true
  for d in $EXCLUDE_DIRS; do
    if $first; then first=false; else PRUNE_ARGS+=(-o); fi
    PRUNE_ARGS+=(-name "$d")
  done
}
find_repos() {
  local root="$1"
  build_prune_args
  { find "$root" -maxdepth "$MAX_DEPTH" \( "${PRUNE_ARGS[@]}" \) -prune -o -name .git -prune -print 2>/dev/null \
    | while IFS= read -r g; do dirname "$g"; done \
    | LC_ALL=C sort; } || true
}

repo_rel_label() {
  local root="${1%/}" dir="${2%/}"
  if [[ "$dir" == "$root" ]]; then
    printf '%s (Main Repo)' "${root##*/}"
  elif [[ "$dir" == "$root/"* ]]; then
    printf '%s' "${dir#"$root"/}"
  else
    printf '%s' "$dir"
  fi
}

show_workspace_dashboard() {
  local root="$1"
  shift
  local -a repos=("$@")
  local i=1 r label br sha porcelain cnt unpushed=0
  step "Workspace Overview (${#repos[@]} repositories under $root)"
  for r in "${repos[@]}"; do
    label=$(repo_rel_label "$root" "$r")
    br=$(git -C "$r" symbolic-ref --short -q HEAD 2>/dev/null || true)
    unpushed=0
    if [[ -z "$br" ]]; then
      sha=$(git -C "$r" rev-parse --short HEAD 2>/dev/null || true)
      br="DETACHED@${sha:-NONE} (manifest-managed)"
    elif ! is_protected "$br"; then
      unpushed=$(git -C "$r" rev-list --count "@{u}..HEAD" -- 2>/dev/null || git -C "$r" rev-list --count "$DEFAULT_REMOTE/$BASE_BRANCH..HEAD" -- 2>/dev/null || echo 0)
    fi
    porcelain=$(git -C "$r" status --porcelain 2>/dev/null || true)
    if [[ -n "$porcelain" ]]; then
      cnt=$(printf '%s\n' "$porcelain" | wc -l | tr -d ' ')
      local up_str=""
      if [[ "$unpushed" -gt 0 ]]; then up_str=", $unpushed unpushed commit(s)"; fi
      printf '%s  [%2d] * %-28s [%-35s] -> %s changed file(s)%s%s\n' "$C_YELLOW" "$i" "$label" "$br" "$cnt" "$up_str" "$C_RESET"
      printf '%s\n' "$porcelain" | head -n 6 | while IFS= read -r line; do
        printf '            %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
      done
      if [[ "$cnt" -gt 6 ]]; then
        printf '            %s... and %d more%s\n' "$C_DIM" "$((cnt - 6))" "$C_RESET"
      fi
    elif [[ "$unpushed" -gt 0 ]]; then
      printf '%s  [%2d] ^ %-28s [%-35s] -> clean (%d unpushed commit(s) ready to push)%s\n' "$C_CYAN" "$i" "$label" "$br" "$unpushed" "$C_RESET"
    else
      printf '%s  [%2d]   %-28s [%-35s] -> clean%s\n' "$C_GREEN" "$i" "$label" "$br" "$C_RESET"
    fi
    i=$((i + 1))
  done
}

show_workspace_health() {
  local root="$1"
  shift
  local -a repos=("$@") changed=() ahead=() on_base=() on_work=()
  local detached_cnt=0 r label br porcelain cnt unpushed=0
  step "Workspace Health"
  printf 'Repositories: %d\n' "${#repos[@]}"
  for r in "${repos[@]}"; do
    label=$(repo_rel_label "$root" "$r")
    br=$(git -C "$r" symbolic-ref --short -q HEAD 2>/dev/null || true)
    unpushed=0
    if [[ -z "$br" ]]; then
      detached_cnt=$((detached_cnt + 1))
    else
      if [[ "$br" == "$BASE_BRANCH" ]]; then
        on_base+=("$label")
      else
        on_work+=("$label [$br]")
      fi
      if ! is_protected "$br"; then
        unpushed=$(git -C "$r" rev-list --count "@{u}..HEAD" -- 2>/dev/null || git -C "$r" rev-list --count "$DEFAULT_REMOTE/$BASE_BRANCH..HEAD" -- 2>/dev/null || echo 0)
      fi
    fi
    porcelain=$(git -C "$r" status --porcelain 2>/dev/null || true)
    if [[ -n "$porcelain" ]]; then
      cnt=$(printf '%s\n' "$porcelain" | wc -l | tr -d ' ')
      changed+=("$label ($cnt file(s))")
    fi
    if [[ "$unpushed" -gt 0 ]]; then
      ahead+=("$label ($unpushed commit(s))")
    fi
  done

  printf '\n%sChanged:%s\n' "$C_YELLOW" "$C_RESET"
  if [[ ${#changed[@]} -gt 0 ]]; then for r in "${changed[@]}"; do printf '  %s\n' "$r"; done; else printf '  none\n'; fi

  printf '\n%sAhead of remote:%s\n' "$C_CYAN" "$C_RESET"
  if [[ ${#ahead[@]} -gt 0 ]]; then for r in "${ahead[@]}"; do printf '  %s\n' "$r"; done; else printf '  none\n'; fi

  printf '\n%sDetached (manifest-managed):%s\n' "$C_DIM" "$C_RESET"
  printf '  %d repos\n' "$detached_cnt"

  printf '\n%sOn %s:%s\n' "$C_GREEN" "$BASE_BRANCH" "$C_RESET"
  if [[ ${#on_base[@]} -gt 0 ]]; then for r in "${on_base[@]}"; do printf '  %s\n' "$r"; done; else printf '  none\n'; fi

  if [[ ${#on_work[@]} -gt 0 ]]; then
    printf '\n%sOn task / feature branches:%s\n' "$C_BOLD" "$C_RESET"
    for r in "${on_work[@]}"; do printf '  %s\n' "$r"; done
  fi
}

match_repos() {
  local root="$1" name="$2" d rel base
  local -a all=()
  MATCHES=()
  name="${name%/}"; name="${name#./}"
  while IFS= read -r d; do
    if [[ -n "$d" ]]; then all+=("$d"); fi
  done < <(find_repos "$root")
  for d in ${all[@]+"${all[@]}"}; do
    rel="${d#"$root"/}"; base="${d##*/}"
    if [[ "$base" == "$name" || "$rel" == "$name" || "$rel" == */"$name" ]]; then MATCHES+=("$d"); fi
  done
  if [[ ${#MATCHES[@]} -eq 0 ]]; then
    name=$(lower "$name")
    for d in ${all[@]+"${all[@]}"}; do
      rel=$(lower "${d#"$root"/}"); base=$(lower "${d##*/}")
      if [[ "$base" == "$name" || "$rel" == "$name" || "$rel" == */"$name" ]]; then MATCHES+=("$d"); fi
    done
  fi
}

resolve_repo() {
  local top="" sup="" root name d found=false
  local -a roots=()
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$top" ]]; then WORKSPACE_ROOT="$top"; else WORKSPACE_ROOT="$PWD"; fi

  if [[ -n "$COMPONENT" ]]; then
    if [[ "$COMPONENT" == *,* ]]; then
      local -a parts=() resolved=()
      local p
      IFS=',' read -r -a parts <<<"$COMPONENT"
      if [[ ${#parts[@]} -gt 1 ]]; then
        for p in "${parts[@]}"; do
          p=$(trim "$p")
          if [[ -z "$p" ]]; then continue; fi
          match_repos "$PWD" "$p"
          if [[ ${#MATCHES[@]} -eq 1 ]]; then
            resolved+=("${MATCHES[0]}")
          elif [[ ${#MATCHES[@]} -gt 1 ]]; then
            if $NONINTERACTIVE; then die "$EX_NOTFOUND" "Ambiguous component '$p'."; fi
            warn "Multiple repos match '$p':"
            pick_from_list "Repository" "${MATCHES[@]}"
            resolved+=("$PICKED")
          else
            die "$EX_NOTFOUND" "No git repository named '$p' found under $PWD."
          fi
        done
        MULTI_REPOS=("${resolved[@]}")
        REPO_DIR="${MULTI_REPOS[0]}"
        return 0
      fi
    fi
    name="${COMPONENT%/}"
    if [[ -d "$name" && -e "$name/.git" ]]; then
      REPO_DIR=$(cd "$name" && pwd); return 0
    fi
    if [[ -n "$top" && ( "${top##*/}" == "$name" || "$top" == */"$name" ) ]]; then
      REPO_DIR="$top"; return 0
    fi
    roots+=("$PWD")
    if [[ -n "$top" && "$top" != "$PWD" ]]; then roots+=("$top"); fi
    if [[ -n "$top" ]]; then sup=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true); fi
    if [[ -n "$sup" ]]; then roots+=("$sup"); fi
    for root in "${roots[@]}"; do
      info "Searching '$root' for git repo '$name'..."
      match_repos "$root" "$name"
      if [[ ${#MATCHES[@]} -gt 0 ]]; then found=true; break; fi
    done
    if ! $found; then
      local plain=""
      build_prune_args
      plain=$(find "$PWD" -maxdepth "$MAX_DEPTH" \( "${PRUNE_ARGS[@]}" \) -prune -o -type d -name "$name" -print 2>/dev/null | head -n 5 || true)
      die "$EX_NOTFOUND" "No git repository named '$name' found under: ${roots[*]}" \
        "Check the spelling, or pass a path:  --component path/to/$name" \
        "${plain:+Folders with that name exist but have no .git (not a repo/submodule): $(printf '%s' "$plain" | tr '\n' ' ')}" \
        "Submodule not checked out?  git submodule update --init --recursive"
    fi
    if [[ ${#MATCHES[@]} -eq 1 ]]; then
      REPO_DIR="${MATCHES[0]}"
    elif $NONINTERACTIVE; then
      warn "Ambiguous: ${#MATCHES[@]} repositories match '$name':"
      for d in "${MATCHES[@]}"; do hint "$d"; done
      die "$EX_NOTFOUND" "Cannot choose without a terminal." \
        "Use a longer path suffix (e.g. --component stack/$name) or the full path."
    else
      warn "Several repositories match '$name' - pick one:"
      pick_from_list "Repository" "${MATCHES[@]}"
      REPO_DIR="$PICKED"
    fi
    return 0
  fi

  local -a all=()
  while IFS= read -r d; do
    if [[ -n "$d" ]]; then all+=("$d"); fi
  done < <(find_repos "$PWD")

  if [[ ${#all[@]} -eq 0 && -n "$top" ]]; then
    REPO_DIR="$top"; return 0
  fi
  if [[ ${#all[@]} -eq 0 ]]; then
    die "$EX_NOTFOUND" "No git repositories found under $PWD (depth $MAX_DEPTH)." \
      "cd to your Main Repo root, or raise GIT_FLOW_MAX_DEPTH"
  fi
  if [[ ${#all[@]} -eq 1 ]]; then
    REPO_DIR="${all[0]}"; return 0
  fi

  show_workspace_dashboard "$PWD" "${all[@]}"
  if $NONINTERACTIVE; then
    if [[ -n "$top" ]]; then REPO_DIR="$top"; return 0; fi
    die "$EX_USAGE" "Multiple repositories found under current folder and no --component given." \
      "Pass -c <component-name> (or run interactively to pick from the list)"
  fi

  printf '\n%s\n' "${C_CYAN}Tip: Type a number (1-${#all[@]}), '2 3' for multi-component branching, 'h' for compact health summary, or 's' to Sync ALL repos.${C_RESET}"
  local sel
  while true; do
    read -r -p "Select repository (1-${#all[@]}, e.g. '2 3', name, 'h' = health, 's' = sync all, 'q' = quit): " sel || die "$EX_ABORT" "Input closed - aborting."
    sel=$(trim "$sel")
    if [[ -z "$sel" ]]; then continue; fi
    if [[ "$sel" == [qQ] ]]; then die "$EX_ABORT" "Cancelled."; fi
    if [[ "$sel" == [hH] ]]; then show_workspace_health "$PWD" "${all[@]}"; printf '\n'; continue; fi
    if [[ "$sel" == [sS0] ]]; then
      DO_SYNC=true
      REPO_DIR="${all[0]}"
      return 0
    fi
    local -a toks=() chosen=()
    read -r -a toks <<<"${sel//,/ }"
    if [[ ${#toks[@]} -gt 1 ]]; then
      local ok_all=true tok
      for tok in "${toks[@]}"; do
        if [[ "$tok" =~ ^[0-9]+$ ]] && [[ "$tok" -ge 1 && "$tok" -le "${#all[@]}" ]]; then
          chosen+=("${all[$((tok - 1))]}")
        else
          match_repos "$PWD" "$tok"
          if [[ ${#MATCHES[@]} -eq 1 ]]; then
            chosen+=("${MATCHES[0]}")
          else
            warn "Could not uniquely match '$tok'."
            ok_all=false; break
          fi
        fi
      done
      if $ok_all && [[ ${#chosen[@]} -gt 1 ]]; then
        MULTI_REPOS=("${chosen[@]}")
        REPO_DIR="${MULTI_REPOS[0]}"
        return 0
      fi
      continue
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le "${#all[@]}" ]]; then
      REPO_DIR="${all[$((sel - 1))]}"
      return 0
    fi
    match_repos "$PWD" "$sel"
    if [[ ${#MATCHES[@]} -eq 1 ]]; then REPO_DIR="${MATCHES[0]}"; return 0; fi
    if [[ ${#MATCHES[@]} -gt 1 ]]; then
      warn "Multiple repos match '$sel':"
      pick_from_list "Repository" "${MATCHES[@]}"
      REPO_DIR="$PICKED"
      return 0
    fi
    warn "No repository matched '$sel'. Enter 1-${#all[@]}, '2 3' for multi-component branching, a component name, 's' to sync all, or 'q' to quit."
  done
}

# ------------------------------------------------ .repo & fetch helpers ------
fetch_dotrepo() {
  if $NO_FETCH; then return 0; fi
  local root="$1" dotrepo
  for dotrepo in "$root/.repo" "$WORKSPACE_ROOT/.repo"; do
    if [[ ! -d "$dotrepo" ]]; then continue; fi
    if git -C "$dotrepo" rev-parse --git-dir >/dev/null 2>&1; then
      info "Found .repo folder ($dotrepo) -> running 'git fetch --all --prune'..."
      git -C "$dotrepo" fetch --all --prune --quiet >/dev/null 2>&1 || true
    fi
    if [[ -d "$dotrepo/manifests" ]] && git -C "$dotrepo/manifests" rev-parse --git-dir >/dev/null 2>&1; then
      info "Found .repo/manifests -> running 'git fetch --all --prune'..."
      git -C "$dotrepo/manifests" fetch --all --prune --quiet >/dev/null 2>&1 || true
    fi
    break
  done
}

resolve_remote_name() {
  REMOTE="$DEFAULT_REMOTE"
  if git remote get-url "$REMOTE" >/dev/null 2>&1; then return 0; fi
  local -a remotes=()
  local r
  while IFS= read -r r; do
    if [[ -n "$r" ]]; then remotes+=("$r"); fi
  done < <(git remote 2>/dev/null || true)
  if [[ ${#remotes[@]} -eq 0 ]]; then
    die "$EX_STATE" "No git remotes are configured in $REPO_DIR." "Add one with: git remote add origin <gitlab-url>"
  fi
  if $REMOTE_EXPLICIT; then
    die "$EX_STATE" "Remote '$REMOTE' is not configured in $REPO_DIR." \
      "Configured remotes: ${remotes[*]}" "Use --remote <name>"
  fi
  for r in "${remotes[@]}"; do
    if git show-ref --verify --quiet "refs/remotes/$r/$BASE_BRANCH"; then
      info "Remote 'origin' not found; auto-selected remote '$r' (has $BASE_BRANCH)."
      REMOTE="$r"
      return 0
    fi
  done
  REMOTE="${remotes[0]}"
  info "Remote 'origin' not found; auto-selected configured remote '$REMOTE'."
}

# ------------------------------------------------------------ preflight -------
is_protected() {
  local b="$1" p
  case "$b" in main|master|develop|release/*) return 0 ;; esac
  if [[ "$b" == "$BASE_BRANCH" ]]; then return 0; fi
  for p in $EXTRA_PROTECTED; do
    # shellcheck disable=SC2254
    case "$b" in $p) return 0 ;; esac
  done
  return 1
}

detect_repo_state() {
  local gd
  gd=$(git rev-parse --absolute-git-dir)
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; then
    die "$EX_STATE" "A rebase is in progress in $REPO_DIR." \
      "Resolve conflicts, then: git add <files> && git rebase --continue" \
      "Or back out safely:      git rebase --abort"
  fi
  if [[ -f "$gd/MERGE_HEAD" ]]; then
    die "$EX_STATE" "A merge is in progress in $REPO_DIR." \
      "Resolve conflicts, then: git add <files> && git commit" \
      "Or back out safely:      git merge --abort"
  fi
  if [[ -f "$gd/CHERRY_PICK_HEAD" ]]; then
    die "$EX_STATE" "A cherry-pick is in progress." "Finish: git cherry-pick --continue" "Or: git cherry-pick --abort"
  fi
  if [[ -f "$gd/REVERT_HEAD" ]]; then
    die "$EX_STATE" "A revert is in progress." "Finish: git revert --continue" "Or: git revert --abort"
  fi
  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    die "$EX_STATE" "Unresolved merge conflicts exist in the working tree." \
      "See them: git status" "Fix, then: git add <files>"
  fi
}

net_failure() {
  local out="$1"
  case "$out" in
    *"Permission denied"*|*"Authentication failed"*|*"could not read Username"*|*"returned error: 401"*|*"returned error: 403"*|*"Host key verification failed"*)
      die "$EX_NETWORK" "Authentication to '$REMOTE' failed." \
        "SSH: 'ssh -T <git-host>' and 'ssh-add -l' show whether your key is loaded" \
        "HTTPS: refresh your token / credential helper (git credential-manager, or re-enter PAT)" \
        "Also confirm you have access to this repository on the server" ;;
    *"Could not resolve host"*|*"timed out"*|*"Connection refused"*|*"Network is unreachable"*|*"unable to access"*)
      die "$EX_NETWORK" "Cannot reach '$REMOTE' (network/DNS/proxy)." \
        "Are you on the VPN? Is the proxy configured (git config --get http.proxy)?" \
        "Work offline with --no-fetch (pushing still needs network)" ;;
    *)
      die "$EX_NETWORK" "Fetching from '$REMOTE' failed." "git said: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')" ;;
  esac
}

setup_ssh_env() {
  if [[ -z "${GIT_SSH_COMMAND:-}" && -z "${GIT_SSH:-}" && -z "$(git config --get core.sshCommand 2>/dev/null || true)" ]]; then
    export GIT_SSH_COMMAND="ssh -o ConnectTimeout=20"
  fi
  if $NONINTERACTIVE; then export GIT_TERMINAL_PROMPT=0; fi
}

preflight() {
  step "Pre-flight checks"
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$EX_STATE" "'$REPO_DIR' is not a valid git working tree." "Is the submodule initialised? git submodule update --init"
  fi
  detect_repo_state
  if git symbolic-ref -q HEAD >/dev/null 2>&1; then
    DETACHED=false; CUR_BRANCH=$(git symbolic-ref --short HEAD)
  else
    DETACHED=true; CUR_BRANCH=""
  fi
  if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    die "$EX_STATE" "This repository has no commits yet." "Make an initial commit or clone from the remote first."
  fi
  resolve_remote_name
  ok "Repository state is clean (no rebase/merge/cherry-pick in progress)."
  if $NO_FETCH; then
    warn "Skipping fetch (--no-fetch): remote refs may be stale."
  else
    fetch_dotrepo "$WORKSPACE_ROOT"
    info "Running 'git fetch --all --prune' in $REPO_DIR..."
    local out
    if ! out=$(git fetch --all --prune --quiet 2>&1); then net_failure "$out"; fi
    resolve_remote_name
    ok "All remotes fetched and refs up to date (using remote '$REMOTE')."
  fi
}

show_categorized_changes() {
  local -a rhapsody=() autosar=() deleted=() other=()
  local ln st p tag p_low
  while IFS= read -r ln; do
    if [[ ${#ln} -lt 4 ]]; then continue; fi
    st="${ln:0:2}"
    p="${ln:3}"
    if [[ "$p" == *" -> "* ]]; then p="${p##* -> }"; fi
    p="${p#\"}"; p="${p%\"}"
    tag=$(trim "$st")
    p_low=$(lower "$p")
    if [[ "$st" == *D* ]]; then
      deleted+=("[$tag] $p")
    elif [[ "$p_low" =~ \.(rpwx|rpy|sbsx|sbs|cls|clsx|cmp|cmpx|omd|omdx|msc|mscx|ucd|ucdx|hep|prp|rpl|rplx)$ ]]; then
      rhapsody+=("[$tag] $p")
    elif [[ "$p_low" =~ \.(arxml|dbc|ldf|a2l|cdd|odx|pdx|ecuc|dpa|dcf)$ ]]; then
      autosar+=("[$tag] $p")
    else
      other+=("[$tag] $p")
    fi
  done < <(git -c core.quotepath=off status --porcelain 2>/dev/null || true)

  if [[ ${#rhapsody[@]} -eq 0 && ${#autosar[@]} -eq 0 && ${#deleted[@]} -eq 0 && ${#other[@]} -eq 0 ]]; then
    ok "Working tree clean."
    return 0
  fi
  local f
  if [[ ${#rhapsody[@]} -gt 0 ]]; then
    printf '\n%s  Rhapsody Changes (%d):%s\n' "$C_CYAN" "${#rhapsody[@]}" "$C_RESET"
    for f in "${rhapsody[@]}"; do printf '    %s\n' "$f"; done
  fi
  if [[ ${#autosar[@]} -gt 0 ]]; then
    printf '\n%s  AUTOSAR / ARXML Changes (%d):%s\n' "$C_YELLOW" "${#autosar[@]}" "$C_RESET"
    for f in "${autosar[@]}"; do printf '    %s\n' "$f"; done
  fi
  if [[ ${#deleted[@]} -gt 0 ]]; then
    printf '\n%s  Deleted Artifacts (%d):%s\n' "$C_RED" "${#deleted[@]}" "$C_RESET"
    for f in "${deleted[@]}"; do printf '    %s\n' "$f"; done
  fi
  if [[ ${#other[@]} -gt 0 ]]; then
    printf '\n%s  Source / Other Changes (%d):%s\n' "$C_BOLD" "${#other[@]}" "$C_RESET"
    for f in "${other[@]}"; do printf '    %s\n' "$f"; done
  fi
}

show_status() {
  step "Repository status"
  info "Repo   : $REPO_DIR"
  if $DETACHED; then info "HEAD   : DETACHED at $(git rev-parse --short HEAD) (manifest-managed)"; else info "Branch : $CUR_BRANCH"; fi
  show_categorized_changes
}

ensure_base_ref() {
  if git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BASE_BRANCH^{commit}" >/dev/null; then return 0; fi
  if ! $NO_FETCH; then
    info "Branch '$BASE_BRANCH' not in local remote-tracking refs yet; fetching '$BASE_BRANCH' from '$REMOTE'..."
    git fetch --quiet "$REMOTE" "+refs/heads/$BASE_BRANCH:refs/remotes/$REMOTE/$BASE_BRANCH" >/dev/null 2>&1 || true
    if git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BASE_BRANCH^{commit}" >/dev/null; then
      ok "Found '$REMOTE/$BASE_BRANCH' on remote."
      return 0
    fi
  fi
  local def="" rl cand
  def=$(git symbolic-ref --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)
  def="${def#"$REMOTE"/}"
  if [[ -z "$def" ]]; then
    for cand in develop main master; do
      if git rev-parse --verify --quiet "refs/remotes/$REMOTE/$cand^{commit}" >/dev/null; then def="$cand"; break; fi
    done
  fi
  if [[ -n "$def" && "$def" != "$BASE_BRANCH" ]] && ! $NONINTERACTIVE; then
    warn "Base branch '$BASE_BRANCH' not found on '$REMOTE'; found '$def' on remote."
    if confirm "Use '$def' as the base branch for this component?" y y; then BASE_BRANCH="$def"; return 0; fi
  fi
  rl=$(git branch -r | tr '\n' ' ' || true)
  die "$EX_NOTFOUND" "Base branch '$REMOTE/$BASE_BRANCH' does not exist." \
    "Use --base <branch> or export GIT_FLOW_BASE=<branch>" \
    "Remote branches: ${rl:0:300}" \
    "${NO_FETCH:+}$( [[ "$NO_FETCH" == true ]] && echo 'You used --no-fetch: refs may be missing; run without it.' || true)"
}

sync_local_base_branch() {
  local base="$BASE_BRANCH" remote="$REMOTE" remote_ref="$REMOTE/$BASE_BRANCH"
  step "Syncing local '$base' branch with '$remote_ref'"
  if git show-ref --verify --quiet "refs/heads/$base"; then
    if $DETACHED || [[ "$CUR_BRANCH" != "$base" ]]; then
      info "Switching to local '$base' branch..."
      if ! try git checkout "$base"; then
        warn "Could not checkout local '$base' (an untracked file may conflict). Will create branch directly off '$remote_ref'."
        return 1
      fi
      CUR_BRANCH="$base"; DETACHED=false
    fi
    git branch "--set-upstream-to=$remote_ref" "$base" >/dev/null 2>&1 || true
    info "Pulling latest changes into '$base' (git pull --ff-only $remote $base)..."
    if ! try git pull --ff-only "$remote" "$base"; then
      warn "Local '$base' could not be fast-forwarded (it may have local commits). Will create branch directly off '$remote_ref'."
      return 1
    fi
    ok "Local '$base' is checked out and up to date with '$remote_ref'."
    return 0
  else
    info "Local '$base' was not listed in 'git branch' yet (only existed on remote as '$remote_ref')."
    info "Creating local '$base' tracking '$remote_ref'..."
    if ! try git checkout -b "$base" --track "$remote_ref"; then
      warn "Could not create local '$base' (an untracked file may conflict). Will create branch directly off '$remote_ref'."
      return 1
    fi
    CUR_BRANCH="$base"; DETACHED=false
    ok "Local '$base' created, checked out, and synced with '$remote_ref'."
    return 0
  fi
}

do_sync_all() {
  local root="$1" d label rem cur dirty
  local -a repos=()
  while IFS= read -r d; do
    if [[ -n "$d" ]]; then repos+=("$d"); fi
  done < <(find_repos "$root")
  if [[ ${#repos[@]} -eq 0 ]]; then
    die "$EX_NOTFOUND" "No git repositories found under $root."
  fi
  step "Syncing ALL (${#repos[@]}) repositories to latest '$BASE_BRANCH'"
  fetch_dotrepo "$root"

  local synced=0 skipped=0 failed=0
  for d in "${repos[@]}"; do
    label=$(repo_rel_label "$root" "$d")
    printf '\n%s--- [%s] ---%s\n' "$C_CYAN" "$label" "$C_RESET"
    cd "$d" || { failed=$((failed + 1)); continue; }
    REPO_DIR="$d"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      warn "Skipping '$label' (not a valid working tree)."
      skipped=$((skipped + 1)); continue
    fi
    rem="$DEFAULT_REMOTE"
    if ! git remote get-url "$rem" >/dev/null 2>&1; then
      rem=$(git remote 2>/dev/null | head -n 1 || true)
    fi
    if [[ -z "$rem" ]]; then
      warn "Skipping '$label' (no git remote configured)."
      skipped=$((skipped + 1)); continue
    fi
    if ! $NO_FETCH; then
      info "Running 'git fetch --all --prune'..."
      if ! git fetch --all --prune --quiet >/dev/null 2>&1; then
        warn "Fetch failed in '$label'."
        failed=$((failed + 1)); continue
      fi
    fi
    if ! git rev-parse --verify --quiet "refs/remotes/$rem/$BASE_BRANCH^{commit}" >/dev/null; then
      if ! $NO_FETCH; then
        git fetch --quiet "$rem" "+refs/heads/$BASE_BRANCH:refs/remotes/$rem/$BASE_BRANCH" >/dev/null 2>&1 || true
      fi
    fi
    if ! git rev-parse --verify --quiet "refs/remotes/$rem/$BASE_BRANCH^{commit}" >/dev/null; then
      warn "Remote '$rem' does not have branch '$BASE_BRANCH' in '$label' - fetched remotes only."
      skipped=$((skipped + 1)); continue
    fi
    dirty=$(git status --porcelain --untracked-files=no 2>/dev/null || true)
    if [[ -n "$dirty" ]]; then
      warn "Has uncommitted tracked changes - fetched latest refs, kept current branch untouched."
      skipped=$((skipped + 1)); continue
    fi
    cur=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
    if [[ -n "$cur" && "$cur" != "$BASE_BRANCH" ]] && ! is_protected "$cur"; then
      warn "Currently on active work branch '$cur' - fetched latest refs, kept branch '$cur' checked out."
      skipped=$((skipped + 1)); continue
    fi
    if git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
      if [[ "$cur" != "$BASE_BRANCH" ]]; then
        if ! try git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
          warn "Could not switch to '$BASE_BRANCH' in '$label' (untracked file collision?)."
          failed=$((failed + 1)); continue
        fi
      fi
      git branch "--set-upstream-to=$rem/$BASE_BRANCH" "$BASE_BRANCH" >/dev/null 2>&1 || true
      if try git pull --ff-only "$rem" "$BASE_BRANCH"; then
        ok "'$label' is now on '$BASE_BRANCH' and up to date with '$rem/$BASE_BRANCH'."
        synced=$((synced + 1))
      else
        warn "Could not fast-forward '$BASE_BRANCH' in '$label'."
        failed=$((failed + 1))
      fi
    else
      if try git checkout -b "$BASE_BRANCH" --track "$rem/$BASE_BRANCH"; then
        ok "'$label' created local '$BASE_BRANCH' tracking '$rem/$BASE_BRANCH' and is up to date."
        synced=$((synced + 1))
      else
        warn "Could not checkout '$BASE_BRANCH' in '$label'."
        failed=$((failed + 1))
      fi
    fi
  done
  step "Workspace Sync Summary"
  ok "Synced to '$BASE_BRANCH': $synced   |   Kept as-is (dirty/feature branch): $skipped   |   Failed: $failed"
}

# ------------------------------------------------- input collection -----------
sanitize_desc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//'
}

DETECTED_JIRA=""; DETECTED_JIRA_SRC=""
detect_jira_id() {
  DETECTED_JIRA=""; DETECTED_JIRA_SRC=""
  local found=""
  if [[ -n "$CUR_BRANCH" ]]; then
    found=$(printf '%s' "$CUR_BRANCH" | grep -oE "$JIRA_PATTERN" | head -n 1 || true)
    if [[ -n "$found" ]]; then DETECTED_JIRA="$found"; DETECTED_JIRA_SRC="current branch '$CUR_BRANCH'"; return 0; fi
  fi
  found=$(git -c core.quotepath=off status --porcelain 2>/dev/null | grep -oE "$JIRA_PATTERN" | head -n 1 || true)
  if [[ -n "$found" ]]; then DETECTED_JIRA="$found"; DETECTED_JIRA_SRC="changed file name"; return 0; fi
  found=$( { git diff --cached -U0 2>/dev/null || true; git diff -U0 2>/dev/null || true; } | grep -E '^\+[^+]' | head -n 500 | grep -oE "$JIRA_PATTERN" | head -n 1 || true)
  if [[ -n "$found" ]]; then DETECTED_JIRA="$found"; DETECTED_JIRA_SRC="changed file contents"; return 0; fi
  return 1
}

collect_branch_inputs() {
  if [[ -z "$JIRA_ID" ]]; then
    if detect_jira_id; then
      if $JIRA_FROM_BRANCH; then
        JIRA_ID="$DETECTED_JIRA"
        info "Auto-detected Jira ID '$JIRA_ID' from $DETECTED_JIRA_SRC (--jira-from-branch)."
      elif ! $NONINTERACTIVE; then
        info "Auto-detected Jira ID '$DETECTED_JIRA' from $DETECTED_JIRA_SRC (press Enter to use it)."
        LAST_JIRA_ID="$DETECTED_JIRA"
      fi
    elif $JIRA_FROM_BRANCH; then
      die "$EX_USAGE" "Could not extract a Jira ID from current branch or changed files." "Pass --jira OSKDC33837-14809 explicitly"
    fi
  fi

  local tries=0
  while true; do
    if [[ -z "$JIRA_ID" ]]; then
      if ! prompt "Jira Task ID (e.g. OSKDC33837-14809)" "$LAST_JIRA_ID"; then
        die "$EX_USAGE" "Missing Jira ID." "Pass --jira OSKDC33837-14809 or --jira-from-branch"
      fi
      JIRA_ID="$REPLY_VAL"
    fi
    JIRA_ID=$(upper "$(trim "$JIRA_ID")")
    if [[ "$JIRA_ID" =~ $JIRA_REGEX ]]; then LAST_JIRA_ID="$JIRA_ID"; break; fi
    if $NONINTERACTIVE; then
      die "$EX_USAGE" "Invalid Jira ID '$JIRA_ID'." "Expected a key like OSKDC33837-14809 (LETTERS-NUMBER)"
    fi
    warn "Invalid Jira ID '$JIRA_ID' - expected something like OSKDC33837-14809."
    JIRA_ID=""; tries=$((tries + 1))
    if [[ $tries -ge 3 ]]; then die "$EX_USAGE" "Too many invalid Jira IDs."; fi
  done

  if [[ -z "$BRANCH_TYPE" ]]; then
    if $NONINTERACTIVE; then
      BRANCH_TYPE="none"
      info "No --type given; defaulting to 'none' (direct Jira ID + title)."
    else
      printf '%s\n' "Select branch prefix / type:" \
        "  [1] none     (direct Jira ID + title: $JIRA_ID-your-title)" \
        "  [2] feature  (feature/$JIRA_ID-your-title)" \
        "  [3] bugfix   (bugfix/$JIRA_ID-your-title)" \
        "  [4] hotfix   (hotfix/$JIRA_ID-your-title)"
      prompt "Enter number" "1" || true
      case "$(lower "$REPLY_VAL")" in
        1|none|direct|jira) BRANCH_TYPE="none" ;;
        2|feature) BRANCH_TYPE="feature" ;;
        3|bugfix) BRANCH_TYPE="bugfix" ;;
        4|hotfix) BRANCH_TYPE="hotfix" ;;
        *) warn "Unrecognised choice; using 'none' (direct Jira ID + title)."; BRANCH_TYPE="none" ;;
      esac
    fi
  fi

  tries=0
  while true; do
    if [[ -z "$DESC" ]]; then
      if ! prompt "Branch title / short description (required, e.g. update-can-parser)" ""; then
        die "$EX_USAGE" "Missing branch title / description." "Pass --desc \"short description\""
      fi
      DESC="$REPLY_VAL"
    fi
    SANITIZED=$(sanitize_desc "$DESC")
    if [[ -n "$SANITIZED" ]]; then break; fi
    if $NONINTERACTIVE; then die "$EX_USAGE" "Branch title '$DESC' has no letters or digits."; fi
    warn "Branch title / description is required and must contain letters or digits."
    DESC=""; tries=$((tries + 1))
    if [[ $tries -ge 3 ]]; then die "$EX_USAGE" "Too many invalid descriptions."; fi
  done
  local core_name="${JIRA_ID}-${SANITIZED}"
  if [[ "$BRANCH_TYPE" == "none" ]]; then
    BRANCH_NAME="$core_name"
  else
    BRANCH_NAME="${BRANCH_TYPE}/${core_name}"
  fi
  if ! git check-ref-format --branch "$BRANCH_NAME" >/dev/null 2>&1; then
    die "$EX_USAGE" "'$BRANCH_NAME' is not a valid git branch name." "Change --desc"
  fi
  info "Branch name: ${C_BOLD}$BRANCH_NAME${C_RESET}"
}

check_branch_free() {
  if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    if ! $NONINTERACTIVE; then
      warn "Branch '$BRANCH_NAME' already exists locally."
      if confirm "Switch to existing local branch '$BRANCH_NAME' instead?" y n; then
        run git checkout "$BRANCH_NAME"
        CUR_BRANCH="$BRANCH_NAME"; DETACHED=false
        return 1
      fi
    fi
    die "$EX_STATE" "Branch '$BRANCH_NAME' already exists locally." \
      "Continue on it:   git checkout $BRANCH_NAME" "Or choose a different --desc"
  fi
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH_NAME"; then
    if ! $NONINTERACTIVE; then
      warn "Branch '$BRANCH_NAME' already exists on '$REMOTE'."
      if confirm "Check out and track existing remote branch '$REMOTE/$BRANCH_NAME'?" y n; then
        run git checkout -b "$BRANCH_NAME" --track "$REMOTE/$BRANCH_NAME"
        CUR_BRANCH="$BRANCH_NAME"; DETACHED=false
        return 1
      fi
    fi
    die "$EX_STATE" "Branch '$BRANCH_NAME' already exists on '$REMOTE'." \
      "Check it out:  git checkout -b $BRANCH_NAME $REMOTE/$BRANCH_NAME" "Or choose a different --desc"
  fi
  return 0
}

# ------------------------------------------------------- action: branch ------
guard_dirty_for_branch() {
  CARRY_CHANGES=false
  local changes
  changes=$(git status --porcelain --untracked-files=no)
  if [[ -z "$changes" ]]; then return 0; fi
  warn "Uncommitted changes detected in tracked files:"
  git status -s --untracked-files=no
  if $CARRY_FLAG; then
    info "Carrying uncommitted changes to the new branch (--carry)."
    CARRY_CHANGES=true
    return 0
  fi
  if $AUTO_STASH; then
    STASH_MSG="git_flow auto-stash $(date +%Y%m%d-%H%M%S) before $BRANCH_NAME"
    run git stash push -m "$STASH_MSG"
    if ! $DRY_RUN; then STASH_CREATED=true; fi
    ok "Changes stashed."
    return 0
  fi
  if $NONINTERACTIVE; then
    die "$EX_STATE" "Uncommitted changes detected in tracked files." \
      "Pass --carry to carry them onto the new branch, or --stash to stash them first"
  fi
  printf '\n%s\n' \
    "How would you like to handle these uncommitted changes?" \
    "  [1] Carry changes to new branch (recommended - keeps modified files untouched)" \
    "  [2] Stash changes and create clean branch off latest $BASE_BRANCH" \
    "  [3] Cancel"
  prompt "Enter choice" "1" || true
  case "$(lower "$REPLY_VAL")" in
    1|carry)
      CARRY_CHANGES=true
      info "Will carry your uncommitted changes onto the new branch." ;;
    2|stash)
      STASH_MSG="git_flow auto-stash $(date +%Y%m%d-%H%M%S) before $BRANCH_NAME"
      run git stash push -m "$STASH_MSG"
      if ! $DRY_RUN; then STASH_CREATED=true; fi
      ok "Changes stashed." ;;
    3|cancel|q|quit)
      die "$EX_ABORT" "Cancelled - no branch was created and your files were not touched." ;;
    *)
      warn "Unrecognised choice; carrying changes to the new branch."
      CARRY_CHANGES=true ;;
  esac
}

handle_detached_for_branch() {
  local sha rescue
  sha=$(git rev-parse --short HEAD)
  if [[ -z "$(git for-each-ref --contains HEAD --count=1 refs/heads refs/remotes refs/tags)" ]]; then
    warn "HEAD is detached at $sha and those commits are not on any branch - leaving would orphan them."
    rescue="rescue/detached-$sha"
    if confirm "Create safety branch '$rescue' to keep them?" y y; then
      run git branch "$rescue"
      ok "Kept your commits on '$rescue'."
    else
      die "$EX_STATE" "Aborted to avoid orphaning commits." "Keep them: git branch rescue/my-work"
    fi
  else
    info "Detached HEAD at $sha (commits are reachable from other refs - safe to leave)."
  fi
}

do_branch() {
  ensure_base_ref
  collect_branch_inputs
  if ! check_branch_free; then
    ok "Now on existing branch ${C_BOLD}$BRANCH_NAME${C_RESET}."
    return 0
  fi
  if $DETACHED; then handle_detached_for_branch; fi
  guard_dirty_for_branch
  if $CARRY_CHANGES; then
    step "Creating branch '$BRANCH_NAME' (carrying uncommitted changes)"
    run git checkout -b "$BRANCH_NAME"
    ok "Now on ${C_BOLD}$BRANCH_NAME${C_RESET} (your uncommitted changes were carried over safely without touching files on disk)."
    local behind_base
    behind_base=$(git rev-list --count "HEAD..$REMOTE/$BASE_BRANCH" -- 2>/dev/null || echo 0)
    if [[ "$behind_base" -gt 0 ]]; then
      info "Note: Your current base is $behind_base commit(s) behind $REMOTE/$BASE_BRANCH."
      hint "After committing your changes, you can run [7] Update branch with latest $BASE_BRANCH before pushing."
    fi
  else
    if sync_local_base_branch; then
      step "Creating branch '$BRANCH_NAME'"
      run git checkout -b "$BRANCH_NAME"
    else
      step "Creating branch off $REMOTE/$BASE_BRANCH"
      run git checkout -b "$BRANCH_NAME" --no-track "$REMOTE/$BASE_BRANCH"
    fi
    ok "Now on ${C_BOLD}$BRANCH_NAME${C_RESET} (branched from latest $BASE_BRANCH)."
  fi
  printf '\n%s\n' "Next:  edit/review code, then run from Main Repo:"
  printf '%s\n' "  $SELF"
}

# --------------------------------------------- rescue / protected handling ----
rescue_to_branch() {
  local reason="$1" pending ahead=0 where rec_jira
  where="${CUR_BRANCH:-DETACHED HEAD}"
  detect_jira_id || true
  rec_jira="${JIRA_ID:-${DETECTED_JIRA:-${LAST_JIRA_ID:-OSKDC33837-14809}}}"
  printf '\n%s\n' "${C_RED}================================================================${C_RESET}" >&2
  printf '%s\n'   "${C_RED}  WARNING: Protected Branch / Detached HEAD Detected!${C_RESET}" >&2
  printf '%s\n'   "${C_YELLOW}  You are currently on:   $where${C_RESET}" >&2
  printf '%s\n'   "${C_YELLOW}  Creating a commit directly on '$where' is NOT RECOMMENDED / BLOCKED.${C_RESET}" >&2
  printf '%s\n'   "${C_CYAN}  Recommended branch:     ${rec_jira}-short-description${C_RESET}" >&2
  printf '%s\n'   "${C_RED}================================================================${C_RESET}" >&2
  warn "$reason"
  pending=$(git status --porcelain)
  if ! $DETACHED && git show-ref --verify --quiet "refs/remotes/$REMOTE/$CUR_BRANCH"; then
    ahead=$(git rev-list --count "$REMOTE/$CUR_BRANCH..HEAD" --)
  fi
  if [[ -z "$pending" && "$ahead" -eq 0 && "$DETACHED" == false ]]; then
    die "$EX_PROTECTED" "You are on protected branch '$CUR_BRANCH' with nothing to move." \
      "Start new work with:  $SELF --branch --jira $rec_jira --desc \"short description\""
  fi
  if $NONINTERACTIVE && { [[ -z "$JIRA_ID" ]] || [[ -z "$DESC" ]]; }; then
    die "$EX_PROTECTED" "Refusing to commit/push on '$where'." \
      "Re-run with --jira $rec_jira --desc \"title\" (and optional --type) to move your work to a new branch automatically" \
      "Or create it yourself: git checkout -b ${rec_jira}-short-desc"
  fi
  if ! confirm "Create a new Jira branch and move your current work (uncommitted changes + $ahead local commit(s)) onto it now?" y y; then
    die "$EX_PROTECTED" "Aborted - nothing was changed." "Create a branch first: git checkout -b ${rec_jira}-short-desc"
  fi
  collect_branch_inputs
  if check_branch_free; then
    if [[ "$ahead" -gt 0 ]]; then
      warn "$ahead local commit(s) on '$CUR_BRANCH' move into the new branch. Local '$CUR_BRANCH' stays ahead of $REMOTE."
      hint "After your MR merges, realign it:  git checkout $CUR_BRANCH && git reset --hard $REMOTE/$CUR_BRANCH"
    fi
    run git checkout -b "$BRANCH_NAME"
  fi
  CUR_BRANCH="$BRANCH_NAME"; DETACHED=false
  ok "Work moved to ${C_BOLD}$BRANCH_NAME${C_RESET}."
}

ensure_work_branch() {
  if $DETACHED; then
    rescue_to_branch "HEAD is detached - commits made here are easily lost."
  elif is_protected "$CUR_BRANCH"; then
    rescue_to_branch "'$CUR_BRANCH' is a protected branch - direct commits/pushes are blocked."
  fi
}

check_branch_convention() {
  if [[ "$CUR_BRANCH" =~ $BRANCH_REGEX ]]; then return 0; fi
  warn "Branch '$CUR_BRANCH' does not match <JIRA-ID>-<title> or <feature|bugfix|hotfix>/<JIRA-ID>-<title>."
  hint "Pipelines/MR rules may reject it. Rename: git branch -m $CUR_BRANCH PROJ-123-short-desc"
  if $FORCE; then warn "Continuing because of --force."; return 0; fi
  if confirm "Continue anyway?" n n; then return 0; fi
  die "$EX_STATE" "Stopped: branch name violates the naming convention." "Rename it (see above) or pass --force"
}

resolve_commit_jira() {
  local from_branch=""
  from_branch=$(printf '%s' "$CUR_BRANCH" | grep -oE "$JIRA_PATTERN" | head -n 1 || true)
  if [[ -n "$JIRA_ID" ]]; then
    JIRA_ID=$(upper "$(trim "$JIRA_ID")")
    if ! [[ "$JIRA_ID" =~ $JIRA_REGEX ]]; then
      die "$EX_USAGE" "Invalid Jira ID '$JIRA_ID'." "Expected a key like PROJ-123"
    fi
    if [[ -n "$from_branch" && "$from_branch" != "$JIRA_ID" ]]; then
      warn "Branch '$CUR_BRANCH' is for $from_branch but you passed $JIRA_ID."
      if ! $FORCE && ! confirm "Commit under $JIRA_ID anyway?" n n; then
        die "$EX_USAGE" "Jira ID mismatch - stopped to avoid a mis-linked commit." \
          "Use --jira $from_branch, or rename the branch, or pass --force"
      fi
    fi
  elif [[ -n "$from_branch" ]]; then
    JIRA_ID="$from_branch"
    info "Jira ID auto-detected from branch: $JIRA_ID"
  else
    if ! prompt "Jira Task ID (e.g. PROJ-123)" "$LAST_JIRA_ID"; then
      die "$EX_USAGE" "Cannot infer a Jira ID from branch '$CUR_BRANCH'." "Pass --jira PROJ-123"
    fi
    JIRA_ID=$(upper "$REPLY_VAL")
  fi
  if ! [[ "$JIRA_ID" =~ $JIRA_REGEX ]]; then
    die "$EX_USAGE" "Invalid Jira ID '$JIRA_ID'." "Expected a key like PROJ-123"
  fi
  LAST_JIRA_ID="$JIRA_ID"
}

format_commit_message() {
  local m="$COMMIT_MSG" re key tries=0
  re="^\\[?(${JIRA_PATTERN})\\]?([[:space:]]*[:-][[:space:]]*|[[:space:]]+|$)(.*)\$"
  while true; do
    if [[ -z "$m" ]]; then
      if ! prompt "Commit description ($JIRA_ID will be added automatically)" ""; then
        die "$EX_USAGE" "Commit message is empty." "Pass --commit \"description\""
      fi
      m="$REPLY_VAL"
    fi
    m=$(printf '%s' "$m" | tr '\r\n\t' '   ' | sed -E 's/ +/ /g; s/^ //; s/ $//')
    local m_up
    m_up=$(upper "$m")
    if [[ "$m_up" =~ $re ]]; then
      key="${BASH_REMATCH[1]}"
      if [[ "$key" != "$JIRA_ID" ]]; then
        die "$EX_USAGE" "Commit message has a different Jira ID ($key) than the branch ($JIRA_ID)." "Fix the message or --jira"
      fi
      m=$(printf '%s' "$m" | sed -E "s/^\\[?[A-Za-z][A-Za-z0-9_]*-[0-9]+\\]?([[:space:]]*[:-][[:space:]]*|[[:space:]]+|$)//")
    fi
    if [[ -n "$m" ]]; then break; fi
    if $NONINTERACTIVE; then
      die "$EX_USAGE" "Commit message must include a description after $JIRA_ID." "Pass --commit \"what you changed\""
    fi
    warn "Commit message cannot be just the Jira ID - please add a description of what changed."
    m=""; tries=$((tries + 1))
    if [[ $tries -ge 3 ]]; then die "$EX_USAGE" "Too many empty commit descriptions."; fi
  done
  FORMATTED_MSG="${JIRA_ID}: ${m}"
  if [[ ${#FORMATTED_MSG} -gt 72 ]]; then warn "Commit subject is ${#FORMATTED_MSG} chars (>72); consider shortening."; fi
}

candidate_files() {
  if $HAS_STAGED; then
    git -c core.quotepath=off diff --cached --name-only
  else
    git -c core.quotepath=off ls-files -m
    git -c core.quotepath=off ls-files -o --exclude-standard
  fi
}

check_sensitive_files() {
  local bad
  bad=$( { candidate_files || true; } | grep -Ei '(^|/)(\.env(\..+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]+\.(pem|p12|pfx|jks|keystore|key))$' | grep -Eiv '\.(example|sample|template|dist)$' || true)
  if [[ -z "$bad" ]]; then return 0; fi
  warn "Files that look like secrets are about to be committed:"
  printf '%s\n' "$bad" | while IFS= read -r f; do printf '       %s\n' "$f" >&2; done
  if $FORCE; then warn "Continuing because of --force."; return 0; fi
  if confirm "Commit them anyway?" n n; then return 0; fi
  die "$EX_STATE" "Stopped: possible secrets in the commit." \
    "Add them to .gitignore, or stage only what you want: git add <files>" "Override (not recommended): --force"
}

has_unpushed_commits() {
  local n=0
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$CUR_BRANCH"; then
    n=$(git rev-list --count "$REMOTE/$CUR_BRANCH..HEAD" --)
  elif git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BASE_BRANCH" >/dev/null; then
    n=$(git rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" --)
  fi
  if [[ "$n" -gt 0 ]]; then return 0; else return 1; fi
}

select_files_interactively() {
  local -a files=() chosen=()
  local f i=1 sel tok valid
  while IFS= read -r f; do
    if [[ -n "$f" ]]; then files+=("$f"); fi
  done < <(candidate_files)
  if [[ ${#files[@]} -eq 0 ]]; then die "$EX_STATE" "No modified or untracked files found to stage."; fi
  printf '\n'
  info "Select specific files to stage for this commit:"
  for f in "${files[@]}"; do
    printf '  [%d] %s\n' "$i" "$f"
    i=$((i + 1))
  done
  while true; do
    read -r -p "Enter file numbers separated by space/comma (e.g. 1 3, 'a' = all, 'q' = quit): " sel || die "$EX_ABORT" "Input closed - aborting."
    sel=$(trim "$sel")
    if [[ -z "$sel" ]]; then continue; fi
    if [[ "$sel" == [qQ] ]]; then die "$EX_ABORT" "Cancelled."; fi
    if [[ "$sel" == [aA] ]]; then
      run git add -A
      HAS_STAGED=true
      return 0
    fi
    chosen=()
    valid=true
    for tok in ${sel//,/ }; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [[ "$tok" -ge 1 && "$tok" -le "${#files[@]}" ]]; then
        chosen+=("${files[$((tok - 1))]}")
      else
        valid=false; break
      fi
    done
    if $valid && [[ ${#chosen[@]} -gt 0 ]]; then
      run git add -- "${chosen[@]}"
      HAS_STAGED=true
      info "Staged selected files:"
      git diff --cached --stat
      return 0
    fi
    warn "Please enter numbers between 1 and ${#files[@]} (e.g. 1 2), 'a' for all, or 'q' to quit."
  done
}

RHAPSODY_MODEL_FILES=()
collect_rhapsody_model_files() {
  RHAPSODY_MODEL_FILES=()
  local ln p p_low
  while IFS= read -r ln; do
    if [[ ${#ln} -lt 4 ]]; then continue; fi
    p="${ln:3}"
    if [[ "$p" == *" -> "* ]]; then p="${p##* -> }"; fi
    p="${p#\"}"; p="${p%\"}"
    p_low=$(lower "$p")
    if [[ "$p_low" =~ \.(rpwx|sbsx|rpy)$ ]]; then
      RHAPSODY_MODEL_FILES+=("$p")
    fi
  done < <(git -c core.quotepath=off status --porcelain 2>/dev/null || true)
}

stage_and_commit() {
  step "Commit"
  if [[ -z "$(git config user.email 2>/dev/null || true)" || -z "$(git config user.name 2>/dev/null || true)" ]]; then
    die "$EX_STATE" "git user.name / user.email are not configured." \
      "git config user.name \"Your Name\"" "git config user.email you@company.com"
  fi
  HAS_STAGED=false
  if ! git diff --cached --quiet; then HAS_STAGED=true; fi
  local pending
  pending=$(git status --porcelain)
  if ! $HAS_STAGED && [[ -z "$pending" ]]; then
    if $DO_PUSH && has_unpushed_commits; then
      info "Nothing new to commit - will push the existing commits."
      return 0
    fi
    die "$EX_STATE" "Nothing to commit - working tree is clean." \
      "Edit files first, or use --push on its own to push existing commits."
  fi
  format_commit_message
  if $HAS_STAGED; then
    info "Committing what is already staged (other edits are left out):"
    git diff --cached --stat
  else
    info "Nothing staged yet. Changes in this component:"
    show_categorized_changes
    collect_rhapsody_model_files
    if $MODEL_ONLY; then
      if [[ ${#RHAPSODY_MODEL_FILES[@]} -eq 0 ]]; then
        die "$EX_STATE" "No Rhapsody model files (*.rpwx, *.sbsx, *.rpy) found to commit (--model-only)."
      fi
      info "Staging ${#RHAPSODY_MODEL_FILES[@]} Rhapsody model file(s) only (--model-only)..."
      run git add -- "${RHAPSODY_MODEL_FILES[@]}"
      HAS_STAGED=true
    elif $STAGE_ALL; then
      check_sensitive_files
      run git add -A
      HAS_STAGED=true
    elif $NONINTERACTIVE; then
      die "$EX_STATE" "Nothing staged." "Stage selectively: git add <files>, or pass --all or --model-only"
    else
      printf '\n%s\n' "How would you like to stage files for this commit?" "  [1] Commit ALL changes (git add -A)"
      if [[ ${#RHAPSODY_MODEL_FILES[@]} -gt 0 ]]; then
        printf '%s\n' \
          "  [2] Commit Rhapsody model files only (${#RHAPSODY_MODEL_FILES[@]} file(s): *.rpwx, *.sbsx, *.rpy - skips .bak/.tmp/generated)" \
          "  [3] Pick specific files from a numbered list"
      else
        printf '%s\n' "  [2] Pick specific files from a numbered list"
      fi
      printf '%s\n' "  [q] Cancel"
      prompt "Enter choice" "1" || true
      local sc="$REPLY_VAL"
      if [[ "$sc" == [qQ] ]]; then die "$EX_ABORT" "Cancelled."; fi
      if [[ "$sc" == "1" ]]; then
        check_sensitive_files
        run git add -A
        HAS_STAGED=true
      elif [[ "$sc" == "2" && ${#RHAPSODY_MODEL_FILES[@]} -gt 0 ]]; then
        info "Staging ${#RHAPSODY_MODEL_FILES[@]} Rhapsody model file(s) only:"
        local mf
        for mf in "${RHAPSODY_MODEL_FILES[@]}"; do printf '       %s\n' "$mf"; done
        run git add -- "${RHAPSODY_MODEL_FILES[@]}"
        HAS_STAGED=true
      elif [[ ( "$sc" == "3" && ${#RHAPSODY_MODEL_FILES[@]} -gt 0 ) || ( "$sc" == "2" && ${#RHAPSODY_MODEL_FILES[@]} -eq 0 ) ]]; then
        select_files_interactively
      else
        die "$EX_USAGE" "Invalid choice '$sc'."
      fi
    fi
  fi
  check_sensitive_files
  info "Committing: \"$FORMATTED_MSG\""
  if run_logged git commit -m "$FORMATTED_MSG"; then
    if $DRY_RUN; then SIM_COMMIT=true; fi
    ok "Committed."
  else
    die "$EX_GIT" "Commit failed (pre-commit hook, empty commit or config problem)." \
      "Read the output above; your changes are still staged - fix and re-run the same command"
  fi
}

# ------------------------------------------------------------ push / MR ------
mr_body_template() {
  cat <<EOF
## Summary
<!-- What changed and why (1-3 sentences) -->

## Jira
- Ticket: ${MR_JIRA_LINE}

## Branch
- \`${CUR_BRANCH}\` -> \`${BASE_BRANCH}\`

## Commits (${MR_NCOMMITS})
${MR_COMMITS}

## Files changed
\`\`\`
${MR_STAT}
\`\`\`

## How to test
- [ ] <!-- steps / evidence -->

## Checklist
- [ ] Branch name and commit messages carry the Jira ID
- [ ] Rebased/merged on latest \`${BASE_BRANCH}\`, no conflicts
- [ ] Builds and tests pass locally
- [ ] Pipeline is green
EOF
}

read_mr_people() {
  if $MR_PEOPLE_PROMPTED || $NONINTERACTIVE || [[ "$MR_MODE" == "none" ]]; then return 0; fi
  MR_PEOPLE_PROMPTED=true
  if [[ -z "$ASSIGNEE" ]]; then
    if prompt "GitLab Assignee CDS ID (optional, e.g. jfernan1 - Enter to skip)" "$LAST_ASSIGNEE"; then
      if [[ -n "$REPLY_VAL" ]]; then ASSIGNEE="$REPLY_VAL"; LAST_ASSIGNEE="$REPLY_VAL"; fi
    fi
  fi
  if [[ -z "$REVIEWER" ]]; then
    if prompt "GitLab Reviewer CDS ID(s) (optional, e.g. rkumar2 or 'rkumar2 asmith3' - Enter to skip)" "$LAST_REVIEWER"; then
      if [[ -n "$REPLY_VAL" ]]; then REVIEWER="$REPLY_VAL"; LAST_REVIEWER="$REPLY_VAL"; fi
    fi
  fi
}

format_gitlab_handles() {
  local raw="$1" tok out=""
  for tok in ${raw//,/ }; do
    tok="${tok#@}"
    if [[ -n "$tok" ]]; then
      if [[ -n "$out" ]]; then out="$out @$tok"; else out="@$tok"; fi
    fi
  done
  printf '%s' "$out"
}

url_encode() {
  local str="$1" i ch hex out=""
  local LC_ALL=C
  for (( i = 0; i < ${#str}; i++ )); do
    ch="${str:i:1}"
    case "$ch" in
      [a-zA-Z0-9.~_-]) out+="$ch" ;;
      *) printf -v hex '%%%02X' "'$ch"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

build_mr_metadata() {
  local base_ref="$REMOTE/$BASE_BRANCH" human nl last jira subj
  jira="$JIRA_ID"
  if [[ -z "$jira" ]]; then
    jira=$(printf '%s' "$CUR_BRANCH" | grep -oE "$JIRA_PATTERN" | head -n 1 || true)
  fi
  MR_NCOMMITS=$(git rev-list --count "$base_ref..HEAD" -- 2>/dev/null || echo 0)
  if $SIM_COMMIT; then MR_NCOMMITS=$((MR_NCOMMITS + 1)); fi
  MR_COMMITS=$(git log --reverse --format='- %s (`%h`)' "$base_ref..HEAD" -- 2>/dev/null || true)
  MR_STAT=$(git diff --stat=100 "$base_ref...HEAD" -- 2>/dev/null || true)
  if [[ -z "$MR_STAT" ]]; then
    MR_STAT=$(git status --short)
    if [[ -n "$MR_STAT" ]]; then MR_STAT="(uncommitted - would be included)"$'\n'"$MR_STAT"; fi
  fi
  if [[ -z "$MR_STAT" ]]; then MR_STAT="(no changes vs $base_ref)"; fi
  nl=$(printf '%s\n' "$MR_STAT" | wc -l | tr -d ' ')
  if [[ "$nl" -gt 41 ]]; then
    last=$(printf '%s\n' "$MR_STAT" | tail -n 1)
    MR_STAT="$(printf '%s\n' "$MR_STAT" | head -n 40)"$'\n'"... ($((nl - 41)) more files)"$'\n'"$last"
  fi
  if [[ -z "$MR_COMMITS" ]]; then MR_COMMITS="- ${FORMATTED_MSG:-_(none yet)_}"; fi
  if [[ -n "$jira" && -n "$JIRA_URL" ]]; then MR_JIRA_LINE="[$jira](${JIRA_URL%/}/browse/$jira)"; else MR_JIRA_LINE="${jira:-UNKNOWN}"; fi
  local leaf="${CUR_BRANCH#*/}"
  if [[ -n "$jira" && "$leaf" == "$jira" ]]; then
    human=""
  else
    human=$(printf '%s' "$leaf" | sed -E "s/^${jira:-NONE}-//; s/-/ /g" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  fi
  subj=$(git log -1 --format=%s 2>/dev/null || true)
  if $SIM_COMMIT; then subj="$FORMATTED_MSG"; fi
  if [[ ( "$MR_NCOMMITS" -le 1 || -z "$human" ) && -n "$subj" && "$subj" == "$jira:"* ]]; then
    MR_TITLE="$subj"
  elif [[ -n "$human" ]]; then
    MR_TITLE="${jira:-UNKNOWN}: $human"
  else
    MR_TITLE="${subj:-${jira:-$CUR_BRANCH}}"
  fi
  MR_BODY=$(mr_body_template)
  local qa="" ah="" rh=""
  if [[ -n "$ASSIGNEE" ]]; then
    ah=$(format_gitlab_handles "$ASSIGNEE")
    if [[ -n "$ah" ]]; then qa="/assign $ah"; fi
  fi
  if [[ -n "$REVIEWER" ]]; then
    rh=$(format_gitlab_handles "$REVIEWER")
    if [[ -n "$rh" ]]; then
      if [[ -n "$qa" ]]; then qa="${qa}"$'\n'"/assign_reviewer $rh"; else qa="/assign_reviewer $rh"; fi
    fi
  fi
  if [[ -n "$qa" ]]; then
    MR_BODY="${MR_BODY}"$'\n\n'"${qa}"
  fi
}

classify_push_failure() {
  local out
  out=$(cat "$LOGFILE" 2>/dev/null || true)
  case "$out" in
    *"Permission denied"*|*"Authentication failed"*|*"could not read Username"*|*"returned error: 401"*|*"returned error: 403"*)
      die "$EX_NETWORK" "Push failed: authentication/permission problem on '$REMOTE'." \
        "Refresh your SSH key / token and retry" "Make sure you have Developer (write) access to this repo" ;;
    *"protected branch"*|*"GH006"*|*"not allowed to push"*)
      die "$EX_PROTECTED" "Push rejected: the server says this branch is protected." \
        "Push a feature branch instead and open an MR into $BASE_BRANCH" ;;
    *"non-fast-forward"*|*"fetch first"*|*"Updates were rejected"*)
      die "$EX_GIT" "Push rejected: the remote branch has commits you don't have (diverged)." \
        "Rebase onto it: git pull --rebase $REMOTE $CUR_BRANCH   then re-run with --push" \
        "Conflicts? fix files -> git add -> git rebase --continue   (or git rebase --abort)" \
        "This script never force-pushes. If you rewrote history on purpose: git push --force-with-lease $REMOTE $CUR_BRANCH" ;;
    *"exceeds"*|*"File size"*|*"too large"*|*"large files"*)
      die "$EX_GIT" "Push rejected: a file/pack exceeds the server size limit." \
        "Find big files: git rev-list --objects --all | sort | tail" "Remove them from the commit and use Git LFS if needed" ;;
    *"hook declined"*|*"remote rejected"*)
      die "$EX_GIT" "Push rejected by a server-side hook / policy." \
        "Read the 'remote:' lines above - typical causes: branch name, commit message (Jira ID), file rules" \
        "Fix the commit: git commit --amend -m \"PROJ-123: message\"  then re-run --push" ;;
    *"Could not resolve host"*|*"timed out"*|*"Connection"*)
      die "$EX_NETWORK" "Push failed: network problem." "Check VPN/proxy and retry" ;;
    *)
      die "$EX_GIT" "Push failed." "Read the git output above." "Preview with --dry-run; check: git status, git remote -v" ;;
  esac
}

check_unpushed_commit_jira() {
  if $DO_COMMIT || [[ -z "$JIRA_ID" ]] || $NONINTERACTIVE; then return 0; fi
  local subj re
  subj=$(git log -1 --format=%s 2>/dev/null || true)
  if [[ -z "$subj" ]]; then return 0; fi
  re="^\\[?${JIRA_PATTERN}\\]?"
  if [[ "$(upper "$subj")" =~ $re ]]; then return 0; fi
  warn "Your latest commit message (\"$subj\") does not start with Jira ID '$JIRA_ID:'."
  hint "GitLab commit hooks may reject a push if the commit message is missing the Jira ID."
  if confirm "Automatically prefix '$JIRA_ID: ' to your latest commit before pushing?" y n; then
    local new_msg="${JIRA_ID}: ${subj}"
    run git commit --amend -m "$new_msg"
    ok "Updated commit message to: \"$new_msg\""
  fi
}

push_branch() {
  step "Push"
  if $DETACHED || is_protected "$CUR_BRANCH"; then
    die "$EX_PROTECTED" "Refusing to push '${CUR_BRANCH:-detached HEAD}' (protected / detached)."
  fi
  local ahead=0 behind=0 counts
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$CUR_BRANCH"; then
    counts=$(git rev-list --left-right --count "HEAD...$REMOTE/$CUR_BRANCH" --)
    ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
    if $SIM_COMMIT; then ahead=$((ahead + 1)); fi
    if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
      warn "Branch has diverged from $REMOTE/$CUR_BRANCH: $ahead ahead, $behind behind."
      if confirm "Rebase your commits onto $REMOTE/$CUR_BRANCH now (git pull --rebase)?" n n; then
        if ! try git pull --rebase "$REMOTE" "$CUR_BRANCH"; then
          die "$EX_STATE" "Rebase stopped on conflicts." \
            "Fix files -> git add <files> -> git rebase --continue   (or: git rebase --abort)" \
            "Then re-run: $SELF --push"
        fi
      else
        die "$EX_GIT" "Diverged from remote - not pushing." \
          "Rebase: git pull --rebase $REMOTE $CUR_BRANCH   then re-run with --push" \
          "Intentional history rewrite? git push --force-with-lease (this script never force-pushes)"
      fi
    elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
      die "$EX_STATE" "Remote branch is $behind commit(s) ahead; nothing of yours to push." "git pull --rebase $REMOTE $CUR_BRANCH"
    elif [[ "$ahead" -eq 0 ]]; then
      info "Branch already up to date on '$REMOTE' - nothing to push."
      return 0
    fi
  else
    ahead=$(git rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" --)
    if $SIM_COMMIT; then ahead=$((ahead + 1)); fi
    if [[ "$ahead" -eq 0 ]]; then
      die "$EX_STATE" "No commits beyond $REMOTE/$BASE_BRANCH - an MR would be empty." "Commit first: $SELF --commit \"message\""
    fi
  fi

  check_unpushed_commit_jira

  local behind_base mt_rc=0
  behind_base=$(git rev-list --count "HEAD..$REMOTE/$BASE_BRANCH" --)
  if [[ "$behind_base" -gt 0 ]]; then
    warn "Branch is $behind_base commit(s) behind $REMOTE/$BASE_BRANCH."
    git merge-tree --write-tree HEAD "$REMOTE/$BASE_BRANCH" >/dev/null 2>&1 || mt_rc=$?
    if [[ "$mt_rc" -eq 1 ]]; then
      warn "WARNING: The MR will have MERGE CONFLICTS with $BASE_BRANCH!"
      hint "Recommended: resolve conflicts locally before pushing:  git rebase $REMOTE/$BASE_BRANCH"
      if ! $NONINTERACTIVE && ! $FORCE; then
        if ! confirm "Push anyway even though it has merge conflicts with '$BASE_BRANCH'?" n n; then
          die "$EX_STATE" "Stopped so you can resolve conflicts with '$REMOTE/$BASE_BRANCH' first." \
            "Run: git rebase $REMOTE/$BASE_BRANCH" \
            "Resolve conflicts -> git add <files> -> git rebase --continue" \
            "Then run $SELF again to push."
        fi
      fi
    else
      ok "No conflicts detected with $REMOTE/$BASE_BRANCH."
      local dirty_now
      dirty_now=$(git status --porcelain --untracked-files=no 2>/dev/null || true)
      if ! $NONINTERACTIVE && [[ -z "$dirty_now" ]]; then
        local already_pushed=false method=""
        if git show-ref --verify --quiet "refs/remotes/$REMOTE/$CUR_BRANCH"; then
          already_pushed=true
          method="merge $REMOTE/$BASE_BRANCH (safe, no force-push needed)"
        else
          method="rebase onto $REMOTE/$BASE_BRANCH (clean linear history)"
        fi
        if confirm "Update your branch with latest '$REMOTE/$BASE_BRANCH' automatically before pushing ($method)?" y n; then
          if $already_pushed; then
            if ! try git merge --no-edit "$REMOTE/$BASE_BRANCH"; then
              try git merge --abort >/dev/null 2>&1 || true
              warn "Auto-merge could not complete cleanly and was safely aborted. Continuing with push."
            else ok "Branch updated with latest '$REMOTE/$BASE_BRANCH'."; fi
          else
            if ! try git rebase "$REMOTE/$BASE_BRANCH"; then
              try git rebase --abort >/dev/null 2>&1 || true
              warn "Auto-rebase could not complete cleanly and was safely aborted. Continuing with push."
            else ok "Branch rebased cleanly onto latest '$REMOTE/$BASE_BRANCH'."; fi
          fi
        fi
      fi
    fi
  fi

  read_mr_people
  build_mr_metadata
  detect_mr_tool
  local -a push_cmd=(git push --set-upstream "$REMOTE" "$CUR_BRANCH")
  local use_gitlab_opts=false remote_url
  remote_url=$(git remote get-url "$REMOTE" 2>/dev/null || true)
  if $DO_MR && [[ -z "$MR_TOOL" && "$remote_url" != *"github.com"* ]]; then
    use_gitlab_opts=true
    local escaped_desc
    escaped_desc=$(printf '%s' "$MR_BODY" | awk 'BEGIN{ORS=""} {if(NR>1) printf "\\n"; gsub(/\r/,""); print}')
    push_cmd+=(-o merge_request.create -o "merge_request.target=$BASE_BRANCH" -o "merge_request.title=$MR_TITLE" -o "merge_request.description=$escaped_desc" -o merge_request.remove_source_branch)
    if [[ -n "$ASSIGNEE" ]]; then
      local a_clean
      a_clean=$(printf '%s' "${ASSIGNEE//,/ }" | awk '{print $1}')
      a_clean="${a_clean#@}"
      if [[ -n "$a_clean" ]]; then push_cmd+=(-o "merge_request.assign=$a_clean"); fi
    fi
    if $DRAFT; then push_cmd+=(-o merge_request.draft); fi
    info "Pushing '$CUR_BRANCH' to '$REMOTE' (git push --set-upstream $REMOTE $CUR_BRANCH) with GitLab auto-MR push options (title, description, assignee/reviewer, delete after merge)..."
  else
    info "Pushing '$CUR_BRANCH' to '$REMOTE' (git push --set-upstream $REMOTE $CUR_BRANCH)..."
  fi

  local push_ok=false
  if run_logged "${push_cmd[@]}"; then
    push_ok=true
  elif $use_gitlab_opts && grep -Eiq 'push options|not support' "$LOGFILE" 2>/dev/null; then
    warn "Remote server does not support GitLab push options; retrying normal git push..."
    use_gitlab_opts=false
    if run_logged git push --set-upstream "$REMOTE" "$CUR_BRANCH"; then push_ok=true; fi
  fi

  if $push_ok; then
    ok "Pushed ${C_BOLD}$CUR_BRANCH${C_RESET} -> $REMOTE (upstream tracking set)."
    if $use_gitlab_opts; then
      MR_CREATED_VIA_PUSH=true
      ok "GitLab Merge Request created via push options ($CUR_BRANCH -> $BASE_BRANCH, delete source branch enabled)."
    fi
    PUSH_URL=$(grep -Eo 'https?://[^[:space:]]*(merge_requests|pull)[^[:space:]]*' "$LOGFILE" 2>/dev/null | head -n 1 | tr -d '\r' || true)
    if [[ "$PUSH_URL" == *"/merge_requests/new"* ]]; then
      local sep="?" enc_base enc_title
      if [[ "$PUSH_URL" == *"?"* ]]; then sep="&"; fi
      enc_base=$(url_encode "$BASE_BRANCH")
      enc_title=$(url_encode "$MR_TITLE")
      PUSH_URL="${PUSH_URL}${sep}merge_request%5Btarget_branch%5D=${enc_base}&merge_request%5Btitle%5D=${enc_title}&merge_request%5Bforce_remove_source_branch%5D=1"
    fi
  else
    classify_push_failure
  fi
}

copy_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then wl-copy
  elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --input
  elif command -v clip.exe >/dev/null 2>&1; then clip.exe
  elif command -v clip >/dev/null 2>&1; then clip
  else return 1
  fi
}

open_url_in_browser() {
  local url="$1"
  if command -v msedge >/dev/null 2>&1; then msedge "$url" >/dev/null 2>&1 &
  elif [[ -x "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" ]]; then "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" "$url" >/dev/null 2>&1 &
  elif [[ -x "/c/Program Files/Microsoft/Edge/Application/msedge.exe" ]]; then "/c/Program Files/Microsoft/Edge/Application/msedge.exe" "$url" >/dev/null 2>&1 &
  elif command -v cmd.exe >/dev/null 2>&1; then cmd.exe /c start "" "microsoft-edge:$url" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1
  else return 1
  fi
}

mr_handoff() {
  step "MR hand-off"
  local gd
  gd=$(git rev-parse --absolute-git-dir)
  read_mr_people
  build_mr_metadata
  if ! $DRY_RUN; then
    printf '%s\n' "$MR_BODY" >"$gd/MR_DESCRIPTION.md"
    info "Description saved to: $gd/MR_DESCRIPTION.md"
    if [[ -t 1 ]] && printf '%s\n' "$MR_BODY" | copy_clipboard >/dev/null 2>&1; then
      ok "Description copied to clipboard (press Ctrl+V in GitLab)."
    fi
  fi
  printf '\n%s\n%s\n' "${C_BOLD}---- MR TITLE ----${C_RESET}" "$MR_TITLE"
  printf '\n%s\n%s\n%s\n' "${C_BOLD}---- MR DESCRIPTION ----${C_RESET}" "$MR_BODY" "${C_BOLD}---- END ----${C_RESET}"
  if [[ -n "$PUSH_URL" ]]; then
    info "GitLab MR Link: $PUSH_URL"
    if ! $NONINTERACTIVE && ! $DRY_RUN; then
      if [[ "$MR_MODE" == "gui" ]]; then
        info "Opening GitLab MR link in Microsoft Edge..."
        open_url_in_browser "$PUSH_URL" || warn "Could not launch Microsoft Edge automatically - copy the URL above."
      elif [[ "$MR_MODE" != "none" ]]; then
        if confirm "Open the GitLab MR link in Microsoft Edge now?" y n; then
          open_url_in_browser "$PUSH_URL" || warn "Could not launch Microsoft Edge automatically - copy the URL above."
        fi
      fi
    fi
  fi
}

detect_mr_tool() {
  MR_TOOL=""
  local url
  url=$(git remote get-url "$REMOTE" 2>/dev/null || true)
  case "$url" in
    *gitlab*) if command -v glab >/dev/null 2>&1; then MR_TOOL=glab; fi ;;
    *github*) if command -v gh >/dev/null 2>&1; then MR_TOOL=gh; fi ;;
    *) if command -v glab >/dev/null 2>&1; then MR_TOOL=glab; elif command -v gh >/dev/null 2>&1; then MR_TOOL=gh; fi ;;
  esac
}

create_mr() {
  if $MR_CREATED_VIA_PUSH; then return 0; fi
  detect_mr_tool
  if [[ -z "$MR_TOOL" ]]; then
    warn "No CLI tool (glab/gh) found and push-options MR was not used - use the printed MR link/text above."
    hint "Use the title/description printed above${PUSH_URL:+ and open: $PUSH_URL}"
    return 1
  fi
  local -a cmd
  if [[ "$MR_TOOL" == glab ]]; then
    cmd=(glab mr create --source-branch "$CUR_BRANCH" --target-branch "$BASE_BRANCH" --title "$MR_TITLE" --description "$MR_BODY" --remove-source-branch --yes)
    if [[ -n "$ASSIGNEE" ]]; then
      local a_clean
      a_clean=$(printf '%s' "${ASSIGNEE//,/ }" | awk '{print $1}')
      a_clean="${a_clean#@}"
      if [[ -n "$a_clean" ]]; then cmd+=(--assignee "$a_clean"); fi
    fi
    if [[ -n "$REVIEWER" ]]; then
      local r_csv
      r_csv=$(printf '%s' "${REVIEWER//,/ }" | tr -s ' ' ',' | sed 's/@//g; s/^,//; s/,$//')
      if [[ -n "$r_csv" ]]; then cmd+=(--reviewer "$r_csv"); fi
    fi
  else
    cmd=(gh pr create --head "$CUR_BRANCH" --base "$BASE_BRANCH" --title "$MR_TITLE" --body "$MR_BODY")
  fi
  if $DRAFT; then cmd+=(--draft); fi
  step "Creating MR with $MR_TOOL"
  if $DRY_RUN; then
    printf '%s\n' "  ${C_YELLOW}[dry-run]${C_RESET} would run: $MR_TOOL ${MR_TOOL/glab/mr} create ... (title/description as printed above)"
    return 0
  fi
  if "${cmd[@]}"; then
    ok "MR created."
    return 0
  fi
  warn "$MR_TOOL could not create the MR (already exists? not authenticated?)."
  hint "Check: $MR_TOOL auth status   -   or paste the description printed above into the web UI"
  return 1
}

do_commit_push() {
  ensure_work_branch
  check_branch_convention
  resolve_commit_jira
  if $DO_COMMIT; then stage_and_commit; fi
  if $DO_PUSH; then
    ensure_base_ref
    push_branch
    mr_handoff
    if $DO_MR; then
      if ! create_mr; then MR_FAILED=true; fi
    else
      hint "Tip: add --mr next time to auto-create the GitLab MR during push." >&2
    fi
  else
    ok "Done. Push when ready:  $SELF --push --mr"
  fi
}

do_mr_text() {
  if $DETACHED || is_protected "$CUR_BRANCH"; then
    die "$EX_PROTECTED" "'${CUR_BRANCH:-detached HEAD}' is not a work branch - no MR text to generate." \
      "Switch to your feature branch first."
  fi
  ensure_base_ref
  mr_handoff
}

do_undo_commit() {
  step "Undo Last Unpushed Commit"
  if $DETACHED || is_protected "$CUR_BRANCH"; then
    die "$EX_PROTECTED" "Refusing to undo commit on '${CUR_BRANCH:-detached HEAD}' (protected / detached)." \
      "Switch to your feature branch first."
  fi
  local unpushed=0
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$CUR_BRANCH"; then
    unpushed=$(git rev-list --count "$REMOTE/$CUR_BRANCH..HEAD" --)
  else
    ensure_base_ref
    unpushed=$(git rev-list --count "$REMOTE/$BASE_BRANCH..HEAD" --)
  fi
  if [[ "$unpushed" -le 0 ]]; then
    die "$EX_STATE" "No unpushed local commits to undo on '$CUR_BRANCH'." \
      "Only commits that have NOT been pushed to GitLab yet can be safely undone here."
  fi
  local last_commit
  last_commit=$(git log -1 --oneline)
  info "Last unpushed commit: $last_commit"
  info "This runs 'git reset --soft HEAD~1': all your file edits stay intact and staged."
  if ! confirm "Undo this commit (keeping all your code changes)?" n n; then
    info "Cancelled - commit was not undone."
    return 0
  fi
  run git reset --soft HEAD~1
  ok "Last commit undone. Your file changes are still intact and staged (run git status to inspect)."
}

do_update_from_base() {
  step "Update Branch with Latest '$REMOTE/$BASE_BRANCH'"
  if $DETACHED || is_protected "$CUR_BRANCH"; then
    die "$EX_PROTECTED" "Not on a work branch ('${CUR_BRANCH:-detached HEAD}')." \
      "Switch to your feature branch first, or use --sync to update develop."
  fi
  ensure_base_ref
  local dirty
  dirty=$(git status --porcelain --untracked-files=no 2>/dev/null || true)
  if [[ -n "$dirty" ]]; then
    die "$EX_STATE" "You have uncommitted changes to tracked files." \
      "Commit or stash them first (git stash push -m wip) before updating from develop."
  fi
  local behind_base mt_rc=0
  behind_base=$(git rev-list --count "HEAD..$REMOTE/$BASE_BRANCH" --)
  if [[ "$behind_base" -eq 0 ]]; then
    ok "Branch '$CUR_BRANCH' is already up to date with '$REMOTE/$BASE_BRANCH'."
    return 0
  fi
  info "Branch '$CUR_BRANCH' is $behind_base commit(s) behind '$REMOTE/$BASE_BRANCH'. Checking for merge conflicts..."
  git merge-tree --write-tree HEAD "$REMOTE/$BASE_BRANCH" >/dev/null 2>&1 || mt_rc=$?
  if [[ "$mt_rc" -eq 1 ]]; then
    warn "Merge CONFLICTS detected between '$CUR_BRANCH' and '$REMOTE/$BASE_BRANCH'!"
    hint "Resolve conflicts manually so you can review each line:"
    hint "  git rebase $REMOTE/$BASE_BRANCH"
    hint "  (fix files -> git add <files> -> git rebase --continue, or git rebase --abort)"
    return 0
  fi
  ok "Zero conflicts detected with '$REMOTE/$BASE_BRANCH'!"
  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$CUR_BRANCH"; then
    info "Branch is already pushed to '$REMOTE' - using safe merge (no force-push needed)..."
    if ! try git merge --no-edit "$REMOTE/$BASE_BRANCH"; then
      try git merge --abort >/dev/null 2>&1 || true
      die "$EX_GIT" "Merge could not complete cleanly and was safely aborted."
    fi
    ok "Branch '$CUR_BRANCH' updated with latest '$REMOTE/$BASE_BRANCH' via merge. Ready to push!"
  else
    info "Branch has not been pushed yet - rebasing cleanly onto '$REMOTE/$BASE_BRANCH'..."
    if ! try git rebase "$REMOTE/$BASE_BRANCH"; then
      try git rebase --abort >/dev/null 2>&1 || true
      die "$EX_GIT" "Rebase could not complete cleanly and was safely aborted."
    fi
    ok "Branch '$CUR_BRANCH' rebased cleanly onto latest '$REMOTE/$BASE_BRANCH'. Ready to push!"
  fi
}

do_multi_branch() {
  local root="$1"
  shift
  local -a repos=("$@")
  step "Multi-Component Branch Creation (${#repos[@]} repositories)"
  local r label
  for r in "${repos[@]}"; do
    info "  Target: $(repo_rel_label "$root" "$r")"
  done
  printf '\n'
  collect_branch_inputs
  local target_branch="$BRANCH_NAME"
  local orig_jira="$JIRA_ID" orig_type="$BRANCH_TYPE" orig_desc="$DESC"

  fetch_dotrepo "$root"
  local created=0 existing=0 failed=0
  for r in "${repos[@]}"; do
    label=$(repo_rel_label "$root" "$r")
    printf '\n%s=== [%s] ===%s\n' "$C_CYAN" "$label" "$C_RESET"
    if ! cd "$r"; then warn "[$label] Cannot enter directory."; failed=$((failed + 1)); continue; fi
    REPO_DIR="$r"
    JIRA_ID="$orig_jira"; BRANCH_TYPE="$orig_type"; DESC="$orig_desc"; BRANCH_NAME="$target_branch"
    setup_ssh_env
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      warn "Skipping '$label' (not a valid working tree)."; failed=$((failed + 1)); continue
    fi
    if git symbolic-ref -q HEAD >/dev/null 2>&1; then
      DETACHED=false; CUR_BRANCH=$(git symbolic-ref --short HEAD)
    else
      DETACHED=true; CUR_BRANCH=""
    fi
    resolve_remote_name
    if ! $NO_FETCH; then
      info "Running 'git fetch --all --prune'..."
      if ! git fetch --all --prune --quiet >/dev/null 2>&1; then
        warn "[$label] Fetch failed."; failed=$((failed + 1)); continue
      fi
      resolve_remote_name
    fi
    if ! ensure_base_ref; then failed=$((failed + 1)); continue; fi
    if ! check_branch_free; then
      ok "[$label] Switched to existing branch '$target_branch'."
      existing=$((existing + 1)); continue
    fi
    if $DETACHED; then handle_detached_for_branch; fi
    guard_dirty_for_branch
    if $CARRY_CHANGES; then
      run git checkout -b "$target_branch"
      ok "[$label] Created branch '$target_branch' (carried uncommitted changes safely)."
    else
      if sync_local_base_branch; then
        run git checkout -b "$target_branch"
      else
        run git checkout -b "$target_branch" --no-track "$REMOTE/$BASE_BRANCH"
      fi
      ok "[$label] Created branch '$target_branch' off latest '$BASE_BRANCH'."
    fi
    created=$((created + 1))
  done
  step "Multi-Component Branch Summary"
  ok "Created '$target_branch': $created   |   Switched to existing: $existing   |   Failed: $failed"
}

do_discard_files() {
  step "Safely Discard Unwanted File Changes (with Stash Backup)"
  local -a paths=() statuses=() kinds=()
  local ln st p kind
  while IFS= read -r ln; do
    if [[ ${#ln} -lt 4 ]]; then continue; fi
    st="${ln:0:2}"
    p="${ln:3}"
    if [[ "$p" == *" -> "* ]]; then p="${p##* -> }"; fi
    p="${p#\"}"; p="${p%\"}"
    if [[ "$st" == "??" ]]; then kind="untracked"; else kind="modified"; fi
    statuses+=("$st"); paths+=("$p"); kinds+=("$kind")
  done < <(git -c core.quotepath=off status --porcelain 2>/dev/null || true)

  if [[ ${#paths[@]} -eq 0 ]]; then
    ok "Working tree is already clean - nothing to discard."
    return 0
  fi

  info "Files with uncommitted changes in this component:"
  local i=0
  for (( i = 0; i < ${#paths[@]}; i++ )); do
    printf '  [%d]  %s  %s  (%s)\n' "$((i + 1))" "${statuses[$i]}" "${paths[$i]}" "${kinds[$i]}"
  done

  if $NONINTERACTIVE; then
    die "$EX_USAGE" "Cannot pick files to discard in non-interactive mode." \
      "Run interactively to select which files to discard safely."
  fi

  local -a chosen=()
  local sel tok valid
  printf '\n'
  while true; do
    read -r -p "Enter file numbers to discard (e.g. 1 3, 'a' = all, 'q' = cancel): " sel || die "$EX_ABORT" "Input closed - aborting."
    sel=$(trim "$sel")
    if [[ -z "$sel" ]]; then continue; fi
    if [[ "$sel" == [qQ] ]]; then info "Cancelled - no files were touched."; return 0; fi
    if [[ "$sel" == [aA] ]]; then chosen=("${paths[@]}"); break; fi
    chosen=(); valid=true
    for tok in ${sel//,/ }; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [[ "$tok" -ge 1 && "$tok" -le "${#paths[@]}" ]]; then
        chosen+=("${paths[$((tok - 1))]}")
      else
        valid=false; break
      fi
    done
    if $valid && [[ ${#chosen[@]} -gt 0 ]]; then break; fi
    warn "Please enter numbers between 1 and ${#paths[@]} (e.g. 1 2), 'a' for all, or 'q' to cancel."
  done

  printf '\n'
  warn "About to discard changes in ${#chosen[@]} file(s):"
  for p in "${chosen[@]}"; do printf '       %s\n' "$p" >&2; done
  info "A safety backup will be saved in git stash BEFORE discarding so you can restore anytime."
  if ! confirm "Discard these ${#chosen[@]} file(s) now?" n n; then
    info "Cancelled - no files were touched."
    return 0
  fi

  local backup_msg="git_flow backup before discard $(date +%Y%m%d-%H%M%S)"
  run git stash push --include-untracked -m "$backup_msg" -- "${chosen[@]}"
  ok "Discarded changes in ${#chosen[@]} file(s)."
  info "Safety backup saved in git stash: \"$backup_msg\""
  hint "Changed your mind? Restore with: git stash pop   (or inspect: git stash list)"
}

select_mr_mode_interactive() {
  printf '\n%s\n' \
    "How would you like to raise the Merge Request on GitLab?" \
    "  [1] GitLab GUI (open MR page in Microsoft Edge so you can review/add notes & click Create)" \
    "  [2] Auto-create from CLI (create MR automatically during push with Assignee/Reviewer CDS ID)" \
    "  [3] Push only (skip raising MR for now)"
  prompt "Enter choice" "1" || true
  case "$(lower "$REPLY_VAL")" in
    1|gui|edge|browser) MR_MODE="gui"; DO_MR=false ;;
    2|cli|auto) MR_MODE="cli"; DO_MR=true ;;
    3|none|push|skip) MR_MODE="none"; DO_MR=false ;;
    *) warn "Unrecognised choice; using GitLab GUI (Microsoft Edge)."; MR_MODE="gui"; DO_MR=false ;;
  esac
}

do_wizard() {
  step "Complete Workflow Wizard (Branch -> Commit -> Push -> MR)"
  local need_branch=true
  if ! $DETACHED && ! is_protected "$CUR_BRANCH" && [[ "$CUR_BRANCH" =~ $BRANCH_REGEX ]] && [[ -z "$DESC" ]]; then
    if $NONINTERACTIVE; then
      need_branch=false
      info "Already on Jira branch '$CUR_BRANCH' - keeping it."
    elif confirm "Already on Jira branch '$CUR_BRANCH'. Continue on this branch?" y y; then
      need_branch=false
    fi
  fi
  if $need_branch; then
    do_branch
    CUR_BRANCH="$BRANCH_NAME"
    DETACHED=false
  fi

  local pending
  pending=$(git status --porcelain 2>/dev/null || true)
  if [[ -n "$pending" ]]; then
    resolve_commit_jira
    stage_and_commit
  elif has_unpushed_commits; then
    resolve_commit_jira
    info "Working tree is clean - will proceed with existing unpushed commit(s)."
  else
    ok "Branch '$CUR_BRANCH' is ready. Edit your files, then run $SELF --wizard again to commit, push & raise MR."
    return 0
  fi

  local want_push=false
  if $DO_PUSH || $DO_MR; then
    want_push=true
  elif confirm "Push '$CUR_BRANCH' to '$REMOTE' now?" y y; then
    want_push=true
  fi
  if ! $want_push; then
    ok "Committed locally on '$CUR_BRANCH'. Run $SELF --push --mr when ready."
    return 0
  fi
  DO_PUSH=true
  if ! $DO_MR && ! $NONINTERACTIVE; then
    select_mr_mode_interactive
  fi
  ensure_base_ref
  push_branch
  mr_handoff
  if $DO_MR; then
    if ! create_mr; then MR_FAILED=true; fi
  fi
}

interactive_menu() {
  step "Choose an action"
  printf '%s\n' \
    "  [0] Wizard: Full Flow (Branch + Commit + Push + MR in one go)" \
    "  [1] Start New Branch (fetch --all -> checkout & pull $BASE_BRANCH -> create Jira branch)" \
    "  [2] Commit changes (+ Push & Raise GitLab MR)" \
    "  [3] Push existing commits (+ Raise GitLab MR)" \
    "  [4] Show MR title/description for this branch" \
    "  [5] Sync ALL workspace repos (fetch --all -> checkout $BASE_BRANCH -> pull)" \
    "  [6] Undo last unpushed commit (keeps all your file changes intact)" \
    "  [7] Update current branch with latest $BASE_BRANCH (conflict-checked)" \
    "  [8] Discard unwanted file changes (saves a safety stash backup first)" \
    "  [q] Quit"
  local c
  read -r -p "Enter choice: " c || die "$EX_ABORT" "Input closed - aborting."
  case "$c" in
    0) DO_WIZARD=true ;;
    1) DO_BRANCH=true ;;
    2) DO_COMMIT=true
       if confirm "Push to '$REMOTE' after committing?" y y; then DO_PUSH=true; fi ;;
    3) DO_PUSH=true ;;
    4) DO_MRTEXT=true ;;
    5) DO_SYNC=true ;;
    6) DO_UNDO=true ;;
    7) DO_UPDATE=true ;;
    8) DO_DISCARD=true ;;
    q|Q) info "Bye."; exit 0 ;;
    *) die "$EX_USAGE" "Invalid choice '$c'." ;;
  esac
  if $DO_PUSH; then
    select_mr_mode_interactive
  fi
}

reset_interactive_run_state() {
  DO_BRANCH=false; DO_COMMIT=false; DO_PUSH=false; DO_MR=false; DO_MRTEXT=false; DO_SYNC=false; DO_WIZARD=false; DO_UNDO=false; DO_UPDATE=false; DO_DISCARD=false
  COMPONENT=""; JIRA_ID=""; BRANCH_TYPE=""; DESC=""; COMMIT_MSG=""
  ASSIGNEE=""; REVIEWER=""; MR_PEOPLE_PROMPTED=false
  REPO_DIR=""; MULTI_REPOS=(); CUR_BRANCH=""; DETACHED=false
  BRANCH_NAME=""; SANITIZED=""; SIM_COMMIT=false; CARRY_CHANGES=false
  HAS_STAGED=false; FORMATTED_MSG=""; PUSH_URL=""; MR_TITLE=""; MR_BODY=""; MR_CREATED_VIA_PUSH=false; MR_MODE=""
}

# ------------------------------------------------------------------ main -----
main() {
  local start_dir="$PWD"
  WORKSPACE_ROOT="$start_dir"
  parse_args "$@"
  setup_colors
  if ! command -v git >/dev/null 2>&1; then
    die "$EX_STATE" "git is not installed or not on PATH."
  fi
  LOGFILE=$(mktemp "${TMPDIR:-/tmp}/git_flow.XXXXXX")
  determine_mode

  printf '%s\n' "${C_CYAN}=========================================${C_RESET}"
  printf '%s\n' "${C_BOLD} Git & Jira Flow Assistant  v$VERSION${C_RESET}"
  printf '%s\n' "${C_CYAN}=========================================${C_RESET}"

  if $DO_HEALTH; then
    local -a all=()
    local d
    while IFS= read -r d; do
      if [[ -n "$d" ]]; then all+=("$d"); fi
    done < <(find_repos "$start_dir")
    if [[ ${#all[@]} -eq 0 ]]; then die "$EX_NOTFOUND" "No git repositories found under $start_dir."; fi
    show_workspace_health "$start_dir" "${all[@]}"
    return 0
  fi

  if $DO_STATUS; then
    local -a all=()
    local d
    while IFS= read -r d; do
      if [[ -n "$d" ]]; then all+=("$d"); fi
    done < <(find_repos "$start_dir")
    if [[ ${#all[@]} -eq 0 ]]; then die "$EX_NOTFOUND" "No git repositories found under $start_dir."; fi
    show_workspace_dashboard "$start_dir" "${all[@]}"
    return 0
  fi

  if $DRY_RUN; then warn "DRY RUN: mutating commands are only printed, never executed."; fi

  while true; do
    cd "$start_dir" || die "$EX_NOTFOUND" "Cannot enter $start_dir"
    if $DO_SYNC && [[ -z "$COMPONENT" ]]; then
      setup_ssh_env
      do_sync_all "$start_dir"
    else
      resolve_repo
      if [[ ${#MULTI_REPOS[@]} -gt 1 ]]; then
        setup_ssh_env
        do_multi_branch "$start_dir" "${MULTI_REPOS[@]}"
      elif $DO_SYNC && [[ -z "$COMPONENT" ]]; then
        setup_ssh_env
        do_sync_all "$start_dir"
      else
        cd "$REPO_DIR" || die "$EX_NOTFOUND" "Cannot enter $REPO_DIR"
        REPO_DIR=$(pwd)
        ok "Working in: $REPO_DIR"
        setup_ssh_env
        preflight
        show_status

        if $MENU_MODE; then interactive_menu; fi

        if $DO_SYNC; then
          if [[ -n "$COMPONENT" ]]; then
            ensure_base_ref
            sync_local_base_branch || true
          else
            do_sync_all "$start_dir"
          fi
        elif $DO_WIZARD; then
          do_wizard
        elif $DO_UNDO; then
          do_undo_commit
        elif $DO_UPDATE; then
          do_update_from_base
        elif $DO_DISCARD; then
          do_discard_files
        elif $DO_BRANCH; then
          do_branch
        elif $DO_MRTEXT; then
          do_mr_text
        else
          do_commit_push
        fi
      fi
    fi

    if $DRY_RUN; then printf '\n%s\n' "${C_YELLOW}Dry run complete - nothing was changed.${C_RESET}"; fi
    if ! $MENU_MODE || $NONINTERACTIVE; then break; fi
    printf '\n'
    if ! confirm "Work on another component / perform another action in this workspace?" n n; then break; fi
    reset_interactive_run_state
  done

  if $MR_FAILED; then exit "$EX_MR"; fi
}

main "$@"
