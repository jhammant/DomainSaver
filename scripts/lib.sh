#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib.sh - DomainSaver shared core library.
#
# Source this from every other DomainSaver script:
#
#     . "$(dirname "$0")/lib.sh"
#
# DESIGN CONSTRAINTS (deliberate, do not "modernise" away):
#   * Portable to bash 3.2 (the /bin/bash shipped by macOS). No associative
#     arrays, no `declare -A`, no `${var^^}`, no `readarray`. Lookup tables are
#     TSV files read with awk, or space-delimited strings matched with `case`.
#   * POSIX-ish external tools only: curl, jq, awk, grep, sed, tr, cut, whois.
#     No GNU-only flags. Never `sed -i` (BSD sed needs an argument to -i).
#   * No network access, no file writes and no side effects at source time.
#     Everything that touches the network or the cache happens inside a
#     function, when it is called.
#   * Safe to source under `set -euo pipefail`.
#
# THE CENTRAL IDEA THIS LIBRARY ENCODES:
#   AVAILABILITY IS NOT PURCHASABILITY. An RDAP 404 means "not present in the
#   registry", which covers three very different commercial realities:
#   genuinely available, registry-RESERVED, and PREMIUM-PRICED. This library
#   therefore only ever reports UNREGISTERED / REGISTERED / ERROR. Promoting
#   UNREGISTERED to AVAILABLE, PREMIUM or RESERVED requires a real price quote
#   and is the job of the pricing layer, never of a probe.
#
# STATUS VOCABULARY OWNED BY THIS FILE:
#   UNREGISTERED  not present in the registry (may still be reserved/premium)
#   REGISTERED    taken
#   ERROR         lookup failed, rate-limited, timed out or was unparseable
#
# Public functions are prefixed `ds_`. Anything prefixed `_ds_` is internal and
# may change without notice.

# Idempotent source guard: sourcing twice must be a no-op, not a re-definition
# storm (and must not clobber caller state).
if [ -n "${DS_LIB_SOURCED:-}" ]; then
	# shellcheck disable=SC2317  # reached only when this file is re-sourced
	return 0 2>/dev/null || true
fi
DS_LIB_SOURCED=1

DS_LIB_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# SECTION 1: paths
# ---------------------------------------------------------------------------

