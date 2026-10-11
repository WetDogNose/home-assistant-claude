#!/bin/bash
# opencode-config — manage OpenCode's own configuration from the terminal.
#
# OpenCode can talk to any API endpoint, and all of that is expressed in one
# JSON file. This command exists so that Claude Code (or you) can change that
# file safely: atomically, with a backup, without ever putting an API key in
# the file itself, and without clobbering a file that is mid-edit.
#
# It edits the USER layer only. The add-on writes two further layers of its own
# (see opencode-layers); those are regenerated at boot and are not edited here.
#
# Runs inside the user's terminal — plain bash, no bashio.

set -o pipefail

CONFIG_DIR="${OPENCODE_USER_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/opencode}"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
SECRETS_DIR="${CONFIG_DIR}/secrets"
RUN_DIR="${OPENCODE_RUN_DIR:-/run/claude-terminal}"
DEFAULTS_FILE="${OPENCODE_DEFAULTS_FILE:-${RUN_DIR}/opencode-defaults.json}"
SHARED_REPORT="${OPENCODE_SHARED_REPORT:-${RUN_DIR}/opencode-mcp-shared.json}"
EMPTY_CONFIG='{"$schema":"https://opencode.ai/config.json"}'

show_help() {
    cat << 'EOF'
opencode-config — manage OpenCode's configuration

Usage:
  opencode-config path
  opencode-config show
  opencode-config set-provider <id> [options]
  opencode-config set-model <provider/model>
  opencode-config remove-provider <id>
  opencode-config mcp list
  opencode-config mcp add <name> --url <url> [--header K=V ...]
  opencode-config mcp add <name> [--env K=V ...] -- <command> [args ...]
  opencode-config mcp remove <name>
  opencode-config mcp sync
  opencode-config validate
  opencode-config test <id>

set-provider options:
  --base-url <url>     API endpoint, e.g. http://192.168.1.20:11434/v1
  --npm <package>      AI SDK package. Defaults to @ai-sdk/openai-compatible for
                       a new provider; use @ai-sdk/openai for a Responses API
  --builtin            <id> is a provider OpenCode already knows (anthropic,
                       openai, ...): change its endpoint, do not set a package
  --name <text>        Display name
  --model <id>         Model to list (repeatable)
  --header K=V         Extra request header (repeatable)
  --api-key-stdin      Read the API key from standard input and store it in a
                       separate file with 600 permissions
  --api-key-env <VAR>  Read the API key from an environment variable at run time

API keys are never accepted as arguments: they would land in shell history and
in the process list.

Examples:
  opencode-config set-provider ollama --base-url http://192.168.1.20:11434/v1 \
      --name "Ollama" --model qwen2.5-coder:32b
  printf '%s' "$KEY" | opencode-config set-provider openrouter \
      --base-url https://openrouter.ai/api/v1 --model anthropic/claude-opus-5-5 --api-key-stdin
  opencode-config set-model ollama/qwen2.5-coder:32b
  opencode-config test ollama
  opencode-config mcp sync       # after `claude mcp add`, share it with OpenCode

Changes take effect the next time OpenCode starts.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

valid_id() {
    case "$1" in
        ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# Variables that hold this add-on's own credentials for Home Assistant. They
# are never a model provider's API key, so naming one as a key source can only
# be a mistake or an attempt to have it sent somewhere.
reserved_env() {
    case "$1" in
        SUPERVISOR_TOKEN|HASSIO_TOKEN|HOMEASSISTANT_TOKEN|HA_TOKEN) return 0 ;;
    esac
    return 1
}

# OpenCode expands {env:NAME} and {file:PATH} wherever they appear in its
# config. In a header or an MCP environment value that turns "store this text"
# into "read this secret and send it" -- a header of {env:SUPERVISOR_TOKEN} on
# a provider is the Home Assistant token delivered to that provider. API keys
# have their own flags; nothing else needs a reference.
reject_reference() {
    case "$2" in
        *"{env:"*|*"{file:"*)
            die "$1 values may not contain {env:...} or {file:...} references."
            ;;
    esac
}

