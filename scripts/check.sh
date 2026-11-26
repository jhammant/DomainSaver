#!/usr/bin/env bash
# shellcheck shell=bash
#
# check.sh - DomainSaver: check one or a few domains, precisely.
#
#     scripts/check.sh shed.link bar.link example.com
#     printf 'shed.top\nallotment.co\n' | scripts/check.sh
#     scripts/check.sh --json shed.page | jq .
#
# For each name this prints the registry status (via lib.sh's ds_probe), the
# TLD's STANDARD list price, and the TLD's reputation / renewal-risk flags.
#
# THE ONE THING THIS SCRIPT REFUSES TO DO:
#   It never says AVAILABLE. ds_probe can only tell us that a name is absent
#   from the registry (UNREGISTERED), and "absent" covers three very different
#   commercial realities: genuinely available, registry-RESERVED, and
#   PREMIUM-PRICED. Measured examples: shed.link looked free and quoted
#   $819.27/yr against a $7.72 standard price; bar.link quoted $1638.01.
#   Promoting UNREGISTERED to AVAILABLE requires a real per-name quote, which
#   is quote.sh's job, not this script's.
#
# DESIGN CONSTRAINTS (inherited from lib.sh, deliberate, do not "modernise"):
#   * bash 3.2 compatible - no associative arrays, no `declare -A`, no
#     `${var^^}`, no `readarray`. Tables are TSV files read with awk.
#   * POSIX-ish external tools only; no GNU-only flags; never `sed -i`.
#   * stdout carries ONLY the table (or the JSON). Every banner, warning,
#     legend and diagnostic goes to stderr, so `check.sh ... | cut -f2` is
#     always safe.
#
# Internal helpers are prefixed `_ck_` so they can never collide with lib.sh's
# `ds_` / `_ds_` namespace.

set -euo pipefail

# ---------------------------------------------------------------------------
# SECTION 1: bootstrap - locate and source the shared library
# ---------------------------------------------------------------------------

_CK_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)
if [ ! -r "$_CK_DIR/lib.sh" ]; then
	printf '[ds] FATAL: cannot read %s/lib.sh (is the repo intact?)\n' "$_CK_DIR" >&2
	exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$_CK_DIR/lib.sh"

_CK_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# SECTION 2: defaults and state
# ---------------------------------------------------------------------------

_CK_JSON=0        # --json
_CK_QUIET=0       # -q / --quiet
_CK_PRICES=1      # --no-price turns this off
_CK_BIG_LIST=25   # above this many names, point the user at the batch runner
_CK_DETAIL_W=40   # DETAIL column truncation width in table mode
_CK_ROWS=""       # temp file: one TSV record per checked name
_CK_JSONBUF=""    # temp file: one JSON object per checked name

# Record layout of $_CK_ROWS (tab separated, never any empty field - "-" is
# used as the placeholder so `read` with IFS=TAB cannot mis-align):
#   1 domain  2 tld  3 status  4 registration  5 renewal  6 flags(csv)
#   7 detail  8 price_key
_CK_TAB=$(printf '\t')

# shellcheck disable=SC2329  # invoked indirectly, from the EXIT trap below
_ck_cleanup() {
	if [ -n "${_CK_ROWS:-}" ]; then rm -f "$_CK_ROWS"; fi
	if [ -n "${_CK_JSONBUF:-}" ]; then rm -f "$_CK_JSONBUF"; fi
	return 0
}
trap _ck_cleanup EXIT

# ---------------------------------------------------------------------------
# SECTION 3: usage
# ---------------------------------------------------------------------------

