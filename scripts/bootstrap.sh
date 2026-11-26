#!/usr/bin/env bash
# shellcheck shell=bash
#
# bootstrap.sh - refresh DomainSaver's local caches in data/.
#
# The downloaded caches in data/ are derived and disposable, but the directory
# also contains hand-maintained registry limits, reputation flags and RDAP
# overrides. Delete only generated files when refreshing; bootstrap preserves
# those local policy files but cannot reconstruct custom edits to them. Neither
# upstream source needs credentials.
#
# WHAT IT PRODUCES (canonical names are the ones lib.sh reads):
#   data/rdap-bootstrap.json   raw IANA RDAP bootstrap  (data.iana.org/rdap/dns.json)
#   data/rdap-endpoints.tsv    tld<TAB>rdap_base_url    (alias: tldmap.tsv)
#   data/porkbun-pricing.json  raw Porkbun price list   (public pricing/get API)
#   data/tld-prices.tsv        tld<TAB>reg<TAB>renew<TAB>transfer (alias: prices.tsv)
#   data/whois-servers.tsv     tld<TAB>whois_server     (seeded, then grown lazily)
#   data/tld-flags.tsv         tld<TAB>FLAGS            (alias: reputation.tsv)
#   data/rdap-overrides.tsv    tld<TAB>URL|WHOIS        (commented template only)
#
# The short aliases (tldmap.tsv / prices.tsv / reputation.tsv) are symlinks to
# the canonical files, so there is exactly one copy of every fact on disk.
#
# WHY THE CACHES MATTER: the RDAP map is what keeps us off the rdap.org proxy
# (which 429s after ~60 lookups) and on each registry's own endpoint, and the
# price table is the baseline a per-name quote is compared against to tell
# "available" apart from "premium-priced". A stale or truncated cache produces
# confidently wrong answers, so this script verifies what it downloaded and
# refuses to install a table that fails a sanity check.
#
# DESIGN CONSTRAINTS (same as lib.sh, deliberate):
#   * bash 3.2 compatible - no associative arrays, no `declare -A`, no readarray.
#   * POSIX-ish tools only; no GNU-only flags; never `sed -i`.
#   * Idempotent: re-running is a no-op unless a cache is stale or --force.
#   * Never destroys a good cache. Downloads land in a temp file and are only
#     moved into place after they parse and pass their shape check.
#
# Internal helpers are prefixed `_bs_`; script-level settings `BS_`.

set -euo pipefail

# Resolve our own directory so the script works from any cwd, then load the
# shared library (which resolves DS_ROOT / DS_DATA_DIR the same way).
_BS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$_BS_DIR/lib.sh"

BS_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# SECTION 1: sources, thresholds and defaults
# ---------------------------------------------------------------------------

# Upstream sources. Both are public; neither takes an API key.
BS_IANA_URL="https://data.iana.org/rdap/dns.json"
BS_PORKBUN_URL="https://api.porkbun.com/api/json/v3/pricing/get"

# Sanity floors. Measured reality (2026-07): IANA lists 1200 TLDs, Porkbun
# prices 907. A result far below these means a captive portal, a corporate
# proxy or a truncated transfer - not a genuinely smaller internet.
BS_MIN_RDAP_TLDS=1000
BS_MIN_PRICE_TLDS=500

# HTTP settings. DS_CONNECT_TIMEOUT comes from lib.sh; these files are ~80 KB
# so a 60s ceiling is generous.
BS_HTTP_MAX_TIME=60
BS_HTTP_RETRIES=3

# Refresh policy. A cache older than this many whole days is refetched.
# Overridable with --max-age or the DS_BOOTSTRAP_MAX_AGE_DAYS environment var.
BS_MAX_AGE_DAYS="${DS_BOOTSTRAP_MAX_AGE_DAYS:-7}"

BS_FORCE=0   # --force: refresh regardless of cache age
BS_REBUILD=0 # --rebuild: no network at all, rebuild tables from cached JSON

# Whois servers that must be right from the first run, verified against
# `whois -h whois.iana.org <tld>`. .co is the classic trap: whois.registry.co,
# NOT whois.nic.co. lib.sh grows this file lazily for every other TLD.
BS_WHOIS_SEEDS="uk=whois.nic.uk co=whois.registry.co io=whois.nic.io \
me=whois.nic.me sh=whois.nic.sh gg=whois.gg"