# scheme://host[:port] of a URL, for deciding whether an endpoint has moved.
url_origin() {
    local rest="${1#*://}"
    printf '%s://%s' "${1%%://*}" "${rest%%/*}"
}

# Print the user layer, or the empty document when there is none yet.
#
# A file that exists but does not parse is NOT treated as empty. It is the
# user's file mid-edit, and replacing it with a fresh document would silently
# discard whatever they were writing -- same rule as claude-hooks.
load_config() {
    if [ ! -e "$CONFIG_FILE" ]; then
        if [ -e "${CONFIG_DIR}/opencode.jsonc" ]; then
            die "${CONFIG_DIR}/opencode.jsonc exists. This command edits opencode.json only and will not create a second config beside it. Edit the .jsonc by hand, or rename it."
        fi
        printf '%s\n' "$EMPTY_CONFIG"
        return 0
    fi
    if ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "Error: ${CONFIG_FILE} is not valid JSON; refusing to modify it." >&2
        [ -f "${CONFIG_FILE}.bak" ] && echo "       The previous version is at ${CONFIG_FILE}.bak" >&2
        return 1
    fi
    cat "$CONFIG_FILE"
}

# Apply a jq filter to the user layer. Arguments mirror jq: options first, the
# filter LAST.
update_config() {
    local current updated tmp filter
    filter="${*: -1}"
    current=$(load_config) || return 1

    updated=$(printf '%s' "$current" | jq "${@:1:$#-1}" "$filter") \
        || { echo "Error: could not apply the change." >&2; return 1; }
    [ -n "$updated" ] || { echo "Error: the change produced an empty document." >&2; return 1; }

    mkdir -p "$CONFIG_DIR" || return 1
    [ -f "$CONFIG_FILE" ] && cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    printf '%s\n' "$updated" > "$tmp" || { rm -f "$tmp"; return 1; }
    # 600: headers and MCP environments can hold credentials even when the API
    # key itself is kept out.
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

restart_note() {
    echo "Restart OpenCode for this to take effect."
}

# Mask anything that is, or may be, a credential. A {env:..} or {file:..}
# reference is not a secret and is the useful thing to see, so it is kept.
REDACT_FILTER='
    def ref: type == "string" and test("^\\{(env|file):[^}]+\\}$");
    def mask: if ref then . elif type == "string" and length > 0 then "***" else . end;
    def maskall: if type == "object" then map_values(mask) else . end;
    (if (.provider | type) == "object" then
        .provider |= map_values(
            if (.options | type) == "object" then
                .options |= ((if has("apiKey") then .apiKey |= mask else . end)
                             | (if has("headers") then .headers |= maskall else . end))
            else . end)
     else . end)
    | (if (.mcp | type) == "object" then
        .mcp |= map_values(
            (if has("environment") then .environment |= maskall else . end)
            | (if has("headers") then .headers |= maskall else . end))
       else . end)'

cmd_show() {
    local current
    current=$(load_config) || return 1
    printf '%s' "$current" | jq "$REDACT_FILTER"
}

cmd_set_provider() {
    local id="${1:-}"
    valid_id "$id" || die "provider id must be letters, digits, '.', '_' or '-'."
    shift

    local base_url="" npm="" name="" builtin="false" key_stdin="false" key_env=""
    local models=() headers=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --base-url)      base_url="${2:-}"; shift 2 ;;
            --npm)           npm="${2:-}"; shift 2 ;;
            --name)          name="${2:-}"; shift 2 ;;
            --model)         models+=("${2:-}"); shift 2 ;;
            --header)        headers+=("${2:-}"); shift 2 ;;
            --builtin)       builtin="true"; shift ;;
            --api-key-stdin) key_stdin="true"; shift ;;
            --api-key-env)   key_env="${2:-}"; shift 2 ;;
            --api-key|--key)
                die "API keys are not accepted as arguments. Use --api-key-stdin or --api-key-env."
                ;;
            *) die "unknown option '$1'." ;;
        esac
    done

    case "$base_url" in
        ''|http://*|https://*) ;;
        *) die "--base-url must start with http:// or https://." ;;
    esac
    if [ "$key_stdin" = "true" ] && [ -n "$key_env" ]; then
        die "use only one of --api-key-stdin and --api-key-env."
    fi
    case "$key_env" in
        *[!A-Za-z0-9_]*) die "--api-key-env takes a variable name." ;;
    esac
    if reserved_env "$key_env"; then
        die "${key_env} is this add-on's Home Assistant credential, not a provider API key."
    fi
    # OpenCode installs and imports whatever package is named here the next
    # time it starts, without asking. The AI SDK's own scope covers every
    # provider protocol; anything else is a hand edit the user makes knowingly.
    case "$npm" in
        ''|@ai-sdk/*) ;;
        *) die "--npm accepts only @ai-sdk/* packages. To use another package, edit $(basename "$CONFIG_FILE") by hand." ;;
    esac
    case "$npm" in
        *[!A-Za-z0-9@/._-]*) die "--npm has characters that are not valid in a package name." ;;
    esac

    local header pair_json headers_json='{}' models_json='[]' api_key_ref=""
    for header in ${headers[@]+"${headers[@]}"}; do
        case "$header" in
            ?*=*) ;;
            *) die "--header expects NAME=value, got '${header}'." ;;
        esac
        reject_reference "--header" "${header#*=}"
        pair_json=$(jq -nc --arg k "${header%%=*}" --arg v "${header#*=}" '{($k): $v}')
        headers_json=$(jq -nc --argjson a "$headers_json" --argjson b "$pair_json" '$a + $b')
    done
    if [ "${#models[@]}" -gt 0 ]; then
        models_json=$(printf '%s\n' "${models[@]}" | jq -Rnc '[inputs | select(length > 0)]')
    fi

    # Validate that the file can be edited BEFORE reading a key from stdin, so
    # a refused edit does not leave an orphaned secrets file behind.
    local existing old_url drop_credentials="false"
    existing=$(load_config) || return 1

    # Moving a provider to a different host must not carry its credentials
    # along. Otherwise "change the base URL" followed by `test` -- or simply
    # by using OpenCode -- delivers the stored key and headers to the new
    # address, which is exactly what someone steering the agent would ask for.
    old_url=$(printf '%s' "$existing" | jq -r --arg id "$id" '.provider[$id].options.baseURL // empty')
    if [ -n "$base_url" ] && [ -n "$old_url" ] \
        && [ "$(url_origin "$base_url")" != "$(url_origin "$old_url")" ]; then
        drop_credentials="true"
    fi

    if [ "$key_stdin" = "true" ]; then
        local key secret_file
        IFS= read -r key || true
        [ -n "$key" ] || die "no API key on standard input."
        secret_file="${SECRETS_DIR}/${id}"
        if ! mkdir -p "$SECRETS_DIR" || ! chmod 700 "$SECRETS_DIR"; then
            die "could not create ${SECRETS_DIR}."
        fi
        ( umask 077 && printf '%s' "$key" > "$secret_file" ) || die "could not write ${secret_file}."
        chmod 600 "$secret_file"
        api_key_ref="{file:${secret_file}}"
    elif [ -n "$key_env" ]; then
        api_key_ref="{env:${key_env}}"
    fi

    update_config \
        --arg id "$id" --arg base_url "$base_url" --arg npm "$npm" --arg name "$name" \
        --arg builtin "$builtin" --arg api_key "$api_key_ref" --arg drop "$drop_credentials" \
        --argjson headers "$headers_json" --argjson models "$models_json" '
        (if (.provider | type) == "object" then .provider else {} end) as $providers
        | ($providers | has($id)) as $exists
        | (if $exists and ($providers[$id] | type) == "object" then $providers[$id] else {} end) as $old
        | (if ($old.options | type) == "object" then $old.options else {} end) as $old_options
        | (if $drop == "true" then ($old_options | del(.apiKey, .headers)) else $old_options end) as $old_options
        | (if ($old.models | type) == "object" then $old.models else {} end) as $old_models
        | .provider = ($providers + {($id): (
            $old
            # A new provider that is not one OpenCode already knows needs an
            # SDK package to speak through; openai-compatible is what almost
            # every self-hosted and aggregator endpoint implements.
            + (if $npm != "" then {npm: $npm}
               elif ($exists | not) and $builtin != "true" then {npm: "@ai-sdk/openai-compatible"}
               else {} end)
            + (if $name != "" then {name: $name} else {} end)
            + {options: (
                $old_options
                + (if $base_url != "" then {baseURL: $base_url} else {} end)
                + (if $api_key != "" then {apiKey: $api_key} else {} end)
                + (if ($headers | length) > 0
                   then {headers: ((if ($old_options.headers | type) == "object" then $old_options.headers else {} end) + $headers)}
                   else {} end)
              )}
            + (if ($models | length) > 0 or ($old_models | length) > 0
               then {models: (reduce $models[] as $m ($old_models;
                        if has($m) then . else .[$m] = {} end))}
               else {} end)
          )})' || return 1

    echo "Provider '${id}' saved to ${CONFIG_FILE}"
    [ -n "$api_key_ref" ] && echo "API key reference: ${api_key_ref}"
    if [ "$drop_credentials" = "true" ]; then
        echo "The endpoint moved to a different host, so the previous API key and headers were"
        echo "NOT carried over. Supply them again for the new endpoint if it needs them."
    fi
    restart_note
}

cmd_set_model() {
    local model="${1:-}"
    case "$model" in
        ?*/?*) ;;
        *) die "expected <provider>/<model>, e.g. ollama/qwen2.5-coder:32b." ;;
    esac
    update_config --arg model "$model" '.model = $model' || return 1
    echo "Default model set to ${model}"
    restart_note
}

