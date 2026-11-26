#!/usr/bin/env bash
# shellcheck shell=bash
#
# quote.sh - real per-name pricing and premium detection for DomainSaver.
#
# WHY THIS SCRIPT EXISTS
#   AVAILABILITY IS NOT PURCHASABILITY. lib.sh's probes can only ever say
#   UNREGISTERED ("absent from the registry"), which lumps together three very
#   different commercial realities: genuinely available, registry-RESERVED, and
#   PREMIUM-PRICED. Measured examples from this project:
#       shed.link   looked free -> quoted   $819.27/yr (list .link is  $7.72)
#       bar.link    looked free -> quoted  $1638.01/yr
#       shed.top    looked free -> quoted    $50.91/yr (list .top  is  $4.63)
#       allotment.co looked free -> quoted  $109.47/yr
#   Only a real, authenticated per-name quote can tell those apart. That is
#   what this script does, and it is the ONLY place in the toolkit allowed to
#   promote a name to AVAILABLE.
#
# DESIGN CONSTRAINTS (deliberate, do not "modernise" away):
#   * Portable to bash 3.2 (the /bin/bash shipped by macOS): no associative
#     arrays, no `declare -A`, no `${var^^}`, no `readarray`. Arithmetic on
#     money is done in awk, because the shell has no floats.
#   * POSIX-ish external tools only: curl, jq, awk, grep, sed, tr. No GNU-only
#     flags, never `sed -i`.
#   * Credentials come from the environment ONLY, are never written to disk,
#     never passed in argv (so `ps` cannot see them) and are redacted from all
#     output. See SECURITY below.
#
# SECURITY
#   PORKBUN_API_KEY / PORKBUN_SECRET_KEY are read from the environment. The
#   request body is piped to curl on STDIN (`--data-binary @-`), never given as
#   a command-line argument and never written to a temp file, so the keys never
#   appear in the process table or on disk. Everything this script prints goes
#   through _dq_redact first, so even an unexpected upstream echo cannot leak a
#   key into logs.
#
# API CONTRACT USED (verified against Porkbun's published OpenAPI spec,
# https://porkbun.com/api/json/v3/spec):
#   POST /api/json/v3/domain/checkDomain/{domain}
#   body: {"apikey":"pk1_...","secretapikey":"sk1_..."}
#   200:  { status:"SUCCESS",
#           response:{ avail:"yes"|"no", type, price, firstYearPromo:"yes"|"no",
#                      regularPrice, premium:"yes"|"no", minDuration,
#                      additional:{ renewal:{price,regularPrice},
#                                   transfer:{price,regularPrice} } },
#           limits:{ TTL, limit, used, naturalLanguage }, ttlRemaining }
#   4xx:  { status:"ERROR", message, code, next_action:{type,hint,url} }
#   Rate limit: 1 check per 10 seconds per ACCOUNT by default (configurable per
#   key). Hence the conservative default delay of 11s between calls, plus
#   adaptive slow-down driven by the `limits` object the API returns.
#
# See --help for usage. Exit codes are documented there and in EXIT CODES.

set -euo pipefail

# Deterministic numeric parsing/formatting and byte-wise collation. Without
# this, `printf '%.2f' 9.73` mis-parses under a comma-decimal locale.
LC_ALL=C
export LC_ALL

_DQ_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$_DQ_DIR/lib.sh"

DS_QUOTE_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Tunables. Every one is env-overridable; the flags below set the same values.
# ---------------------------------------------------------------------------

# Porkbun API base. Overridable so tests can point at a local stub.
: "${DS_PORKBUN_API_BASE:=https://api.porkbun.com/api/json/v3}"

# Seconds to wait between quote calls. Porkbun's documented default is one
# check per 10 seconds per account, so 11 leaves a margin for clock skew.
: "${DS_QUOTE_DELAY:=11}"

# Attempts per domain when the API rate-limits us or the network fails.
: "${DS_QUOTE_RETRIES:=3}"

# PREMIUM verdict thresholds. A name is premium-priced when the registry says
# so (response.premium == "yes") OR when its quote is at least
# DS_QUOTE_PREMIUM_MULTIPLE times the TLD's standard list price AND at least
# DS_QUOTE_PREMIUM_MIN_DELTA dollars more in absolute terms. The absolute floor
# stops a stale cache or a rounding difference on a $2 TLD from being shouted
# about; every real premium seen in the wild clears it by orders of magnitude.
: "${DS_QUOTE_PREMIUM_MULTIPLE:=1.5}"
: "${DS_QUOTE_PREMIUM_MIN_DELTA:=5}"

# text | tsv | json
: "${DS_QUOTE_FORMAT:=text}"

# auto | always | never  - see --probe in the help text.
: "${DS_QUOTE_PROBE_MODE:=auto}"

# Testing hook: when set to a directory, per-name responses are read from
# "$DS_QUOTE_FIXTURE_DIR/<domain>.json" instead of the network, no credentials
# are required and no delay is applied. Used by tests/; not for production.
: "${DS_QUOTE_FIXTURE_DIR:=}"

_DQ_BODY_FILE=""
_DQ_HEADER_PRINTED=0
_DQ_CALLS=0
_DQ_DELAY_NOTED=0
_DQ_PROBE_STATUS=""
_DQ_PROBE_DETAIL=""
_DQ_N_AVAILABLE=0
_DQ_N_PREMIUM=0
_DQ_N_RESERVED=0
_DQ_N_REGISTERED=0
_DQ_N_UNAVAILABLE=0
_DQ_N_ERROR=0

_dq_cleanup() {
	[ -n "$_DQ_BODY_FILE" ] && rm -f "$_DQ_BODY_FILE"
	return 0
}
trap _dq_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# SECTION 1: help
# ---------------------------------------------------------------------------