# _ds_resolve_lib_dir
#   Internal. Echoes the absolute directory containing this lib.sh, following
#   symlinks. Runs entirely in subshells so the caller's cwd is never changed.
_ds_resolve_lib_dir() {
	_ds_src="${BASH_SOURCE[0]:-$0}"
	while [ -h "$_ds_src" ]; do
		_ds_dir=$(cd -P "$(dirname "$_ds_src")" >/dev/null 2>&1 && pwd)
		_ds_src=$(readlink "$_ds_src")
		case "$_ds_src" in
		/*) ;;
		*) _ds_src="$_ds_dir/$_ds_src" ;;
		esac
	done
	cd -P "$(dirname "$_ds_src")" >/dev/null 2>&1 && pwd
}

# DS_LIB_DIR / DS_ROOT / DS_DATA_DIR are resolved once, at source time, from the
# location of this file - so every script works regardless of the caller's cwd.
# All three honour a pre-existing environment value (useful for tests).
: "${DS_LIB_DIR:=$(_ds_resolve_lib_dir)}"
: "${DS_ROOT:=$(cd -P "$DS_LIB_DIR/.." >/dev/null 2>&1 && pwd)}"
: "${DS_DATA_DIR:=$DS_ROOT/data}"
unset _ds_src _ds_dir 2>/dev/null || true

# ds_root
#   Args:   none
#   Stdout: absolute path to the repository root (the parent of scripts/).
#   Exit:   always 0
ds_root() { printf '%s\n' "$DS_ROOT"; }

# ds_data_dir
#   Args:   none
#   Stdout: absolute path to the cache/data directory ($DS_ROOT/data).
#   Exit:   always 0
#   Note:   does not create the directory; see _ds_ensure_data_dir.
ds_data_dir() { printf '%s\n' "$DS_DATA_DIR"; }

# Cache file locations. Sibling scripts should reference these variables rather
# than hard-coding filenames, so the layout can change in one place.
DS_RDAP_BOOTSTRAP_JSON="$DS_DATA_DIR/rdap-bootstrap.json"  # raw IANA dns.json
DS_RDAP_INDEX_TSV="$DS_DATA_DIR/rdap-endpoints.tsv"        # tld<TAB>url
DS_RDAP_OVERRIDES_TSV="$DS_DATA_DIR/rdap-overrides.tsv"    # tld<TAB>url|WHOIS
DS_WHOIS_SERVERS_TSV="$DS_DATA_DIR/whois-servers.tsv"      # tld<TAB>server
DS_PRICING_JSON="$DS_DATA_DIR/porkbun-pricing.json"        # raw Porkbun payload
DS_PRICE_INDEX_TSV="$DS_DATA_DIR/tld-prices.tsv"           # tld<TAB>reg<TAB>ren<TAB>xfer
DS_TLD_FLAGS_TSV="$DS_DATA_DIR/tld-flags.tsv"              # tld<TAB>EXTRA FLAGS

# ---------------------------------------------------------------------------
# SECTION 2: logging
# ---------------------------------------------------------------------------

# ds_log <message...>
#   Informational logging. Writes "[ds] <message>" to STDERR (never stdout, so
#   it can never corrupt a pipeline of probe results). Silenced by DS_QUIET=1.
#   Exit: always 0.
ds_log() {
	[ "${DS_QUIET:-0}" = "1" ] && return 0
	printf '[ds] %s\n' "$*" >&2
	return 0
}

# ds_warn <message...>
#   Warning logging to STDERR. Always shown, even under DS_QUIET, because
#   warnings here mean "your results may be wrong".
#   Exit: always 0.
ds_warn() {
	printf '[ds] WARN: %s\n' "$*" >&2
	return 0
}

# ds_debug <message...>
#   Verbose tracing to STDERR. Only emitted when DS_DEBUG=1.
#   Exit: always 0.
ds_debug() {
	[ "${DS_DEBUG:-0}" = "1" ] || return 0
	printf '[ds] DEBUG: %s\n' "$*" >&2
	return 0
}

# ds_die <message...>
#   Fatal error: writes "[ds] FATAL: <message>" to STDERR and exits 1.
#   Does not return. Do not call from a function whose caller needs to recover.
ds_die() {
	printf '[ds] FATAL: %s\n' "$*" >&2
	exit 1
}

# _ds_have <command>
#   Internal. True (exit 0) if <command> is on PATH.
_ds_have() { command -v "$1" >/dev/null 2>&1; }

# ds_require <command...>
#   Args:   one or more command names that must exist on PATH.
#   Stdout: nothing.
#   Exit:   0 if all present; otherwise calls ds_die (exits 1) naming the first
#           missing command.
ds_require() {
	_dsr_missing=""
	for _dsr_cmd in "$@"; do
		_ds_have "$_dsr_cmd" || _dsr_missing="$_dsr_missing $_dsr_cmd"
	done
	if [ -n "$_dsr_missing" ]; then
		ds_die "missing required command(s):$_dsr_missing"
	fi
	unset _dsr_missing _dsr_cmd
	return 0
}

# _ds_ensure_data_dir
#   Internal. Creates $DS_DATA_DIR if absent. Called only on cache-write paths.
_ds_ensure_data_dir() { mkdir -p "$DS_DATA_DIR" 2>/dev/null || true; }

# _ds_cache_missing <path> <bootstrap-hint>
#   Internal. If <path> does not exist, warn ONCE per process with a clear
#   instruction to run bootstrap.sh, and return 0 (missing). Returns 1 if the
#   file is present. This is how the library "tolerates" a cold cache.
_DS_WARNED_CACHES=""
_ds_cache_missing() {
	[ -s "$1" ] && return 1
	case " $_DS_WARNED_CACHES " in
	*" $1 "*) return 0 ;;
	esac
	_DS_WARNED_CACHES="$_DS_WARNED_CACHES $1"
	ds_warn "cache missing: $1"
	ds_warn "  -> run: $DS_ROOT/scripts/bootstrap.sh   ($2)"
	return 0
}

# _ds_mktemp
#   Internal. Echoes the path of a fresh temp file. Caller must rm it.
_ds_mktemp() { mktemp "${TMPDIR:-/tmp}/domainsaver.XXXXXXXX"; }

# ---------------------------------------------------------------------------
# SECTION 3: string / name helpers
# ---------------------------------------------------------------------------

# ds_normalize_domain <domain>
#   Args:   a domain name, any case, optional trailing dot / surrounding space.
#   Stdout: the lowercased, trimmed, trailing-dot-stripped name.
#   Exit:   0 always (empty input yields empty output).
ds_normalize_domain() {
	printf '%s' "${1:-}" |
		tr '[:upper:]' '[:lower:]' |
		tr -d '[:space:]' |
		sed -e 's/\.$//'
	printf '\n'
}

# ds_normalize_tld <tld>
#   Args:   a TLD, with or without a leading dot, any case.
#   Stdout: the bare lowercased TLD (e.g. "uk").
#   Exit:   0 always.
ds_normalize_tld() {
	printf '%s' "${1:-}" |
		tr '[:upper:]' '[:lower:]' |
		tr -d '[:space:]' |
		sed -e 's/^\.//' -e 's/\.$//'
	printf '\n'
}

# ds_tld <domain>
#   Args:   a domain name.
#   Stdout: its last label, lowercased (e.g. "example.co.uk" -> "uk").
#   Exit:   0 if a TLD was extracted; 1 if the input has no dot at all.
ds_tld() {
	_dst_d=$(ds_normalize_domain "${1:-}")
	case "$_dst_d" in
	*.*) ;;
	*)
		unset _dst_d
		return 1
		;;
	esac
	printf '%s\n' "${_dst_d##*.}"
	unset _dst_d
	return 0
}

# _ds_sanitize_detail <text...>
#   Internal. Squashes whitespace and strips '|' so a detail string can never
#   break the pipe-delimited probe output contract.
_ds_sanitize_detail() {
	printf '%s' "$*" | tr '|' '/' | tr '\n\t' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
	printf '\n'
}

# _ds_url_host <url>
#   Internal. Echoes the lowercased hostname of <url>, stripping the scheme,
#   any userinfo, the port and the path. Host-level matching is the only safe
#   way to test an endpoint against a deny list.
_ds_url_host() {
	printf '%s' "${1:-}" |
		sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
			-e 's#[/?].*$##' \
			-e 's#^[^@]*@##' \
			-e 's#:[0-9]*$##' |
		tr '[:upper:]' '[:lower:]'
	printf '\n'
}

# _ds_timeout <seconds> <command...>
#   Internal. Runs <command> with a wall-clock limit. Uses timeout/gtimeout when
#   available (GNU coreutils), otherwise a pure-bash watchdog - macOS has no
#   `timeout` by default and an unbounded `whois` will hang a batch run forever.
#   Exit: the command's status, or 124 if it was killed for exceeding the limit.
_ds_timeout() {
	_dt_secs="$1"
	shift
	if _ds_have timeout; then
		timeout "$_dt_secs" "$@"
		return $?
	fi
	if _ds_have gtimeout; then
		gtimeout "$_dt_secs" "$@"
		return $?
	fi

	"$@" &
	_dt_pid=$!
	# Watchdog. stdout/stderr are closed so it can never hold open the pipe of
	# an enclosing command substitution.
	(
		_dt_i=0
		while [ "$_dt_i" -lt "$_dt_secs" ]; do
			kill -0 "$_dt_pid" 2>/dev/null || exit 0
			sleep 1
			_dt_i=$((_dt_i + 1))
		done
		kill -TERM "$_dt_pid" 2>/dev/null
		sleep 1
		kill -KILL "$_dt_pid" 2>/dev/null
	) >/dev/null 2>&1 &
	_dt_watch=$!

	_dt_rc=0
	wait "$_dt_pid" 2>/dev/null || _dt_rc=$?
	kill -TERM "$_dt_watch" 2>/dev/null || true
	wait "$_dt_watch" 2>/dev/null || true

	# 143 == 128+SIGTERM, i.e. the watchdog fired. Normalise to timeout's 124.
	[ "$_dt_rc" = "143" ] && _dt_rc=124
	return "$_dt_rc"
}

# ---------------------------------------------------------------------------
# SECTION 4: registry routing tables (hard-won; see README rationale)
# ---------------------------------------------------------------------------

# Google Registry TLDs. The IANA bootstrap endpoint for these throttles hard;
# https://pubapi.registry.google/rdap is generous and is what we must use.
# NOTE: .nexus is a Google Registry TLD and is deliberately routed here even
# though it is sometimes lumped in with Identity Digital.
_DS_GOOGLE_TLDS="app dev foo how day soy page new zip mov meme ing boo esq prof phd rsvp channel nexus"
_DS_GOOGLE_RDAP="https://pubapi.registry.google/rdap"

# TLDs with no usable RDAP service at all - these must go straight to whois.
_DS_NO_RDAP_TLDS="io co me sh gg im st us eu de ch li at es se dk ie nz"

# Identity Digital / Afilias / Donuts throttle RDAP brutally (measured: 87
# lookups still hanging after 10 minutes) - but they must NOT be diverted to
# whois, because most of their gTLDs are RDAP-ONLY. ICANN sunset the WHOIS
# requirement for gTLDs, so IANA returns an empty "whois:" line for them and a
# whois diversion can only ever produce ERROR (measured: betalab.fyi).
# These are therefore SLOW, not unusable: sweep.sh gives every host matching
# this pattern a concurrency budget of 1 (see data/registry-limits.tsv), which
# is what makes them tractable. The pattern is advisory only - it is used to
# flag a registry as throttled, never to refuse RDAP.
_DS_RDAP_HOST_SLOW_RE='identitydigital|afilias|donuts|rightside'

# The rdap.org proxy returns HTTP 429 after roughly 60 requests. Never use it,
# even if it somehow appears in a bootstrap file or an override.
# NB: both patterns are matched against the parsed HOSTNAME (see _ds_url_host),
# never against the whole URL - anchoring on '^' or '.' cannot match a host that
# is preceded by "//" in a URL, which silently disabled this guard once already.
_DS_RDAP_HOST_BANNED_RE='^(.*\.)?rdap\.org$'

# Whois servers that are commonly guessed wrong. .co is whois.registry.co, NOT
# whois.nic.co. Everything else is resolved from IANA at runtime and cached.
_ds_whois_override() {
	case "$1" in
	co) printf 'whois.registry.co\n' ;;
	uk) printf 'whois.nic.uk\n' ;;
	*) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 5: RDAP endpoint resolution
# ---------------------------------------------------------------------------

# ds_build_rdap_index
#   Rebuilds $DS_RDAP_INDEX_TSV (tld<TAB>url) from the cached IANA bootstrap
#   file $DS_RDAP_BOOTSTRAP_JSON. Intended for bootstrap.sh, but also called
#   lazily by ds_rdap_endpoint when the JSON exists and the index does not.
#   Args:   none
#   Stdout: nothing
#   Exit:   0 on success; 1 if the bootstrap JSON is missing or unparseable.
ds_build_rdap_index() {
	_ds_have jq || {
		ds_warn "jq is required to build the RDAP index"
		return 1
	}
	if [ ! -s "$DS_RDAP_BOOTSTRAP_JSON" ]; then
		ds_warn "cannot build RDAP index: $DS_RDAP_BOOTSTRAP_JSON is missing"
		return 1
	fi
	_ds_ensure_data_dir
	_dbi_tmp=$(_ds_mktemp) || return 1
	# dns.json shape: {"services":[[[tld,...],[url,...]],...]}. The URL list is
	# an ARRAY, and two things follow from that:
	#
	#   * PREFER https. A registry may publish both a plaintext and a TLS
	#     endpoint, in either order. Taking [0] blindly can put every lookup for
	#     that registry on cleartext http, where any transparent proxy can turn
	#     a 404 into a 200 - a confidently wrong answer, which is the one thing
	#     this toolkit must never produce.
	#   * TOLERATE a malformed entry. One service block with an empty or
	#     non-string URL list used to abort the whole jq program, which threw
	#     away the endpoints for all 1200 TLDs and silently degraded every
	#     lookup to whois. A bad entry now costs only its own TLDs, and the loss
	#     is reported rather than swallowed.
	if ! jq -r '
		.services[]?
		| [ .[1][]? | select(type == "string")
		    | select(startswith("https://") or startswith("http://")) ] as $urls
		| ( [ $urls[] | select(startswith("https://")) ] + $urls )[0] as $url
		| select($url != null)
		| ($url | sub("/+$"; "")) as $base
		| .[0][]?
		| select(type == "string" and length > 0)
		| [ ascii_downcase, $base ]
		| @tsv
	' "$DS_RDAP_BOOTSTRAP_JSON" >"$_dbi_tmp" 2>/dev/null; then
		rm -f "$_dbi_tmp"
		ds_warn "failed to parse $DS_RDAP_BOOTSTRAP_JSON (corrupt download?)"
		return 1
	fi
	if [ ! -s "$_dbi_tmp" ]; then
		rm -f "$_dbi_tmp"
		ds_warn "RDAP bootstrap parsed to zero entries; refusing to write index"
		return 1
	fi

	# Say so when the bootstrap listed TLDs we could not route: they will fall
	# back to whois, which is correct but slower, and a large number here means
	# the upstream file changed shape.
	_dbi_listed=$(jq '[ .services[]?[0][]? | select(type == "string") ] | length' \
		"$DS_RDAP_BOOTSTRAP_JSON" 2>/dev/null) || _dbi_listed=""
	_dbi_mapped=$(awk 'NF { n++ } END { print n + 0 }' "$_dbi_tmp")
	if [ -n "$_dbi_listed" ] && [ "$_dbi_listed" -gt "$_dbi_mapped" ]; then
		ds_warn "$((_dbi_listed - _dbi_mapped)) TLD(s) in the RDAP bootstrap have no usable URL; those will use whois"
	fi

	mv "$_dbi_tmp" "$DS_RDAP_INDEX_TSV"
	ds_debug "wrote RDAP index: $_dbi_mapped TLDs"
	unset _dbi_tmp _dbi_listed _dbi_mapped
	return 0
}

# _ds_tsv_lookup <file> <key> <column>
#   Internal. Echoes <column> of the first line of tab-separated <file> whose
#   first field equals <key>. Skips '#' comments and blank lines. Exit 1 if not
#   found. This is the associative-array replacement used throughout.
_ds_tsv_lookup() {
	[ -s "$1" ] || return 1
	_dtl_out=$(awk -F'\t' -v key="$2" -v col="$3" '
		/^[ \t]*#/ { next }
		$1 == key  { print $col; found=1; exit }
		END        { if (!found) exit 1 }
	' "$1" 2>/dev/null) || return 1
	[ -n "$_dtl_out" ] || return 1
	printf '%s\n' "$_dtl_out"
	unset _dtl_out
	return 0
}

# ds_rdap_endpoint <tld>
#   Resolves which RDAP base URL (if any) should be used for a TLD, applying
#   every routing rule this project learned the hard way, in priority order:
#     1. data/rdap-overrides.tsv  (user/bootstrap supplied; wins over all)
#     2. Google Registry TLDs     -> https://pubapi.registry.google/rdap
#     3. Known no-RDAP TLDs       -> whois
#     4. IANA bootstrap index, rejecting banned proxy hosts and flagging slow
#        registries so callers can throttle them
#   Args:   $1 = TLD, with or without leading dot, any case.
#   Stdout: the RDAP base URL with no trailing slash (e.g.
#           "https://pubapi.registry.google/rdap"), and nothing else.
#   Exit:   0  URL printed, use RDAP.
#           1  this TLD must NOT use RDAP - fall back to whois. Nothing printed.
#           2  usage error (no TLD given).
ds_rdap_endpoint() {
	_dre_tld=$(ds_normalize_tld "${1:-}")
	if [ -z "$_dre_tld" ]; then
		ds_warn "ds_rdap_endpoint: missing <tld>"
		return 2
	fi

	# 1. Explicit override file. A value of "WHOIS" (any case) forces whois.
	if _dre_ov=$(_ds_tsv_lookup "$DS_RDAP_OVERRIDES_TSV" "$_dre_tld" 2); then
		case "$(printf '%s' "$_dre_ov" | tr '[:upper:]' '[:lower:]')" in
		whois | none | -)
			ds_debug "rdap[$_dre_tld]: override says whois"
			return 1
			;;
		esac
		_dre_host=$(_ds_url_host "$_dre_ov")
		if grep -qiE "$_DS_RDAP_HOST_BANNED_RE" <<<"$_dre_host"; then
			ds_debug "rdap[$_dre_tld]: refusing banned override host $_dre_host, use whois"
			return 1
		fi
		printf '%s\n' "${_dre_ov%/}"
		return 0
	fi

	# 2. Google Registry: the bootstrap endpoint throttles, pubapi does not.
	case " $_DS_GOOGLE_TLDS " in
	*" $_dre_tld "*)
		printf '%s\n' "$_DS_GOOGLE_RDAP"
		return 0
		;;
	esac

	# 3. TLDs with no RDAP service.
	case " $_DS_NO_RDAP_TLDS " in
	*" $_dre_tld "*)
		ds_debug "rdap[$_dre_tld]: no RDAP service, use whois"
		return 1
		;;
	esac

	# 4. IANA bootstrap. Build the index lazily if only the raw JSON is cached.
	if [ ! -s "$DS_RDAP_INDEX_TSV" ] && [ -s "$DS_RDAP_BOOTSTRAP_JSON" ]; then
		ds_build_rdap_index || true
	fi
	if [ ! -s "$DS_RDAP_INDEX_TSV" ]; then
		_ds_cache_missing "$DS_RDAP_INDEX_TSV" "downloads the IANA RDAP bootstrap"
		return 1
	fi

	if ! _dre_url=$(_ds_tsv_lookup "$DS_RDAP_INDEX_TSV" "$_dre_tld" 2); then
		ds_debug "rdap[$_dre_tld]: not in IANA bootstrap, use whois"
		return 1
	fi

	# Host-level deny checks. Match the hostname, never the full URL.
	_dre_host=$(_ds_url_host "$_dre_url")
	# Reject the rdap.org proxy outright - it 429s after ~60 requests.
	if grep -qiE "$_DS_RDAP_HOST_BANNED_RE" <<<"$_dre_host"; then
		ds_debug "rdap[$_dre_tld]: refusing rdap.org proxy, use whois"
		return 1
	fi
	# Identity Digital and friends are SLOW, not unusable, and are mostly
	# RDAP-only - diverting them to whois produces ERROR, not an answer.
	# Flag them so callers can throttle, but still return the endpoint.
	if grep -qiE "$_DS_RDAP_HOST_SLOW_RE" <<<"$_dre_host"; then
		ds_debug "rdap[$_dre_tld]: throttled registry, use concurrency 1"
	fi

	printf '%s\n' "${_dre_url%/}"
	unset _dre_tld _dre_url _dre_ov
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 6: whois server resolution
# ---------------------------------------------------------------------------

# ds_whois_server <tld>
#   Resolves the authoritative whois server for a TLD, in priority order:
#     1. hard-coded overrides for the ones everybody guesses wrong
#        (.co is whois.registry.co, NOT whois.nic.co; .uk is whois.nic.uk)
#     2. the on-disk cache data/whois-servers.tsv
#     3. a live IANA lookup (`whois -h whois.iana.org <tld>`), whose result is
#        appended to the cache so it is only ever paid for once
#   Args:   $1 = TLD, with or without leading dot, any case.
#   Stdout: the whois server hostname (e.g. "whois.nic.uk"), and nothing else.
#   Exit:   0 on success; 1 if no server could be determined; 2 on usage error.
ds_whois_server() {
	_dws_tld=$(ds_normalize_tld "${1:-}")
	if [ -z "$_dws_tld" ]; then
		ds_warn "ds_whois_server: missing <tld>"
		return 2
	fi

	# 1. Hard-coded corrections.
	if _dws_srv=$(_ds_whois_override "$_dws_tld"); then
		printf '%s\n' "$_dws_srv"
		return 0
	fi

	# 2. Cache.
	if _dws_srv=$(_ds_tsv_lookup "$DS_WHOIS_SERVERS_TSV" "$_dws_tld" 2); then
		printf '%s\n' "$_dws_srv"
		return 0
	fi

	# 3. Live IANA lookup.
	if ! _ds_have whois; then
		ds_warn "whois command not found; cannot resolve server for .$_dws_tld"
		return 1
	fi
	ds_debug "whois[$_dws_tld]: asking whois.iana.org"
	_dws_out=$(_ds_timeout "${DS_WHOIS_TIMEOUT:-20}" whois -h whois.iana.org "$_dws_tld" 2>/dev/null) || _dws_out=""
	_dws_srv=$(awk 'tolower($1) == "whois:" && $2 != "" { print $2; exit }' <<<"$_dws_out")

	if [ -z "$_dws_srv" ]; then
		ds_debug "whois[$_dws_tld]: IANA returned no whois: line"
		unset _dws_out
		return 1
	fi
	_dws_srv=$(printf '%s' "$_dws_srv" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

	# Append to the cache. A single short line append is atomic enough for the
	# parallel xargs fan-outs this tool does; duplicates are harmless because
	# _ds_tsv_lookup takes the first match.
	_ds_ensure_data_dir
	if [ ! -f "$DS_WHOIS_SERVERS_TSV" ]; then
		printf '# tld\twhois_server  (generated by DomainSaver; safe to delete)\n' \
			>>"$DS_WHOIS_SERVERS_TSV" 2>/dev/null || true
	fi
	printf '%s\t%s\n' "$_dws_tld" "$_dws_srv" >>"$DS_WHOIS_SERVERS_TSV" 2>/dev/null || true

	printf '%s\n' "$_dws_srv"
	unset _dws_tld _dws_srv _dws_out
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: probes
# ---------------------------------------------------------------------------

# Tunables. Every one can be overridden from the environment.
: "${DS_HTTP_TIMEOUT:=15}"      # seconds, per RDAP request
: "${DS_CONNECT_TIMEOUT:=10}"   # seconds, TCP connect
: "${DS_WHOIS_TIMEOUT:=20}"     # seconds, per whois query
: "${DS_RDAP_RETRIES:=4}"       # attempts before giving up on a retryable code
: "${DS_RDAP_BACKOFF_BASE:=2}"  # seconds; doubles each attempt
: "${DS_RDAP_BACKOFF_MAX:=30}"  # seconds; cap on a single sleep
: "${DS_USER_AGENT:=DomainSaver/$DS_LIB_VERSION}"

# ds_probe_rdap <domain> [rdap_base_url]
#   RDAP-only probe with exponential backoff on 429/503/502/504/408 and on
#   curl-level failures (reported as HTTP 000).
#   Args:   $1 = domain name.
#           $2 = optional RDAP base URL; pass it in hot loops to skip the
#                per-name endpoint resolution.
#   Stdout: exactly one line, "STATUS|domain|detail" where STATUS is one of
#           UNREGISTERED, REGISTERED, ERROR.
#           detail examples: "rdap:404", "rdap:200 registrar=Example Inc",
#           "rdap:429 gave up after 4 attempts", "rdap:none no endpoint".
#   Exit:   0 for UNREGISTERED or REGISTERED; 1 for ERROR.
#   Note:   UNREGISTERED here means "absent from the registry". It does NOT
#           mean purchasable - it may be reserved or premium-priced.
ds_probe_rdap() {
	_dpr_dom=$(ds_normalize_domain "${1:-}")
	_dpr_base="${2:-}"

	if [ -z "$_dpr_dom" ]; then
		ds_warn "ds_probe_rdap: missing <domain>"
		printf 'ERROR||%s\n' "usage: ds_probe_rdap <domain>"
		return 1
	fi
	if ! _dpr_tld=$(ds_tld "$_dpr_dom"); then
		printf 'ERROR|%s|%s\n' "$_dpr_dom" "invalid domain (no TLD)"
		return 1
	fi
	if [ -z "$_dpr_base" ]; then
		if ! _dpr_base=$(ds_rdap_endpoint "$_dpr_tld"); then
			printf 'ERROR|%s|%s\n' "$_dpr_dom" "rdap:none no endpoint for .$_dpr_tld"
			return 1
		fi
	fi
	if ! _ds_have curl; then
		printf 'ERROR|%s|%s\n' "$_dpr_dom" "curl not installed"
		return 1
	fi

	_dpr_url="${_dpr_base%/}/domain/$_dpr_dom"
	_dpr_body=$(_ds_mktemp) || {
		printf 'ERROR|%s|%s\n' "$_dpr_dom" "cannot create temp file"
		return 1
	}

	_dpr_attempt=1
	_dpr_code="000"
	while [ "$_dpr_attempt" -le "$DS_RDAP_RETRIES" ]; do
		_dpr_code=$(curl -sS -L --max-redirs 3 \
			-A "$DS_USER_AGENT" \
			-H 'Accept: application/rdap+json' \
			--connect-timeout "$DS_CONNECT_TIMEOUT" \
			--max-time "$DS_HTTP_TIMEOUT" \
			-o "$_dpr_body" -w '%{http_code}' \
			"$_dpr_url" 2>/dev/null) || _dpr_code="000"
		[ -n "$_dpr_code" ] || _dpr_code="000"

		case "$_dpr_code" in
		429 | 503 | 502 | 504 | 408 | 000)
			if [ "$_dpr_attempt" -ge "$DS_RDAP_RETRIES" ]; then
				break
			fi
			# Exponential backoff with a little jitter, capped, so a whole
			# batch does not retry in lockstep against one registry.
			_dpr_sleep=$((DS_RDAP_BACKOFF_BASE * (1 << (_dpr_attempt - 1))))
			[ "$_dpr_sleep" -gt "$DS_RDAP_BACKOFF_MAX" ] && _dpr_sleep="$DS_RDAP_BACKOFF_MAX"
			_dpr_sleep=$((_dpr_sleep + (RANDOM % 2)))
			ds_debug "rdap $_dpr_dom: HTTP $_dpr_code, retry $_dpr_attempt in ${_dpr_sleep}s"
			sleep "$_dpr_sleep"
			_dpr_attempt=$((_dpr_attempt + 1))
			;;
		*)
			break
			;;
		esac
	done

	_dpr_status="ERROR"
	_dpr_detail="rdap:$_dpr_code"
	_dpr_rc=1

	case "$_dpr_code" in
	200)
		# Some registries answer 200 with an RDAP error object rather than an
		# HTTP error status, so validate the body instead of trusting the status
		# line. A malformed 200 response is not evidence of registration.
		_dpr_shape="invalid"
		if ! _ds_have jq; then
			_dpr_detail="rdap:200 cannot validate response (jq not installed)"
		elif ! _dpr_shape=$(jq -r '
			if type != "object" then "invalid"
			elif .errorCode? != null then "error:" + (.errorCode | tostring)
			elif .objectClassName? == "domain" and
				([.ldhName?, .unicodeName?] |
				 map(select(type == "string" and length > 0)) | length > 0)
			then "domain"
			else "invalid"
			end
		' "$_dpr_body" 2>/dev/null); then
			_dpr_shape="invalid"
		fi

		case "$_dpr_shape" in
		error:404)
			_dpr_status="UNREGISTERED"
			_dpr_detail="rdap:200 errorCode=404"
			_dpr_rc=0
			;;
		error:*)
			_dpr_status="ERROR"
			_dpr_detail="rdap:200 errorCode=${_dpr_shape#error:}"
			_dpr_rc=1
			;;
		domain)
			_dpr_status="REGISTERED"
			_dpr_detail="rdap:200"
			_dpr_reg=$(jq -r '
				[ .entities[]? | select(any(.roles[]?; . == "registrar"))
				  | .vcardArray[1][]? | select(.[0] == "fn") | .[3] ][0] // empty
			' "$_dpr_body" 2>/dev/null) || _dpr_reg=""
			[ -n "$_dpr_reg" ] && _dpr_detail="rdap:200 registrar=$_dpr_reg"
			_dpr_rc=0
			;;
		invalid)
			[ "$_dpr_detail" != "rdap:200" ] ||
				_dpr_detail="rdap:200 invalid RDAP response"
			;;
		esac
		;;
	404)
		# The load-bearing case. Absent from the registry: available, RESERVED
		# or PREMIUM. Only a real quote can tell those apart.
		_dpr_status="UNREGISTERED"
		_dpr_detail="rdap:404"
		_dpr_rc=0
		;;
	429)
		_dpr_detail="rdap:429 rate-limited, gave up after $DS_RDAP_RETRIES attempts"
		;;
	000)
		_dpr_detail="rdap:000 network/timeout after $DS_RDAP_RETRIES attempts"
		;;
	esac

	rm -f "$_dpr_body"
	printf '%s|%s|%s\n' "$_dpr_status" "$_dpr_dom" "$(_ds_sanitize_detail "$_dpr_detail")"
	unset _dpr_dom _dpr_base _dpr_tld _dpr_url _dpr_body _dpr_attempt \
		_dpr_code _dpr_sleep _dpr_status _dpr_detail _dpr_shape _dpr_reg 2>/dev/null || true
	return "$_dpr_rc"
}

# Whois response patterns, matched case-insensitively, line-anchored where it
# matters, in this order: rate-limit, then free, then taken. Order is critical -
# many "no match" replies still contain the word "registrar" in their legal
# boilerplate, so the free patterns must be tested before the taken patterns.
_DS_WHOIS_RE_RATELIMIT='you have exceeded|exceeded the maximum|(limit|quota|rate)[ -]*exceeded|exceeded[^.]*(limit|quota|maximum|allowance)|query rate|rate limit|too many (requests|connections|queries)|try again later|slow down|temporarily unavailable|access denied|connection refused|no whois server is known|timeout|service unavailable'
_DS_WHOIS_RE_FREE='no match for|^no match|not found|no data found|no entries found|domain not found|no object found|nothing found|^ *status: *free|^ *status: *available|available for (registration|purchase)|no such domain|not registered|object does not exist|we do not have an entry in our database|query_status: *220|domain status: *no object found|this domain name has not been registered'
_DS_WHOIS_RE_TAKEN='^ *domain name: |^domain: |^ *registered on: |^ *creation date: |^ *created: |^ *created on: |^ *registry domain id: |^ *registrar: |^ *registrar whois server: |^ *name server: |^nserver: |^ *status: *(connect|active|ok|client|server)|query_status: *200'

# ds_probe_whois <domain> [whois_server]
#   Whois-only probe, handling the per-registry output formats:
#     * Nominet (.uk)      "No match for" vs "Registered on:"
#     * Verisign (.com)    "No match for" vs "Domain Name:"
#     * .co (registry.co)  "No Data Found"/"NOT FOUND" vs "Domain Name:"
#     * DENIC (.de)        "Status: free" vs "Status: connect"
#     * generic gTLD/ccTLD via the ordered pattern sets above
#   Args:   $1 = domain name.
#           $2 = optional whois server; pass it in hot loops to skip resolution.
#   Stdout: exactly one line, "STATUS|domain|detail" where STATUS is one of
#           UNREGISTERED, REGISTERED, ERROR.
#           detail examples: "whois:whois.nic.uk", "whois:whois.nic.uk timeout",
#           "whois:whois.verisign-grs.com rate-limited",
#           "whois:whois.nic.example unparsed response".
#   Exit:   0 for UNREGISTERED or REGISTERED; 1 for ERROR.
#   Note:   UNREGISTERED means absent from the registry, not purchasable.
ds_probe_whois() {
	_dpw_dom=$(ds_normalize_domain "${1:-}")
	_dpw_srv="${2:-}"

	if [ -z "$_dpw_dom" ]; then
		ds_warn "ds_probe_whois: missing <domain>"
		printf 'ERROR||%s\n' "usage: ds_probe_whois <domain>"
		return 1
	fi
	if ! _dpw_tld=$(ds_tld "$_dpw_dom"); then
		printf 'ERROR|%s|%s\n' "$_dpw_dom" "invalid domain (no TLD)"
		return 1
	fi
	if ! _ds_have whois; then
		printf 'ERROR|%s|%s\n' "$_dpw_dom" "whois not installed"
		return 1
	fi
	if [ -z "$_dpw_srv" ]; then
		if ! _dpw_srv=$(ds_whois_server "$_dpw_tld"); then
			printf 'ERROR|%s|%s\n' "$_dpw_dom" "whois:none no server for .$_dpw_tld"
			return 1
		fi
	fi

	# A failed whois process is an expected lookup outcome, not a fatal shell
	# error. Capture its status explicitly so callers running under `set -e`
	# still receive the promised ERROR record below.
	_dpw_out=""
	_dpw_rc=0
	_dpw_out=$(_ds_timeout "$DS_WHOIS_TIMEOUT" whois -h "$_dpw_srv" "$_dpw_dom" 2>/dev/null) || _dpw_rc=$?

	if [ "$_dpw_rc" = "124" ]; then
		printf 'ERROR|%s|%s\n' "$_dpw_dom" "whois:$_dpw_srv timeout after ${DS_WHOIS_TIMEOUT}s"
		return 1
	fi
	if [ -z "$_dpw_out" ]; then
		printf 'ERROR|%s|%s\n' "$_dpw_dom" "whois:$_dpw_srv empty response"
		return 1
	fi

	case "$(ds_whois_classify "$_dpw_out")" in
	RATELIMIT)
		printf 'ERROR|%s|%s\n' "$_dpw_dom" "whois:$_dpw_srv rate-limited or refused"
		return 1
		;;
	FREE)
		printf 'UNREGISTERED|%s|%s\n' "$_dpw_dom" "whois:$_dpw_srv"
		return 0
		;;
	TAKEN)
		printf 'REGISTERED|%s|%s\n' "$_dpw_dom" "whois:$_dpw_srv"
		return 0
		;;
	esac

	# Never guess. An unrecognised format is an ERROR to be triaged, not a
	# silent "available" that sends someone to a checkout page.
	printf 'ERROR|%s|%s\n' "$_dpw_dom" "whois:$_dpw_srv unparsed response"
	unset _dpw_dom _dpw_srv _dpw_tld _dpw_out _dpw_rc
	return 1
}

# ds_whois_classify <raw_whois_text>
#   Classifies a raw whois response. Split out from ds_probe_whois so the
#   registry-format patterns can be unit-tested against captured fixtures
#   without touching the network.
#   Args:   $1 = the complete raw whois response text.
#   Stdout: exactly one of: RATELIMIT, FREE, TAKEN, UNKNOWN.
#   Exit:   0 always.
#   Order is load-bearing: RATELIMIT before FREE (a throttled reply must never
#   read as available), and FREE before TAKEN (many "no match" replies still
#   contain "Registrar:" in their legal boilerplate).
ds_whois_classify() {
	_dwc_txt="${1:-}"
	if [ -z "$_dwc_txt" ]; then
		printf 'UNKNOWN\n'
		return 0
	fi
	if grep -qiE "$_DS_WHOIS_RE_RATELIMIT" <<<"$_dwc_txt"; then
		printf 'RATELIMIT\n'
	elif grep -qiE "$_DS_WHOIS_RE_FREE" <<<"$_dwc_txt"; then
		printf 'FREE\n'
	elif grep -qiE "$_DS_WHOIS_RE_TAKEN" <<<"$_dwc_txt"; then
		printf 'TAKEN\n'
	else
		printf 'UNKNOWN\n'
	fi
	unset _dwc_txt
	return 0
}

# ds_probe <domain>
#   The general-purpose probe. Routes to RDAP when the TLD has a usable RDAP
#   endpoint (per ds_rdap_endpoint), otherwise to whois; and if RDAP returns
#   ERROR it retries once over whois, because a throttled registry must not be
#   allowed to look like a definitive answer.
#   Args:   $1 = domain name.
#   Stdout: exactly one line, "STATUS|domain|detail" where STATUS is one of
#           UNREGISTERED, REGISTERED, ERROR. The domain is normalised
#           (lowercased, trailing dot stripped). detail never contains '|'.
#   Exit:   0 for UNREGISTERED or REGISTERED; 1 for ERROR.
#   REMEMBER: UNREGISTERED is not AVAILABLE. Do not render it as purchasable
#   without a real price quote from the pricing layer.
ds_probe() {
	_dp_dom=$(ds_normalize_domain "${1:-}")
	if [ -z "$_dp_dom" ]; then
		ds_warn "ds_probe: missing <domain>"
		printf 'ERROR||%s\n' "usage: ds_probe <domain>"
		return 1
	fi
	if ! _dp_tld=$(ds_tld "$_dp_dom"); then
		printf 'ERROR|%s|%s\n' "$_dp_dom" "invalid domain (no TLD)"
		return 1
	fi

	if _dp_base=$(ds_rdap_endpoint "$_dp_tld"); then
		_dp_rc=0
		_dp_res=$(ds_probe_rdap "$_dp_dom" "$_dp_base") || _dp_rc=$?
		if [ "$_dp_rc" = "0" ]; then
			printf '%s\n' "$_dp_res"
			return 0
		fi
		# RDAP failed. Fall back to whois rather than reporting a rate limit as
		# fact. Preserve the RDAP detail so the failure is still visible.
		_dp_rdap_detail=${_dp_res##*|}
		if _dp_res=$(ds_probe_whois "$_dp_dom"); then
			printf '%s|%s|%s\n' "${_dp_res%%|*}" "$_dp_dom" \
				"$(_ds_sanitize_detail "${_dp_res##*|} after ${_dp_rdap_detail}")"
			return 0
		fi
		printf 'ERROR|%s|%s\n' "$_dp_dom" \
			"$(_ds_sanitize_detail "${_dp_rdap_detail}; then ${_dp_res##*|}")"
		return 1
	fi

	_dp_rc=0
	_dp_res=$(ds_probe_whois "$_dp_dom") || _dp_rc=$?
	printf '%s\n' "$_dp_res"
	unset _dp_dom _dp_tld _dp_base _dp_res _dp_rdap_detail
	return "$_dp_rc"
}

# ---------------------------------------------------------------------------
# SECTION 8: pricing
# ---------------------------------------------------------------------------

# ds_build_price_index
#   Rebuilds $DS_PRICE_INDEX_TSV (tld<TAB>registration<TAB>renewal<TAB>transfer)
#   from the cached Porkbun pricing payload $DS_PRICING_JSON. Intended for
#   bootstrap.sh; also called lazily by ds_std_price.
#   Args:   none
#   Stdout: nothing
#   Exit:   0 on success; 1 if the pricing JSON is missing or unparseable.
ds_build_price_index() {
	_ds_have jq || {
		ds_warn "jq is required to build the price index"
		return 1
	}
	if [ ! -s "$DS_PRICING_JSON" ]; then
		ds_warn "cannot build price index: $DS_PRICING_JSON is missing"
		return 1
	fi
	_ds_ensure_data_dir
	_dbp_tmp=$(_ds_mktemp) || return 1
	if ! jq -r '
		.pricing | to_entries[]
		| [ (.key | ascii_downcase),
		    (.value.registration // ""),
		    (.value.renewal // ""),
		    (.value.transfer // "") ]
		| @tsv
	' "$DS_PRICING_JSON" >"$_dbp_tmp" 2>/dev/null; then
		rm -f "$_dbp_tmp"
		ds_warn "failed to parse $DS_PRICING_JSON (corrupt download?)"
		return 1
	fi
	if [ ! -s "$_dbp_tmp" ]; then
		rm -f "$_dbp_tmp"
		ds_warn "price payload parsed to zero entries; refusing to write index"
		return 1
	fi
	mv "$_dbp_tmp" "$DS_PRICE_INDEX_TSV"
	ds_debug "wrote price index: $(wc -l <"$DS_PRICE_INDEX_TSV" | tr -d ' ') TLDs"
	unset _dbp_tmp
	return 0
}

# ds_std_price <tld>
#   Looks up the TLD's STANDARD (non-premium) list price from the cached
#   Porkbun price table. This is the baseline a per-name quote is compared
#   against to decide whether a name is premium-priced.
#   Args:   $1 = TLD, with or without leading dot, any case.
#   Stdout: one line: "<registration><TAB><renewal>" - both bare decimal USD
#           strings, e.g. "7.72	7.72". Nothing is printed on failure.
#   Exit:   0 on success; 1 if the TLD is not in the table or the cache is
#           missing (a bootstrap.sh hint is warned once per process);
#           2 on usage error.
#   Note:   RENEWAL is the number that matters, not first-year registration.
ds_std_price() {
	_dsp_tld=$(ds_normalize_tld "${1:-}")
	if [ -z "$_dsp_tld" ]; then
		ds_warn "ds_std_price: missing <tld>"
		return 2
	fi

	if [ ! -s "$DS_PRICE_INDEX_TSV" ] && [ -s "$DS_PRICING_JSON" ]; then
		ds_build_price_index || true
	fi
	if [ ! -s "$DS_PRICE_INDEX_TSV" ]; then
		_ds_cache_missing "$DS_PRICE_INDEX_TSV" "downloads the Porkbun price list"
		return 1
	fi

	_dsp_row=$(awk -F'\t' -v key="$_dsp_tld" '
		/^[ \t]*#/ { next }
		$1 == key  { printf "%s\t%s\n", $2, $3; found=1; exit }
		END        { if (!found) exit 1 }
	' "$DS_PRICE_INDEX_TSV" 2>/dev/null) || return 1

	[ -n "$_dsp_row" ] || return 1
	printf '%s\n' "$_dsp_row"
	unset _dsp_tld _dsp_row
	return 0
}

# ds_porkbun_creds_ok
#   Args:   none
#   Stdout: nothing
#   Exit:   0 if both PORKBUN_API_KEY and PORKBUN_SECRET_KEY are set and
#           non-empty; 1 otherwise, having warned once per process that
#           per-name premium pricing is unavailable and that results will
#           therefore stay at UNREGISTERED rather than being promoted to
#           AVAILABLE.
#   Credentials are read from the environment only. They are never logged,
#   never written to data/, and must never be hard-coded.
_DS_PORKBUN_WARNED=0
ds_porkbun_creds_ok() {
	if [ -n "${PORKBUN_API_KEY:-}" ] && [ -n "${PORKBUN_SECRET_KEY:-}" ]; then
		return 0
	fi
	if [ "$_DS_PORKBUN_WARNED" = "0" ]; then
		_DS_PORKBUN_WARNED=1
		ds_warn "PORKBUN_API_KEY / PORKBUN_SECRET_KEY not set - no per-name quotes."
		ds_warn "  Results stay UNREGISTERED and are NOT promoted to AVAILABLE:"
		ds_warn "  an unregistered name may be registry-reserved or premium-priced."
	fi
	return 1
}

# ---------------------------------------------------------------------------
# SECTION 9: TLD reputation and renewal traps
# ---------------------------------------------------------------------------

# Registries with no premium tier: the published list price IS the real price,
# so an unregistered name there is far more likely to be genuinely available.
_DS_NO_PREMIUM_TLDS="com net uk org"

# Spam-associated TLDs. Some corporate mail filters and proxies block these
# wholesale, which makes them a poor choice however cheap they look. The
# "$5.64 cluster" plus the usual suspects.
_DS_SPAM_TLDS="bid date download loan men party stream trade win top click quest"

# Known renewal traps: cheap first year, brutal renewal. Listed explicitly so
# they are still flagged when the price cache is cold.
_DS_RENEWAL_TRAP_TLDS="bar codes fun works zone online site space lol live rest"

# ds_tld_flags <tld>
#   Computes reputation and pricing-risk flags for a TLD, combining hard-coded
#   knowledge with values derived from the cached price table, plus any extra
#   flags listed for the TLD in data/tld-flags.tsv (tld<TAB>FLAG FLAG).
#   Args:   $1 = TLD, with or without leading dot, any case.
#   Stdout: exactly one line: zero or more flag tokens, space-separated, in a
#           stable order, de-duplicated. An empty line means "no flags".
#           Possible tokens:
#             NO_PREMIUM_REGISTRY  registry has no premium tier; list price is
#                                  the real price (com, net, uk, org)
#             SPAM_ASSOCIATED      commonly blocked by corporate filters
#             RENEWAL_TRAP         renewal >= 3x registration and >= $20, or on
#                                  the known-trap list
#             RENEWAL_EXPENSIVE    renewal >= $25/yr
#             NO_PRICE_DATA        TLD absent from the cached price table
#   Exit:   0 on success; 2 on usage error.
ds_tld_flags() {
	_dtf_tld=$(ds_normalize_tld "${1:-}")
	if [ -z "$_dtf_tld" ]; then
		ds_warn "ds_tld_flags: missing <tld>"
		return 2
	fi
	_dtf_flags=""

	case " $_DS_NO_PREMIUM_TLDS " in
	*" $_dtf_tld "*) _dtf_flags="$_dtf_flags NO_PREMIUM_REGISTRY" ;;
	esac
	case " $_DS_SPAM_TLDS " in
	*" $_dtf_tld "*) _dtf_flags="$_dtf_flags SPAM_ASSOCIATED" ;;
	esac
	case " $_DS_RENEWAL_TRAP_TLDS " in
	*" $_dtf_tld "*) _dtf_flags="$_dtf_flags RENEWAL_TRAP" ;;
	esac

	if _dtf_price=$(ds_std_price "$_dtf_tld" 2>/dev/null); then
		_dtf_reg=$(printf '%s' "$_dtf_price" | cut -f1)
		_dtf_ren=$(printf '%s' "$_dtf_price" | cut -f2)
		_dtf_calc=$(awk -v r="$_dtf_reg" -v n="$_dtf_ren" 'BEGIN {
			out = "";
			if (r + 0 > 0 && n + 0 >= 3 * (r + 0) && n + 0 >= 20) out = out " RENEWAL_TRAP";
			if (n + 0 >= 25) out = out " RENEWAL_EXPENSIVE";
			print out;
		}')
		_dtf_flags="$_dtf_flags$_dtf_calc"
	else
		_dtf_flags="$_dtf_flags NO_PRICE_DATA"
	fi

	# Optional user-supplied extras.
	if _dtf_extra=$(_ds_tsv_lookup "$DS_TLD_FLAGS_TSV" "$_dtf_tld" 2); then
		_dtf_flags="$_dtf_flags $_dtf_extra"
	fi

	# De-duplicate while preserving first-seen order. Split with tr rather than
	# unquoted word splitting, so a stray '*' in tld-flags.tsv cannot glob.
	# (awk arrays are fine; only bash associative arrays are off-limits here.)
	printf '%s' "$_dtf_flags" | tr -s '[:space:]' '\n' |
		awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep = " " } END { print "" }'

	unset _dtf_tld _dtf_flags _dtf_price _dtf_reg _dtf_ren _dtf_calc _dtf_extra 2>/dev/null || true
	return 0
}

# End of lib.sh