cmd_remove_provider() {
    local id="${1:-}"
    valid_id "$id" || die "provider id must be letters, digits, '.', '_' or '-'."
    update_config --arg id "$id" '
        if (.provider | type) == "object" then
            .provider |= del(.[$id])
            | if (.provider | length) == 0 then del(.provider) else . end
        else . end' || return 1
    rm -f "${SECRETS_DIR:?}/${id}"
    echo "Provider '${id}' removed."
    restart_note
}

cmd_mcp_list() {
    local current
    current=$(load_config) || return 1
    printf '%s' "$current" | jq -r '
        if (.mcp | type) == "object" then .mcp else {} end
        | to_entries[] | select(.key | test("^[A-Za-z0-9._-]{1,64}$"))
        | "\(.key)\t\(.value.type | tostring | gsub("[^a-z]"; ""))\tuser"'
    if [ -s "$DEFAULTS_FILE" ]; then
        local shared='[]'
        [ -s "$SHARED_REPORT" ] && shared=$(jq -c '.shared' "$SHARED_REPORT" 2>/dev/null || echo '[]')
        jq -r --argjson shared "$shared" '
            if (.mcp | type) == "object" then .mcp else {} end
            | to_entries[]
            | .key as $name
            | "\($name)\t\(.value.type | tostring | gsub("[^a-z]"; ""))\t\(if ($shared | index($name)) != null then "shared from Claude Code" else "add-on" end)"' \
            "$DEFAULTS_FILE" 2>/dev/null
    fi
}