_dq_usage() {
	cat <<'EOF'
quote.sh - real per-name domain pricing and premium detection (Porkbun API)

USAGE
  quote.sh [OPTIONS] <domain> [domain...]
  quote.sh [OPTIONS] -f <file>       # one name per line ("-" means stdin)
  sweep.sh names.txt | quote.sh -    # sweep/check output is understood as-is

WHY
  A registry saying "not registered" does NOT mean "you can buy it": the name
  may be registry-RESERVED or PREMIUM-priced. shed.link probed as unregistered
  and quoted $819.27/yr against a $7.72 list price. Only an authenticated
  per-name quote can tell those apart, so this is the only script in the
  toolkit that is allowed to output AVAILABLE.

VERDICTS
  AVAILABLE    quoted, purchasable, priced in line with the TLD's list price
  PREMIUM      quoted and purchasable, but priced far above the list price
               (registry flagged it premium, or quote >= N x list; see -m)
  RESERVED     the registrar returns no sellable offer: unregistered in the
               registry but not for sale, or offered with no price at all
  REGISTERED   already taken (confirmed by an RDAP/whois probe)
  UNAVAILABLE  not sellable, and no probe evidence to say whether that is
               because it is registered or because it is reserved
               (only appears with --probe never, or when a probe errors)
  ERROR        the quote itself failed - rate limit, network, unsupported TLD

OPTIONS
  -f, --file FILE        read names from FILE ("-" = stdin). Repeatable.
  -o, --format FORMAT    text (default, aligned table) | tsv | json (JSONL)
  -d, --delay SECONDS    wait between API calls (default 11; see RATE LIMITS)
  -m, --premium-multiple N
                         quote/list ratio at or above which a name is called
                         PREMIUM (default 1.5)
      --premium-min-delta N
                         absolute USD difference also required before the
                         ratio rule fires (default 5)
      --probe MODE       auto (default) | always | never
                           auto   - quote first; probe only when the quote says
                                    "not sellable", to tell REGISTERED from
                                    RESERVED
                           always - probe first; names that are already
                                    REGISTERED are reported without spending a
                                    rate-limited quote (best for long lists)
                           never  - never probe; unsellable names report
                                    UNAVAILABLE
  -q, --quiet            suppress progress logging (warnings still shown)
  -v, --debug            verbose tracing to stderr
  -h, --help             this text
  -V, --version          print version and exit

INPUT
  Accepts, and auto-detects, every shape the toolkit produces:
    shed.link                            a bare name (one or several per line)
    UNREGISTERED|shed.link|rdap:404      a lib.sh probe line
    UNREGISTERED<TAB>shed.link<TAB>...   sweep.sh rows (status first)
    shed.link<TAB>UNREGISTERED<TAB>...   check.sh --quiet rows (name first)
  A line that mixes a name with other data is treated as a result row: its
  first name and any status word are used and the rest is ignored. Names
  already known to be REGISTERED are reported as such without spending a
  quote, which is the cheapest way to price a large sweep. Blank lines, "#"
  comments and table headers are ignored, names are lowercased, and duplicates
  are dropped (a quote costs about 10 seconds).

  Names given as ARGUMENTS are never silently discarded: a malformed one is
  reported as an ERROR row, because an argument is an explicit instruction.

OUTPUT
  text  aligned table: DOMAIN VERDICT QUOTE-REG QUOTE-REN LIST-REG LIST-REN
        RATIO NOTES. Prices are USD per year; RATIO is quoted renewal over
        list renewal; a run summary is written to stderr.
  tsv   "#"-commented header, then:
        domain, verdict, quoted_reg, quoted_reg_regular, quoted_renew,
        std_reg, std_renew, renewal_ratio, min_years, flags, detail
  json  one JSON object per line (JSONL) - collect with `jq -s .`

NOTES / FLAGS
  API_PREMIUM        the registry itself flags this name as premium
  PRICE_OVER_LIST    quote materially exceeds the TLD's list price
  FIRST_YEAR_PROMO   the registration price shown is a first-year promo; the
                     renewal is what you actually pay every year after
  MIN_DURATION=N     the registry demands an N-year minimum registration
  plus the TLD-level flags from lib.sh: NO_PREMIUM_REGISTRY, SPAM_ASSOCIATED,
  RENEWAL_TRAP, RENEWAL_EXPENSIVE, NO_PRICE_DATA

CREDENTIALS
  Needs a Porkbun API key. Create one at https://porkbun.com/account/api, then:
      export PORKBUN_API_KEY='pk1_...'
      export PORKBUN_SECRET_KEY='sk1_...'
  Keys are read from the environment only: never passed in argv, never written
  to disk, and redacted from all output. The rest of DomainSaver works fine
  without a key - it just stops at UNREGISTERED instead of AVAILABLE.

RATE LIMITS
  Porkbun allows one domain check per 10 seconds per account by default, so a
  100-name list takes about 18 minutes. The script waits DS_QUOTE_DELAY (11s)
  between calls, reads the `limits` object the API returns and slows itself
  down further if the account's limit is tighter, and on a 429 waits for the
  `ttlRemaining` the API reports before retrying. Please do not lower --delay
  below the limit your key actually has: you will simply be throttled.

ENVIRONMENT
  PORKBUN_API_KEY, PORKBUN_SECRET_KEY   credentials (required)
  DS_QUOTE_DELAY, DS_QUOTE_RETRIES, DS_QUOTE_FORMAT, DS_QUOTE_PROBE_MODE,
  DS_QUOTE_PREMIUM_MULTIPLE, DS_QUOTE_PREMIUM_MIN_DELTA,
  DS_PORKBUN_API_BASE                   same knobs as the flags
  DS_HTTP_TIMEOUT, DS_CONNECT_TIMEOUT   curl timeouts (from lib.sh)
  DS_QUIET, DS_DEBUG                    logging (from lib.sh)
  DS_QUOTE_FIXTURE_DIR                  testing hook: read responses from
                                        <dir>/<domain>.json instead of the API
  DS_QUOTE_NO_MAIN                      testing hook: when set, sourcing this
                                        script defines its functions and runs
                                        nothing

EXIT CODES
  0  every name got a definitive verdict
  1  at least one name ended in ERROR
  2  usage error
  3  no credentials configured (see CREDENTIALS)
  4  aborted: the API rejected our credentials or the request outright

EXAMPLES
  quote.sh shed.link bar.link
  quote.sh -o json -f candidates.txt | jq -s 'map(select(.verdict=="AVAILABLE"))'
  sweep.sh names.txt | grep '^UNREGISTERED' | quote.sh --probe never -
  check.sh -q shed.link | quote.sh -o json -
EOF
}

# _dq_no_creds_help
#   Friendly, actionable "you have no API key" guidance. Called after
#   ds_porkbun_creds_ok has already explained the consequence, so this covers
#   only the fix.
_dq_no_creds_help() {
	cat >&2 <<EOF

quote.sh needs an authenticated Porkbun API key, because only a real per-name
quote can separate "unregistered" from "actually purchasable at a sane price".

To enable per-name quotes:

  1. Sign in at https://porkbun.com/account/api and create an API key.
     You get two values: a public key ("pk1_...") and a secret ("sk1_...").
     Tip: create a dedicated key rather than reusing a master key, and use the
     gear icon to restrict it to your source IP.

  2. Export both in your shell (note the field name is the SECRET key):

       export PORKBUN_API_KEY='pk1_your_key_here'
       export PORKBUN_SECRET_KEY='sk1_your_secret_here'

     Put them in a git-ignored .env or your shell profile - never in the repo.

  3. Re-run:  $0 example.com

Everything else in DomainSaver works without a key: probing, the per-TLD list
prices and the reputation/renewal-trap flags are all unauthenticated. Without a
key the toolkit deliberately stops at UNREGISTERED and never says AVAILABLE,
because an unregistered name may still be registry-reserved or premium-priced.
EOF
}

# ---------------------------------------------------------------------------
# SECTION 2: credential handling (argv-free, redacted)
# ---------------------------------------------------------------------------

