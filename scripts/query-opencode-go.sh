#!/usr/bin/env bash
# Query OpenCode Go API-key status and usage.
#
# OpenCode stores the Go model API key in the OpenCode data auth file under:
#   ~/.local/share/opencode/auth.json -> ["opencode-go"].key
#
# The key validates access to the OpenCode Go model API. Usage windows come
# from the official usage API (https://opencode.ai/zen/go/v1/usage) with the
# same API key.

set -euo pipefail

PROVIDER_ID="opencode-go"
MODELS_URL="https://opencode.ai/zen/go/v1/models"
USAGE_API_URL="https://opencode.ai/zen/go/v1/usage"

JSON_OUTPUT=false
MODELS_ONLY=false
AUTH_FILE_OVERRIDE="${OPENCODE_GO_AUTH_FILE:-${OPENCODE_AUTH_FILE:-}}"
API_KEY="${OPENCODE_GO_API_KEY:-${OPENCODE_API_KEY:-}}"
API_KEY_SOURCE=""
USAGE_SOURCE="OpenCode Go API (zen/go/v1/usage)"

usage() {
    cat <<'EOF'
Usage: scripts/query-opencode-go.sh [options]

Options:
  --json                    Print machine-readable JSON
  --models-only             Validate the OpenCode Go API key only
  --auth-file PATH          Read OpenCode auth from PATH
  -h, --help                Show this help

Environment:
  OPENCODE_GO_API_KEY       OpenCode Go API key override
  OPENCODE_API_KEY          OpenCode API key override used by the Go provider
  OPENCODE_GO_AUTH_FILE     OpenCode auth.json path override
  OPENCODE_AUTH_FILE        OpenCode auth.json path override
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

mask_secret() {
    local value="$1"
    local length=${#value}

    if (( length <= 8 )); then
        printf '***'
        return
    fi

    local prefix="${value:0:6}"
    local suffix_start=$((length - 4))
    local suffix="${value:suffix_start:4}"
    printf '%s...%s' "$prefix" "$suffix"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --models-only)
                MODELS_ONLY=true
                shift
                ;;
            --auth-file)
                [[ $# -ge 2 ]] || fail "--auth-file requires a path"
                AUTH_FILE_OVERRIDE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
    done
}

auth_file_candidates() {
    if [[ -n "$AUTH_FILE_OVERRIDE" ]]; then
        printf '%s\n' "$AUTH_FILE_OVERRIDE"
    fi

    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        printf '%s\n' "$XDG_DATA_HOME/opencode/auth.json"
    fi

    printf '%s\n' "$HOME/.local/share/opencode/auth.json"
    printf '%s\n' "$HOME/Library/Application Support/opencode/auth.json"
}

find_auth_file() {
    local candidate
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(auth_file_candidates)

    return 1
}

load_api_key() {
    if [[ -n "$API_KEY" ]]; then
        API_KEY_SOURCE="environment"
        return
    fi

    local auth_file
    auth_file="$(find_auth_file)" || {
        fail "OpenCode auth file not found. Expected ~/.local/share/opencode/auth.json or set OPENCODE_GO_API_KEY."
    }

    API_KEY="$(jq -r --arg provider "$PROVIDER_ID" '.[$provider].key // empty' "$auth_file")"
    [[ -n "$API_KEY" ]] || {
        fail "No OpenCode Go API key found at $auth_file under key \"$PROVIDER_ID\"."
    }

    API_KEY_SOURCE="$auth_file"
}
http_get_to_file() {
    local url="$1"
    shift
    local body_file
    body_file="$(mktemp)"
    local status
    status="$(
        curl -sS -L -o "$body_file" -w '%{http_code}' "$url" "$@" || true
    )"
    printf '%s %s\n' "$status" "$body_file"
    [[ "$status" =~ ^2 ]]
}

validate_models_api() {
    local fetched
    fetched="$(http_get_to_file "$MODELS_URL" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json")" || {
        local status="${fetched%% *}"
        local body_file="${fetched#* }"
        local message
        message="$(jq -r '.error.message // .message // .error // empty' "$body_file" 2>/dev/null || true)"
        rm -f "$body_file"
        [[ -n "$message" ]] || message="HTTP $status from $MODELS_URL"
        fail "OpenCode Go API key validation failed: $message"
    }

    local body_file="${fetched#* }"

    local model_count
    model_count="$(jq -r '(.data // .models // []) | length' "$body_file")"
    rm -f "$body_file"
    printf '%s\n' "$model_count"
}

fetch_usage_api() {
    local fetched
    fetched="$(http_get_to_file "$USAGE_API_URL" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json")" || {
        local status="${fetched%% *}"
        local body_file="${fetched#* }"
        local message
        message="$(jq -r '.error.message // .message // .error // empty' "$body_file" 2>/dev/null || true)"
        rm -f "$body_file"
        [[ -n "$message" ]] || message="OpenCode Go usage API request failed (HTTP $status)"
        jq -n --arg message "$message" '{"error": $message}'
        return 4
    }

    local body_file="${fetched#* }"
    parse_go_windows "$body_file"
    local parse_status=$?
    rm -f "$body_file"
    return "$parse_status"
}