# Reputation seeds. NOTE: lib.sh already hard-codes this knowledge in
# ds_tld_flags, and de-duplicates flags, so these rows are belt-and-braces.
# The file exists as the documented, user-editable extension point: add your
# own TLDs and flags here and ds_tld_flags will pick them up.
BS_SPAM_TLDS="bid date download loan men party stream trade win top click quest"
BS_RENEWAL_TRAP_TLDS="bar codes fun works zone online site space lol live rest"
BS_NO_PREMIUM_TLDS="com net uk org"

# Short alias -> canonical target (both live in data/). Kept as "alias=target"
# pairs rather than an associative array, for bash 3.2.
BS_ALIASES="tldmap.tsv=rdap-endpoints.tsv prices.tsv=tld-prices.tsv \
reputation.tsv=tld-flags.tsv"

BS_STEP=0
BS_STEPS=7
BS_FAILURES=0
BS_TMPDIR=""

# ---------------------------------------------------------------------------
# SECTION 2: usage and argument parsing
# ---------------------------------------------------------------------------

# _bs_usage
#   Prints the help text on stdout. Exit: always 0.
_bs_usage() {
	cat <<'EOF'
bootstrap.sh - refresh DomainSaver's local caches in data/

USAGE
  scripts/bootstrap.sh [options]

OPTIONS
  -f, --force            Refresh every cache regardless of its age.
      --max-age DAYS     Treat a cache older than DAYS whole days as stale.
                         Default 7. Use --force rather than --max-age 0.
      --rebuild          Offline mode: do not touch the network. Rebuild the
                         TSV tables from the JSON already in data/.
  -q, --quiet            Suppress progress output. Warnings and errors still
                         print (they mean your results may be wrong).
  -h, --help             Show this help and exit.
  -V, --version          Show the bootstrap and library versions and exit.

ENVIRONMENT
  DS_DATA_DIR                 Where the caches live. Default <repo>/data.
  DS_BOOTSTRAP_MAX_AGE_DAYS   Default for --max-age.
  DS_CONNECT_TIMEOUT          TCP connect timeout, seconds (default 10).
  DS_QUIET / DS_DEBUG         Same effect as --quiet / verbose tracing.

  No credentials are used or needed here. PORKBUN_API_KEY / PORKBUN_SECRET_KEY
  are only read at query time, for per-name premium quotes.

EXIT STATUS
  0  caches are present, fresh and passed every sanity check
  1  a download, a rebuild or a verification check failed
  2  bad usage

EXAMPLES
  scripts/bootstrap.sh                 # refresh anything older than 7 days
  scripts/bootstrap.sh --force         # refetch everything now
  scripts/bootstrap.sh --rebuild       # rebuild tables offline from cached JSON
  scripts/bootstrap.sh --max-age 1 -q  # cron-friendly daily refresh
EOF
}

# _bs_usage_error <message...>
#   Prints a message and the usage text on stderr, then exits 2.
_bs_usage_error() {
	printf '[ds] usage error: %s\n\n' "$*" >&2
	_bs_usage >&2
	exit 2
}

# _bs_parse_args <argv...>
#   Sets BS_FORCE / BS_MAX_AGE_DAYS / BS_REBUILD / DS_QUIET from the command
#   line. Rejects unknown options and stray positional arguments, because
#   silently ignoring an argument is how a cron job quietly stops refreshing.
_bs_parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-f | --force)
			BS_FORCE=1
			;;
		--rebuild | --offline)
			BS_REBUILD=1
			;;
		--max-age)
			[ "$#" -ge 2 ] || _bs_usage_error "--max-age needs a number of days"
			shift
			_bs_set_max_age "$1"
			;;
		--max-age=*)
			_bs_set_max_age "${1#*=}"
			;;
		-q | --quiet)
			# Consumed by ds_log in lib.sh, not by this file.
			# shellcheck disable=SC2034
			DS_QUIET=1
			;;
		-h | --help)
			_bs_usage
			exit 0
			;;
		-V | --version)
			printf 'bootstrap.sh %s (lib.sh %s)\n' "$BS_VERSION" "$DS_LIB_VERSION"
			exit 0
			;;
		--)
			shift
			[ "$#" -eq 0 ] || _bs_usage_error "unexpected argument: $1"
			break
			;;
		-*)
			_bs_usage_error "unknown option: $1"
			;;
		*)
			_bs_usage_error "unexpected argument: $1 (this script takes options only)"
			;;
		esac
		shift
	done
}