# _dq_redact
#   Filter: copies STDIN to STDOUT with any literal occurrence of either
#   credential replaced by "***REDACTED***". The keys are handed to awk through
#   the ENVIRONMENT (where they already live), never through argv, so this adds
#   no new exposure. Short values are ignored so a truncated key cannot cause
#   every character of the output to be scrubbed.
_dq_redact() {
	awk '
		function scrub(s, needle,   out, p) {
			if (length(needle) < 8) return s
			out = ""
			while ((p = index(s, needle)) > 0) {
				out = out substr(s, 1, p - 1) "***REDACTED***"
				s = substr(s, p + length(needle))
			}
			return out s
		}
		{
			line = scrub($0, ENVIRON["PORKBUN_API_KEY"])
			line = scrub(line, ENVIRON["PORKBUN_SECRET_KEY"])
			print line
		}
	'
}

# _dq_json_escape <value>
#   Minimal JSON string escaping for a credential. Runs the value through sed
#   on STDIN, so it never appears in any external process's argv.
_dq_json_escape() {
	printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _dq_auth_body
#   Stdout: the JSON auth body. printf is a shell builtin and the escaping runs
#   through sed's STDIN, so no credential is ever visible in the process table.
_dq_auth_body() {
	printf '{"apikey":"%s","secretapikey":"%s"}' \
		"$(_dq_json_escape "${PORKBUN_API_KEY:-}")" \
		"$(_dq_json_escape "${PORKBUN_SECRET_KEY:-}")"
}

# _dq_check_creds
#   Verifies credentials are present and sane. Exits 3 with guidance if not.
_dq_check_creds() {
	[ -n "$DS_QUOTE_FIXTURE_DIR" ] && return 0
	if ! ds_porkbun_creds_ok; then
		_dq_no_creds_help
		exit 3
	fi
	# A newline in a credential would corrupt the JSON body and, worse, could
	# smuggle a header into a log line. Refuse rather than guess.
	case "$PORKBUN_API_KEY$PORKBUN_SECRET_KEY" in
	*[[:cntrl:]]*)
		ds_die "PORKBUN_API_KEY / PORKBUN_SECRET_KEY contain control characters (bad copy-paste?)"
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 3: formatting helpers
# ---------------------------------------------------------------------------

# _dq_is_number <value>
#   Exit 0 if the value is a plain, non-negative decimal number. Deliberately
#   strict: "$9.73", "9.7.3" and "" must all fail, because they would make
#   printf %.2f complain and would poison the premium arithmetic.
_dq_is_number() {
	printf '%s' "${1:-}" | grep -qE '^[0-9]+(\.[0-9]+)?$|^\.[0-9]+$'
}

# _dq_money <value>
#   Stdout: the value formatted as "1234.56", or "-" when it is missing or not
#   a plain decimal number. Never adds a currency symbol: everything here is
#   USD per year and the header says so once.
_dq_money() {
	if _dq_is_number "${1:-}"; then
		printf '%.2f' "$1"
	else
		printf '%s' '-'
	fi
}

# ---------------------------------------------------------------------------
# SECTION 4: the API call
# ---------------------------------------------------------------------------

# _dq_sleep_between
#   Applies the inter-call delay, but only between calls - never before the
#   first one and never after the last.
_dq_sleep_between() {
	[ -n "$DS_QUOTE_FIXTURE_DIR" ] && return 0
	[ "$_DQ_CALLS" -eq 0 ] && return 0
	case "$DS_QUOTE_DELAY" in
	0 | 0.0) return 0 ;;
	esac
	ds_debug "rate limit: sleeping ${DS_QUOTE_DELAY}s before the next quote"
	sleep "$DS_QUOTE_DELAY"
	return 0
}

# _dq_adapt_delay <ttl> <limit>
#   The API tells us the account's real allowance in every successful response.
#   If it is tighter than our configured delay, raise the delay. We never lower
#   it automatically: being slower than necessary costs time, being faster than
#   allowed costs a ban.
_dq_adapt_delay() {
	_dqa_ttl="${1:-}"
	_dqa_lim="${2:-}"
	_dq_is_number "$_dqa_ttl" || return 0
	_dq_is_number "$_dqa_lim" || return 0
	_dqa_want=$(awk -v t="$_dqa_ttl" -v l="$_dqa_lim" -v cur="$DS_QUOTE_DELAY" 'BEGIN {
		if (l + 0 <= 0 || t + 0 <= 0) { print ""; exit }
		want = (t + 0) / (l + 0) + 1
		if (want > cur + 0) printf "%.0f", want
	}')
	[ -n "$_dqa_want" ] || return 0
	if [ "$_DQ_DELAY_NOTED" = "0" ]; then
		_DQ_DELAY_NOTED=1
		ds_warn "Porkbun reports $_dqa_lim check(s) per ${_dqa_ttl}s for this key;"
		ds_warn "  raising the inter-call delay from ${DS_QUOTE_DELAY}s to ${_dqa_want}s"
	fi
	DS_QUOTE_DELAY="$_dqa_want"
	return 0
}