# _ck_usage
#   Writes the help text to STDOUT. Callers that are reporting a usage ERROR
#   redirect it to stderr themselves (`_ck_usage >&2`).
_ck_usage() {
	cat <<'EOF'
check.sh - check one or a few domains precisely: registry status, standard
           price and TLD risk flags.

USAGE
  check.sh [options] <domain> [domain...]
  check.sh [options] -                    read domains from stdin
  cat names.txt | check.sh [options]      ditto (no domain arguments)

  Domains may also be given on stdin one per line, or several per line
  separated by spaces or commas. Blank lines and '#' comments are ignored.
  Duplicates are checked once.

OPTIONS
  --json           emit machine-readable JSON on stdout instead of a table
                   (requires jq)
  -q, --quiet      no header, no legend: stdout becomes header-free
                   TAB-separated rows
                   (domain, status, registration, renewal, flags, detail)
  -v, --verbose    verbose tracing from the library (sets DS_DEBUG=1)
      --no-price   skip the price and flag lookup; report status only
  -h, --help       this text
  -V, --version    print the version and exit

STATUS VALUES (owned by lib.sh; this script never invents others)
  UNREGISTERED   not present in the registry. This is NOT the same as
                 available: the name may be registry-RESERVED or
                 PREMIUM-priced. Only a real per-name quote can tell those
                 apart - see quote.sh.
  REGISTERED     taken.
  ERROR          the lookup failed, was rate-limited, timed out or could not
                 be parsed. It is not an answer; re-run it.

PRICES
  Porkbun STANDARD list prices in USD for the whole TLD, from the cached price
  table. They are NOT a quote for this particular name. RENEWAL is the number
  that matters: several TLDs are cheap for one year and brutal thereafter.

FLAGS
  NO_PREMIUM_REGISTRY   registry has no premium tier, so list price is real
  SPAM_ASSOCIATED       commonly blocked wholesale by corporate filters
  RENEWAL_TRAP          renewal >= 3x registration and >= $20
  RENEWAL_EXPENSIVE     renewal >= $25/yr
  NO_PRICE_DATA         TLD absent from the cached price table

OUTPUT STREAMS
  stdout   the table (with a header unless --quiet), or the JSON document
  stderr   banners, legends, warnings and per-name diagnostics

EXIT STATUS
  0   every name got an answer (UNREGISTERED or REGISTERED)
  1   at least one name ended in ERROR (or was not a valid domain name)
  2   usage error: bad option, or no domains supplied

ENVIRONMENT
  DS_HTTP_TIMEOUT, DS_WHOIS_TIMEOUT, DS_RDAP_RETRIES, DS_DEBUG, ... see lib.sh.
  PORKBUN_API_KEY / PORKBUN_SECRET_KEY are NOT used here; they are what
  quote.sh needs to turn UNREGISTERED into AVAILABLE or PREMIUM.

FIRST RUN
  If data/ is empty, run scripts/bootstrap.sh first: it downloads the IANA
  RDAP bootstrap and the Porkbun price list. Without them this script still
  works, but every TLD falls back to whois and no prices are shown.
EOF
}

# ---------------------------------------------------------------------------
# SECTION 4: small helpers
# ---------------------------------------------------------------------------

# _ck_dash <value>
#   Echoes <value>, or "-" if it is empty. Keeps every TSV field non-empty so
#   `read` with a tab IFS cannot silently collapse adjacent separators.
_ck_dash() {
	if [ -z "${1:-}" ]; then printf '%s\n' '-'; else printf '%s\n' "$1"; fi
}

# _ck_money <value>
#   Echoes <value> formatted to 2 decimal places, or "-" if it is not a plain
#   decimal number (Porkbun occasionally returns an empty string).
_ck_money() {
	awk -v v="${1:-}" 'BEGIN {
		if (v ~ /^[0-9]+(\.[0-9]+)?$/) printf "%.2f\n", v + 0; else print "-"
	}'
}

# Domain syntax. Deliberately strict and ASCII-only: at least two labels, each
# label alphanumeric-with-inner-hyphens, and a TLD that starts with a letter
# (which also rejects bare IPv4 addresses). Punycode ("xn--p1ai") passes.
# Unicode names must be punycoded by the caller - registries key on the A-label
# and silently guessing the conversion here would be worse than refusing.
_CK_DOMAIN_RE='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]([a-z0-9-]*[a-z0-9])?$'

# _ck_valid_domain <normalized-domain>
#   Exit: 0 if the name is syntactically a domain we can look up, else 1.
_ck_valid_domain() {
	_ckv_d="${1:-}"
	if [ -z "$_ckv_d" ]; then return 1; fi
	if [ "${#_ckv_d}" -gt 253 ]; then return 1; fi
	if ! printf '%s' "$_ckv_d" | grep -qE "$_CK_DOMAIN_RE"; then return 1; fi
	# No label may exceed 63 octets.
	if printf '%s' "$_ckv_d" | grep -qE '[a-z0-9-]{64}'; then return 1; fi
	unset _ckv_d
	return 0
}