# _bs_set_max_age <days>
#   Validates and stores --max-age. Exits 2 if it is not a non-negative integer.
_bs_set_max_age() {
	case "${1:-}" in
	'' | *[!0-9]*) _bs_usage_error "--max-age must be a whole number of days, got: '${1:-}'" ;;
	esac
	BS_MAX_AGE_DAYS="$1"
}

# ---------------------------------------------------------------------------
# SECTION 3: small helpers
# ---------------------------------------------------------------------------

# _bs_mktemp
#   Echoes the path of a fresh temp file inside this run's private temp dir.
#   Everything lands in one directory so cleanup is a single rm -rf that works
#   even for temp files created inside a command substitution (a subshell
#   cannot add to a parent's variable, so a path list would leak).
_bs_mktemp() {
	mktemp "$BS_TMPDIR/t.XXXXXXXX" ||
		ds_die "cannot create a temp file in $BS_TMPDIR (disk full? no write access?)"
}

# _bs_cleanup
#   EXIT/INT/TERM trap. Removes this run's temp directory.
_bs_cleanup() {
	if [ -n "$BS_TMPDIR" ] && [ -d "$BS_TMPDIR" ]; then
		rm -rf "$BS_TMPDIR" 2>/dev/null || true
	fi
	BS_TMPDIR=""
}
trap _bs_cleanup EXIT INT TERM

# _bs_or_devnull <path>
#   Stdout: <path> if it is a readable file, otherwise /dev/null. Lets awk read
#   "the old file, if there is one" without a conditional at every call site.
_bs_or_devnull() {
	if [ -f "${1:-}" ]; then
		printf '%s\n' "$1"
	else
		printf '/dev/null\n'
	fi
}

# _bs_step <message...>
#   Progress line: "[ds] [3/7] message".
_bs_step() {
	BS_STEP=$((BS_STEP + 1))
	ds_log "[$BS_STEP/$BS_STEPS] $*"
}

# _bs_fail <message...>
#   Records a verification failure and prints it. Checks keep running so one
#   run reports every problem, not just the first.
_bs_fail() {
	BS_FAILURES=$((BS_FAILURES + 1))
	ds_warn "CHECK FAILED: $*"
}

# _bs_rows <file>
#   Stdout: number of data rows (comments and blank lines excluded). 0 if the
#   file is missing. Exit: always 0.
_bs_rows() {
	[ -s "${1:-}" ] || {
		printf '0\n'
		return 0
	}
	awk '!/^[ \t]*#/ && NF { n++ } END { print n + 0 }' "$1"
}

# _bs_is_fresh <file>
#   Exit: 0 if <file> exists, is non-empty, and was modified within the last
#   BS_MAX_AGE_DAYS whole days; 1 otherwise (missing, empty, stale, or --force).
#   Uses find -mtime, which behaves the same on BSD and GNU; `stat` does not.
_bs_is_fresh() {
	if [ "$BS_FORCE" = "1" ]; then
		return 1
	fi
	[ -s "${1:-}" ] || return 1
	if find "$1" -mtime "+$BS_MAX_AGE_DAYS" 2>/dev/null | grep -q .; then
		return 1
	fi
	return 0
}

# _bs_curl_hint <curl_exit_code>
#   Stdout: a human explanation of a curl failure, so the error message says
#   what to do rather than just printing a number.
_bs_curl_hint() {
	case "${1:-}" in
	6) printf 'DNS lookup failed - offline, or a DNS/VPN problem\n' ;;
	7) printf 'could not connect - firewall, proxy, or the host is down\n' ;;
	22) printf 'the server returned an HTTP error status\n' ;;
	28) printf 'timed out after %ss\n' "$BS_HTTP_MAX_TIME" ;;
	35 | 51 | 58 | 59 | 60 | 77) printf 'TLS/certificate failure - a MITM proxy re-signing traffic?\n' ;;
	*) printf 'curl exit code %s\n' "${1:-?}" ;;
	esac
}