cmd_mcp_add() {
    local name="${1:-}"
    valid_id "$name" || die "server name must be letters, digits, '.', '_' or '-'."
    shift

    local url="" envs=() headers=() command=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --url)    url="${2:-}"; shift 2 ;;
            --env)    envs+=("${2:-}"); shift 2 ;;
            --header) headers+=("${2:-}"); shift 2 ;;
            --)       shift; command=("$@"); break ;;
            *) die "unknown option '$1'. Put the server command after '--'." ;;
        esac
    done

    if [ -n "$url" ] && [ "${#command[@]}" -gt 0 ]; then
        die "give either --url or a command after '--', not both."
    fi
    if [ -z "$url" ] && [ "${#command[@]}" -eq 0 ]; then
        die "give --url <url> for a remote server, or a command after '--' for a local one."
    fi

    local pair pair_json env_json='{}' headers_json='{}' command_json='[]'
    for pair in ${envs[@]+"${envs[@]}"}; do
        case "$pair" in ?*=*) ;; *) die "--env expects NAME=value, got '${pair}'." ;; esac
        reject_reference "--env" "${pair#*=}"
        pair_json=$(jq -nc --arg k "${pair%%=*}" --arg v "${pair#*=}" '{($k): $v}')
        env_json=$(jq -nc --argjson a "$env_json" --argjson b "$pair_json" '$a + $b')
    done
    for pair in ${headers[@]+"${headers[@]}"}; do
        case "$pair" in ?*=*) ;; *) die "--header expects NAME=value, got '${pair}'." ;; esac
        reject_reference "--header" "${pair#*=}"
        pair_json=$(jq -nc --arg k "${pair%%=*}" --arg v "${pair#*=}" '{($k): $v}')
        headers_json=$(jq -nc --argjson a "$headers_json" --argjson b "$pair_json" '$a + $b')
    done
    if [ "${#command[@]}" -gt 0 ]; then
        # Fed in as lines, not as jq arguments: a server command routinely has
        # words like -y in it, which jq would take for its own options.
        command_json=$(printf '%s\n' "${command[@]}" | jq -Rnc '[inputs]')
    fi

    update_config \
        --arg name "$name" --arg url "$url" \
        --argjson env "$env_json" --argjson headers "$headers_json" --argjson command "$command_json" '
        .mcp = ((if (.mcp | type) == "object" then .mcp else {} end) + {($name): (
            if $url != "" then
                {type: "remote", url: $url}
                + (if ($headers | length) > 0 then {headers: $headers} else {} end)
            else
                {type: "local", command: $command}
                + (if ($env | length) > 0 then {environment: $env} else {} end)
            end + {enabled: true})})' || return 1

    echo "MCP server '${name}' added to ${CONFIG_FILE}"
    restart_note
}