# _ck_price_key <domain> <registry-tld>
#   Porkbun prices some multi-label suffixes separately ("co.uk" is not "uk"),
#   so prefer the two-label suffix when the price table actually has it, and
#   fall back to the registry TLD otherwise.
#   Stdout: the key to pass to ds_std_price.
_ck_price_key() {
	_ckk_dom="${1:-}"
	_ckk_tld="${2:-}"
	_ckk_two=""
	case "$_ckk_dom" in
	*.*.*)
		_ckk_rest="${_ckk_dom%.*}"
		_ckk_two="${_ckk_rest##*.}.$_ckk_tld"
		;;
	esac
	if [ -n "$_ckk_two" ] && ds_std_price "$_ckk_two" >/dev/null 2>&1; then
		printf '%s\n' "$_ckk_two"
	else
		printf '%s\n' "$_ckk_tld"
	fi
	unset _ckk_dom _ckk_tld _ckk_two _ckk_rest 2>/dev/null || true
	return 0
}

# _ck_flags_csv <space-separated-flags> <had_price>
#   Renders lib.sh's flag tokens as a comma-separated list ("-" when empty).
#   When <had_price> is 1 the NO_PRICE_DATA token is dropped: it means the
#   registry TLD is absent from the table, but we priced the name under a
#   longer suffix (e.g. .co.uk), so reporting "no price data" would be a lie.
_ck_flags_csv() {
	awk -v s="${1:-}" -v havep="${2:-0}" 'BEGIN {
		n = split(s, a, /[ \t]+/)
		out = ""
		for (i = 1; i <= n; i++) {
			if (a[i] == "") continue
			if (havep == 1 && a[i] == "NO_PRICE_DATA") continue
			out = out (out == "" ? "" : ",") a[i]
		}
		print (out == "" ? "-" : out)
	}'
}

# ---------------------------------------------------------------------------
# SECTION 5: input collection
# ---------------------------------------------------------------------------

# _ck_emit_tokens <text...>
#   Splits its arguments on whitespace and commas, strips '#' comments, and
#   prints one normalised candidate name per line.
_ck_emit_tokens() {
	printf '%s\n' "$*" |
		sed -e 's/#.*$//' |
		tr ',;' '  ' |
		tr -s '[:space:]' '\n' |
		while IFS= read -r _cke_tok; do
			[ -n "$_cke_tok" ] || continue
			ds_normalize_domain "$_cke_tok"
		done
}