# _bs_fetch_json <label> <url> <dest> <jq_shape_check> [post_body]
#   Downloads JSON to a temp file, checks that it parses AND matches a shape
#   assertion, and only then moves it into place. An existing good cache is
#   never overwritten by a bad download.
#   Exit: 0 on success; 1 on any failure (having warned with a useful reason).
_bs_fetch_json() {
	_bsf_label="$1"
	_bsf_url="$2"
	_bsf_dest="$3"
	_bsf_check="$4"
	_bsf_post="${5:-}"

	_bsf_tmp=$(_bs_mktemp)
	_bsf_err=$(_bs_mktemp)
	_bsf_rc=0

	if [ -n "$_bsf_post" ]; then
		curl -fsS -L --max-redirs 3 \
			-A "$DS_USER_AGENT" \
			-H 'Content-Type: application/json' \
			-X POST --data "$_bsf_post" \
			--retry "$BS_HTTP_RETRIES" --retry-delay 2 \
			--connect-timeout "$DS_CONNECT_TIMEOUT" \
			--max-time "$BS_HTTP_MAX_TIME" \
			-o "$_bsf_tmp" "$_bsf_url" 2>"$_bsf_err" || _bsf_rc=$?
	else
		curl -fsS -L --max-redirs 3 \
			-A "$DS_USER_AGENT" \
			-H 'Accept: application/json' \
			--retry "$BS_HTTP_RETRIES" --retry-delay 2 \
			--connect-timeout "$DS_CONNECT_TIMEOUT" \
			--max-time "$BS_HTTP_MAX_TIME" \
			-o "$_bsf_tmp" "$_bsf_url" 2>"$_bsf_err" || _bsf_rc=$?
	fi

	if [ "$_bsf_rc" -ne 0 ]; then
		ds_warn "download failed: $_bsf_label"
		ds_warn "  url  : $_bsf_url"
		ds_warn "  why  : $(_bs_curl_hint "$_bsf_rc")"
		if [ -s "$_bsf_err" ]; then
			ds_warn "  curl : $(tr '\n' ' ' <"$_bsf_err" | sed -e 's/  */ /g' -e 's/ $//')"
		fi
		return 1
	fi
	if [ ! -s "$_bsf_tmp" ]; then
		ds_warn "download failed: $_bsf_label returned an empty body"
		return 1
	fi
	if ! jq -e "$_bsf_check" "$_bsf_tmp" >/dev/null 2>&1; then
		ds_warn "download failed: $_bsf_label returned an unexpected payload"
		ds_warn "  expected jq: $_bsf_check"
		ds_warn "  got (first 120 bytes): $(dd if="$_bsf_tmp" bs=1 count=120 2>/dev/null | tr '\n\t' '  ')"
		ds_warn "  a login page or an error blob here means a captive portal or proxy"
		return 1
	fi

	chmod 0644 "$_bsf_tmp" 2>/dev/null || true
	mv "$_bsf_tmp" "$_bsf_dest" || {
		ds_warn "cannot write $_bsf_dest"
		return 1
	}
	ds_log "      saved $_bsf_dest ($(wc -c <"$_bsf_dest" | tr -d ' ') bytes)"
	unset _bsf_label _bsf_url _bsf_dest _bsf_check _bsf_post _bsf_tmp _bsf_err _bsf_rc
	return 0
}

# _bs_merge_tsv <first-wins-file> <second-file>
#   Stdout: the union of both files' data rows, keyed on column 1, with the
#   first file winning on conflict, comments and blanks dropped, sorted by key
#   so repeated runs produce byte-identical files. This is the bash-3.2-safe
#   stand-in for merging two associative arrays.
_bs_merge_tsv() {
	awk -F'\t' '
		/^[ \t]*#/  { next }
		/^[ \t]*$/  { next }
		$1 == ""    { next }
		!seen[$1]++ { print }
	' "$1" "$2" | LC_ALL=C sort
}

# _bs_install_file <tmp> <dest>
#   Moves a generated table into place with sane permissions.
_bs_install_file() {
	chmod 0644 "$1" 2>/dev/null || true
	mv "$1" "$2" || ds_die "cannot write $2 (check permissions on $DS_DATA_DIR)"
}

# ---------------------------------------------------------------------------
# SECTION 4: the steps
# ---------------------------------------------------------------------------