cmd_mcp_remove() {
    local name="${1:-}"
    valid_id "$name" || die "server name must be letters, digits, '.', '_' or '-'."
    update_config --arg name "$name" '
        if (.mcp | type) == "object" then
            .mcp |= del(.[$name])
            | if (.mcp | length) == 0 then del(.mcp) else . end
        else . end' || return 1
    echo "MCP server '${name}' removed from the user config."
    echo "A server shared from Claude Code or provided by the add-on is not affected."
    restart_note
}

cmd_mcp_sync() {
    command -v opencode-layers >/dev/null 2>&1 || die "opencode-layers is not installed."
    opencode-layers resync || die "could not regenerate the add-on's OpenCode layers."
    if [ -s "$SHARED_REPORT" ]; then
        jq -r '"Shared from Claude Code: \(if (.shared | length) > 0 then (.shared | join(", ")) else "none" end)",
               (if (.skipped | length) > 0 then "Not shared (no OpenCode equivalent): \(.skipped | join(", "))" else empty end),
               (if ((.unapproved // []) | length) > 0 then "Not shared (in /config/.mcp.json but not approved in Claude Code): \(.unapproved | join(", "))\n  Start Claude in /config and approve the server there first." else empty end)' \
            "$SHARED_REPORT"
    fi
    restart_note
}

cmd_mcp() {
    case "${1:-}" in
        list)   cmd_mcp_list ;;
        add)    shift; cmd_mcp_add "$@" ;;
        remove) shift; cmd_mcp_remove "$@" ;;
        sync)   cmd_mcp_sync ;;
        *) die "usage: opencode-config mcp list|add|remove|sync" ;;
    esac
}