# _dq_api_check <domain> <body_file>
#   POSTs one checkDomain request, writing the response body to <body_file>.
#   Stdout: the HTTP status code ("000" when curl itself failed).
#   Exit:   always 0 - transport failures are reported through the code.
_dq_api_check() {
	_dqc_dom="$1"
	_dqc_out="$2"

	# Testing hook: serve a canned response instead of calling the API.
	if [ -n "$DS_QUOTE_FIXTURE_DIR" ]; then
		if [ -s "$DS_QUOTE_FIXTURE_DIR/$_dqc_dom.json" ]; then
			cat "$DS_QUOTE_FIXTURE_DIR/$_dqc_dom.json" >"$_dqc_out"
			printf '200\n'
		else
			: >"$_dqc_out"
			printf '404\n'
		fi
		return 0
	fi

	# The body goes in on STDIN. It must never be an argument: argv is world
	# readable through `ps`.
	_dqc_code=$(_dq_auth_body | curl -sS \
		-X POST \
		-A "$DS_USER_AGENT" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json' \
		--data-binary @- \
		--connect-timeout "$DS_CONNECT_TIMEOUT" \
		--max-time "$DS_HTTP_TIMEOUT" \
		-o "$_dqc_out" -w '%{http_code}' \
		"${DS_PORKBUN_API_BASE%/}/domain/checkDomain/$_dqc_dom" 2>/dev/null) || _dqc_code="000"
	[ -n "$_dqc_code" ] || _dqc_code="000"
	printf '%s\n' "$_dqc_code"
	unset _dqc_dom _dqc_out _dqc_code
	return 0
}

# _dq_parse_body <body_file>
#   Stdout: one '|'-separated line of the fields we care about, in this order:
#     1 status  2 avail  3 premium  4 price  5 regularPrice  6 firstYearPromo
#     7 renewal.price  8 renewal.regularPrice  9 transfer.price  10 minDuration
#     11 message  12 code  13 limits.TTL  14 limits.limit  15 ttlRemaining
#     16 next_action.hint  17 next_action.url
#   Exit: 1 if the body is missing or is not JSON.
#
#   WHY '|' AND NOT TAB: tab, space and newline are "IFS whitespace", and the
#   shell collapses runs of them, so `IFS=<tab> read a b c` silently merges
#   empty fields and shifts every value after the first missing one. A
#   non-whitespace separator preserves empty fields exactly. Values are
#   stripped of '|' (and of any embedded newline/tab) first, which is the same
#   contract lib.sh's probe output uses.
_dq_parse_body() {
	[ -s "$1" ] || return 1
	jq -r '
		def s: if . == null then "" else (tostring | gsub("[|\r\n\t]"; " ")) end;
		[ (.status | s),
		  (.response.avail | s),
		  (.response.premium | s),
		  (.response.price | s),
		  (.response.regularPrice | s),
		  (.response.firstYearPromo | s),
		  (.response.additional.renewal.price | s),
		  (.response.additional.renewal.regularPrice | s),
		  (.response.additional.transfer.price | s),
		  (.response.minDuration | s),
		  (.message | s),
		  (.code | s),
		  (.limits.TTL | s),
		  (.limits.limit | s),
		  (.ttlRemaining | s),
		  (.next_action.hint | s),
		  (.next_action.url | s)
		] | join("|")
	' "$1" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# SECTION 5: the premium rule
# ---------------------------------------------------------------------------

# _dq_verdict <avail> <api_premium> <quoted_reg> <quoted_renew> <std_reg> <std_renew>
#   Applies the documented premium rule and returns one '|'-separated line:
#     verdict|ratio|notes   (ratio empty when no baseline price is known,
#     notes a space-separated token list, possibly empty)
#
#   THE RULE, stated once:
#     A quoted name is PREMIUM when the registry flags it premium, OR when
#     either its registration or its renewal quote is at least
#     DS_QUOTE_PREMIUM_MULTIPLE times the TLD's standard list price AND at
#     least DS_QUOTE_PREMIUM_MIN_DELTA dollars more in absolute terms.
#
#   Renewal is the headline ratio because renewal is what you pay every year:
#   first-year promotions only ever push the registration ratio DOWN, so a high
#   registration ratio is still a genuine premium signal, never a promo
#   artifact - which is why either side of the comparison can trip the rule.
_dq_verdict() {
	awk -v avail="${1:-}" -v prem="${2:-}" \
		-v qreg="${3:-}" -v qren="${4:-}" \
		-v sreg="${5:-}" -v sren="${6:-}" \
		-v mult="$DS_QUOTE_PREMIUM_MULTIPLE" -v mind="$DS_QUOTE_PREMIUM_MIN_DELTA" '
	function isnum(v) { return (v != "" && v + 0 == v) }
	BEGIN {
		notes = ""; ratio = ""; over = 0

		if (isnum(qren) && isnum(sren) && sren + 0 > 0 && qren + 0 > 0) {
			ratio = (qren + 0) / (sren + 0)
			if (ratio >= mult + 0 && (qren + 0) - (sren + 0) >= mind + 0) over = 1
		}
		if (isnum(qreg) && isnum(sreg) && sreg + 0 > 0 && qreg + 0 > 0) {
			r2 = (qreg + 0) / (sreg + 0)
			if (ratio == "") ratio = r2
			if (r2 >= mult + 0 && (qreg + 0) - (sreg + 0) >= mind + 0) over = 1
		}
		if (over) notes = notes " PRICE_OVER_LIST"
		if (prem == "yes") notes = notes " API_PREMIUM"

		priced = ((isnum(qreg) && qreg + 0 > 0) || (isnum(qren) && qren + 0 > 0))

		if (avail == "yes") {
			if (!priced) {
				# Offered but with no price: the registrar has nothing to
				# sell us. Treat exactly like a registry reservation.
				verdict = "RESERVED"
				notes = notes " NO_PRICE_OFFERED"
			} else if (prem == "yes" || over) {
				verdict = "PREMIUM"
			} else {
				verdict = "AVAILABLE"
			}
		} else if (avail == "no") {
			# Not sellable. Whether that is "registered" or "reserved" is
			# decided by the caller, from a registry probe.
			verdict = "UNAVAILABLE"
		} else {
			verdict = "ERROR"
		}

		sub(/^ /, "", notes)
		# Pipe separated, never tab: see the note in _dq_parse_body about the
		# shell collapsing runs of IFS whitespace and eating empty fields.
		if (ratio == "") printf "%s||%s\n", verdict, notes
		else             printf "%s|%.4f|%s\n", verdict, ratio, notes
	}'
}

# ---------------------------------------------------------------------------
# SECTION 6: output
# ---------------------------------------------------------------------------

# _dq_emit <domain> <verdict> <qreg> <qreg_regular> <qren> <sreg> <sren>
#          <ratio> <min_years> <flags> <detail>
#   Writes one result row in the selected format. All output is redacted.
_dq_emit() {
	_dqe_dom="$1"
	_dqe_verdict="$2"
	_dqe_qreg="$3"
	_dqe_qregreg="$4"
	_dqe_qren="$5"
	_dqe_sreg="$6"
	_dqe_sren="$7"
	_dqe_ratio="$8"
	_dqe_minyr="$9"
	shift 9
	_dqe_flags="$1"
	_dqe_detail="$(_ds_sanitize_detail "${2:-}")"

	# Porkbun still returns the TLD's list prices for a name it will not sell.
	# Reporting those as "the quote" would imply you could buy example.com for
	# $11.06, so only a purchasable verdict carries quoted prices.
	case "$_dqe_verdict" in
	AVAILABLE | PREMIUM) ;;
	*)
		_dqe_qreg=""
		_dqe_qregreg=""
		_dqe_qren=""
		_dqe_ratio=""
		;;
	esac

	case "$_dqe_verdict" in
	AVAILABLE) _DQ_N_AVAILABLE=$((_DQ_N_AVAILABLE + 1)) ;;
	PREMIUM) _DQ_N_PREMIUM=$((_DQ_N_PREMIUM + 1)) ;;
	RESERVED) _DQ_N_RESERVED=$((_DQ_N_RESERVED + 1)) ;;
	REGISTERED) _DQ_N_REGISTERED=$((_DQ_N_REGISTERED + 1)) ;;
	UNAVAILABLE) _DQ_N_UNAVAILABLE=$((_DQ_N_UNAVAILABLE + 1)) ;;
	*) _DQ_N_ERROR=$((_DQ_N_ERROR + 1)) ;;
	esac

	case "$DS_QUOTE_FORMAT" in
	json)
		jq -c -n \
			--arg domain "$_dqe_dom" \
			--arg verdict "$_dqe_verdict" \
			--arg qreg "$_dqe_qreg" \
			--arg qregreg "$_dqe_qregreg" \
			--arg qren "$_dqe_qren" \
			--arg sreg "$_dqe_sreg" \
			--arg sren "$_dqe_sren" \
			--arg ratio "$_dqe_ratio" \
			--arg minyr "$_dqe_minyr" \
			--arg flags "$_dqe_flags" \
			--arg detail "$_dqe_detail" '
			def num: if . == null or . == "" then null else (tonumber? // null) end;
			{
				domain: $domain,
				verdict: $verdict,
				quoted_registration: ($qreg | num),
				quoted_registration_regular: ($qregreg | num),
				quoted_renewal: ($qren | num),
				standard_registration: ($sreg | num),
				standard_renewal: ($sren | num),
				renewal_ratio: ($ratio | num),
				min_duration_years: ($minyr | num),
				flags: ($flags | split(" ") | map(select(length > 0))),
				detail: $detail,
				source: "porkbun"
			}' | _dq_redact
		;;
	tsv)
		if [ "$_DQ_HEADER_PRINTED" = "0" ]; then
			_DQ_HEADER_PRINTED=1
			printf '# domain\tverdict\tquoted_reg\tquoted_reg_regular\tquoted_renew\tstd_reg\tstd_renew\trenewal_ratio\tmin_years\tflags\tdetail\n'
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_dqe_dom" "$_dqe_verdict" \
			"$(_dq_money "$_dqe_qreg")" "$(_dq_money "$_dqe_qregreg")" \
			"$(_dq_money "$_dqe_qren")" \
			"$(_dq_money "$_dqe_sreg")" "$(_dq_money "$_dqe_sren")" \
			"${_dqe_ratio:--}" "${_dqe_minyr:--}" \
			"$_dqe_flags" "$_dqe_detail" | _dq_redact
		;;
	*)
		if [ "$_DQ_HEADER_PRINTED" = "0" ]; then
			_DQ_HEADER_PRINTED=1
			printf '%s\n' '# prices are USD per year; RATIO = quoted renewal / list renewal'
			printf '%-28s %-11s %10s %10s %9s %9s %7s  %s\n' \
				DOMAIN VERDICT QUOTE-REG QUOTE-REN LIST-REG LIST-REN RATIO NOTES
		fi
		_dqe_ratio_disp="-"
		if _dq_is_number "$_dqe_ratio"; then
			_dqe_ratio_disp=$(awk -v r="$_dqe_ratio" 'BEGIN { printf "%.1fx", r }')
		fi
		_dqe_note="$_dqe_flags"
		[ -n "$_dqe_detail" ] && _dqe_note="${_dqe_note:+$_dqe_note }($_dqe_detail)"
		printf '%-28s %-11s %10s %10s %9s %9s %7s  %s\n' \
			"$_dqe_dom" "$_dqe_verdict" \
			"$(_dq_money "$_dqe_qreg")" "$(_dq_money "$_dqe_qren")" \
			"$(_dq_money "$_dqe_sreg")" "$(_dq_money "$_dqe_sren")" \
			"$_dqe_ratio_disp" "$_dqe_note" | _dq_redact
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: quoting one name
# ---------------------------------------------------------------------------