# _bs_refresh_rdap
#   Step 1+2: fetch the IANA RDAP bootstrap (unless it is fresh) and rebuild
#   data/rdap-endpoints.tsv from it via lib.sh's ds_build_rdap_index.
_bs_refresh_rdap() {
	_bs_step "IANA RDAP bootstrap ($BS_IANA_URL)"
	if [ "$BS_REBUILD" = "1" ]; then
		[ -s "$DS_RDAP_BOOTSTRAP_JSON" ] ||
			ds_die "--rebuild needs $DS_RDAP_BOOTSTRAP_JSON, which is missing. Run without --rebuild once."
		ds_log "      offline mode: using cached $DS_RDAP_BOOTSTRAP_JSON"
	elif _bs_is_fresh "$DS_RDAP_BOOTSTRAP_JSON"; then
		ds_log "      cached copy is under $BS_MAX_AGE_DAYS day(s) old, skipping (use --force to refetch)"
	else
		_bs_fetch_json "IANA RDAP bootstrap" "$BS_IANA_URL" "$DS_RDAP_BOOTSTRAP_JSON" \
			'(.services | type == "array") and (.services | length >= 100)' ||
			ds_die "could not refresh the RDAP bootstrap. Existing cache left untouched; try --rebuild to work offline."
		ds_log "      published: $(jq -r '.publication // "unknown"' "$DS_RDAP_BOOTSTRAP_JSON")"
	fi

	_bs_step "building $DS_RDAP_INDEX_TSV (tld -> rdap base url)"
	ds_build_rdap_index ||
		ds_die "failed to build the RDAP index from $DS_RDAP_BOOTSTRAP_JSON. Delete it and re-run with --force."
	# lib.sh builds via mktemp, which is 0600; these are public facts, and a
	# shared checkout should be able to read them.
	chmod 0644 "$DS_RDAP_INDEX_TSV" 2>/dev/null || true
	ds_log "      $(_bs_rows "$DS_RDAP_INDEX_TSV") TLDs mapped"

	# Informational only: lib.sh refuses the rdap.org proxy at lookup time
	# (it 429s after ~60 requests), but it is worth knowing if IANA ever
	# starts publishing it as an endpoint.
	_bsr_proxy=$(awk -F'\t' 'tolower($2) ~ /rdap\.org/ { n++ } END { print n + 0 }' \
		"$DS_RDAP_INDEX_TSV")
	if [ "$_bsr_proxy" -gt 0 ]; then
		ds_warn "$_bsr_proxy TLD(s) point at the rdap.org proxy; lib.sh will route those to whois"
	fi
	unset _bsr_proxy
}

# _bs_refresh_prices
#   Step 3+4: fetch Porkbun's public price list (unless it is fresh) and
#   rebuild data/tld-prices.tsv from it via lib.sh's ds_build_price_index.
_bs_refresh_prices() {
	_bs_step "Porkbun public pricing ($BS_PORKBUN_URL)"
	if [ "$BS_REBUILD" = "1" ]; then
		[ -s "$DS_PRICING_JSON" ] ||
			ds_die "--rebuild needs $DS_PRICING_JSON, which is missing. Run without --rebuild once."
		ds_log "      offline mode: using cached $DS_PRICING_JSON"
	elif _bs_is_fresh "$DS_PRICING_JSON"; then
		ds_log "      cached copy is under $BS_MAX_AGE_DAYS day(s) old, skipping (use --force to refetch)"
	else
		# No auth: this endpoint takes an empty JSON body and returns every
		# TLD's list price. Per-name premium quotes need a key and are not
		# this script's job.
		_bs_fetch_json "Porkbun pricing" "$BS_PORKBUN_URL" "$DS_PRICING_JSON" \
			'.status == "SUCCESS" and (.pricing | length >= 100)' '{}' ||
			ds_die "could not refresh Porkbun pricing. Existing cache left untouched; try --rebuild to work offline."
	fi

	_bs_step "building $DS_PRICE_INDEX_TSV (tld -> registration/renewal/transfer)"
	ds_build_price_index ||
		ds_die "failed to build the price index from $DS_PRICING_JSON. Delete it and re-run with --force."
	chmod 0644 "$DS_PRICE_INDEX_TSV" 2>/dev/null || true
	ds_log "      $(_bs_rows "$DS_PRICE_INDEX_TSV") TLDs priced"
}

# _bs_seed_whois
#   Step 5: seed data/whois-servers.tsv with the entries that must be right on
#   a cold cache, preserving anything lib.sh has discovered since. The seeds
#   win on conflict; every other row is kept. Re-running is byte-idempotent.
_bs_seed_whois() {
	_bs_step "seeding $DS_WHOIS_SERVERS_TSV"
	_bsw_seed=$(_bs_mktemp)
	for _bsw_pair in $BS_WHOIS_SEEDS; do
		printf '%s\t%s\n' "${_bsw_pair%%=*}" "${_bsw_pair#*=}" >>"$_bsw_seed"
	done

	_bsw_out=$(_bs_mktemp)
	{
		printf '# tld\twhois_server\n'
		printf '#\n'
		printf '# Seeded by bootstrap.sh and grown lazily by ds_whois_server (lib.sh),\n'
		printf '# which resolves unknown TLDs with: whois -h whois.iana.org <tld>\n'
		printf '# Safe to delete: it will be rebuilt. Seeded rows win over cached ones.\n'
		_bs_merge_tsv "$_bsw_seed" "$(_bs_or_devnull "$DS_WHOIS_SERVERS_TSV")"
	} >"$_bsw_out"

	_bs_install_file "$_bsw_out" "$DS_WHOIS_SERVERS_TSV"
	ds_log "      $(_bs_rows "$DS_WHOIS_SERVERS_TSV") whois servers known ($(printf '%s\n' "$BS_WHOIS_SEEDS" | wc -w | tr -d ' ') seeded)"
	unset _bsw_seed _bsw_out _bsw_pair
}