cmd_validate() {
    local current rc=0 ref path
    current=$(load_config) || return 1
    echo "OK: ${CONFIG_FILE} parses"

    # A {file:} reference to a file that is not there fails at OpenCode start
    # with an error that names the config, not the missing key.
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        path="${ref/#\~/$HOME}"
        if [ -r "$path" ]; then
            echo "OK: ${ref} exists"
        else
            echo "FAIL: referenced file ${ref} is missing or unreadable"
            rc=1
        fi
    done < <(printf '%s' "$current" | jq -r '
        [.. | strings | scan("\\{file:([^}]+)\\}") | .[0]] | unique | .[]')

    if command -v opencode >/dev/null 2>&1; then
        # Output is DISCARDED on purpose: the resolved config has every {env:}
        # and {file:} reference expanded, i.e. it contains the API keys.
        local errors
        if errors=$(timeout 60 opencode debug config 2>&1 >/dev/null); then
            echo "OK: OpenCode accepts the merged configuration"
        else
            echo "FAIL: OpenCode rejects the configuration:"
            printf '%s\n' "$errors" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^/  /' | head -20
            rc=1
        fi
    else
        echo "SKIP: opencode is not on PATH; schema not checked"
    fi
    return "$rc"
}

# Resolve an apiKey value to the key itself, for `test` only. Never printed.
#
# Deliberately narrower than what OpenCode itself will expand. `test` sends the
# result to whatever baseURL the config names, so it must not be a way to read
# an arbitrary file or the add-on's own Home Assistant token and post it: a
# {file:} reference is honoured only inside this command's secrets directory,
# and reserved variables are refused. Returns 1 for a reference it will not
# follow.
resolve_secret() {
    local value="$1" path var
    case "$value" in
        "{file:"*"}")
            path="${value#\{file:}"; path="${path%\}}"
            case "$path" in
                "${SECRETS_DIR}/"*) ;;
                *) return 1 ;;
            esac
            valid_id "${path#"${SECRETS_DIR}/"}" || return 1
            [ -r "$path" ] && tr -d '\r\n' < "$path"
            return 0
            ;;
        "{env:"*"}")
            var="${value#\{env:}"; var="${var%\}}"
            case "$var" in *[!A-Za-z0-9_]*|'') return 1 ;; esac
            reserved_env "$var" && return 1
            printf '%s' "${!var:-}"
            return 0
            ;;
        *"{file:"*|*"{env:"*) return 1 ;;
        *) printf '%s' "$value" ;;
    esac
}