# Shared usage-window parser for the usage API response.
# Usage: parse_go_windows <file>
# Prints {"windows": {...}} on success or {"error": ...} on failure.
parse_go_windows() {
    local path="$1"

    python3 - "$path" <<'PY'
import datetime as dt
import json
import sys

path = sys.argv[1]
raw = open(path, "r", encoding="utf-8", errors="ignore").read()

fields = {
    "rolling": "5h",
    "weekly": "Weekly",
    "monthly": "Monthly",
}

now = dt.datetime.now(dt.timezone.utc)

def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(2)

def duration(seconds):
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"

def parse_reset(value):
    if not value or not isinstance(value, str):
        return None, None
    text = value.replace("Z", "+00:00")
    try:
        reset_at = dt.datetime.fromisoformat(text)
    except ValueError:
        return None, None
    if reset_at.tzinfo is None:
        reset_at = reset_at.replace(tzinfo=dt.timezone.utc)
    reset_seconds = int((reset_at - now).total_seconds())
    return max(0, reset_seconds), reset_at

def window_dict(field, label, usage_percent, reset_seconds, reset_at):
    if reset_at is None:
        reset_in = None
        resets_at = None
    else:
        reset_in = duration(reset_seconds)
        resets_at = reset_at.isoformat().replace("+00:00", "Z")
    return {
        "field": field,
        "label": label,
        "usage_percent": usage_percent,
        "percent_remaining": max(0.0, 100.0 - usage_percent),
        "reset_in_seconds": reset_seconds,
        "reset_in": reset_in,
        "resets_at": resets_at,
    }

def parse_percent(value):
    # Accept numbers and numeric strings (mirrors the app decoder).
    # Booleans are rejected: float(True) is 1.0, which would fake a window.
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    fail("OpenCode Go usage API returned invalid JSON")
usage = payload.get("usage") if isinstance(payload, dict) else None
if not isinstance(usage, dict):
    fail("No OpenCode Go usage windows found in API response")

windows = {}
for key, label in fields.items():
    entry = usage.get(key)
    if not isinstance(entry, dict):
        continue
    if isinstance(entry.get("status"), str) and entry["status"].lower() != "ok":
        continue
    usage_percent = parse_percent(entry.get("percent"))
    if usage_percent is None:
        continue
    reset_seconds, reset_at = parse_reset(entry.get("resetsAt"))
    windows[key] = window_dict(key, label, usage_percent, reset_seconds, reset_at)

if not windows:
    fail("No OpenCode Go usage windows found in API response")
print(json.dumps({"windows": windows}, sort_keys=True))
PY
}
print_text_result() {
    local model_count="$1"
    local usage_json="${2:-}"
    local usage_error="${3:-}"

    echo "=== OpenCode Go Usage ==="
    echo ""
    echo "Auth source: $API_KEY_SOURCE"
    echo "API key: $(mask_secret "$API_KEY")"
    echo "Model API: OK ($model_count models available)"

    if [[ "$MODELS_ONLY" == true ]]; then
        return
    fi

    echo ""
    if [[ -z "$usage_json" ]]; then
        echo "Usage: not available"
        echo "Reason: ${usage_error:-usage API request failed}"
        return
    fi

    echo "Usage source: $USAGE_SOURCE"
    echo "$usage_json" | jq -r '
        def pct: ((. * 100 | round) / 100 | tostring);
        .windows
        | to_entries[]
        | "\(.value.label): \(.value.usage_percent | pct)% used, \(.value.percent_remaining | pct)% left, resets in \(.value.reset_in // "unknown") (\(.value.resets_at // "unknown"))"
    '
}

print_json_result() {
    local model_count="$1"
    local usage_json="${2:-null}"
    local usage_error="${3:-}"

    jq -n \
        --arg provider "$PROVIDER_ID" \
        --arg auth_source "$API_KEY_SOURCE" \
        --arg key_preview "$(mask_secret "$API_KEY")" \
        --arg models_url "$MODELS_URL" \
        --arg usage_source "$USAGE_SOURCE" \
        --argjson model_count "$model_count" \
        --argjson usage "$usage_json" \
        --arg usage_error "$usage_error" \
        '{
            provider: $provider,
            auth: {
                source: $auth_source,
                key_preview: $key_preview
            },
            models: {
                endpoint: $models_url,
                status: "ok",
                count: $model_count
            },
            usage: $usage,
            usage_source: (if $usage_source == "" then null else $usage_source end),
            usage_error: (if $usage_error == "" then null else $usage_error end)
        }'
}

main() {
    parse_args "$@"
    require_command curl
    require_command jq
    require_command python3

    load_api_key

    local model_count
    model_count="$(validate_models_api)"

    if [[ "$MODELS_ONLY" == true ]]; then
        if [[ "$JSON_OUTPUT" == true ]]; then
            print_json_result "$model_count"
        else
            print_text_result "$model_count"
        fi
        return
    fi

    local usage_json=""
    local usage_error=""
    local api_output=""
    if ! api_output="$(fetch_usage_api)"; then
        usage_error="$(jq -r '.error // empty' <<<"$api_output" 2>/dev/null || true)"
        [[ -n "$usage_error" ]] || usage_error="usage API request failed"
    else
        usage_json="$api_output"
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        if [[ -n "$usage_json" ]]; then
            print_json_result "$model_count" "$usage_json"
        else
            print_json_result "$model_count" "null" "$usage_error"
        fi
    else
        print_text_result "$model_count" "$usage_json" "$usage_error"
    fi
}

main "$@"