# _dq_std_prices <domain> <registry_tld>
#   Stdout: "<std_reg><TAB><std_renew>", empty fields when unknown.
#   Registrars can price a two-label suffix such as co.uk independently from its
#   registry TLD. Prefer that exact price row, then fall back to the final label.
_dq_std_prices() {
	_dqs_domain="$1"
	_dqs_tld="$2"
	_dqs_suffix=$(printf '%s\n' "$_dqs_domain" | awk -F. '
		NF >= 3 { print $(NF - 1) "." $NF }
	')

	if [ -n "$_dqs_suffix" ] && _dqs_row=$(ds_std_price "$_dqs_suffix" 2>/dev/null); then
		printf '%s\n' "$_dqs_row"
	elif _dqs_row=$(ds_std_price "$_dqs_tld" 2>/dev/null); then
		printf '%s\n' "$_dqs_row"
	else
		printf '\t\n'
	fi
	unset _dqs_domain _dqs_tld _dqs_suffix _dqs_row 2>/dev/null || true
	return 0
}

# _dq_fatal_code <code>
#   Exit 0 when an API error code means "every subsequent call will fail too",
#   so the run should abort instead of burning a rate-limited call per name.
_dq_fatal_code() {
	case "${1:-}" in
	INVALID_API_KEYS_001 | INVALID_API_KEYS_002 | MISSING_SECRETAPIKEY | \
		API_KEY_REQUIRED | INVALID_TOKEN | INVALID_USER | IP_NOT_ALLOWED | \
		INVALID_PROTOCOL | METHOD_NOT_ALLOWED | INVALID_OR_EMPTY_JSON)
		return 0
		;;
	esac
	return 1
}

# _dq_abort <message> <hint> <url>
#   Reports an unrecoverable API rejection and exits 4.
_dq_abort() {
	printf '\n' >&2
	printf '[ds] FATAL: Porkbun rejected the request: %s\n' "${1:-unknown error}" | _dq_redact >&2
	[ -n "${2:-}" ] && printf '[ds]        %s\n' "$2" | _dq_redact >&2
	[ -n "${3:-}" ] && printf '[ds]        see: %s\n' "$3" >&2
	printf '[ds]        aborting before spending more rate-limited calls.\n' >&2
	exit 4
}

# _dq_probe <domain>
#   Runs lib.sh's registry probe and stores the result in _DQ_PROBE_STATUS
#   (UNREGISTERED | REGISTERED | ERROR) and _DQ_PROBE_DETAIL. Results go into
#   globals rather than stdout because a `$(...)` call site would run this in a
#   subshell, where the second return value would be lost.
_dq_probe() {
	_DQ_PROBE_STATUS="ERROR"
	_DQ_PROBE_DETAIL=""
	_dqp_res=$(ds_probe "$1") || true
	if [ -n "$_dqp_res" ]; then
		_DQ_PROBE_STATUS="${_dqp_res%%|*}"
		_DQ_PROBE_DETAIL="${_dqp_res##*|}"
	fi
	unset _dqp_res
	return 0
}