# _ck_collect <candidates-file> <read_stdin> [args...]
#   Fills <candidates-file> with de-duplicated, normalised candidate names,
#   preserving first-seen order.
_ck_collect() {
	_ckc_out="$1"
	_ckc_stdin="$2"
	shift 2
	_ckc_raw=$(_ds_mktemp)

	for _ckc_arg in "$@"; do
		_ck_emit_tokens "$_ckc_arg" >>"$_ckc_raw"
	done

	if [ "$_ckc_stdin" = "1" ]; then
		while IFS= read -r _ckc_line || [ -n "$_ckc_line" ]; do
			_ck_emit_tokens "$_ckc_line" >>"$_ckc_raw"
		done
	fi

	awk 'NF && !seen[$0]++' "$_ckc_raw" >"$_ckc_out"
	rm -f "$_ckc_raw"
	unset _ckc_out _ckc_stdin _ckc_raw _ckc_arg _ckc_line 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 6: the check itself
# ---------------------------------------------------------------------------

# _ck_check_one <normalised-domain>
#   Probes one name and appends exactly one TSV record to $_CK_ROWS.
#   Never fails the script: an unresolvable name becomes an ERROR record, which
#   is the honest answer. Guessing "free" from a broken lookup is how naive
#   tools send people to a checkout page for a name that is not for sale.
_ck_check_one() {
	_cko_dom="$1"
	_cko_tld=""
	_cko_status="ERROR"
	_cko_detail="input: not a valid domain name"
	_cko_reg="-"
	_cko_ren="-"
	_cko_flags="-"
	_cko_pkey="-"

	if _ck_valid_domain "$_cko_dom"; then
		_cko_tld=$(ds_tld "$_cko_dom") || _cko_tld=""

		# ds_probe returns 1 for ERROR but still prints its one-line result, so
		# capture unconditionally and parse the STATUS out of the line.
		_cko_res=$(ds_probe "$_cko_dom") || true
		_cko_res=${_cko_res%%$'\n'*}
		if [ -n "$_cko_res" ]; then
			_cko_status="${_cko_res%%|*}"
			_cko_rest="${_cko_res#*|}"
			_cko_detail="${_cko_rest#*|}"
		else
			_cko_status="ERROR"
			_cko_detail="probe returned no result"
		fi

		if [ "$_CK_PRICES" = "1" ] && [ -n "$_cko_tld" ]; then
			_cko_havep=0
			_cko_pkey=$(_ck_price_key "$_cko_dom" "$_cko_tld")
			if _cko_price=$(ds_std_price "$_cko_pkey" 2>/dev/null); then
				_cko_reg=$(_ck_money "$(printf '%s' "$_cko_price" | cut -f1)")
				_cko_ren=$(_ck_money "$(printf '%s' "$_cko_price" | cut -f2)")
				if [ "$_cko_reg" != "-" ] || [ "$_cko_ren" != "-" ]; then
					_cko_havep=1
				fi
			fi
			# Reputation flags always come from the registry TLD: that is the
			# key lib.sh's hard-coded lists are written against.
			_cko_raw_flags=$(ds_tld_flags "$_cko_tld" 2>/dev/null) || _cko_raw_flags=""
			_cko_flags=$(_ck_flags_csv "$_cko_raw_flags" "$_cko_havep")
		fi
	else
		ds_warn "not a valid domain name, skipping: '$_cko_dom' (expected e.g. example.com; IDNs must be punycoded)"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(_ck_dash "$_cko_dom")" \
		"$(_ck_dash "$_cko_tld")" \
		"$(_ck_dash "$_cko_status")" \
		"$(_ck_dash "$_cko_reg")" \
		"$(_ck_dash "$_cko_ren")" \
		"$(_ck_dash "$_cko_flags")" \
		"$(_ck_dash "$_cko_detail")" \
		"$(_ck_dash "$_cko_pkey")" >>"$_CK_ROWS"

	unset _cko_dom _cko_tld _cko_status _cko_detail _cko_reg _cko_ren \
		_cko_flags _cko_pkey _cko_res _cko_rest _cko_price _cko_havep \
		_cko_raw_flags 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: rendering
# ---------------------------------------------------------------------------

# _ck_render_table <with_header>
#   Aligned, human-readable table on stdout. Column widths are computed in awk
#   (awk arrays are fine here; only bash associative arrays are off-limits),
#   and the format string is built by hand rather than using printf's '*'
#   width, which is not portable across every awk.
_ck_render_table() {
	awk -F'\t' -v hdr="${1:-1}" -v dw="$_CK_DETAIL_W" '
	function money(v) { return (v == "-" ? "-" : "$" v) }
	function widen(s, cur) { return (length(s) > cur ? length(s) : cur) }
	BEGIN {
		h1 = "DOMAIN"; h2 = "STATUS"; h3 = "REG/YR"
		h4 = "RENEW/YR"; h5 = "FLAGS"; h6 = "DETAIL"
		w1 = length(h1); w2 = length(h2); w3 = length(h3)
		w4 = length(h4); w5 = length(h5)
	}
	{
		n++
		d[n] = $1
		st[n] = $3
		rg[n] = money($4)
		rn[n] = money($5)
		fl[n] = $6
		dt[n] = $7
		if (length(dt[n]) > dw) dt[n] = substr(dt[n], 1, dw - 3) "..."
		w1 = widen(d[n], w1); w2 = widen(st[n], w2); w3 = widen(rg[n], w3)
		w4 = widen(rn[n], w4); w5 = widen(fl[n], w5)
	}
	END {
		fmt = "%-" w1 "s  %-" w2 "s  %" w3 "s  %" w4 "s  %-" w5 "s  %s\n"
		if (hdr == 1) printf fmt, h1, h2, h3, h4, h5, h6
		for (i = 1; i <= n; i++) printf fmt, d[i], st[i], rg[i], rn[i], fl[i], dt[i]
	}
	' "$_CK_ROWS"
}

# _ck_render_tsv
#   Header-free TAB-separated rows for --quiet: domain, status, registration,
#   renewal, flags, detail. Prices are bare numbers (no '$') so they can be fed
#   straight into awk/bc.
_ck_render_tsv() {
	awk -F'\t' 'BEGIN { OFS = "\t" } { print $1, $3, $4, $5, $6, $7 }' "$_CK_ROWS"
}

# _ck_render_json
#   A single JSON document on stdout. jq does the escaping, because registrar
#   names in RDAP details routinely contain quotes, commas and backslashes.
#   `purchasable` is deliberately null for UNREGISTERED: this script cannot
#   know, and a JSON consumer must not be able to mistake absence for a yes.
_ck_render_json() {
	_ckj_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown\n')
	_ckj_quotes="false"
	if ds_porkbun_creds_ok 2>/dev/null; then _ckj_quotes="true"; fi

	_CK_JSONBUF=$(_ds_mktemp)
	while IFS="$_CK_TAB" read -r _ckj_dom _ckj_tld _ckj_st _ckj_reg _ckj_ren \
		_ckj_fl _ckj_dt _ckj_pk; do
		[ -n "$_ckj_dom" ] || continue
		jq -n \
			--arg domain "$_ckj_dom" \
			--arg tld "$_ckj_tld" \
			--arg status "$_ckj_st" \
			--arg registration "$_ckj_reg" \
			--arg renewal "$_ckj_ren" \
			--arg flags "$_ckj_fl" \
			--arg detail "$_ckj_dt" \
			--arg price_tld "$_ckj_pk" \
			'
			def num: if . == "-" or . == "" then null else tonumber end;
			def dash: if . == "-" or . == "" then null else . end;
			{
				domain:      $domain,
				tld:         ($tld | dash),
				status:      $status,
				detail:      ($detail | dash),
				purchasable: (if $status == "REGISTERED" then false else null end),
				standard_price: {
					currency:     "USD",
					tld:          ($price_tld | dash),
					registration: ($registration | num),
					renewal:      ($renewal | num),
					source:       (if ($registration | num) == null and ($renewal | num) == null
					               then null else "porkbun-list-price" end)
				},
				flags: (if $flags == "-" or $flags == "" then [] else ($flags | split(",")) end)
			}' >>"$_CK_JSONBUF"
	done <"$_CK_ROWS"

	jq -n \
		--slurpfile results "$_CK_JSONBUF" \
		--arg generated "$_ckj_ts" \
		--arg version "$_CK_VERSION" \
		--arg lib "$DS_LIB_VERSION" \
		--argjson quotes "$_ckj_quotes" \
		'{
			tool: "DomainSaver/check.sh",
			version: $version,
			lib_version: $lib,
			generated: $generated,
			quotes_configured: $quotes,
			warning: "UNREGISTERED means absent from the registry, NOT purchasable: the name may be registry-reserved or premium-priced. Confirm with a real per-name quote (quote.sh) before treating it as available.",
			results: $results
		}'

	unset _ckj_ts _ckj_quotes _ckj_dom _ckj_tld _ckj_st _ckj_reg _ckj_ren \
		_ckj_fl _ckj_dt _ckj_pk 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 8: main
# ---------------------------------------------------------------------------

main() {
	_ck_stdin=0
	_ck_positional_seen=0

	# --- options ---
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-h | --help)
			_ck_usage
			exit 0
			;;
		-V | --version)
			printf 'check.sh %s (DomainSaver, lib.sh %s)\n' "$_CK_VERSION" "$DS_LIB_VERSION"
			exit 0
			;;
		--json)
			_CK_JSON=1
			shift
			;;
		-q | --quiet)
			_CK_QUIET=1
			DS_QUIET=1
			export DS_QUIET
			shift
			;;
		-v | --verbose)
			DS_DEBUG=1
			export DS_DEBUG
			shift
			;;
		--no-price | --no-prices)
			_CK_PRICES=0
			shift
			;;
		-)
			_ck_stdin=1
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			printf '[ds] FATAL: unknown option: %s\n\n' "$1" >&2
			_ck_usage >&2
			exit 2
			;;
		*)
			break
			;;
		esac
	done

	# A bare "-" among the positional arguments also means "read stdin". Rebuild
	# the positional list without it, using the rotate idiom so no quoting is
	# lost (bash 3.2-safe; no arrays needed).
	_ck_rot="$#"
	while [ "$_ck_rot" -gt 0 ]; do
		_ck_a="$1"
		shift
		if [ "$_ck_a" = "-" ]; then
			_ck_stdin=1
		else
			set -- "$@" "$_ck_a"
		fi
		_ck_rot=$((_ck_rot - 1))
	done

	if [ "$_CK_JSON" = "1" ] && [ "$_CK_QUIET" = "1" ]; then
		ds_warn "--quiet has no effect on the JSON document; it only silences log lines"
	fi

	ds_require awk grep sed tr cut
	if [ "$_CK_JSON" = "1" ]; then ds_require jq; fi
	if ! command -v curl >/dev/null 2>&1 && ! command -v whois >/dev/null 2>&1; then
		ds_die "neither curl nor whois is installed - nothing can be looked up"
	fi

	# --- input ---
	if [ "$#" -eq 0 ] && [ "$_ck_stdin" = "0" ]; then
		if [ -t 0 ]; then
			printf '[ds] FATAL: no domains given\n\n' >&2
			_ck_usage >&2
			exit 2
		fi
		_ck_stdin=1
	fi
	_ck_positional_seen="$#"

	_CK_ROWS=$(_ds_mktemp)
	_ck_names=$(_ds_mktemp)
	_ck_collect "$_ck_names" "$_ck_stdin" "$@"

	_ck_total=$(awk 'END { print NR + 0 }' "$_ck_names")
	if [ "$_ck_total" -eq 0 ]; then
		rm -f "$_ck_names"
		printf '[ds] FATAL: no domains found in the input\n\n' >&2
		_ck_usage >&2
		exit 2
	fi
	if [ "$_ck_total" -gt "$_CK_BIG_LIST" ]; then
		ds_warn "$_ck_total names given: check.sh probes them one at a time. For long lists use the batch runner, which parallelises and retries."
	fi
	if [ "$_ck_positional_seen" -gt 0 ] && [ "$_ck_stdin" = "1" ]; then
		ds_debug "reading both arguments and stdin"
	fi

	# --- cold-cache notices, once, before the per-name warnings pile up ---
	if [ ! -s "$DS_RDAP_INDEX_TSV" ] && [ ! -s "$DS_RDAP_BOOTSTRAP_JSON" ]; then
		ds_warn "no RDAP index cached: every TLD will fall back to whois (slower)."
		ds_warn "  -> run: $DS_ROOT/scripts/bootstrap.sh"
	fi
	if [ "$_CK_PRICES" = "1" ] && [ ! -s "$DS_PRICE_INDEX_TSV" ] && [ ! -s "$DS_PRICING_JSON" ]; then
		ds_warn "no price table cached: prices and renewal-trap flags are unavailable."
		ds_warn "  -> run: $DS_ROOT/scripts/bootstrap.sh"
		_CK_PRICES=0
	fi

	# --- probe ---
	while IFS= read -r _ck_name; do
		[ -n "$_ck_name" ] || continue
		ds_log "checking $_ck_name"
		_ck_check_one "$_ck_name"
	done <"$_ck_names"
	rm -f "$_ck_names"

	# --- render ---
	if [ "$_CK_JSON" = "1" ]; then
		_ck_render_json
	elif [ "$_CK_QUIET" = "1" ]; then
		_ck_render_tsv
	else
		_ck_render_table 1
	fi

	# --- the part that matters: never let UNREGISTERED read as AVAILABLE ---
	_ck_unreg=$(awk -F'\t' '$3 == "UNREGISTERED" { c++ } END { print c + 0 }' "$_CK_ROWS")
	_ck_errs=$(awk -F'\t' '$3 == "ERROR" { c++ } END { print c + 0 }' "$_CK_ROWS")

	if [ "$_ck_unreg" -gt 0 ]; then
		ds_warn "$_ck_unreg of $_ck_total name(s) are UNREGISTERED, which is NOT the same as AVAILABLE - an unregistered name can still be registry-RESERVED or PREMIUM-priced (measured: shed.link quoted \$819.27/yr against a \$7.72 list price). Confirm with a real quote: $_CK_DIR/quote.sh <domain>"
		if ! ds_porkbun_creds_ok 2>/dev/null; then
			ds_log "  (quote.sh needs PORKBUN_API_KEY and PORKBUN_SECRET_KEY in the environment)"
		fi
	fi

	if [ "$_CK_JSON" != "1" ]; then
		ds_log "status: UNREGISTERED = absent from the registry | REGISTERED = taken | ERROR = no answer, re-run it"
		ds_log "prices are Porkbun list prices in USD for the whole TLD, not a quote for this name; renewal is the number that matters"
	fi

	if [ "$_ck_errs" -gt 0 ]; then
		# The table truncates the DETAIL column, and an ERROR's detail is the
		# one place the whole string matters ("rdap:429 rate-limited, gave up
		# after 4 attempts"), so repeat it in full - but only when it was
		# actually truncated, and only in table mode.
		if [ "$_CK_JSON" != "1" ] && [ "$_CK_QUIET" != "1" ]; then
			awk -F'\t' -v dw="$_CK_DETAIL_W" \
				'$3 == "ERROR" && length($7) > dw { printf "[ds] WARN: %s: %s\n", $1, $7 }' \
				"$_CK_ROWS" >&2
		fi
		return 1
	fi
	return 0
}

_ck_rc=0
main "$@" || _ck_rc=$?
exit "$_ck_rc"