# _bs_seed_reputation
#   Step 6: seed data/tld-flags.tsv with the spam cluster, the known renewal
#   traps and the no-premium registries. EXISTING ROWS WIN - this file is meant
#   to be edited by hand, so a re-run never clobbers your entries; delete a row
#   (or the file) to get the seed value back.
_bs_seed_reputation() {
	_bs_step "seeding $DS_TLD_FLAGS_TSV"
	_bsp_raw=$(_bs_mktemp)
	for _bsp_t in $BS_SPAM_TLDS; do printf '%s\tSPAM_ASSOCIATED\n' "$_bsp_t" >>"$_bsp_raw"; done
	for _bsp_t in $BS_RENEWAL_TRAP_TLDS; do printf '%s\tRENEWAL_TRAP\n' "$_bsp_t" >>"$_bsp_raw"; done
	for _bsp_t in $BS_NO_PREMIUM_TLDS; do printf '%s\tNO_PREMIUM_REGISTRY\n' "$_bsp_t" >>"$_bsp_raw"; done

	# Collapse multiple flags for the same TLD onto one row.
	_bsp_seed=$(_bs_mktemp)
	awk -F'\t' '
		{ if ($1 in flags) flags[$1] = flags[$1] " " $2
		  else { flags[$1] = $2; order[++n] = $1 } }
		END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], flags[order[i]] }
	' "$_bsp_raw" >"$_bsp_seed"

	_bsp_out=$(_bs_mktemp)
	{
		printf '# tld\tFLAG [FLAG...]\n'
		printf '#\n'
		printf '# Extra reputation flags merged in by ds_tld_flags (lib.sh), which also\n'
		printf '# derives RENEWAL_TRAP / RENEWAL_EXPENSIVE from the price table and\n'
		printf '# already hard-codes the seeds below - they are repeated here as the\n'
		printf '# user-editable surface. Flags are de-duplicated, so repetition is free.\n'
		printf '# EDIT FREELY: bootstrap.sh never overwrites a row that already exists.\n'
		_bs_merge_tsv "$(_bs_or_devnull "$DS_TLD_FLAGS_TSV")" "$_bsp_seed"
	} >"$_bsp_out"

	_bs_install_file "$_bsp_out" "$DS_TLD_FLAGS_TSV"
	ds_log "      $(_bs_rows "$DS_TLD_FLAGS_TSV") TLDs flagged"
	unset _bsp_raw _bsp_seed _bsp_out _bsp_t
}

# _bs_write_templates_and_aliases
#   Step 7: write the rdap-overrides.tsv template (only if absent - it is
#   hand-edited) and create the short-name symlinks. Aliases are symlinks, not
#   copies, so there is one copy of every fact and nothing can drift.
_bs_write_templates_and_aliases() {
	_bs_step "templates and short-name aliases"

	if [ ! -e "$DS_RDAP_OVERRIDES_TSV" ]; then
		_bso_tmp=$(_bs_mktemp)
		{
			printf '# tld\tURL | WHOIS\n'
			printf '#\n'
			printf '# Hand-maintained escape hatch, read first by ds_rdap_endpoint (lib.sh).\n'
			printf '# A URL forces that RDAP endpoint; the literal WHOIS forces the whois path.\n'
			printf '# bootstrap.sh creates this file once and never rewrites it.\n'
			printf '#\n'
			printf '# Examples (uncomment to use):\n'
			printf '# app\thttps://pubapi.registry.google/rdap\n'
		} >"$_bso_tmp"
		_bs_install_file "$_bso_tmp" "$DS_RDAP_OVERRIDES_TSV"
		ds_log "      wrote template $DS_RDAP_OVERRIDES_TSV"
		unset _bso_tmp
	else
		ds_log "      keeping your $DS_RDAP_OVERRIDES_TSV"
	fi

	_bsa_made=""
	for _bsa_pair in $BS_ALIASES; do
		_bsa_name="${_bsa_pair%%=*}"
		_bsa_link="$DS_DATA_DIR/$_bsa_name"
		_bsa_target="${_bsa_pair#*=}"
		if [ -e "$_bsa_link" ] && [ ! -L "$_bsa_link" ]; then
			ds_warn "$_bsa_link is a real file, not a symlink - leaving it alone"
			ds_warn "  (delete it if you want the alias to $_bsa_target back)"
			continue
		fi
		# Relative target: the repo stays portable if it is moved or cloned.
		if ln -sf "$_bsa_target" "$_bsa_link"; then
			_bsa_made="$_bsa_made $_bsa_name"
		else
			ds_warn "could not create alias $_bsa_link -> $_bsa_target"
		fi
	done
	if [ -n "$_bsa_made" ]; then
		ds_log "      aliases ->$_bsa_made"
	fi
	unset _bsa_pair _bsa_name _bsa_link _bsa_target _bsa_made
}