# _dq_quote_one <domain> <pre_status>
#   Quotes one name end to end and emits exactly one result row.
#   <pre_status> is the probe status already known for this name (from piped
#   probe output), or "" when unknown.
#   Exit: 0 if the row is a definitive verdict, 1 if it is an ERROR row.
_dq_quote_one() {
	_dqq_dom="$1"
	_dqq_pre="${2:-}"
	_dqq_tld=$(ds_tld "$_dqq_dom") || _dqq_tld=""
	_dqq_flags=""
	[ -n "$_dqq_tld" ] && _dqq_flags=$(ds_tld_flags "$_dqq_tld")

	_dqq_std=$(_dq_std_prices "$_dqq_dom" "$_dqq_tld")
	_dqq_sreg=$(printf '%s' "$_dqq_std" | cut -f1)
	_dqq_sren=$(printf '%s' "$_dqq_std" | cut -f2)

	# 1. Cheap outs that save a rate-limited call.
	if [ "$_dqq_pre" = "REGISTERED" ]; then
		_dq_emit "$_dqq_dom" REGISTERED "" "" "" "$_dqq_sreg" "$_dqq_sren" "" "" \
			"$_dqq_flags" "already REGISTERED per input; no quote spent"
		return 0
	fi
	if [ "$DS_QUOTE_PROBE_MODE" = "always" ] && [ -z "$_dqq_pre" ]; then
		_dq_probe "$_dqq_dom"
		_dqq_pre="$_DQ_PROBE_STATUS"
		if [ "$_dqq_pre" = "REGISTERED" ]; then
			_dq_emit "$_dqq_dom" REGISTERED "" "" "" "$_dqq_sreg" "$_dqq_sren" "" "" \
				"$_dqq_flags" "$_DQ_PROBE_DETAIL; no quote spent"
			return 0
		fi
	fi

	# 2. The quote, with retries for rate limits and transport failures.
	_dqq_attempt=1
	_dqq_status=""
	_dqq_fields=""
	while :; do
		_dq_sleep_between
		_DQ_CALLS=$((_DQ_CALLS + 1))
		ds_debug "quote $_dqq_dom: attempt $_dqq_attempt"
		_dqq_code=$(_dq_api_check "$_dqq_dom" "$_DQ_BODY_FILE")

		if ! _dqq_fields=$(_dq_parse_body "$_DQ_BODY_FILE"); then
			_dqq_fields=""
		fi

		# Field order matches _dq_parse_body.
		_dqq_status=""
		_dqq_avail=""
		_dqq_prem=""
		_dqq_price=""
		_dqq_regprice=""
		_dqq_promo=""
		_dqq_ren=""
		_dqq_renreg=""
		_dqq_xfer=""
		_dqq_mindur=""
		_dqq_msg=""
		_dqq_ecode=""
		_dqq_ttl=""
		_dqq_limit=""
		_dqq_ttlrem=""
		_dqq_hint=""
		_dqq_url=""
		if [ -n "$_dqq_fields" ]; then
			IFS='|' read -r _dqq_status _dqq_avail _dqq_prem \
				_dqq_price _dqq_regprice _dqq_promo _dqq_ren _dqq_renreg \
				_dqq_xfer _dqq_mindur _dqq_msg _dqq_ecode _dqq_ttl \
				_dqq_limit _dqq_ttlrem _dqq_hint _dqq_url <<<"$_dqq_fields"
		fi

		# Abort the whole run on errors that will repeat for every name.
		if [ "$_dqq_status" = "ERROR" ] && _dq_fatal_code "$_dqq_ecode"; then
			_dq_abort "$_dqq_msg" "$_dqq_hint" "$_dqq_url"
		fi

		# Rate limited? Honour the reset the API tells us about.
		_dqq_limited=0
		[ "$_dqq_code" = "429" ] && _dqq_limited=1
		[ "$_dqq_ecode" = "RATE_LIMIT_EXCEEDED" ] && _dqq_limited=1
		if [ "$_dqq_limited" = "1" ]; then
			if [ "$_dqq_attempt" -ge "$DS_QUOTE_RETRIES" ]; then
				_dq_emit "$_dqq_dom" ERROR "" "" "" "$_dqq_sreg" "$_dqq_sren" "" "" \
					"$_dqq_flags" "rate-limited, gave up after $DS_QUOTE_RETRIES attempts"
				return 1
			fi
			_dqq_wait="$DS_QUOTE_DELAY"
			if _dq_is_number "$_dqq_ttlrem"; then
				_dqq_wait=$(awk -v t="$_dqq_ttlrem" 'BEGIN { w = t + 1; if (w > 120) w = 120; printf "%.0f", w }')
			fi
			ds_log "rate limited on $_dqq_dom; waiting ${_dqq_wait}s"
			sleep "$_dqq_wait"
			_dqq_attempt=$((_dqq_attempt + 1))
			continue
		fi

		# Transport or server failure: back off and retry.
		case "$_dqq_code" in
		000 | 500 | 502 | 503 | 504)
			if [ "$_dqq_attempt" -ge "$DS_QUOTE_RETRIES" ]; then
				_dq_emit "$_dqq_dom" ERROR "" "" "" "$_dqq_sreg" "$_dqq_sren" "" "" \
					"$_dqq_flags" "HTTP $_dqq_code after $DS_QUOTE_RETRIES attempts"
				return 1
			fi
			_dqq_wait=$((5 * _dqq_attempt))
			ds_debug "quote $_dqq_dom: HTTP $_dqq_code, retrying in ${_dqq_wait}s"
			sleep "$_dqq_wait"
			_dqq_attempt=$((_dqq_attempt + 1))
			continue
			;;
		esac
		break
	done

	_dq_adapt_delay "$_dqq_ttl" "$_dqq_limit"

	# 3. Non-fatal API error for this one name (bad TLD, unsupported name...).
	if [ "$_dqq_status" != "SUCCESS" ]; then
		_dqq_detail="HTTP $_dqq_code"
		[ -n "$_dqq_ecode" ] && _dqq_detail="$_dqq_detail $_dqq_ecode"
		[ -n "$_dqq_msg" ] && _dqq_detail="$_dqq_detail: $_dqq_msg"
		[ -z "$_dqq_fields" ] && _dqq_detail="$_dqq_detail (unparseable response)"
		case " $_dqq_flags " in
		*" NO_PRICE_DATA "*)
			_dqq_detail="$_dqq_detail - .$_dqq_tld is not in Porkbun's price list, it may not be sold there"
			;;
		esac
		_dq_emit "$_dqq_dom" ERROR "" "" "" "$_dqq_sreg" "$_dqq_sren" "" "" \
			"$_dqq_flags" "$_dqq_detail"
		return 1
	fi

	# 4. Apply the premium rule.
	_dqq_v=$(_dq_verdict "$_dqq_avail" "$_dqq_prem" "$_dqq_price" "$_dqq_ren" \
		"$_dqq_sreg" "$_dqq_sren")
	_dqq_verdict=""
	_dqq_ratio=""
	_dqq_notes=""
	IFS='|' read -r _dqq_verdict _dqq_ratio _dqq_notes <<<"$_dqq_v"

	_dqq_detail=""
	# A SUCCESS body that carries no availability field is a contract change on
	# Porkbun's side, not an answer. Say so rather than inventing a verdict.
	if [ "$_dqq_verdict" = "ERROR" ]; then
		_dq_emit "$_dqq_dom" ERROR "" "" "" "$_dqq_sreg" "$_dqq_sren" "" "" \
			"$_dqq_flags" "HTTP $_dqq_code SUCCESS body with no usable availability field"
		return 1
	fi

	# 5. "Not sellable" needs a registry probe to say WHY.
	if [ "$_dqq_verdict" = "UNAVAILABLE" ]; then
		if [ -z "$_dqq_pre" ] && [ "$DS_QUOTE_PROBE_MODE" = "auto" ]; then
			_dq_probe "$_dqq_dom"
			_dqq_pre="$_DQ_PROBE_STATUS"
			_dqq_detail="$_DQ_PROBE_DETAIL"
		fi
		case "$_dqq_pre" in
		REGISTERED)
			_dqq_verdict="REGISTERED"
			;;
		UNREGISTERED)
			# Absent from the registry yet the registrar will not sell it:
			# that is the definition of a registry reservation.
			_dqq_verdict="RESERVED"
			_dqq_detail="${_dqq_detail:+$_dqq_detail; }unregistered but not for sale"
			;;
		*)
			_dqq_detail="${_dqq_detail:+$_dqq_detail; }registrar will not sell it; probe inconclusive"
			;;
		esac
	fi

	[ "$_dqq_promo" = "yes" ] && _dqq_notes="${_dqq_notes:+$_dqq_notes }FIRST_YEAR_PROMO"
	if _dq_is_number "$_dqq_mindur" && [ "${_dqq_mindur%.*}" -gt 1 ] 2>/dev/null; then
		_dqq_notes="${_dqq_notes:+$_dqq_notes }MIN_DURATION=${_dqq_mindur%.*}"
	fi
	_dqq_allflags="$_dqq_notes"
	if [ -n "$_dqq_flags" ]; then
		_dqq_allflags="${_dqq_allflags:+$_dqq_allflags }$_dqq_flags"
	fi
	ds_debug "quote $_dqq_dom: transfer=${_dqq_xfer:--} renewal_regular=${_dqq_renreg:--}"

	_dq_emit "$_dqq_dom" "$_dqq_verdict" "$_dqq_price" "$_dqq_regprice" "$_dqq_ren" \
		"$_dqq_sreg" "$_dqq_sren" "$_dqq_ratio" "${_dqq_mindur%.*}" \
		"$_dqq_allflags" "$_dqq_detail"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 8: input handling
