#!/usr/bin/env bash
# Claude Sandbox — Run Claude Code in a lightweight Docker container
# Source this file in your .bashrc/.zshrc

# Resolve script directory (install.sh pre-sets this; fallback for manual sourcing)
if [[ -z "${_SANDBOX_SCRIPT_DIR:-}" ]]; then
  _SANDBOX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi

# Load platform-specific implementation
case "$(uname -s)" in
  Darwin) source "$_SANDBOX_SCRIPT_DIR/lib/platform-darwin.sh" ;;
  *)      source "$_SANDBOX_SCRIPT_DIR/lib/platform-linux.sh" ;;
esac

# Prune exited/dead sandbox containers
_sandbox_prune() {
  docker container prune --filter "label=claude-sandbox" -f >/dev/null 2>&1
}

# Core: launch a new sandbox container
_claude_docker() {
  local mode="${SANDBOX_HOSTNAME:-sandbox}"
  local dir_hash
  dir_hash=$(_sandbox_hash "$PWD")
  local name="claude-${mode}-${dir_hash}"

  # Prune dead sandbox containers on every launch
  _sandbox_prune

  # Ensure macOS image exists
  _sandbox_ensure_image || return 1

  # Stop existing container for this directory (if any)
  if docker ps -q --filter "name=^${name}$" | grep -q .; then
    docker rm -f "$name" >/dev/null 2>&1
  fi

  # SANDBOX_MOUNTS: newline-separated list of Docker bind mounts to add
  # Each line uses standard -v syntax (src:dest or src:dest:ro)
  # Example:
  #   export SANDBOX_MOUNTS="
  #     /mnt/c/Users/me/Documents/vault:/data/vault
  #     /opt/tools:/opt/tools:ro
  #   "
  local extra_mounts=()
  local pwd_remapped=0
  while IFS= read -r m; do
    m="${m#"${m%%[![:space:]]*}"}"  # trim leading whitespace
    [[ -z "$m" ]] && continue
    extra_mounts+=(-v "$m")
    # If this mount's destination is $PWD, skip the default -v $PWD:$PWD below
    local spec="${m%:ro}"; spec="${spec%:rw}"
    [[ "${spec##*:}" == "$PWD" ]] && pwd_remapped=1
  done <<< "${SANDBOX_MOUNTS:-}"

  # Load project-specific env vars from .sandbox.env
  local env_args=()
  if [[ -f "$PWD/.sandbox.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
      [[ -z "$line" || "$line" == \#* ]] && continue
      env_args+=(-e "$line")
    done < "$PWD/.sandbox.env"
  fi

  # Platform callback fills these in
  local platform_args=()
  local image
  local sandbox_path
  # Default: WSL/Linux-style host home binds. Platforms that own home setup
  # themselves (macOS, via named volumes) flip this to 0 in _sandbox_platform_setup.
  local _SANDBOX_HOST_HOME=1
  _sandbox_platform_setup || return 1

  local host_home_args=()
  if [[ "$_SANDBOX_HOST_HOME" == "1" ]]; then
    host_home_args=(
      --tmpfs "$HOME:uid=$(id -u),gid=$(id -g),mode=0755"
      -v /tmp:/tmp
      -v "$HOME/.ssh:$HOME/.ssh:ro"
      -v "$HOME/.aws:$HOME/.aws"
      -v "$HOME/.gnupg:$HOME/.gnupg:ro"
      -v "$HOME/.gitconfig:$HOME/.gitconfig:ro"
      -v "$HOME/.claude:$HOME/.claude"
      -v "$HOME/.claude.json:$HOME/.claude.json"
    )
  fi

  local pwd_mount=()
  [[ "$pwd_remapped" == "0" ]] && pwd_mount=(-v "$PWD:$PWD")

  docker run -it --rm \
    --init \
    --name "$name" \
    --label "claude-sandbox" \
    --label "claude-sandbox.dir=$PWD" \
    --user "$(id -u):$(id -g)" \
    --hostname "${SANDBOX_HOSTNAME:-sandbox}" \
    --network host \
    -e HOME="$HOME" \
    -e PATH="$sandbox_path" \
    ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
    ${COLORTERM:+-e COLORTERM="$COLORTERM"} \
    ${FORCE_COLOR:+-e FORCE_COLOR="$FORCE_COLOR"} \
    -e TERM="${TERM:-xterm-256color}" \
    -e LANG="${LANG:-C.UTF-8}" \
    ${LC_ALL:+-e LC_ALL="$LC_ALL"} \
    -e PROMPT_COMMAND='PS1="\[\033[1;36m\]\h\[\033[0m\]:\[\033[1;33m\]\w\[\033[0m\]\[\033[1;32m\]$(parse_git_branch 2>/dev/null)\[\033[0m\]\[\033[1;37m\]\$ \[\033[0m\]"' \
    "${pwd_mount[@]}" \
    "${host_home_args[@]}" \
    "${platform_args[@]}" \
    "${extra_mounts[@]}" \
    "${env_args[@]}" \
    -w "$PWD" \
    "$image" \
    "$@"
}

# sandbox — subcommand interface
sandbox() {
  case "${1:-shell}" in
    shell)
      _claude_docker bash
      ;;
    ls|list)
      docker ps --filter "label=claude-sandbox" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Label \"claude-sandbox.dir\"}}"
      ;;
    stop)
      local containers
      containers=$(docker ps -q --filter "label=claude-sandbox")
      if [[ -n "$containers" ]]; then
        echo "$containers" | xargs docker stop >/dev/null
        _sandbox_prune
        echo "Stopped all sandbox containers."
      else
        echo "No running sandbox containers."
      fi
      ;;
    exec)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Usage: sandbox exec <command> [args...]"
        return 1
      fi
      _claude_docker "$@"
      ;;
    attach)
      local mode="${SANDBOX_HOSTNAME:-sandbox}"
      local dir_hash
      dir_hash=$(_sandbox_hash "$PWD")
      local name="claude-${mode}-${dir_hash}"
      if docker ps -q --filter "name=^${name}$" | grep -q .; then
        docker exec -it --user "$(id -u):$(id -g)" "$name" bash
      else
        echo "No running sandbox for this directory. Use 'sandbox' to start one."
      fi
      ;;
    help|-h|--help)
      cat <<'HELP'
sandbox — Docker sandbox for development

Commands:
  sandbox              Open an interactive shell (default)
  sandbox ls           List running sandbox containers
  sandbox stop         Stop all sandbox containers
  sandbox exec <cmd>   Run a one-off command in a new container
  sandbox attach       Attach to a running container for this directory

  yolo                 Run Claude Code with --dangerously-skip-permissions

Environment:
  SANDBOX_IMAGE        Override base image (default: ubuntu:22.04 on Linux,
                       claude-sandbox:latest on macOS)
  SANDBOX_HOSTNAME     Override container hostname (default: sandbox)
  SANDBOX_MOUNTS       Extra bind mounts (newline-separated, -v syntax)

Per-project:
  .sandbox.env         Auto-loaded env vars (KEY=VALUE, one per line)
HELP
      ;;
    *)
      echo "Unknown command: $1 (try 'sandbox help')"
      return 1
      ;;
  esac
}

# Run Claude Code with --dangerously-skip-permissions inside the sandbox
alias yolo='SANDBOX_HOSTNAME=yolo _claude_docker bash -c "claude -c --dangerously-skip-permissions 2>/dev/null || claude --dangerously-skip-permissions"'
alias yolonew='SANDBOX_HOSTNAME=yolo _claude_docker bash -c "claude --dangerously-skip-permissions"'