# ---------------------------------------------------------------------------
# SECTION 5: verification
# ---------------------------------------------------------------------------

# _bs_verify
#   Proves the caches are usable THROUGH lib.sh's own accessors, not just that
#   files exist: row counts against the measured floors, then real lookups.
#   Every check runs so one run reports every problem.
#   Exit: 0 if all checks passed; 1 otherwise.
_bs_verify() {
	ds_log "verifying..."

	# 1. Table sizes. Far below the floor means truncation, not a smaller internet.
	_bsv_rdap=$(_bs_rows "$DS_RDAP_INDEX_TSV")
	if [ "$_bsv_rdap" -lt "$BS_MIN_RDAP_TLDS" ]; then
		_bs_fail "RDAP map has $_bsv_rdap TLDs, expected at least $BS_MIN_RDAP_TLDS."
		ds_warn "  IANA published 1200 in 2026-07. A short table means a truncated"
		ds_warn "  download or a proxy serving something else. Re-run with --force."
	fi
	_bsv_price=$(_bs_rows "$DS_PRICE_INDEX_TSV")
	if [ "$_bsv_price" -lt "$BS_MIN_PRICE_TLDS" ]; then
		_bs_fail "price table has $_bsv_price TLDs, expected at least $BS_MIN_PRICE_TLDS."
		ds_warn "  Porkbun listed 907 in 2026-07. Re-run with --force."
	fi

	# 2. RDAP routing actually resolves, and to a real https endpoint.
	if _bsv_url=$(ds_rdap_endpoint com); then
		case "$_bsv_url" in
		https://*) ds_debug "rdap[com] = $_bsv_url" ;;
		*) _bs_fail "ds_rdap_endpoint com returned a non-https endpoint: $_bsv_url" ;;
		esac
	else
		_bs_fail "ds_rdap_endpoint com found no endpoint - the RDAP map is unusable."
	fi

	# 3. Pricing actually resolves, and to a number rather than an empty string.
	if _bsv_row=$(ds_std_price com); then
		_bsv_ren=$(printf '%s' "$_bsv_row" | cut -f2)
		if ! awk -v v="$_bsv_ren" 'BEGIN { exit !(v + 0 > 0) }'; then
			_bs_fail "ds_std_price com gave a non-numeric renewal ('$_bsv_ren') - payload shape changed?"
		else
			ds_debug "price[com] renewal = $_bsv_ren"
		fi
	else
		_bs_fail "ds_std_price com found no price - the price table is unusable."
	fi

	# 4. Every whois seed is present in the file with the value we seeded.
	for _bsv_pair in $BS_WHOIS_SEEDS; do
		_bsv_tld="${_bsv_pair%%=*}"
		_bsv_want="${_bsv_pair#*=}"
		_bsv_got=$(awk -F'\t' -v k="$_bsv_tld" '!/^[ \t]*#/ && $1 == k { print $2; exit }' \
			"$DS_WHOIS_SERVERS_TSV")
		[ "$_bsv_got" = "$_bsv_want" ] ||
			_bs_fail "whois seed for .$_bsv_tld is '$_bsv_got', expected '$_bsv_want'"
	done

	# 5. And that lib.sh reads them back (io is not hard-coded in lib.sh, so
	#    this genuinely exercises the cache rather than an override).
	if _bsv_srv=$(ds_whois_server io); then
		[ "$_bsv_srv" = "whois.nic.io" ] ||
			_bs_fail "ds_whois_server io returned '$_bsv_srv', expected whois.nic.io"
	else
		_bs_fail "ds_whois_server io failed - the whois cache is unusable."
	fi

	# 6. Reputation flags: the seeded knowledge and the computed rule both fire.
	case " $(ds_tld_flags com) " in
	*" NO_PREMIUM_REGISTRY "*) ;;
	*) _bs_fail "ds_tld_flags com is missing NO_PREMIUM_REGISTRY" ;;
	esac
	case " $(ds_tld_flags top) " in
	*" SPAM_ASSOCIATED "*) ;;
	*) _bs_fail "ds_tld_flags top is missing SPAM_ASSOCIATED" ;;
	esac
	case " $(ds_tld_flags online) " in
	*" RENEWAL_TRAP "*) ;;
	*) _bs_fail "ds_tld_flags online is missing RENEWAL_TRAP - is the price table stale?" ;;
	esac

	# 7. The aliases point somewhere real.
	for _bsv_apair in $BS_ALIASES; do
		_bsv_link="$DS_DATA_DIR/${_bsv_apair%%=*}"
		[ -e "$_bsv_link" ] || _bs_fail "alias $_bsv_link does not resolve to a file"
	done

	unset _bsv_rdap _bsv_price _bsv_url _bsv_row _bsv_ren _bsv_pair _bsv_tld \
		_bsv_want _bsv_got _bsv_srv _bsv_apair _bsv_link 2>/dev/null || true

	[ "$BS_FAILURES" -eq 0 ]
}