cmd_test() {
    local id="${1:-}" current base_url key_ref key
    valid_id "$id" || die "usage: opencode-config test <provider-id>"
    current=$(load_config) || return 1

    base_url=$(printf '%s' "$current" | jq -r --arg id "$id" '.provider[$id].options.baseURL // empty')
    [ -n "$base_url" ] || die "provider '${id}' has no baseURL in ${CONFIG_FILE}."
    key_ref=$(printf '%s' "$current" | jq -r --arg id "$id" '.provider[$id].options.apiKey // empty')
    if ! key=$(resolve_secret "$key_ref"); then
        die "provider '${id}' takes its API key from a reference this command will not follow (only keys stored with --api-key-stdin, or a non-reserved --api-key-env). Nothing was sent."
    fi

    # These values come from a file that may have been edited by hand, and
    # they are about to be handed to curl. Checked with `case`, which sees the
    # whole string: a line-oriented tool such as grep tests each line
    # separately, so a value with an embedded newline passes it.
    case "$base_url" in
        http://*|https://*) ;;
        *) die "provider '${id}' has a baseURL that is not http(s)." ;;
    esac
    case "$base_url" in
        *[[:cntrl:][:space:]\"\\]*)
            die "provider '${id}' has a baseURL containing quotes, backslashes, spaces or control characters."
            ;;
    esac
    case "$key" in
        *[[:cntrl:]]*) die "the API key for '${id}' contains control characters." ;;
    esac
    # A header is one line. A CR or LF inside a name or value would smuggle a
    # second header into the request.
    if ! printf '%s' "$current" | jq -e --arg id "$id" '
        (.provider[$id].options.headers // {})
        | if type != "object" then false
          else all(to_entries[];
                   (.key | test("^[A-Za-z0-9-]+$"))
                   and (.value | type == "string" or type == "number" or type == "boolean")
                   and (.value | tostring | test("[\\x00-\\x1f\\x7f]") | not)
                   and (.value | tostring | test("\\{(env|file):") | not))
          end' >/dev/null 2>&1; then
        die "provider '${id}' has a header name or value that cannot be sent safely."
    fi

    # Headers go to curl in a FILE (-H @file), one per line, and the URL as an
    # ordinary argument after `--`. The key must stay out of the process list,
    # but a curl *config* is the wrong tool for that: in its syntax a newline
    # starts a new directive and `output` is a file write, so anything that
    # slipped past validation became an arbitrary-write primitive. A header
    # file can only ever hold headers.
    local body headers status
    body=$(mktemp) || return 1
    headers=$(mktemp) || { rm -f "$body"; return 1; }
    chmod 600 "$headers"
    {
        [ -n "$key" ] && printf 'Authorization: Bearer %s\n' "$key"
        printf '%s' "$current" | jq -r --arg id "$id" '
            (.provider[$id].options.headers // {}) | to_entries[] | "\(.key): \(.value | tostring)"'
    } > "$headers"

    status=$(curl -sS -m 15 -o "$body" -w '%{http_code}' -H "@${headers}" \
        -- "${base_url%/}/models" 2>/dev/null) || status="000"
    rm -f "$headers"

    local rc=0
    case "$status" in
        2??)
            local count
            count=$(jq -r 'if (.data | type) == "array" then (.data | length)
                           elif (.models | type) == "array" then (.models | length)
                           else "?" end' "$body" 2>/dev/null || echo "?")
            echo "OK: ${base_url%/}/models answered ${status} (${count} models)"
            # The ids are text chosen by the endpoint, shown on a terminal and
            # very likely read by the agent that ran this. Printable characters
            # only, bounded, so a reply cannot draw on the screen or pose as
            # instructions spread over several lines.
            jq -r '[if (.data | type) == "array" then .data[].id
                    elif (.models | type) == "array" then .models[] | (.id // .name)
                    else empty end
                    | tostring | gsub("[^A-Za-z0-9 ._:/@+-]"; "") | .[0:100] | select(length > 0)]
                   | .[0:20][]' "$body" 2>/dev/null | sed 's/^/  /'
            ;;
        000)
            echo "FAIL: could not connect to ${base_url%/}/models"
            rc=1
            ;;
        401|403)
            echo "FAIL: ${base_url%/}/models answered ${status} — the endpoint is reachable but rejected the credentials"
            rc=1
            ;;
        *)
            echo "FAIL: ${base_url%/}/models answered ${status}"
            echo "  Some endpoints do not implement /models and still serve completions;"
            echo "  if so, try a prompt in OpenCode before concluding it is broken."
            rc=1
            ;;
    esac
    rm -f "$body"
    return "$rc"
}

case "${1:-}" in
    path)            echo "$CONFIG_FILE" ;;
    show)            cmd_show ;;
    set-provider)    shift; cmd_set_provider "$@" ;;
    set-model)       shift; cmd_set_model "$@" ;;
    remove-provider) shift; cmd_remove_provider "$@" ;;
    mcp)             shift; cmd_mcp "$@" ;;
    validate)        cmd_validate ;;
    test)            shift; cmd_test "$@" ;;
    -h|--help|help)  show_help ;;
    *)               show_help; exit 1 ;;
esac