# ---------------------------------------------------------------------------

# _dq_normalize_input
#   Filter: reads candidate lines on STDIN, writes "<domain>|<prestatus>".
#   Understands every shape the rest of the toolkit emits, so any of them can
#   be piped straight in:
#     shed.link                                  a bare name
#     shed.link bar.link                         several names on one line
#     UNREGISTERED|shed.link|rdap:404            lib.sh / sweep.sh probe output
#     shed.link<TAB>UNREGISTERED<TAB>7.72<TAB>.. check.sh --quiet rows
#   A line that mixes names with other data (prices, flags, a detail string) is
#   treated as a result row: only its first name is taken, along with any
#   status word it carries. Comments, blanks, table headers and duplicates are
#   dropped and everything is lowercased.
_dq_normalize_input() {
	awk '
		function is_status(u) {
			return (u == "UNREGISTERED" || u == "REGISTERED" || u == "ERROR" ||
			        u == "AVAILABLE" || u == "PREMIUM" || u == "RESERVED" ||
			        u == "UNAVAILABLE")
		}
		# A name needs a dot and an alphabetic last label, so that a price like
		# "7.72" in a result row is never mistaken for a domain.
		function is_name(t) {
			return (t ~ /^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z][A-Za-z0-9-]*$/)
		}
		function emit(dom, status) {
			dom = tolower(dom)
			sub(/\.$/, "", dom)
			if (dom == "" || seen[dom]++) return
			printf "%s|%s\n", dom, status
		}
		{ sub(/\r$/, "") }
		/^[ \t]*#/ { next }
		/^[ \t]*$/ { next }
		{
			# Probe format first: STATUS|domain|detail.
			if (index($0, "|") > 0) {
				n = split($0, f, /\|/)
				if (n >= 2) {
					s = f[1]; d = f[2]
					gsub(/[ \t]/, "", s); gsub(/[ \t]/, "", d)
					emit(d, toupper(s))
					next
				}
			}

			n = split($0, tok, /[ \t,]+/)
			status = ""; ndom = 0; nother = 0
			for (i = 1; i <= n; i++) {
				t = tok[i]
				sub(/\.$/, "", t)
				if (t == "") continue
				u = toupper(t)
				if (is_status(u)) { if (status == "") status = u; continue }
				if (is_name(t)) { doms[++ndom] = t; continue }
				nother++
			}
			if (ndom == 0) next
			# Nothing but names (and maybe a status): take them all. Otherwise
			# this is a result row, so only its first name is a candidate.
			if (nother == 0) {
				for (i = 1; i <= ndom; i++) emit(doms[i], status)
			} else {
				emit(doms[1], status)
			}
		}
	'
}

# _dq_normalize_args
#   Filter for names given as command-line ARGUMENTS: lowercase, strip a
#   trailing dot, drop blanks and duplicates - but never drop anything that
#   merely looks wrong. An argument is an explicit instruction, so a typo must
#   surface as a loud ERROR row, not vanish the way a junk line in a piped
#   result table should.
_dq_normalize_args() {
	awk '
		{ sub(/\r$/, ""); gsub(/^[ \t]+/, ""); gsub(/[ \t]+$/, "") }
		$0 == "" { next }
		{
			d = tolower($0)
			sub(/\.$/, "", d)
			if (d == "" || seen[d]++) next
			printf "%s|\n", d
		}
	'
}

# _dq_valid_domain <domain>
#   Exit 0 for a syntactically plausible registrable name. Deliberately strict:
#   a malformed name would waste a rate-limited call.
_dq_valid_domain() {
	case "${1:-}" in
	*.*) ;;
	*) return 1 ;;
	esac
	[ "${#1}" -le 253 ] || return 1
	printf '%s' "$1" |
		grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
}

# ---------------------------------------------------------------------------
# SECTION 9: main
# ---------------------------------------------------------------------------

main() {
	_dqm_files=""
	_dqm_args=""
	_dqm_rc=0

	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help)
			_dq_usage
			return 0
			;;
		-V | --version)
			printf 'quote.sh %s (lib.sh %s)\n' "$DS_QUOTE_VERSION" "$DS_LIB_VERSION"
			return 0
			;;
		-f | --file)
			[ $# -ge 2 ] || {
				ds_warn "$1 needs a FILE argument"
				return 2
			}
			_dqm_files="$_dqm_files
$2"
			shift 2
			;;
		-o | --format)
			[ $# -ge 2 ] || {
				ds_warn "$1 needs a FORMAT argument"
				return 2
			}
			DS_QUOTE_FORMAT=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
			shift 2
			;;
		-d | --delay)
			[ $# -ge 2 ] || {
				ds_warn "$1 needs a SECONDS argument"
				return 2
			}
			DS_QUOTE_DELAY="$2"
			shift 2
			;;
		-m | --premium-multiple)
			[ $# -ge 2 ] || {
				ds_warn "$1 needs a NUMBER argument"
				return 2
			}
			DS_QUOTE_PREMIUM_MULTIPLE="$2"
			shift 2
			;;
		--premium-min-delta)
			[ $# -ge 2 ] || {
				ds_warn "$1 needs a NUMBER argument"
				return 2
			}
			DS_QUOTE_PREMIUM_MIN_DELTA="$2"
			shift 2
			;;
		--probe)
			[ $# -ge 2 ] || {
				ds_warn "--probe needs a MODE argument (auto|always|never)"
				return 2
			}
			DS_QUOTE_PROBE_MODE=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
			shift 2
			;;
		-q | --quiet)
			# shellcheck disable=SC2034  # read by lib.sh's ds_log
			DS_QUIET=1
			shift
			;;
		-v | --debug)
			# shellcheck disable=SC2034  # read by lib.sh's ds_debug
			DS_DEBUG=1
			shift
			;;
		-)
			_dqm_files="$_dqm_files