# _bs_summary
#   Prints the final one-line-per-cache report.
_bs_summary() {
	ds_log ""
	ds_log "data/ is ready:"
	ds_log "$(printf '  %-24s %6s rows' "rdap-endpoints.tsv" "$(_bs_rows "$DS_RDAP_INDEX_TSV")")"
	ds_log "$(printf '  %-24s %6s rows' "tld-prices.tsv" "$(_bs_rows "$DS_PRICE_INDEX_TSV")")"
	ds_log "$(printf '  %-24s %6s rows' "whois-servers.tsv" "$(_bs_rows "$DS_WHOIS_SERVERS_TSV")")"
	ds_log "$(printf '  %-24s %6s rows' "tld-flags.tsv" "$(_bs_rows "$DS_TLD_FLAGS_TSV")")"
	ds_log ""
	ds_log "Reminder: UNREGISTERED is not AVAILABLE. Promoting a name needs a real"
	ds_log "quote (PORKBUN_API_KEY / PORKBUN_SECRET_KEY), never just an RDAP 404."
}

# ---------------------------------------------------------------------------
# SECTION 6: main
# ---------------------------------------------------------------------------

main() {
	_bs_parse_args "$@"

	if [ "$BS_REBUILD" = "1" ] && [ "$BS_FORCE" = "1" ]; then
		ds_warn "--force has no effect with --rebuild (offline mode never downloads)"
	fi

	ds_require curl jq awk mktemp
	# whois is not needed to bootstrap, only to probe - so warn, do not die.
	command -v whois >/dev/null 2>&1 ||
		ds_warn "whois is not installed; lookups for no-RDAP TLDs (.io/.co/.uk/...) will fail"

	mkdir -p "$DS_DATA_DIR" || ds_die "cannot create $DS_DATA_DIR"
	[ -w "$DS_DATA_DIR" ] || ds_die "$DS_DATA_DIR is not writable"

	BS_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/domainsaver-bootstrap.XXXXXXXX") ||
		ds_die "cannot create a temp directory in ${TMPDIR:-/tmp}"

	ds_log "DomainSaver bootstrap $BS_VERSION -> $DS_DATA_DIR"
	if [ "$BS_REBUILD" = "1" ]; then
		ds_log "offline mode: rebuilding tables from cached JSON only"
	fi

	_bs_refresh_rdap
	_bs_refresh_prices
	_bs_seed_whois
	_bs_seed_reputation
	_bs_write_templates_and_aliases

	if ! _bs_verify; then
		ds_warn ""
		ds_die "$BS_FAILURES verification check(s) failed - the caches are NOT trustworthy. See the warnings above; 'scripts/bootstrap.sh --force' refetches everything."
	fi

	_bs_summary
	return 0
}

main "$@"

# End of bootstrap.sh