-"
			shift
			;;
		--)
			shift
			while [ $# -gt 0 ]; do
				_dqm_args="$_dqm_args
$1"
				shift
			done
			;;
		-*)
			ds_warn "unknown option: $1"
			ds_warn "try: $0 --help"
			return 2
			;;
		*)
			_dqm_args="$_dqm_args
$1"
			shift
			;;
		esac
	done

	# --- validate settings ---------------------------------------------------
	case "$DS_QUOTE_FORMAT" in
	text | tsv | json) ;;
	*)
		ds_warn "unknown --format '$DS_QUOTE_FORMAT' (want: text, tsv or json)"
		return 2
		;;
	esac
	case "$DS_QUOTE_PROBE_MODE" in
	auto | always | never) ;;
	*)
		ds_warn "unknown --probe mode '$DS_QUOTE_PROBE_MODE' (want: auto, always or never)"
		return 2
		;;
	esac
	if ! printf '%s' "$DS_QUOTE_DELAY" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
		ds_warn "--delay must be a non-negative number of seconds, got '$DS_QUOTE_DELAY'"
		return 2
	fi
	if ! printf '%s' "$DS_QUOTE_PREMIUM_MULTIPLE" | grep -qE '^[0-9]+(\.[0-9]+)?$' ||
		awk -v m="$DS_QUOTE_PREMIUM_MULTIPLE" 'BEGIN { exit (m + 0 >= 1) ? 1 : 0 }'; then
		ds_warn "--premium-multiple must be a number >= 1, got '$DS_QUOTE_PREMIUM_MULTIPLE'"
		return 2
	fi
	if ! printf '%s' "$DS_QUOTE_PREMIUM_MIN_DELTA" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
		ds_warn "--premium-min-delta must be a non-negative number, got '$DS_QUOTE_PREMIUM_MIN_DELTA'"
		return 2
	fi
	if ! printf '%s' "$DS_QUOTE_RETRIES" | grep -qE '^[1-9][0-9]*$'; then
		ds_warn "DS_QUOTE_RETRIES must be a positive integer, got '$DS_QUOTE_RETRIES'"
		return 2
	fi

	ds_require curl jq awk grep sed

	# --- collect input -------------------------------------------------------
	# No names and no -f: read stdin when it is a pipe, otherwise show help.
	if [ -z "$_dqm_args" ] && [ -z "$_dqm_files" ]; then
		if [ -t 0 ]; then
			_dq_usage >&2
			return 2
		fi
		_dqm_files="
-"
	fi

	# Arguments and piped/file input are normalised by different rules: an
	# argument is an explicit instruction, so a malformed one must surface as an
	# ERROR row, while a junk line in a piped result table is just noise.
	_dqm_cand=$(_ds_mktemp) || ds_die "cannot create temp file"
	if [ -n "$_dqm_args" ]; then
		printf '%s\n' "$_dqm_args" | _dq_normalize_args >>"$_dqm_cand"
	fi

	_dqm_raw=$(_ds_mktemp) || ds_die "cannot create temp file"
	_dqm_oldifs="$IFS"
	IFS="
"
	for _dqm_f in $_dqm_files; do
		[ -n "$_dqm_f" ] || continue
		if [ "$_dqm_f" = "-" ]; then
			cat >>"$_dqm_raw"
		elif [ -r "$_dqm_f" ]; then
			cat "$_dqm_f" >>"$_dqm_raw"
		else
			IFS="$_dqm_oldifs"
			rm -f "$_dqm_raw" "$_dqm_cand"
			ds_warn "cannot read file: $_dqm_f"
			return 2
		fi
	done
	IFS="$_dqm_oldifs"
	_dq_normalize_input <"$_dqm_raw" >>"$_dqm_cand"
	rm -f "$_dqm_raw"

	# Final cross-source de-duplication: a name is worth about ten seconds.
	_dqm_list=$(_ds_mktemp) || ds_die "cannot create temp file"
	awk -F'|' '$1 != "" && !seen[$1]++' "$_dqm_cand" >"$_dqm_list"
	rm -f "$_dqm_cand"

	if [ ! -s "$_dqm_list" ]; then
		rm -f "$_dqm_list"
		ds_warn "no domain names found in the input"
		return 2
	fi

	_dqm_count=$(grep -c . "$_dqm_list" | tr -d ' ')

	# --- credentials ---------------------------------------------------------
	_dq_check_creds

	_DQ_BODY_FILE=$(_ds_mktemp) || ds_die "cannot create temp file"

	if [ "$_dqm_count" -gt 1 ] && [ -z "$DS_QUOTE_FIXTURE_DIR" ]; then
		_dqm_eta=$(awk -v n="$_dqm_count" -v d="$DS_QUOTE_DELAY" 'BEGIN {
			secs = (n - 1) * d
			if (secs < 90) printf "%.0f sec", secs
			else printf "%.0f min", secs / 60
		}')
		ds_log "quoting $_dqm_count name(s), ${DS_QUOTE_DELAY}s apart (about $_dqm_eta)"
	fi

	# --- the loop ------------------------------------------------------------
	# The list is read on fd 3, not stdin: a probe or a curl inside the loop
	# body must never be able to swallow the remaining candidates.
	_dqm_start=$SECONDS
	while IFS='|' read -r _dqm_dom _dqm_pre <&3; do
		[ -n "$_dqm_dom" ] || continue
		if ! _dq_valid_domain "$_dqm_dom"; then
			_dq_emit "$_dqm_dom" ERROR "" "" "" "" "" "" "" "" "not a valid domain name"
			_dqm_rc=1
			continue
		fi
		if ! _dq_quote_one "$_dqm_dom" "$_dqm_pre"; then
			_dqm_rc=1
		fi
	done 3<"$_dqm_list"
	rm -f "$_dqm_list"

	# --- summary (stderr, so stdout stays machine-readable) ------------------
	ds_log "done in $((SECONDS - _dqm_start))s: ${_DQ_N_AVAILABLE} available, ${_DQ_N_PREMIUM} premium, ${_DQ_N_RESERVED} reserved, ${_DQ_N_REGISTERED} registered, ${_DQ_N_UNAVAILABLE} unavailable, ${_DQ_N_ERROR} error ($_DQ_CALLS quote call(s) spent)"
	if [ "$_DQ_N_PREMIUM" -gt 0 ]; then
		ds_log "PREMIUM means purchasable but priced above the TLD's list price - check the renewal, not just year one."
	fi

	return "$_dqm_rc"
}

# Testing hook, mirroring DS_QUOTE_FIXTURE_DIR: `DS_QUOTE_NO_MAIN=1 . quote.sh`
# loads the functions without running anything, so tests/ can exercise the
# premium rule and the parsers offline. Unset (the normal case) runs the tool.
if [ -z "${DS_QUOTE_NO_MAIN:-}" ]; then
	main "$@"
fi
