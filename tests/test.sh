#!/usr/bin/env bash
# shellcheck shell=bash
#
# test.sh - DomainSaver's end-to-end test suite.
#
# This is not a smoke test. It exercises the real scripts, end to end, through
# their real command-line interfaces, and asserts the behaviour the project
# exists to guarantee:
#
#     AVAILABILITY IS NOT PURCHASABILITY.
#
#     An RDAP 404 means "absent from the registry", which covers genuinely
#     available, registry-RESERVED and PREMIUM-PRICED names. check.sh and
#     sweep.sh must therefore NEVER print the word AVAILABLE, however the
#     probe answered - only quote.sh, holding a real per-name quote, may.
#     That guarantee is asserted explicitly, offline and online, in every
#     output format the tools support (see "the core guarantee" below).
#
# THREE GROUPS OF TEST
#
#   UNIT      pure functions from lib.sh, plus the shipped data files.
#
#   OFFLINE   full end-to-end runs of bootstrap.sh / check.sh / sweep.sh /
#             quote.sh / generate.sh with `curl` and `whois` replaced by stubs
#             on PATH that serve captured registry responses. These are real
#             end-to-end tests - argument parsing, registry routing, probing,
#             pricing, rendering and exit codes all run for real - but they are
#             deterministic and touch no network, so CI can run them on every
#             pull request without hammering a registry.
#
#   NETWORK   opt-in. Talks to real registries and to IANA/Porkbun. Skipped
#             when DS_SKIP_NETWORK=1 (or DS_TEST_SKIP_NETWORK=1, which is what
#             .github/workflows/ci.yml sets).
#
# USAGE
#   tests/test.sh                     # everything, including the network group
#   DS_SKIP_NETWORK=1 tests/test.sh   # offline only (what CI runs)
#   DS_TEST_VERBOSE=1 tests/test.sh   # echo captured stderr for failing tests
#
# EXIT STATUS
#   0  every test that ran, passed
#   1  at least one test failed
#
# Everything in the OFFLINE and UNIT groups must pass on a fresh clone with an
# empty data/ directory: every fixture this file needs, it builds itself in a
# temp directory. Nothing here writes to the repository.
#
# Same constraints as the scripts under test: bash 3.2 compatible (no
# associative arrays, no `readarray`, no `${var^^}`), POSIX-ish tools only,
# never `sed -i`.

# Single-quoted strings all over this file are shell snippets handed to a CHILD
# bash as data ("bash -c '<snippet>' _ arg"). They must NOT expand here.
# shellcheck disable=SC2016

set -uo pipefail

_T_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)
DS_ROOT_DIR=$(cd -P "$_T_DIR/.." >/dev/null 2>&1 && pwd)
SCRIPTS_DIR="$DS_ROOT_DIR/scripts"
DATA_DIR="$DS_ROOT_DIR/data"
LIB_SH="$SCRIPTS_DIR/lib.sh"

# DS_SKIP_NETWORK is the documented name; DS_TEST_SKIP_NETWORK is kept because
# the CI workflow already sets it. Either one skips the network group.
SKIP_NETWORK=0
[ "${DS_SKIP_NETWORK:-0}" = "1" ] && SKIP_NETWORK=1
[ "${DS_TEST_SKIP_NETWORK:-0}" = "1" ] && SKIP_NETWORK=1

VERBOSE="${DS_TEST_VERBOSE:-0}"

RUN=0
FAILED=0
SKIPPED=0
TMPDIR_T=""

# Filled in by `try`.
OUT=""
ERR=""
RC=0

# ---------------------------------------------------------------------------
# SECTION 1: harness
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329  # invoked indirectly, via the EXIT trap below
_t_cleanup() {
	if [ -n "$TMPDIR_T" ] && [ -d "$TMPDIR_T" ]; then rm -rf "$TMPDIR_T"; fi
	return 0
}
trap _t_cleanup EXIT INT TERM

section() { printf '\n== %s ==\n' "$1"; }

pass() {
	RUN=$((RUN + 1))
	printf 'ok    %s\n' "$1"
	return 0
}

fail() {
	RUN=$((RUN + 1))
	FAILED=$((FAILED + 1))
	printf 'FAIL  %s\n' "$1"
	[ "$#" -ge 2 ] && printf '        %s\n' "$2"
	if [ "$VERBOSE" = "1" ] && [ -n "$ERR" ]; then
		printf '%s\n' "$ERR" | sed -e 's/^/        stderr| /'
	fi
	return 0
}

skip() {
	SKIPPED=$((SKIPPED + 1))
	printf 'skip  %s (%s)\n' "$1" "${2:-no reason given}"
	return 0
}

# try <command...>
#   Runs a command, capturing stdout in $OUT, stderr in $ERR and the exit
#   status in $RC. Never fails the harness itself.
try() {
	RC=0
	"$@" >"$TMPDIR_T/.out" 2>"$TMPDIR_T/.err" || RC=$?
	OUT=$(cat "$TMPDIR_T/.out")
	ERR=$(cat "$TMPDIR_T/.err")
	return 0
}

assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

assert_ne() {
	if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "expected anything but [$2]"; fi
}

assert_rc() {
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected exit $2, got $3"; fi
}

assert_contains() {
	case "$3" in
	*"$2"*) pass "$1" ;;
	*) fail "$1" "expected to contain [$2], got [$(printf '%s' "$3" | head -c 400)]" ;;
	esac
}

assert_not_contains() {
	case "$3" in
	*"$2"*) fail "$1" "must NOT contain [$2], got [$(printf '%s' "$3" | head -c 400)]" ;;
	*) pass "$1" ;;
	esac
}

# assert_no_word <name> <word> <haystack>
#   The word must not appear as a whole word. "UNAVAILABLE" therefore does not
#   count as an occurrence of "AVAILABLE", which is exactly the distinction the
#   core guarantee turns on.
assert_no_word() {
	if printf '%s\n' "$3" | grep -qw "$2"; then
		fail "$1" "found the word [$2] in: $(printf '%s' "$3" | grep -w "$2" | head -3)"
	else
		pass "$1"
	fi
}

assert_word() {
	if printf '%s\n' "$3" | grep -qw "$2"; then
		pass "$1"
	else
		fail "$1" "expected the word [$2], got [$(printf '%s' "$3" | head -c 400)]"
	fi
}

# assert_ge <name> <minimum> <actual>
assert_ge() {
	if [ "${3:-0}" -ge "$2" ] 2>/dev/null; then
		pass "$1"
	else
		fail "$1" "expected at least $2, got ${3:-<empty>}"
	fi
}

assert_file() {
	if [ -s "$2" ]; then pass "$1"; else fail "$1" "missing or empty: $2"; fi
}

# lib_eval <snippet> [env assignments passed through `env`...]
#   Runs <snippet> in a fresh bash with lib.sh sourced. stdout only.
lib_eval() {
	DS_QUIET=1 bash -c '. "$1"; eval "$2"' _ "$LIB_SH" "$1" 2>/dev/null
}

# lib_eval_in <data-dir> <snippet>
#   As lib_eval, but with DS_DATA_DIR pointed at a fixture directory.
lib_eval_in() {
	DS_QUIET=1 DS_DATA_DIR="$1" bash -c '. "$1"; eval "$2"' _ "$LIB_SH" "$2" 2>/dev/null
}

# classify <fixture-file>
#   Runs lib.sh's whois classifier over a captured registry response.
classify() {
	DS_QUIET=1 bash -c '. "$1"; ds_whois_classify "$(cat "$2")"' _ "$LIB_SH" "$1" 2>/dev/null
}

# rows <file>
#   Data rows in a TSV (comments and blank lines excluded).
rows() {
	[ -s "${1:-}" ] || {
		printf '0\n'
		return 0
	}
	awk '!/^[ \t]*#/ && NF { n++ } END { print n + 0 }' "$1"
}

# col <n> <domain> <tsv-text>
#   Field <n> of the first TSV row whose first field is <domain>.
col() {
	printf '%s\n' "$3" | awk -F'\t' -v n="$1" -v d="$2" '$1 == d { print $n; exit }'
}

TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/ds-test.XXXXXX") || exit 1
FIX="$TMPDIR_T/fixtures"
STUB_BIN="$TMPDIR_T/bin"
E2E_DATA="$TMPDIR_T/e2e-data"
mkdir -p "$FIX" "$STUB_BIN" "$E2E_DATA"

# ---------------------------------------------------------------------------
# SECTION 2: fixtures - captured registry responses
# ---------------------------------------------------------------------------
#
# Real responses, captured with `whois -h <server> <name>` on 2026-07-30 and
# trimmed. They are the reason the offline group is a genuine test of the
# parsers rather than a test of a mock: every registry has its own dialect and
# these are the dialects that actually matter.

# Nominet (.uk): a registered name says "Registered on:", never "Domain Name:
# <value>" - the label sits on its own line. A free one says "No match for".
cat >"$FIX/whois-uk-taken.txt" <<'EOF'

    Domain name:
        google.co.uk

    Registrar:
        Markmonitor Inc. [Tag = MARKMONITOR]
        URL: https://www.markmonitor.com

    Relevant dates:
        Registered on: 14-Feb-1999
        Expiry date:  14-Feb-2027
        Last updated:  13-Jan-2026

    Registration status:
        Registered until expiry date.

    Name servers:
        ns1.google.com
        ns2.google.com

    WHOIS lookup made at 12:59:55 30-Jul-2026
EOF

cat >"$FIX/whois-uk-free.txt" <<'EOF'

    No match for "zzq7x4-domainsaver-nope.co.uk".

    This domain name has not been registered.

    WHOIS lookup made at 12:59:56 30-Jul-2026
EOF

# CentralNic, serving .co from whois.registry.co (NOT whois.nic.co).
cat >"$FIX/whois-co-taken.txt" <<'EOF'
Domain Name: GOOGLE.CO
Registry Domain ID: D157997-CNIC
Registrar WHOIS Server: whois.markmonitor.com
Creation Date: 2010-02-25T01:04:59.0Z
Registry Expiry Date: 2027-02-24T23:59:59.0Z
Registrar: MarkMonitor, Inc.
Domain Status: clientTransferProhibited https://icann.org/epp#clientTransferProhibited
Name Server: NS1.GOOGLE.COM
DNSSEC: unsigned
>>> Last update of WHOIS database: 2026-07-30T11:59:56.0Z <<<
EOF

cat >"$FIX/whois-co-free.txt" <<'EOF'
The queried object does not exist: DOMAIN NOT FOUND

>>> Last update of WHOIS database: 2026-07-30T11:59:56.0Z <<<
EOF

# Verisign (.com) - the generic gTLD dialect.
cat >"$FIX/whois-com-taken.txt" <<'EOF'
   Domain Name: GOOGLE.COM
   Registry Domain ID: 2138514_DOMAIN_COM-VRSN
   Registrar WHOIS Server: whois.markmonitor.com
   Creation Date: 1997-09-15T04:00:00Z
   Registrar: MarkMonitor Inc.
   Domain Status: clientTransferProhibited https://icann.org/epp#clientTransferProhibited
   Name Server: NS1.GOOGLE.COM
>>> Last update of whois database: 2026-07-30T11:59:59Z <<<
EOF

cat >"$FIX/whois-com-free.txt" <<'EOF'
No match for domain "ZZQ7X4-DOMAINSAVER-NOPE.COM".
>>> Last update of whois database: 2026-07-30T11:59:59Z <<<
EOF

# A throttled reply. Reading this as "available" is precisely the failure mode
# the tool exists to prevent.
cat >"$FIX/whois-ratelimited.txt" <<'EOF'
WHOIS LIMIT EXCEEDED - SEE WWW.PIR.ORG/WHOIS FOR DETAILS
EOF

# The two responses that make the classifier's ORDER load-bearing.
#
#   1. A "not found" answer whose legal footer still talks about registrars and
#      domain status. Test the taken patterns first and this reads as taken.
cat >"$FIX/whois-free-with-boilerplate.txt" <<'EOF'
No Data Found

>>> Last update of WHOIS database: 2026-07-30T12:00:00Z <<<

NOTICE: The expiration date displayed in this record is the date the
registrar's sponsorship of the domain name registration in the registry is
currently set to expire.

Registrar: Example Registrar, LLC
Registrar WHOIS Server: whois.example-registrar.test
Domain Status: ok https://icann.org/epp#ok
EOF

#   2. A throttled answer that also contains "No match". Test the free patterns
#      first and a rate limit becomes a purchase recommendation.
cat >"$FIX/whois-ratelimited-with-nomatch.txt" <<'EOF'
WHOIS LIMIT EXCEEDED - SEE WWW.PIR.ORG/WHOIS FOR DETAILS
No match for "zzq7x4-domainsaver-nope.org".
EOF

# DENIC (.de) says free/connect rather than anything ICANN-shaped.
cat >"$FIX/whois-de-free.txt" <<'EOF'
Domain: zzq7x4-domainsaver-nope.de
Status: free
EOF

# ---------------------------------------------------------------------------
# SECTION 3: stubs - curl and whois, on PATH, serving the fixtures
# ---------------------------------------------------------------------------
#
# The stubs are how the offline group stays end-to-end: every script under test
# runs unmodified and really does resolve endpoints, spawn workers, parse
# responses and render output. Only the two programs that would touch the
# network are replaced.
#
#   DS_TEST_FIXTURES   directory holding the canned payloads
#   DS_TEST_CURL_LOG   every URL curl was asked for (proves what was fetched,
#                      and that --rebuild fetches nothing)
#   DS_TEST_WHOIS_LOG  "server<TAB>name" per whois call (proves .co is queried
#                      against whois.registry.co, the classic wrong guess)

cat >"$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub for curl. Serves canned RDAP answers and bootstrap payloads.
out=""
url=""
want_code=0
had_stdin_body=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o | --output)
		out="${2:-}"
		shift 2
		;;
	-w | --write-out)
		want_code=1
		shift 2
		;;
	--data-binary)
		had_stdin_body=1
		shift 2
		;;
	-A | --user-agent | -H | --header | -X | --request | -d | --data | --data-raw | \
		--connect-timeout | --max-time | --retry | --retry-delay | --max-redirs)
		shift 2
		;;
	--)
		shift
		;;
	-*)
		shift
		;;
	*)
		url="$1"
		shift
		;;
	esac
done
[ "$had_stdin_body" = "1" ] && cat >/dev/null 2>&1
[ -n "${DS_TEST_CURL_LOG:-}" ] && printf '%s\n' "$url" >>"$DS_TEST_CURL_LOG"

emit() { # emit <http-code> <body>
	[ -n "$out" ] && printf '%s' "$2" >"$out"
	[ "$want_code" = "1" ] && printf '%s' "$1"
	exit 0
}

case "$url" in
*data.iana.org*)
	[ -s "${DS_TEST_FIXTURES:-}/dns.json" ] || exit 22
	[ -n "$out" ] && cat "$DS_TEST_FIXTURES/dns.json" >"$out"
	exit 0
	;;
*api.porkbun.com*pricing*)
	[ -s "${DS_TEST_FIXTURES:-}/pricing.json" ] || exit 22
	[ -n "$out" ] && cat "$DS_TEST_FIXTURES/pricing.json" >"$out"
	exit 0
	;;
*/domain/*)
	name="${url##*/}"
	case "$name" in
	*flaky*)
		# Rate-limited once, then answers: this is what the retry queue is for.
		# The counter lives on disk because every worker is its own process.
		n=0
		if [ -n "${DS_TEST_STATE:-}" ]; then
			printf 'x\n' >>"$DS_TEST_STATE/$name.calls"
			n=$(wc -l <"$DS_TEST_STATE/$name.calls" | tr -d ' ')
		fi
		if [ "${n:-0}" -le 1 ]; then
			emit 429 '{"errorCode":429,"title":"Too Many Requests"}'
		else
			emit 404 '{"errorCode":404,"title":"Not Found"}'
		fi
		;;
	*throttle*)
		emit 429 '{"errorCode":429,"title":"Too Many Requests"}'
		;;
	*softfree*)
		# 200 carrying an RDAP error object: absent, despite the status line.
		emit 200 '{"errorCode":404,"title":"Not Found"}'
		;;
		*servfail*)
			emit 200 '{"errorCode":500,"title":"Internal Server Error"}'
			;;
		*malformed*)
			emit 200 '<html>upstream proxy error</html>'
			;;
		*taken* | google.*)
		emit 200 '{"objectClassName":"domain","ldhName":"'"$name"'","entities":[{"roles":["registrar"],"vcardArray":["vcard",[["version",{},"text","4.0"],["fn",{},"text","Stub Registrar Inc."]]]}]}'
		;;
	*)
		emit 404 '{"errorCode":404,"title":"Not Found"}'
		;;
	esac
	;;
esac
exit 7
STUB

cat >"$STUB_BIN/whois" <<'STUB'
#!/usr/bin/env bash
# Test stub for whois. Serves the captured per-registry dialects.
server=""
name=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-h | --host)
		server="${2:-}"
		shift 2
		;;
	-p | --port)
		shift 2
		;;
	-*)
		shift
		;;
	*)
		name="$1"
		shift
		;;
	esac
done
[ -n "${DS_TEST_WHOIS_LOG:-}" ] && printf '%s\t%s\n' "$server" "$name" >>"$DS_TEST_WHOIS_LOG"

F="${DS_TEST_FIXTURES:-}"

# TLD -> server resolution, the way lib.sh grows its cache.
if [ "$server" = "whois.iana.org" ]; then
	case "$name" in
	fyi | info | *rdaponly*)
		# ICANN sunset the WHOIS requirement for gTLDs, so IANA lists these
		# with an EMPTY whois: line. There is no whois server to fall back to,
		# which is why refusing them RDAP produced nothing but ERROR rows.
		printf 'domain:       %s\n' "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
		printf 'whois:\n'
		;;
	*)
		printf 'whois:        whois.nic.%s\n' "$name"
		;;
	esac
	exit 0
fi

taken=1
case "$name" in
*nope* | *free* | *available*) taken=0 ;;
esac

# "whoisfail" makes the whois side throttle too, so a name can be made to fail
# over BOTH transports - which must produce ERROR, never a cheerful "free".
case "$name" in
*whoisfail*)
	cat "$F/whois-ratelimited.txt"
	exit 0
	;;
esac

case "$server" in
whois.nic.uk)
	if [ "$taken" = "1" ]; then cat "$F/whois-uk-taken.txt"; else cat "$F/whois-uk-free.txt"; fi
	;;
whois.registry.co)
	if [ "$taken" = "1" ]; then cat "$F/whois-co-taken.txt"; else cat "$F/whois-co-free.txt"; fi
	;;
whois.nic.co)
	# The classic wrong guess. Answer with something useless so that a
	# regression in the override shows up as a broken lookup, not a pass.
	printf 'ERROR: no whois server is known for this kind of object\n'
	;;
*)
	if [ "$taken" = "1" ]; then cat "$F/whois-com-taken.txt"; else cat "$F/whois-com-free.txt"; fi
	;;
esac
exit 0
STUB

chmod +x "$STUB_BIN/curl" "$STUB_BIN/whois"
STUB_PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# SECTION 4: fixture data directory (a populated cache, built by hand)
# ---------------------------------------------------------------------------
#
# Deliberately hand-written rather than bootstrapped, so the offline group has
# known prices to assert against and known routing:
#   * .uk and .co are absent from the RDAP index, so they must fall through to
#     whois (which is where the Nominet and whois.registry.co tests live);
#   * .bar registers at $2.57 and renews at $52.01, the renewal trap that makes
#     "which column is the renewal?" a question worth testing;
#   * "co.uk" is priced but bare "uk" is not, which is exactly the shape that
#     makes a name have to be priced under a two-label suffix.

{
	printf '# tld\trdap_base_url\n'
	printf 'com\thttps://rdap.verisign.test/com/v1\n'
	printf 'net\thttps://rdap.verisign.test/net/v1\n'
	printf 'link\thttps://rdap.uniregistry.test/rdap\n'
	printf 'bar\thttps://rdap.centralnic.test/bar\n'
	printf 'org\thttps://rdap.pir.test/rdap\n'
	# An RDAP-ONLY gTLD on a registry that throttles hard. IANA publishes no
	# whois server for it, so RDAP is the only source of truth there is.
	printf 'fyi\thttps://rdap.identitydigital.services/rdap\n'
} >"$E2E_DATA/rdap-endpoints.tsv"

{
	printf '# tld\tregistration\trenewal\ttransfer\n'
	printf 'com\t9.13\t11.06\t9.13\n'
	printf 'net\t11.06\t13.09\t11.06\n'
	printf 'link\t7.72\t7.72\t7.72\n'
	printf 'bar\t2.57\t52.01\t52.01\n'
	printf 'top\t4.63\t4.63\t4.63\n'
	printf 'online\t2.24\t29.00\t29.00\n'
	printf 'co.uk\t6.87\t9.42\t6.87\n'
	printf 'co\t9.73\t28.68\t28.68\n'
	printf 'org\t10.14\t10.14\t10.14\n'
} >"$E2E_DATA/tld-prices.tsv"

# The concurrency table is a committed, hand-tuned file; sweep.sh warns loudly
# without it, so give the fixture cache a copy when the repo has one.
if [ -f "$DATA_DIR/registry-limits.tsv" ]; then
	cp "$DATA_DIR/registry-limits.tsv" "$E2E_DATA/registry-limits.tsv"
fi

# ---------------------------------------------------------------------------
# SECTION 5: synthetic upstream payloads (for the offline bootstrap test)
# ---------------------------------------------------------------------------
#
# Shaped exactly like the real ones and large enough to clear bootstrap.sh's
# sanity floors (1000 RDAP TLDs, 500 priced TLDs), so the offline run exercises
# the same verification path a real run does.

awk 'BEGIN {
	printf "{\"version\":\"1.0\",\"publication\":\"2026-07-30T00:00:00Z\",\"description\":\"stub\",\"services\":["
	printf "[[\"com\",\"net\"],[\"https://rdap.verisign.test/com/v1\"]]"
	printf ",[[\"org\"],[\"https://rdap.pir.test/rdap\"]]"
	printf ",[[\"uk\"],[\"https://rdap.nominet.test/uk\"]]"
	printf ",[[\"link\"],[\"https://rdap.uniregistry.test/rdap\"]]"
	printf ",[[\"bar\"],[\"https://rdap.centralnic.test/bar\"]]"
	printf ",[[\"online\"],[\"https://rdap.centralnic.test/online\"]]"
	printf ",[[\"top\"],[\"https://rdap.top.test/rdap\"]]"
	# The proxy that 429s after ~60 requests, and an Identity Digital host:
	# lib.sh must route both to whois no matter what the bootstrap says.
	printf ",[[\"info\"],[\"https://rdap.identitydigital.services/rdap\"]]"
	printf ",[[\"zzz\"],[\"https://rdap.org/\"]]"
	for (i = 1; i <= 1200; i++)
		printf ",[[\"t%04d\"],[\"https://rdap.filler.test/rdap\"]]", i
	printf "]}"
}' >"$FIX/dns.json"

awk 'BEGIN {
	printf "{\"status\":\"SUCCESS\",\"pricing\":{"
	printf "\"com\":{\"registration\":\"9.13\",\"renewal\":\"11.06\",\"transfer\":\"9.13\"}"
	printf ",\"net\":{\"registration\":\"11.06\",\"renewal\":\"13.09\",\"transfer\":\"11.06\"}"
	printf ",\"bar\":{\"registration\":\"2.57\",\"renewal\":\"52.01\",\"transfer\":\"52.01\"}"
	printf ",\"link\":{\"registration\":\"7.72\",\"renewal\":\"7.72\",\"transfer\":\"7.72\"}"
	printf ",\"top\":{\"registration\":\"4.63\",\"renewal\":\"4.63\",\"transfer\":\"4.63\"}"
	printf ",\"online\":{\"registration\":\"2.24\",\"renewal\":\"29.00\",\"transfer\":\"29.00\"}"
	printf ",\"uk\":{\"registration\":\"8.06\",\"renewal\":\"8.06\",\"transfer\":\"8.06\"}"
	printf ",\"co.uk\":{\"registration\":\"3.00\",\"renewal\":\"4.00\",\"transfer\":\"3.00\"}"
	for (i = 1; i <= 900; i++)
		printf ",\"t%04d\":{\"registration\":\"5.00\",\"renewal\":\"7.00\",\"transfer\":\"5.00\"}", i
	printf "}}"
}' >"$FIX/pricing.json"

# ---------------------------------------------------------------------------
# SECTION 6: static analysis
# ---------------------------------------------------------------------------

section "static analysis"

for f in "$SCRIPTS_DIR"/*.sh "$_T_DIR"/test.sh "$DS_ROOT_DIR"/install.sh; do
	[ -f "$f" ] || continue
	if bash -n "$f" 2>"$TMPDIR_T/syn.err"; then
		pass "bash -n $(basename "$f")"
	else
		fail "bash -n $(basename "$f")" "$(cat "$TMPDIR_T/syn.err")"
	fi
done

# -S warning must match .github/workflows/ci.yml and CONTRIBUTING.md exactly.
# Info-level notes are excluded on purpose: shellcheck releases disagree about
# them, and the Ubuntu runner's build emits SC2317 for every trap handler and
# indirectly-called function while 0.11 emits none. Gating on those makes a
# green build a property of the runner image rather than of the code.
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -x -P "$SCRIPTS_DIR" -S warning "$SCRIPTS_DIR"/*.sh "$_T_DIR"/test.sh \
		>"$TMPDIR_T/sc.out" 2>&1; then
		pass "shellcheck scripts/ and tests/"
	else
		fail "shellcheck scripts/ and tests/" "$(cat "$TMPDIR_T/sc.out")"
	fi
else
	skip "shellcheck" "shellcheck not installed"
fi

# No script may use the constructs that break on the bash 3.2 macOS ships, or
# the GNU-only sed -i whose BSD spelling needs an argument. Whole-line comments
# are stripped first: every one of these files DOCUMENTS the ban in its header,
# and matching that prose would make the check permanently red.
for f in "$SCRIPTS_DIR"/*.sh; do
	b=$(basename "$f")
	grep -vE '^[[:space:]]*#' "$f" >"$TMPDIR_T/code.sh"

	if grep -nE 'declare[[:space:]]+-A|^[[:space:]]*(readarray|mapfile)[[:space:]]|wait[[:space:]]+-n|\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)\}' \
		"$TMPDIR_T/code.sh" >"$TMPDIR_T/p.out" 2>&1; then
		fail "$b avoids bash 4+ constructs" "$(head -3 "$TMPDIR_T/p.out")"
	else
		pass "$b avoids bash 4+ constructs"
	fi

	if grep -nE "sed[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-i([[:space:]]|$)" \
		"$TMPDIR_T/code.sh" >"$TMPDIR_T/p.out" 2>&1; then
		fail "$b avoids sed -i" "$(head -3 "$TMPDIR_T/p.out")"
	else
		pass "$b avoids sed -i"
	fi
done

# ---------------------------------------------------------------------------
# SECTION 7: CLI contract
# ---------------------------------------------------------------------------

section "CLI contract"

for name in bootstrap check generate quote sweep; do
	s="$SCRIPTS_DIR/$name.sh"

	try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$s" --version
	assert_rc "$name.sh --version exits 0" 0 "$RC"
	assert_contains "$name.sh --version names itself" "$name.sh" "$OUT"

	try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$s" --help
	assert_rc "$name.sh --help exits 0" 0 "$RC"
	assert_contains "$name.sh --help has a USAGE block" "USAGE" "$OUT"
done

try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/bootstrap.sh" --definitely-not-an-option
assert_rc "bootstrap.sh rejects an unknown option with exit 2" 2 "$RC"

try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --definitely-not-an-option
assert_rc "generate.sh rejects an unknown option with exit 2" 2 "$RC"

try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/check.sh" --definitely-not-an-option
assert_rc "check.sh rejects an unknown option with exit 2" 2 "$RC"

# A mode with no TLD is a usage error, not an empty run.
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --two
assert_rc "generate.sh --two without --tld exits 2" 2 "$RC"

# ---------------------------------------------------------------------------
# SECTION 8: lib.sh units
# ---------------------------------------------------------------------------

section "lib.sh: names and normalisation"

try env DS_QUIET=1 bash -c '. "$1"' _ "$LIB_SH"
assert_eq "sourcing lib.sh prints nothing on stdout" "" "$OUT"
assert_eq "sourcing lib.sh prints nothing on stderr" "" "$ERR"

assert_eq "sourcing lib.sh twice is a no-op" "ok" \
	"$(lib_eval ': ; . "'"$LIB_SH"'"; printf "%s" ok')"

assert_eq "ds_normalize_domain lowercases, trims and strips the trailing dot" \
	"example.com" "$(lib_eval 'ds_normalize_domain "  ExAmPle.COM. "')"
assert_eq "ds_normalize_tld strips a leading dot" "uk" "$(lib_eval 'ds_normalize_tld ".UK"')"
assert_eq "ds_tld takes the last label" "uk" "$(lib_eval 'ds_tld "example.co.uk"')"

lib_eval 'ds_tld "nodothere" >/dev/null'
assert_rc "ds_tld fails on a name with no dot" 1 "$?"

assert_eq "_ds_url_host parses a hostname out of a URL" "rdap.example.com" \
	"$(lib_eval '_ds_url_host "https://user@rdap.example.com:443/rdap/domain/x.com"')"
assert_eq "_ds_sanitize_detail cannot break the pipe-delimited contract" \
	"a/b c" "$(lib_eval '_ds_sanitize_detail "a|b'"$(printf '\t')"'c"')"

# macOS ships no `timeout`, so lib.sh carries a pure-bash watchdog. An
# unbounded whois would otherwise hang a 30,000-name sweep forever, and this
# is the code path every macOS user actually runs.
cat >"$TMPDIR_T/watchdog.sh" <<'EOF'
. "$1"
# Force the fallback path by hiding timeout/gtimeout from lib.sh.
_ds_have() {
	case "$1" in timeout | gtimeout) return 1 ;; esac
	command -v "$1" >/dev/null 2>&1
}
t0=$(date +%s)
_ds_timeout 1 sleep 20
rc=$?
t1=$(date +%s)
# "prompt" allows for the TERM/KILL grace period and a loaded CI box.
if [ "$((t1 - t0))" -le 6 ]; then prompt=yes; else prompt=no; fi
printf 'killed_rc=%s prompt=%s elapsed=%s\n' "$rc" "$prompt" "$((t1 - t0))"
out=$(_ds_timeout 5 printf 'hello')
printf 'passthrough_out=%s passthrough_rc=%s\n' "$out" "$?"
_ds_timeout 5 sh -c 'exit 7'
printf 'status_rc=%s\n' "$?"
EOF
try env DS_QUIET=1 bash "$TMPDIR_T/watchdog.sh" "$LIB_SH"
assert_contains "the pure-bash watchdog reports a timeout as 124" "killed_rc=124" "$OUT"
assert_contains "the pure-bash watchdog kills promptly, not after 20s" "prompt=yes" "$OUT"
assert_contains "the watchdog passes a command's stdout through" "passthrough_out=hello" "$OUT"
assert_contains "the watchdog passes a command's exit status through" "status_rc=7" "$OUT"

# A nonzero whois process must still produce the library's machine-readable
# ERROR record when its caller enables errexit. Without this, the assignment
# that captures whois output terminates the shell before ds_probe_whois can
# report the failed lookup.
try bash -c 'set -e; . "$1"; whois() { return 1; }; ds_probe_whois example.co whois.invalid' \
	_ "$LIB_SH"
assert_rc "whois process failure exits as an ERROR result" 1 "$RC"
assert_contains "whois process failure emits an ERROR record under errexit" \
	"ERROR|example.co|whois:whois.invalid empty response" "$OUT"

# A direct library caller may enable errexit without wrapping ds_probe in a
# conditional. An RDAP failure must still reach the intended WHOIS fallback.
try bash -c '
	set -e
	. "$1"
	ds_rdap_endpoint() { printf "%s\n" "https://rdap.invalid"; }
	ds_probe_rdap() { printf "%s\n" "ERROR|example.com|rdap:503"; return 1; }
	ds_probe_whois() { printf "%s\n" "REGISTERED|example.com|whois:fallback"; return 0; }
	ds_probe example.com
' _ "$LIB_SH"
assert_rc "RDAP failure falls back to WHOIS under errexit" 0 "$RC"
assert_contains "the fallback result preserves both probe details" \
	"REGISTERED|example.com|whois:fallback after rdap:503" "$OUT"

section "lib.sh: registry routing rules"

# Priority 2: Google Registry TLDs go to pubapi, never to the throttled bootstrap
# endpoint. Asserted with an EMPTY cache, so it can only come from the rule.
assert_eq "Google Registry TLDs route to pubapi.registry.google" \
	"https://pubapi.registry.google/rdap" \
	"$(lib_eval_in "$TMPDIR_T/empty-data" 'ds_rdap_endpoint app')"
assert_eq ".foo also routes to pubapi.registry.google" \
	"https://pubapi.registry.google/rdap" \
	"$(lib_eval_in "$TMPDIR_T/empty-data" 'ds_rdap_endpoint foo')"

# Priority 3: TLDs with no RDAP report "use whois" (exit 1, nothing printed).
for t in io co me sh gg de nz; do
	out=$(lib_eval_in "$TMPDIR_T/empty-data" "ds_rdap_endpoint $t")
	rc=$?
	if [ "$rc" = "1" ] && [ -z "$out" ]; then
		pass ".$t has no RDAP endpoint (falls back to whois)"
	else
		fail ".$t has no RDAP endpoint (falls back to whois)" "rc=$rc out=[$out]"
	fi
done

# Identity Digital throttles brutally, but its gTLDs are RDAP-ONLY.
# ICANN sunset the WHOIS requirement for gTLDs, so IANA returns an empty
# "whois:" line for them and diverting to whois can only ever produce ERROR.
# Regression: betalab.fyi reported ERROR because .fyi was denied RDAP and has
# no whois server. These registries are SLOW, not unusable - sweep.sh throttles
# them to concurrency 1 instead (see data/registry-limits.tsv).
mkdir -p "$TMPDIR_T/slow-data"
printf 'idtest\thttps://rdap.identitydigital.services/rdap\n' >"$TMPDIR_T/slow-data/rdap-endpoints.tsv"
ID_OUT=$(lib_eval_in "$TMPDIR_T/slow-data" 'ds_rdap_endpoint idtest')
assert_rc "an Identity Digital endpoint is returned, not refused (RDAP-only registry)" 0 "$?"
assert_contains "  and it is the Identity Digital endpoint" "identitydigital" "$ID_OUT"

# The rdap.org proxy 429s after ~60 requests. THAT one is refused
# outright, even if a bootstrap file or an override hands it to us. (The index
# lives in slow-data, which exists: pointing this at a directory that does not
# exist would make the test pass for the wrong reason - a missing index also
# returns 1.)
printf 'proxytest\thttps://rdap.org/\n' >"$TMPDIR_T/slow-data/rdap-endpoints.tsv"
lib_eval_in "$TMPDIR_T/slow-data" 'ds_rdap_endpoint proxytest >/dev/null'
assert_rc "the rdap.org proxy is never used" 1 "$?"
printf 'proxytest\thttps://sub.rdap.org/rdap\n' >"$TMPDIR_T/slow-data/rdap-endpoints.tsv"
lib_eval_in "$TMPDIR_T/slow-data" 'ds_rdap_endpoint proxytest >/dev/null'
assert_rc "and neither is a subdomain of the proxy" 1 "$?"
# ...while a host that merely CONTAINS the string is fine: the ban is anchored
# on the parsed hostname, not on a substring of the URL.
printf 'proxytest\thttps://rdap.orgtld.example/rdap\n' >"$TMPDIR_T/slow-data/rdap-endpoints.tsv"
assert_eq "a host that merely looks like rdap.org is not banned" \
	"https://rdap.orgtld.example/rdap" \
	"$(lib_eval_in "$TMPDIR_T/slow-data" 'ds_rdap_endpoint proxytest')"

# Priority 1: the override file wins over everything, in both directions.
mkdir -p "$TMPDIR_T/ovr-data"
{
	printf '# tld\turl\n'
	printf 'app\thttps://rdap.override.test/rdap\n'
	printf 'com\tWHOIS\n'
	printf 'proxytest\thttps://sub.rdap.org/rdap\n'
} >"$TMPDIR_T/ovr-data/rdap-overrides.tsv"
assert_eq "rdap-overrides.tsv overrides even the Google routing rule" \
	"https://rdap.override.test/rdap" \
	"$(lib_eval_in "$TMPDIR_T/ovr-data" 'ds_rdap_endpoint app')"
lib_eval_in "$TMPDIR_T/ovr-data" 'ds_rdap_endpoint com >/dev/null'
assert_rc "rdap-overrides.tsv can force a TLD onto whois" 1 "$?"
lib_eval_in "$TMPDIR_T/ovr-data" 'ds_rdap_endpoint proxytest >/dev/null'
assert_rc "an override cannot bypass the banned RDAP proxy guard" 1 "$?"

# The regression this project keeps re-learning: .co is whois.registry.co.
assert_eq "ds_whois_server co is whois.registry.co, NOT whois.nic.co" \
	"whois.registry.co" "$(lib_eval_in "$TMPDIR_T/empty-data" 'ds_whois_server co')"
assert_ne "ds_whois_server co is not the wrong guess" \
	"whois.nic.co" "$(lib_eval_in "$TMPDIR_T/empty-data" 'ds_whois_server co')"
assert_eq "ds_whois_server uk is whois.nic.uk (Nominet)" \
	"whois.nic.uk" "$(lib_eval_in "$TMPDIR_T/empty-data" 'ds_whois_server uk')"

section "lib.sh: building the RDAP index"

# The IANA bootstrap gives each service an ARRAY of URLs, and both of these
# were live defects: [0] can be the plaintext endpoint, and one malformed entry
# used to abort the whole build - losing the endpoints for all 1200 TLDs and
# silently degrading every lookup in the toolkit to whois.
mkdir -p "$TMPDIR_T/idx-data"
cat >"$TMPDIR_T/idx-data/rdap-bootstrap.json" <<'EOF'
{"version":"1.0","publication":"2026-07-30T00:00:00Z","services":[
 [["com","net"],["https://rdap.verisign.test/com/v1"]],
 [["mixed"],["http://rdap.plain.test/rdap","https://rdap.secure.test/rdap"]],
 [["plainonly"],["http://rdap.plain.test/rdap"]],
 [["brokentld"],[]],
 [["weirdtld"],[null]],
 [["trailing"],["https://rdap.slash.test/rdap///"]]
]}
EOF

try env DS_DATA_DIR="$TMPDIR_T/idx-data" bash -c '. "$1"; ds_build_rdap_index' _ "$LIB_SH"
assert_rc "ds_build_rdap_index survives a malformed service entry" 0 "$RC"
assert_eq "a URL-less entry costs only its own TLD, not the whole index" \
	"https://rdap.verisign.test/com/v1" "$(lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint com')"
assert_eq "every TLD of a multi-TLD entry is mapped" \
	"https://rdap.verisign.test/com/v1" "$(lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint net')"
assert_contains "and the dropped TLDs are reported, not swallowed" \
	"no usable URL" "$ERR"
lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint brokentld >/dev/null'
assert_rc "a TLD with no usable URL falls back to whois" 1 "$?"

# https must win whenever it is offered: an RDAP lookup over cleartext can be
# rewritten by any proxy in the path, and a rewritten 404 is a purchase
# recommendation for a name that is not for sale.
assert_eq "https is preferred when a registry publishes both" \
	"https://rdap.secure.test/rdap" "$(lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint mixed')"
assert_eq "an http-only registry is still usable" \
	"http://rdap.plain.test/rdap" "$(lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint plainonly')"
assert_eq "trailing slashes are stripped so URLs join cleanly" \
	"https://rdap.slash.test/rdap" "$(lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint trailing')"

# A payload that is JSON but not the bootstrap file must not overwrite anything.
printf '{"nope":true}' >"$TMPDIR_T/idx-data/rdap-bootstrap.json"
try env DS_DATA_DIR="$TMPDIR_T/idx-data" bash -c '. "$1"; ds_build_rdap_index' _ "$LIB_SH"
assert_rc "ds_build_rdap_index refuses a payload with no services" 1 "$RC"
assert_eq "and the previous index is left intact" \
	"https://rdap.verisign.test/com/v1" "$(lib_eval_in "$TMPDIR_T/idx-data" 'ds_rdap_endpoint com')"

section "lib.sh: whois dialects"

# Order is load-bearing: a throttled reply must never read as available, and
# "no match" boilerplate routinely contains the word "Registrar".
assert_eq "Nominet (.uk) 'Registered on:' parses as TAKEN" "TAKEN" \
	"$(classify "$FIX/whois-uk-taken.txt")"
assert_eq "Nominet (.uk) 'No match for' parses as FREE" "FREE" \
	"$(classify "$FIX/whois-uk-free.txt")"
assert_eq ".co (CentralNic) registered parses as TAKEN" "TAKEN" \
	"$(classify "$FIX/whois-co-taken.txt")"
assert_eq ".co 'DOMAIN NOT FOUND' parses as FREE" "FREE" \
	"$(classify "$FIX/whois-co-free.txt")"
assert_eq ".com (Verisign) registered parses as TAKEN" "TAKEN" \
	"$(classify "$FIX/whois-com-taken.txt")"
assert_eq ".com 'No match for domain' parses as FREE" "FREE" \
	"$(classify "$FIX/whois-com-free.txt")"
assert_eq "DENIC 'Status: free' parses as FREE" "FREE" \
	"$(classify "$FIX/whois-de-free.txt")"
assert_eq "a rate-limited reply parses as RATELIMIT, never FREE" "RATELIMIT" \
	"$(classify "$FIX/whois-ratelimited.txt")"
# These two are why the classifier tests RATELIMIT, then FREE, then TAKEN, in
# that order. Reorder it and one of them silently becomes the wrong answer.
assert_eq "a 'not found' reply full of registrar boilerplate is still FREE" "FREE" \
	"$(classify "$FIX/whois-free-with-boilerplate.txt")"
assert_eq "a throttled reply that also says 'No match' is RATELIMIT, not FREE" "RATELIMIT" \
	"$(classify "$FIX/whois-ratelimited-with-nomatch.txt")"

assert_eq "an unrecognised reply is UNKNOWN, never a guess" "UNKNOWN" \
	"$(lib_eval 'ds_whois_classify "banana"')"
assert_eq "an empty reply is UNKNOWN" "UNKNOWN" "$(lib_eval 'ds_whois_classify ""')"

section "lib.sh: pricing"

# RENEWAL is the number that matters. .bar registers at 2.57 and renews at
# 52.01, so a column swap here is a 20x lie.
price=$(lib_eval_in "$E2E_DATA" 'ds_std_price bar')
assert_eq "ds_std_price returns <registration>TAB<renewal>" \
	"2.57	52.01" "$price"
assert_eq "ds_std_price column 2 is the RENEWAL" "52.01" \
	"$(printf '%s' "$price" | cut -f2)"
assert_ne "ds_std_price column 2 is not the registration price" "2.57" \
	"$(printf '%s' "$price" | cut -f2)"
assert_eq "ds_std_price column 1 is the registration price" "2.57" \
	"$(printf '%s' "$price" | cut -f1)"
assert_eq "ds_std_price accepts a leading dot and mixed case" \
	"2.57	52.01" "$(lib_eval_in "$E2E_DATA" 'ds_std_price ".BAR"')"

lib_eval_in "$E2E_DATA" 'ds_std_price nosuchtld >/dev/null'
assert_rc "ds_std_price fails for an unknown TLD instead of inventing one" 1 "$?"

# The same fact, built from a Porkbun payload rather than a hand-written table:
# this is what guards against a swap inside ds_build_price_index itself.
mkdir -p "$TMPDIR_T/pricebuild"
cp "$FIX/pricing.json" "$TMPDIR_T/pricebuild/porkbun-pricing.json"
assert_eq "ds_build_price_index maps renewal into column 2" "52.01" \
	"$(lib_eval_in "$TMPDIR_T/pricebuild" 'ds_build_price_index >/dev/null 2>&1; ds_std_price bar' | cut -f2)"

section "lib.sh: TLD reputation"

assert_word "ds_tld_flags com is NO_PREMIUM_REGISTRY" "NO_PREMIUM_REGISTRY" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags com')"
assert_word "ds_tld_flags bid is SPAM_ASSOCIATED" "SPAM_ASSOCIATED" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags bid')"
assert_word "ds_tld_flags top is SPAM_ASSOCIATED" "SPAM_ASSOCIATED" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags top')"
assert_word "ds_tld_flags bar is a RENEWAL_TRAP" "RENEWAL_TRAP" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags bar')"
assert_word "a 20x renewal is also flagged RENEWAL_EXPENSIVE" "RENEWAL_EXPENSIVE" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags bar')"
# .online is a renewal trap derived from the prices (2.24 -> 29.00), not from a
# hard-coded name, so it proves the computed rule fires.
assert_word "a computed renewal trap is flagged (online 2.24 -> 29.00)" "RENEWAL_TRAP" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags online')"
assert_no_word "a flat-priced TLD is not flagged a renewal trap" "RENEWAL_TRAP" \
	"$(lib_eval_in "$E2E_DATA" 'ds_tld_flags link')"
assert_word "an unpriced TLD degrades to NO_PRICE_DATA" "NO_PRICE_DATA" \
	"$(lib_eval_in "$TMPDIR_T/empty-data" 'ds_tld_flags com')"

flags=$(lib_eval_in "$E2E_DATA" 'ds_tld_flags bar')
assert_eq "ds_tld_flags de-duplicates its tokens" "1" \
	"$(printf '%s\n' "$flags" | tr ' ' '\n' | grep -c '^RENEWAL_TRAP$')"

section "lib.sh: credentials"

try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY DS_QUIET=1 \
	bash -c '. "$1"; ds_porkbun_creds_ok' _ "$LIB_SH"
assert_rc "ds_porkbun_creds_ok fails when no key is configured" 1 "$RC"
assert_contains "and says results will NOT be promoted to AVAILABLE" \
	"NOT promoted to AVAILABLE" "$ERR"

try env PORKBUN_API_KEY=pk1_x PORKBUN_SECRET_KEY=sk1_y DS_QUIET=1 \
	bash -c '. "$1"; ds_porkbun_creds_ok' _ "$LIB_SH"
assert_rc "ds_porkbun_creds_ok succeeds when both keys are set" 0 "$RC"

# ---------------------------------------------------------------------------
# SECTION 9: shipped data files
# ---------------------------------------------------------------------------

section "shipped data files"

for f in registry-limits.tsv rdap-overrides.tsv tld-flags.tsv; do
	if [ -f "$DATA_DIR/$f" ]; then
		pass "data/$f ships in the repo"
	else
		fail "data/$f ships in the repo" "seeded file missing - it must be committed"
	fi
done

if [ -f "$DATA_DIR/registry-limits.tsv" ]; then
	bad=$(awk -F'\t' '!/^#/ && NF > 0 { if (NF < 2 || $2 !~ /^[0-9]+$/) print NR }' \
		"$DATA_DIR/registry-limits.tsv" | head -5)
	assert_eq "registry-limits.tsv rows are <pattern> TAB <integer>" "" "$bad"

	# The limits that stop this tool getting banned.
	try bash "$SCRIPTS_DIR/sweep.sh" --explain-limit rdap.identitydigital.services rdap
	assert_eq "Identity Digital gets a single slot" "1" "$(printf '%s' "$OUT" | cut -f2)"
	try bash "$SCRIPTS_DIR/sweep.sh" --explain-limit pubapi.registry.google rdap
	assert_ge "Google's pubapi gets a generous budget" 8 "$(printf '%s' "$OUT" | cut -f2)"
fi

if [ -f "$DATA_DIR/tld-flags.tsv" ]; then
	bad=$(awk -F'\t' '!/^#/ && NF > 0 { if (NF < 2 || $1 == "" || $2 == "") print NR }' \
		"$DATA_DIR/tld-flags.tsv" | head -5)
	assert_eq "tld-flags.tsv rows are <tld> TAB <flags>" "" "$bad"
fi

# ---------------------------------------------------------------------------
# SECTION 10: generate.sh (offline by design)
# ---------------------------------------------------------------------------

section "generate.sh"

try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --two --tld uk
assert_rc "generate.sh --two exits 0" 0 "$RC"
assert_eq "generate.sh --two emits exactly 676 names" "676" "$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "generate.sh --two emits 676 DISTINCT names" "676" "$(printf '%s\n' "$OUT" | sort -u | grep -c .)"
assert_eq "generate.sh --two starts at aa" "aa.uk" "$(printf '%s\n' "$OUT" | head -1)"
assert_eq "generate.sh --two ends at zz" "zz.uk" "$(printf '%s\n' "$OUT" | tail -1)"
assert_eq "generate.sh --two emits only .uk" "676" "$(printf '%s\n' "$OUT" | grep -c '\.uk$')"
assert_contains "generate.sh reports the count on stderr" "676 candidate(s)" "$ERR"

# 19 onsets x 5 vowels x 17 codas = 1615, and it must agree with --count.
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --cvc --tld dev
assert_eq "generate.sh --cvc emits exactly 1615 names (19x5x17)" "1615" "$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "generate.sh --cvc emits 1615 DISTINCT names" "1615" "$(printf '%s\n' "$OUT" | sort -u | grep -c .)"
assert_eq "generate.sh --cvc starts at bab" "bab.dev" "$(printf '%s\n' "$OUT" | head -1)"
assert_eq "generate.sh --cvc labels are all 3 characters" "1615" \
	"$(printf '%s\n' "$OUT" | grep -c '^[a-z][a-z][a-z]\.dev$')"

try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --cvc --tld dev --count
assert_eq "generate.sh --cvc --count agrees with the emitted count" "1615" "$OUT"

# 19 onsets x 5 vowels x 19 onsets x 5 vowels = 9025.
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --cvcv --tld io --count
assert_eq "generate.sh --cvcv counts 9025 names (19x5x19x5)" "9025" "$OUT"

# TLDs interleave, so consecutive queries hit different registries.
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --two --tlds uk,com
assert_eq "generate.sh crosses 676 labels with 2 TLDs" "1352" "$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "generate.sh interleaves TLDs label-major" "aa.uk aa.com ab.uk ab.com" \
	"$(printf '%s\n' "$OUT" | head -4 | tr '\n' ' ' | sed -e 's/ $//')"

try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" --cvc --tld dev --limit 5
assert_eq "generate.sh --limit stops where it says" "5" "$(printf '%s\n' "$OUT" | grep -c .)"

printf 'shed\nhut\nSHED\n\n# a comment\nnot a label!\n' >"$TMPDIR_T/words.txt"
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" \
	--words "$TMPDIR_T/words.txt" --tlds link,dev
assert_eq "generate.sh --words is a full cross product, deduplicated" "4" "$(printf '%s\n' "$OUT" | grep -c .)"
assert_contains "generate.sh --words joins label and TLD" "shed.link" "$OUT"
assert_contains "generate.sh --words skips unusable entries loudly" "skipped 1" "$ERR"

# The generator must never emit a name it knows is illegal.
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash -c \
	'printf "%s\n" shed hut | bash "$1" --words - --tlds link' _ "$SCRIPTS_DIR/generate.sh"
assert_rc "generate.sh --words - reads the list from stdin" 0 "$RC"
assert_eq "and crosses it with the TLDs" "shed.link hut.link" \
	"$(printf '%s\n' "$OUT" | tr '\n' ' ' | sed -e 's/ $//')"

printf -- '-lead\ntrail-\nab--cd\nxn--p1ai\nok\n' >"$TMPDIR_T/edge.txt"
try env DS_DATA_DIR="$TMPDIR_T/empty-data" bash "$SCRIPTS_DIR/generate.sh" \
	--words "$TMPDIR_T/edge.txt" --tlds com
assert_eq "generate.sh drops illegal DNS labels" "ok.com xn--p1ai.com" \
	"$(printf '%s\n' "$OUT" | sort | tr '\n' ' ' | sed -e 's/ $//')"

# Generation is free; the notes about what checking will cost are not silence.
try env DS_DATA_DIR="$E2E_DATA" bash "$SCRIPTS_DIR/generate.sh" --two --tld bar
assert_contains "generate.sh warns about a renewal-trap TLD" "RENEWAL_TRAP" "$ERR"
assert_contains "generate.sh shows the renewal price, not just registration" "renew \$52.01" "$ERR"

try env DS_DATA_DIR="$E2E_DATA" bash "$SCRIPTS_DIR/generate.sh" --cvc --tld top --count
assert_contains "generate.sh warns about a spam-associated TLD" "SPAM_ASSOCIATED" "$ERR"

# ---------------------------------------------------------------------------
# SECTION 11: offline end-to-end - check.sh
# ---------------------------------------------------------------------------

section "check.sh end-to-end (stubbed registries)"

CURL_LOG="$TMPDIR_T/curl.log"
WHOIS_LOG="$TMPDIR_T/whois.log"
: >"$CURL_LOG"
: >"$WHOIS_LOG"

ck() {
	try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" \
		DS_TEST_FIXTURES="$FIX" DS_TEST_CURL_LOG="$CURL_LOG" \
		DS_TEST_WHOIS_LOG="$WHOIS_LOG" DS_RDAP_RETRIES=1 \
		bash "$SCRIPTS_DIR/check.sh" "$@"
}

ck -q taken-by-someone.com
assert_rc "check.sh exits 0 for a resolved name" 0 "$RC"
assert_eq "check.sh reports a registered name as REGISTERED" "REGISTERED" "$(col 2 taken-by-someone.com "$OUT")"
assert_eq "check.sh shows the TLD's list registration price" "9.13" "$(col 3 taken-by-someone.com "$OUT")"
assert_eq "check.sh shows the TLD's list RENEWAL price" "11.06" "$(col 4 taken-by-someone.com "$OUT")"

ck -q zzq7x4-domainsaver-nope.com
assert_rc "check.sh exits 0 for an unregistered name" 0 "$RC"
assert_eq "check.sh reports an absent name as UNREGISTERED" "UNREGISTERED" \
	"$(col 2 zzq7x4-domainsaver-nope.com "$OUT")"
assert_contains "check.sh records how it knows (rdap:404)" "rdap:404" "$OUT"

# ---- THE CORE GUARANTEE ---------------------------------------------------
# An unregistered name, no credentials configured, therefore no quote: the word
# AVAILABLE must not appear anywhere on stdout, in any output format.

section "THE CORE GUARANTEE: UNREGISTERED is never rendered as AVAILABLE"

guarantee() { # guarantee <label> <check.sh args...>
	_g_label="$1"
	shift
	try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY \
		PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
		DS_TEST_CURL_LOG="$CURL_LOG" DS_TEST_WHOIS_LOG="$WHOIS_LOG" \
		DS_RDAP_RETRIES=1 bash "$SCRIPTS_DIR/check.sh" "$@"
	assert_no_word "check.sh never prints AVAILABLE ($_g_label)" "AVAILABLE" "$OUT"
	unset _g_label
}

guarantee "table mode" zzq7x4-domainsaver-nope.com
assert_word "check.sh says UNREGISTERED instead (table mode)" "UNREGISTERED" "$OUT"
assert_contains "check.sh warns that UNREGISTERED is not AVAILABLE" \
	"is NOT the same as AVAILABLE" "$ERR"
assert_contains "check.sh cites the measured evidence for that warning" "819.27" "$ERR"
assert_contains "check.sh points at the script that CAN answer it" "quote.sh" "$ERR"

guarantee "quiet TSV mode" -q zzq7x4-domainsaver-nope.com
assert_word "check.sh says UNREGISTERED instead (quiet mode)" "UNREGISTERED" "$OUT"

guarantee "several names at once" \
	zzq7x4-domainsaver-nope.com softfree-name.com free-two.link taken-by-someone.com
assert_eq "check.sh emits one row per name" "4" "$(printf '%s\n' "$OUT" | grep -c '^[a-z]')"

guarantee "JSON mode" --json zzq7x4-domainsaver-nope.com
assert_rc "check.sh --json exits 0" 0 "$RC"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
	pass "check.sh --json emits valid JSON"
else
	fail "check.sh --json emits valid JSON" "$(printf '%s' "$OUT" | head -c 300)"
fi
assert_eq "check.sh --json status is UNREGISTERED" "UNREGISTERED" \
	"$(printf '%s' "$OUT" | jq -r '.results[0].status')"
assert_eq "check.sh --json refuses to claim purchasability (null, not true)" "null" \
	"$(printf '%s' "$OUT" | jq -r '.results[0].purchasable')"
assert_eq "check.sh --json says no quotes are configured" "false" \
	"$(printf '%s' "$OUT" | jq -r '.quotes_configured')"
assert_contains "check.sh --json carries the warning in the document itself" \
	"NOT purchasable" "$(printf '%s' "$OUT" | jq -r '.warning')"
assert_eq "check.sh --json prices are numbers, and renewal is the renewal" "11.06" \
	"$(printf '%s' "$OUT" | jq -r '.results[0].standard_price.renewal')"

# A registered name is the one case where purchasability IS known: it is false.
guarantee "JSON mode, registered name" --json taken-by-someone.com
assert_eq "check.sh --json says purchasable=false for a REGISTERED name" "false" \
	"$(printf '%s' "$OUT" | jq -r '.results[0].purchasable')"

# ---- back to ordinary check.sh behaviour ----------------------------------

section "check.sh: routing, dialects and failure modes"

# .co has no RDAP, so this must go to whois - and to the RIGHT whois server.
: >"$WHOIS_LOG"
ck -q --no-price google-taken.co
assert_eq "a .co name is answered over whois" "REGISTERED" "$(col 2 google-taken.co "$OUT")"
assert_contains "check.sh queried whois.registry.co for .co" "whois.registry.co" "$(cat "$WHOIS_LOG")"
assert_not_contains "check.sh did NOT guess whois.nic.co" "whois.nic.co" "$(cat "$WHOIS_LOG")"
assert_contains "check.sh reports which whois server answered" "whois:whois.registry.co" "$OUT"

: >"$WHOIS_LOG"
ck -q --no-price zzq7x4-domainsaver-nope.co
assert_eq "an absent .co name is UNREGISTERED over whois" "UNREGISTERED" \
	"$(col 2 zzq7x4-domainsaver-nope.co "$OUT")"

# .uk is absent from this fixture cache, so it falls through to Nominet's whois
# and must be parsed in Nominet's own dialect.
: >"$WHOIS_LOG"
ck -q --no-price google-taken.uk
assert_eq "Nominet 'Registered on:' is parsed as REGISTERED" "REGISTERED" "$(col 2 google-taken.uk "$OUT")"
assert_contains "check.sh queried whois.nic.uk for .uk" "whois.nic.uk" "$(cat "$WHOIS_LOG")"

: >"$WHOIS_LOG"
ck -q --no-price zzq7x4-domainsaver-nope.uk
assert_eq "Nominet 'No match for' is parsed as UNREGISTERED" "UNREGISTERED" \
	"$(col 2 zzq7x4-domainsaver-nope.uk "$OUT")"

# REGRESSION (betalab.fyi): an RDAP-only gTLD on a throttling registry. IANA
# publishes an empty "whois:" line for it, so there is no whois to divert to -
# refusing it RDAP turns every name under that TLD into an ERROR row. Both
# halves are asserted: the whois path really is a dead end, and the lookup
# still produces a definitive answer anyway.
lib_eval_in "$E2E_DATA" 'ds_whois_server fyi >/dev/null'
assert_rc "an RDAP-only gTLD has no whois server at all" 1 "$?"

ck -q --no-price zzq7x4-domainsaver-nope.fyi
assert_eq "and is still answered, over RDAP" "UNREGISTERED" \
	"$(col 2 zzq7x4-domainsaver-nope.fyi "$OUT")"
assert_rc "so it never degrades into an ERROR row" 0 "$RC"
ck -q --no-price taken-name.fyi
assert_eq "a registered name under it resolves too" "REGISTERED" "$(col 2 taken-name.fyi "$OUT")"

# A 200 carrying an RDAP error object means absent, whatever the status line.
ck -q --no-price softfree-name.com
assert_eq "an RDAP 200 with errorCode 404 is UNREGISTERED" "UNREGISTERED" \
	"$(col 2 softfree-name.com "$OUT")"

# A transport-successful response is still not an answer unless its body is a
# valid RDAP domain object. Captive portals and broken proxies commonly return
# HTML with HTTP 200, which must remain ERROR rather than becoming REGISTERED.
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_RDAP_RETRIES=1 bash -c '. "$1"; ds_probe_rdap malformed-body.com "$2"' \
	_ "$LIB_SH" "https://rdap.verisign.test/com/v1"
assert_rc "a malformed RDAP 200 response exits as ERROR" 1 "$RC"
assert_contains "a malformed RDAP 200 response is never REGISTERED" \
	"ERROR|malformed-body.com|rdap:200 invalid RDAP response" "$OUT"

# A throttled registry is not an answer. It must fall back to whois rather than
# be reported as fact - and the fallback must be visible in the detail.
: >"$WHOIS_LOG"
ck -q --no-price throttle-me.com
assert_eq "a rate-limited RDAP falls back to whois instead of guessing" "REGISTERED" \
	"$(col 2 throttle-me.com "$OUT")"
assert_contains "the RDAP rate limit is still reported in the detail" "rdap:429" "$OUT"
assert_contains "the fallback really did query whois" "whois" "$(cat "$WHOIS_LOG")"

# When BOTH sources fail, the answer is ERROR - never "free".
ck -q --no-price throttle-whoisfail.com
assert_eq "when RDAP and whois both fail the result is ERROR" "ERROR" \
	"$(col 2 throttle-whoisfail.com "$OUT")"
assert_rc "check.sh exits 1 when a name ends in ERROR" 1 "$RC"
assert_contains "and the ERROR detail names both failures" "rdap:429" \
	"$(col 6 throttle-whoisfail.com "$OUT")"

ck -q --no-price 'not_a_domain'
assert_eq "a malformed name is an ERROR row, not a silent skip" "ERROR" \
	"$(col 2 not_a_domain "$OUT")"
assert_rc "check.sh exits 1 for a malformed name" 1 "$RC"

# Porkbun prices some two-label suffixes separately: co.uk is not uk. In this
# fixture cache bare "uk" has no price at all, so a name priced under co.uk
# proves the longer suffix is preferred - and proves the NO_PRICE_DATA flag is
# withdrawn once a price really was found.
ck -q zzq7x4-domainsaver-nope.co.uk
assert_eq "a co.uk name is priced under co.uk, not uk" "6.87" \
	"$(col 3 zzq7x4-domainsaver-nope.co.uk "$OUT")"
assert_eq "and its renewal comes from co.uk too" "9.42" \
	"$(col 4 zzq7x4-domainsaver-nope.co.uk "$OUT")"
assert_no_word "NO_PRICE_DATA is not claimed when a price was found" "NO_PRICE_DATA" \
	"$(col 5 zzq7x4-domainsaver-nope.co.uk "$OUT")"
assert_contains "but the registry's own flags still apply" "NO_PREMIUM_REGISTRY" \
	"$(col 5 zzq7x4-domainsaver-nope.co.uk "$OUT")"

# Names are normalised before anything else happens.
ck -q --no-price 'ZZQ7X4-DOMAINSAVER-NOPE.COM.'
assert_eq "check.sh lowercases and strips a trailing dot" "UNREGISTERED" \
	"$(col 2 zzq7x4-domainsaver-nope.com "$OUT")"

# stdin, several names per line, comments and duplicates.
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_RDAP_RETRIES=1 bash -c \
	'printf "%s\n" "# comment" "free-a.com, free-b.com" "free-a.com" | bash "$1" -q --no-price -' \
	_ "$SCRIPTS_DIR/check.sh"
assert_eq "check.sh reads stdin, splits on commas and de-duplicates" "2" \
	"$(printf '%s\n' "$OUT" | grep -c '^[a-z]')"

# ---------------------------------------------------------------------------
# SECTION 12: offline end-to-end - sweep.sh
# ---------------------------------------------------------------------------

section "sweep.sh end-to-end (stubbed registries)"

cat >"$TMPDIR_T/sweep-in.txt" <<'EOF'
# a comment line
taken-one.com

zzq7x4-nope-one.com
google-taken.co
zzq7x4-nope-two.co
google-taken.uk
zzq7x4-nope-three.uk
-illegal-.com
zzq7x4-nope-one.com
EOF

# Not --quiet: the run's warnings and the "UNREGISTERED is not AVAILABLE"
# reminder are part of the contract and are asserted below.
: >"$WHOIS_LOG"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_WHOIS_LOG="$WHOIS_LOG" DS_RDAP_RETRIES=1 \
	bash "$SCRIPTS_DIR/sweep.sh" --no-progress -r 1 "$TMPDIR_T/sweep-in.txt"
SWEEP_OUT="$OUT"
assert_rc "sweep.sh exits 2 when a row is ERROR" 2 "$RC"

body=$(printf '%s\n' "$SWEEP_OUT" | grep -v '^#')
assert_eq "sweep.sh emits exactly one row per UNIQUE input name" "7" "$(printf '%s\n' "$body" | grep -c .)"
assert_eq "sweep.sh preserves input order" \
	"taken-one.com zzq7x4-nope-one.com google-taken.co zzq7x4-nope-two.co google-taken.uk zzq7x4-nope-three.uk -illegal-.com" \
	"$(printf '%s\n' "$body" | awk -F'\t' '{ print $2 }' | tr '\n' ' ' | sed -e 's/ $//')"
assert_eq "sweep.sh: RDAP 200 -> REGISTERED" "REGISTERED" \
	"$(printf '%s\n' "$body" | awk -F'\t' '$2 == "taken-one.com" { print $1 }')"
assert_eq "sweep.sh: RDAP 404 -> UNREGISTERED" "UNREGISTERED" \
	"$(printf '%s\n' "$body" | awk -F'\t' '$2 == "zzq7x4-nope-one.com" { print $1 }')"
assert_eq "sweep.sh: .co over whois -> REGISTERED" "REGISTERED" \
	"$(printf '%s\n' "$body" | awk -F'\t' '$2 == "google-taken.co" { print $1 }')"
assert_eq "sweep.sh: Nominet .uk -> REGISTERED" "REGISTERED" \
	"$(printf '%s\n' "$body" | awk -F'\t' '$2 == "google-taken.uk" { print $1 }')"
assert_eq "sweep.sh: an unusable name becomes a visible ERROR row" "ERROR" \
	"$(printf '%s\n' "$body" | awk -F'\t' '$2 == "-illegal-.com" { print $1 }')"
assert_contains "sweep.sh names the registry group that answered" "whois:whois.registry.co" "$SWEEP_OUT"
assert_contains "sweep.sh used whois.registry.co for .co" "whois.registry.co" "$(cat "$WHOIS_LOG")"
assert_not_contains "sweep.sh did NOT guess whois.nic.co" "whois.nic.co" "$(cat "$WHOIS_LOG")"
assert_no_word "sweep.sh never prints AVAILABLE" "AVAILABLE" "$SWEEP_OUT"
assert_contains "sweep.sh reminds the reader that UNREGISTERED is not AVAILABLE" \
	"UNREGISTERED is not AVAILABLE" "$ERR"

try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_RDAP_RETRIES=1 bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 1 --no-header \
	"$TMPDIR_T/sweep-in.txt"
assert_not_contains "sweep.sh --no-header omits the header" "# status" "$OUT"
assert_eq "sweep.sh -q keeps stdout to the rows themselves" "7" "$(printf '%s\n' "$OUT" | grep -c .)"

# --dry-run must plan without probing anything at all.
: >"$CURL_LOG"
: >"$WHOIS_LOG"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_CURL_LOG="$CURL_LOG" DS_TEST_WHOIS_LOG="$WHOIS_LOG" \
	bash "$SCRIPTS_DIR/sweep.sh" --dry-run --no-progress "$TMPDIR_T/sweep-in.txt"
assert_rc "sweep.sh --dry-run exits 0" 0 "$RC"
assert_contains "sweep.sh --dry-run reports the work plan" "work plan by registry" "$ERR"
assert_eq "sweep.sh --dry-run probes nothing" "0" "$(wc -l <"$CURL_LOG" | tr -d ' ')"

# Work is grouped by registry endpoint, so one angry registry cannot stall the
# others. A .com-only sweep must plan exactly one group.
printf 'free-a.com\nfree-b.com\nfree-c.com\n' >"$TMPDIR_T/sweep-com.txt"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	bash "$SCRIPTS_DIR/sweep.sh" --dry-run --no-progress "$TMPDIR_T/sweep-com.txt"
assert_eq "sweep.sh groups a single-registry list into one group" "1" \
	"$(printf '%s\n' "$ERR" | grep -c 'name(s)  *[0-9]* slot')"

# A registry that throttles once and then answers must be RETRIED, not written
# off. This is the whole point of the retry queue, and the reason a sweep does
# not report a 429 as a finding.
STATE="$TMPDIR_T/state"
mkdir -p "$STATE"
printf 'flaky-one.com\n' >"$TMPDIR_T/sweep-flaky.txt"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_STATE="$STATE" DS_RDAP_RETRIES=1 DS_RDAP_BACKOFF_BASE=1 \
	bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 2 --no-fallback \
	"$TMPDIR_T/sweep-flaky.txt"
assert_rc "sweep.sh exits 0 when a retry rescues the only name" 0 "$RC"
assert_eq "a name rate-limited once is retried, not reported as a finding" "UNREGISTERED" \
	"$(printf '%s\n' "$OUT" | awk -F'\t' '$2 == "flaky-one.com" { print $1 }')"
assert_eq "and the retry is counted in the attempts column" "2" \
	"$(printf '%s\n' "$OUT" | awk -F'\t' '$2 == "flaky-one.com" { print $5 }')"
assert_contains "and the first failure is still visible in the detail" "rdap:429" "$OUT"

# The final round falls back from RDAP to whois, exactly as a single-name probe
# does: a throttled RDAP endpoint must never be the last word.
rm -f "$STATE"/*.calls
printf 'flaky-two.com\n' >"$TMPDIR_T/sweep-flaky2.txt"
: >"$WHOIS_LOG"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_STATE="$STATE" DS_TEST_WHOIS_LOG="$WHOIS_LOG" \
	DS_RDAP_RETRIES=1 DS_RDAP_BACKOFF_BASE=1 \
	bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 2 "$TMPDIR_T/sweep-flaky2.txt"
assert_contains "the final retry round is routed to whois" "whois:" "$OUT"
assert_ge "and whois really was queried" 1 "$(wc -l <"$WHOIS_LOG" | tr -d ' ')"

# The retry queue is bounded, and going over the bound is not allowed to be
# silent: the excess must come back as ERROR rows that say why.
rm -f "$STATE"/*.calls
printf 'flaky-a.com\nflaky-b.com\nflaky-c.com\n' >"$TMPDIR_T/sweep-cap.txt"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_STATE="$STATE" DS_RDAP_RETRIES=1 DS_RDAP_BACKOFF_BASE=1 \
	bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 2 --no-fallback --retry-cap 1 \
	"$TMPDIR_T/sweep-cap.txt"
assert_rc "sweep.sh exits 2 when capped names stay ERROR" 2 "$RC"
assert_eq "the retry cap still emits a row for every name" "3" \
	"$(printf '%s\n' "$OUT" | grep -vc '^#')"
assert_eq "one name fits under the cap and is rescued" "1" \
	"$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "UNREGISTERED"' | grep -c .)"
assert_eq "the names over the cap are ERROR rows" "2" \
	"$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "ERROR"' | grep -c .)"
assert_contains "and each of them says it was never retried" "retry queue cap" "$OUT"

# "Nothing is ever silently dropped" has to hold under real parallelism, not
# just for a handful of names: 120 names across 16 workers appending to one
# results file, and the row count must still be exactly 120, in input order.
awk 'BEGIN { for (i = 1; i <= 120; i++) printf "vol%03d-%s.com\n", i, (i % 3 == 0 ? "taken" : "free") }' \
	>"$TMPDIR_T/sweep-vol.txt"
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_RDAP_RETRIES=1 bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 1 -p 16 \
	"$TMPDIR_T/sweep-vol.txt"
assert_rc "a 120-name parallel sweep exits 0" 0 "$RC"
printf '%s\n' "$OUT" | grep -v '^#' >"$TMPDIR_T/vol.tsv"
assert_eq "every name got exactly one row" "120" "$(grep -c . "$TMPDIR_T/vol.tsv")"
assert_eq "and no name appears twice" "120" "$(cut -f2 "$TMPDIR_T/vol.tsv" | sort -u | grep -c .)"
assert_eq "input order survives 16 concurrent workers" "0" \
	"$(cut -f2 "$TMPDIR_T/vol.tsv" | paste - "$TMPDIR_T/sweep-vol.txt" | awk -F'\t' '$1 != $2' | grep -c .)"
assert_eq "no row was truncated or interleaved by a concurrent append" "0" \
	"$(awk -F'\t' 'NF != 6' "$TMPDIR_T/vol.tsv" | grep -c .)"
assert_eq "the registered third are REGISTERED" "40" \
	"$(awk -F'\t' '$1 == "REGISTERED"' "$TMPDIR_T/vol.tsv" | grep -c .)"
assert_eq "the rest are UNREGISTERED" "80" \
	"$(awk -F'\t' '$1 == "UNREGISTERED"' "$TMPDIR_T/vol.tsv" | grep -c .)"
assert_no_word "and none of the 120 is called AVAILABLE" "AVAILABLE" "$OUT"

# -o writes atomically to a file rather than stdout.
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_RDAP_RETRIES=1 bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 1 \
	-o "$TMPDIR_T/swept.tsv" "$TMPDIR_T/sweep-com.txt"
assert_rc "sweep.sh -o exits 0 when every name resolved" 0 "$RC"
assert_eq "sweep.sh -o writes nothing to stdout" "" "$OUT"
assert_eq "sweep.sh -o writes one row per name" "3" "$(rows "$TMPDIR_T/swept.tsv")"

# ---------------------------------------------------------------------------
# SECTION 13: offline end-to-end - bootstrap.sh
# ---------------------------------------------------------------------------

section "bootstrap.sh end-to-end (stubbed downloads)"

BS_DATA="$TMPDIR_T/bs-data"
mkdir -p "$BS_DATA"
: >"$CURL_LOG"

try env PATH="$STUB_PATH" DS_DATA_DIR="$BS_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_CURL_LOG="$CURL_LOG" bash "$SCRIPTS_DIR/bootstrap.sh" --force
assert_rc "bootstrap.sh --force exits 0 and passes its own verification" 0 "$RC"
assert_file "bootstrap.sh caches the raw IANA payload" "$BS_DATA/rdap-bootstrap.json"
assert_file "bootstrap.sh caches the raw Porkbun payload" "$BS_DATA/porkbun-pricing.json"
assert_file "bootstrap.sh builds the RDAP index" "$BS_DATA/rdap-endpoints.tsv"
assert_file "bootstrap.sh builds the price table" "$BS_DATA/tld-prices.tsv"
assert_file "bootstrap.sh seeds the whois server table" "$BS_DATA/whois-servers.tsv"
assert_file "bootstrap.sh seeds the reputation table" "$BS_DATA/tld-flags.tsv"
assert_file "bootstrap.sh writes the overrides template" "$BS_DATA/rdap-overrides.tsv"
assert_not_contains "the overrides template does not divert RDAP-only .info to WHOIS" \
	$'info\tWHOIS' "$(cat "$BS_DATA/rdap-overrides.tsv")"

assert_ge "the RDAP index has a sane row count (>=1000 TLDs)" 1000 "$(rows "$BS_DATA/rdap-endpoints.tsv")"
assert_ge "the price table has a sane row count (>=500 TLDs)" 500 "$(rows "$BS_DATA/tld-prices.tsv")"
assert_ge "the whois seeds are all present" 6 "$(rows "$BS_DATA/whois-servers.tsv")"
assert_ge "the reputation table is seeded" 20 "$(rows "$BS_DATA/tld-flags.tsv")"

assert_eq "the built RDAP index maps com to its own registry endpoint" \
	"https://rdap.verisign.test/com/v1" "$(lib_eval_in "$BS_DATA" 'ds_rdap_endpoint com')"
assert_eq "a multi-TLD bootstrap entry maps every TLD it lists" \
	"https://rdap.verisign.test/com/v1" "$(lib_eval_in "$BS_DATA" 'ds_rdap_endpoint net')"
assert_eq "the built price table keeps renewal in column 2" "52.01" \
	"$(lib_eval_in "$BS_DATA" 'ds_std_price bar' | cut -f2)"
assert_eq "bootstrap seeds .co as whois.registry.co" "whois.registry.co" \
	"$(awk -F'\t' '$1 == "co" { print $2 }' "$BS_DATA/whois-servers.tsv")"
assert_eq "bootstrap seeds .io so lib.sh can read it back" "whois.nic.io" \
	"$(lib_eval_in "$BS_DATA" 'ds_whois_server io')"

# price-join receives the registry TLD from sweep.sh, but registrars can price
# a longer suffix independently. It must use co.uk's price while retaining uk's
# registry-level reputation flags.
printf 'UNREGISTERED\tshortlist.co.uk\tuk\t-\t1\trdap:404\n' >"$TMPDIR_T/co-uk-sweep.tsv"
try env DS_DATA_DIR="$BS_DATA" bash "$SCRIPTS_DIR/price-join.sh" --no-sort \
	"$TMPDIR_T/co-uk-sweep.tsv"
assert_rc "price-join.sh handles a multi-label priced suffix" 0 "$RC"
assert_eq "price-join.sh prefers co.uk pricing over uk pricing" \
	$'shortlist.co.uk\t3.00\t4.00\tNO_PREMIUM_REGISTRY' "$OUT"

# lib.sh must still refuse the poisoned endpoints the bootstrap file contains.
lib_eval_in "$BS_DATA" 'ds_rdap_endpoint zzz >/dev/null'
assert_rc "a bootstrapped rdap.org endpoint is still refused" 1 "$?"
lib_eval_in "$BS_DATA" 'ds_rdap_endpoint info >/dev/null'
assert_rc "a bootstrapped Identity Digital endpoint is used, not refused" 0 "$?"

for alias_name in tldmap.tsv prices.tsv reputation.tsv; do
	if [ -L "$BS_DATA/$alias_name" ] && [ -s "$BS_DATA/$alias_name" ]; then
		pass "alias data/$alias_name is a symlink that resolves"
	else
		fail "alias data/$alias_name is a symlink that resolves" "not a resolving symlink"
	fi
done

# Idempotence: a second run must not re-download and must not shrink anything.
before=$(rows "$BS_DATA/rdap-endpoints.tsv")
: >"$CURL_LOG"
try env PATH="$STUB_PATH" DS_DATA_DIR="$BS_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_CURL_LOG="$CURL_LOG" bash "$SCRIPTS_DIR/bootstrap.sh" -q
assert_rc "a second bootstrap.sh run exits 0" 0 "$RC"
assert_eq "a fresh cache is not re-downloaded" "0" "$(wc -l <"$CURL_LOG" | tr -d ' ')"
assert_eq "a second run does not shrink the RDAP index" "$before" "$(rows "$BS_DATA/rdap-endpoints.tsv")"

# --rebuild is the offline path: rebuild the tables from cached JSON, no network.
rm -f "$BS_DATA/rdap-endpoints.tsv" "$BS_DATA/tld-prices.tsv"
: >"$CURL_LOG"
try env PATH="$STUB_PATH" DS_DATA_DIR="$BS_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_TEST_CURL_LOG="$CURL_LOG" bash "$SCRIPTS_DIR/bootstrap.sh" --rebuild -q
assert_rc "bootstrap.sh --rebuild exits 0" 0 "$RC"
assert_eq "bootstrap.sh --rebuild touches the network not at all" "0" "$(wc -l <"$CURL_LOG" | tr -d ' ')"
assert_eq "bootstrap.sh --rebuild restores the RDAP index" "$before" "$(rows "$BS_DATA/rdap-endpoints.tsv")"

# A hand-edited reputation row must survive a re-run: the file is documented as
# the user-editable extension point.
printf 'mytld\tMY_OWN_FLAG\n' >>"$BS_DATA/tld-flags.tsv"
try env PATH="$STUB_PATH" DS_DATA_DIR="$BS_DATA" DS_TEST_FIXTURES="$FIX" \
	bash "$SCRIPTS_DIR/bootstrap.sh" -q
assert_contains "bootstrap.sh keeps hand-edited reputation rows" "MY_OWN_FLAG" \
	"$(cat "$BS_DATA/tld-flags.tsv")"
assert_word "and ds_tld_flags picks up the user's own flag" "MY_OWN_FLAG" \
	"$(lib_eval_in "$BS_DATA" 'ds_tld_flags mytld')"

# A truncated or hijacked download must never replace a good cache.
mkdir -p "$TMPDIR_T/badfix"
printf '<html>captive portal</html>' >"$TMPDIR_T/badfix/dns.json"
printf '<html>captive portal</html>' >"$TMPDIR_T/badfix/pricing.json"
try env PATH="$STUB_PATH" DS_DATA_DIR="$BS_DATA" DS_TEST_FIXTURES="$TMPDIR_T/badfix" \
	bash "$SCRIPTS_DIR/bootstrap.sh" --force -q
assert_rc "bootstrap.sh refuses a payload that is not the expected shape" 1 "$RC"
assert_eq "and leaves the good cache untouched" "$before" "$(rows "$BS_DATA/rdap-endpoints.tsv")"

# ---------------------------------------------------------------------------
# SECTION 14: quote.sh - the only script allowed to say AVAILABLE
# ---------------------------------------------------------------------------

section "quote.sh: the premium rule"

QFIX="$TMPDIR_T/quotes"
mkdir -p "$QFIX"

# The measured example this whole toolkit exists because of: shed.link probed
# as unregistered and quoted $819.27/yr against a $7.72 list price.
cat >"$QFIX/shed.link.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"819.27",
"regularPrice":"819.27","firstYearPromo":"no","premium":"no","minDuration":1,
"additional":{"renewal":{"price":"819.27","regularPrice":"819.27"},
"transfer":{"price":"819.27","regularPrice":"819.27"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

cat >"$QFIX/plainname.link.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"7.72",
"regularPrice":"7.72","firstYearPromo":"no","premium":"no","minDuration":1,
"additional":{"renewal":{"price":"7.72","regularPrice":"7.72"},
"transfer":{"price":"7.72","regularPrice":"7.72"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

# Priced in line with the list, but the registry itself says premium.
cat >"$QFIX/flagged.link.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"9.00",
"regularPrice":"9.00","firstYearPromo":"no","premium":"yes","minDuration":1,
"additional":{"renewal":{"price":"9.00","regularPrice":"9.00"},
"transfer":{"price":"9.00","regularPrice":"9.00"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

# Offered, but with no price: the registrar has nothing to sell.
cat >"$QFIX/noprice.link.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"",
"regularPrice":"","firstYearPromo":"no","premium":"no","minDuration":1,
"additional":{}},"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

# Cheap first year, brutal renewal: the renewal must drive the verdict.
cat >"$QFIX/trap.bar.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"2.57",
"regularPrice":"2.57","firstYearPromo":"yes","premium":"no","minDuration":1,
"additional":{"renewal":{"price":"260.00","regularPrice":"260.00"},
"transfer":{"price":"260.00","regularPrice":"260.00"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

# Porkbun prices co.uk independently from bare uk. The fixture price table has
# no uk row, so this quote is only recognised as premium when the registrable
# two-label suffix supplies the correct standard-price baseline.
cat >"$QFIX/priced.co.uk.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"30.00",
"regularPrice":"30.00","firstYearPromo":"no","premium":"no","minDuration":1,
"additional":{"renewal":{"price":"40.00","regularPrice":"40.00"},
"transfer":{"price":"30.00","regularPrice":"30.00"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

cat >"$QFIX/sold.link.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"no","type":"registration","price":"7.72",
"regularPrice":"7.72","firstYearPromo":"no","premium":"no","minDuration":1,
"additional":{"renewal":{"price":"7.72","regularPrice":"7.72"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

# A TLD with no list price at all: the ratio rule cannot fire, so the verdict
# rests on the registrar alone and the row must say the comparison was not
# possible rather than implying the price was checked against a baseline.
cat >"$QFIX/unknown.zip.json" <<'EOF'
{"status":"SUCCESS","response":{"avail":"yes","type":"registration","price":"500.00",
"regularPrice":"500.00","firstYearPromo":"no","premium":"no","minDuration":1,
"additional":{"renewal":{"price":"500.00","regularPrice":"500.00"}}},
"limits":{"TTL":10,"limit":1},"ttlRemaining":0}
EOF

# Same "not for sale" answer as sold.link. The difference is what the REGISTRY
# says, and that difference is the whole RESERVED/REGISTERED distinction:
#   reserved-name.link  probes UNREGISTERED -> registry-RESERVED
#   taken-name.link     probes REGISTERED   -> simply taken
cp "$QFIX/sold.link.json" "$QFIX/reserved-name.link.json"
cp "$QFIX/sold.link.json" "$QFIX/taken-name.link.json"

quote() { # quote <args...>  - fixtures, no credentials, no network
	try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY \
		PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_QUOTE_FIXTURE_DIR="$QFIX" \
		DS_TEST_FIXTURES="$FIX" DS_QUOTE_DELAY=0 \
		bash "$SCRIPTS_DIR/quote.sh" -o tsv --probe never "$@"
}

quote shed.link plainname.link flagged.link noprice.link trap.bar priced.co.uk sold.link
assert_rc "quote.sh exits 0 when every name got a verdict" 0 "$RC"

assert_eq "a name quoted at 106x its list price is PREMIUM, not AVAILABLE" \
	"PREMIUM" "$(col 2 shed.link "$OUT")"
assert_contains "and the reason is stated: PRICE_OVER_LIST" "PRICE_OVER_LIST" \
	"$(col 10 shed.link "$OUT")"
assert_eq "the premium quote is reported in full" "819.27" "$(col 5 shed.link "$OUT")"
assert_eq "against the TLD's list renewal" "7.72" "$(col 7 shed.link "$OUT")"

assert_eq "a name quoted at list price IS available" "AVAILABLE" "$(col 2 plainname.link "$OUT")"
assert_eq "a registry-flagged premium is PREMIUM even at a normal price" \
	"PREMIUM" "$(col 2 flagged.link "$OUT")"
assert_contains "and says the registry flagged it" "API_PREMIUM" "$(col 10 flagged.link "$OUT")"
assert_eq "offered with no price at all is RESERVED, never AVAILABLE" \
	"RESERVED" "$(col 2 noprice.link "$OUT")"
assert_eq "a cheap first year with a 5x renewal is PREMIUM (renewal decides)" \
	"PREMIUM" "$(col 2 trap.bar "$OUT")"
assert_contains "and the first-year promotion is called out" "FIRST_YEAR_PROMO" \
	"$(col 10 trap.bar "$OUT")"
assert_eq "a co.uk quote uses the co.uk list-price baseline" \
	"PREMIUM" "$(col 2 priced.co.uk "$OUT")"
assert_eq "the co.uk renewal baseline is not looked up as bare uk" \
	"9.42" "$(col 7 priced.co.uk "$OUT")"
assert_contains "the multi-label quote records its price comparison" "PRICE_OVER_LIST" \
	"$(col 10 priced.co.uk "$OUT")"
assert_eq "an unsellable name with --probe never is UNAVAILABLE" \
	"UNAVAILABLE" "$(col 2 sold.link "$OUT")"
assert_eq "an unsellable name carries no quoted price" "-" "$(col 3 sold.link "$OUT")"

assert_word "quote.sh IS allowed to print AVAILABLE (with a real quote)" "AVAILABLE" "$OUT"
assert_contains "quote.sh carries the TLD reputation flags through" "RENEWAL_TRAP" \
	"$(col 10 trap.bar "$OUT")"

# Without a list price there is no baseline, so the premium comparison could
# not be made. The row must carry that caveat rather than implying it was.
# (Runs last in this group: it replaces $OUT.)
quote unknown.zip
assert_eq "an unpriced TLD still gets the registrar's answer" "AVAILABLE" "$(col 2 unknown.zip "$OUT")"
assert_contains "but says the list-price comparison was impossible" "NO_PRICE_DATA" \
	"$(col 10 unknown.zip "$OUT")"
assert_eq "and shows no list price it does not have" "-" "$(col 7 unknown.zip "$OUT")"

# --probe auto: when the registrar will not sell a name, a registry probe is
# what separates "someone else owns it" from "the registry is sitting on it".
# This is the distinction naive tools collapse, and it needs both sources.
try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY PATH="$STUB_PATH" \
	DS_DATA_DIR="$E2E_DATA" DS_QUOTE_FIXTURE_DIR="$QFIX" DS_TEST_FIXTURES="$FIX" \
	DS_QUOTE_DELAY=0 DS_RDAP_RETRIES=1 \
	bash "$SCRIPTS_DIR/quote.sh" -o tsv --probe auto reserved-name.link taken-name.link
assert_rc "quote.sh --probe auto exits 0" 0 "$RC"
assert_eq "unregistered + not for sale = RESERVED" "RESERVED" "$(col 2 reserved-name.link "$OUT")"
assert_contains "and says exactly why" "unregistered but not for sale" \
	"$(col 11 reserved-name.link "$OUT")"
assert_eq "registered + not for sale = REGISTERED" "REGISTERED" "$(col 2 taken-name.link "$OUT")"
assert_no_word "neither is ever called AVAILABLE" "AVAILABLE" "$OUT"

# A name that is already known to be registered must not cost a quote call.
try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY PATH="$STUB_PATH" \
	DS_DATA_DIR="$E2E_DATA" DS_QUOTE_FIXTURE_DIR="$QFIX" DS_QUOTE_DELAY=0 \
	bash -c 'printf "%s\n" "REGISTERED|already.link|rdap:200" | bash "$1" -o tsv --probe never -' \
	_ "$SCRIPTS_DIR/quote.sh"
assert_eq "quote.sh trusts a piped REGISTERED status" "REGISTERED" "$(col 2 already.link "$OUT")"
assert_contains "and says it spent no quote on it" "no quote spent" "$(col 11 already.link "$OUT")"

# check.sh --quiet output must pipe straight into quote.sh.
try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY PATH="$STUB_PATH" \
	DS_DATA_DIR="$E2E_DATA" DS_QUOTE_FIXTURE_DIR="$QFIX" DS_QUOTE_DELAY=0 \
	bash -c 'printf "%s\t%s\t%s\t%s\t%s\t%s\n" plainname.link UNREGISTERED 7.72 7.72 - "rdap:404" | bash "$1" -o tsv --probe never -' \
	_ "$SCRIPTS_DIR/quote.sh"
assert_eq "quote.sh understands check.sh --quiet rows" "AVAILABLE" "$(col 2 plainname.link "$OUT")"

# JSON output for the pipeline's machine consumers.
quote -o json plainname.link shed.link
try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY PATH="$STUB_PATH" \
	DS_DATA_DIR="$E2E_DATA" DS_QUOTE_FIXTURE_DIR="$QFIX" DS_QUOTE_DELAY=0 \
	bash "$SCRIPTS_DIR/quote.sh" -o json --probe never plainname.link shed.link
if printf '%s' "$OUT" | jq -e -s . >/dev/null 2>&1; then
	pass "quote.sh -o json emits valid JSONL"
else
	fail "quote.sh -o json emits valid JSONL" "$(printf '%s' "$OUT" | head -c 300)"
fi
assert_eq "quote.sh JSON verdict for a premium name" "PREMIUM" \
	"$(printf '%s' "$OUT" | jq -r -s '.[] | select(.domain == "shed.link") | .verdict')"
assert_eq "quote.sh JSON carries the numeric renewal quote" "819.27" \
	"$(printf '%s' "$OUT" | jq -r -s '.[] | select(.domain == "shed.link") | .quoted_renewal')"

# A name with no fixture is an API failure, and must be an ERROR, not a guess.
quote missing-fixture.link
assert_eq "an unanswered quote is ERROR, never AVAILABLE" "ERROR" "$(col 2 missing-fixture.link "$OUT")"
assert_rc "quote.sh exits 1 when a name ends in ERROR" 1 "$RC"

section "quote.sh: credentials and validation"

try env -u PORKBUN_API_KEY -u PORKBUN_SECRET_KEY DS_DATA_DIR="$E2E_DATA" \
	bash "$SCRIPTS_DIR/quote.sh" example.com
assert_rc "quote.sh exits 3 without credentials" 3 "$RC"
assert_contains "and explains how to get a key" "porkbun.com/account/api" "$ERR"
assert_no_word "and never claims a name is AVAILABLE without one" "AVAILABLE" "$OUT"

try env PORKBUN_API_KEY=pk1_secretvalue PORKBUN_SECRET_KEY=sk1_secretvalue \
	DS_DATA_DIR="$E2E_DATA" DS_QUOTE_FIXTURE_DIR="$QFIX" DS_QUOTE_DELAY=0 \
	bash "$SCRIPTS_DIR/quote.sh" -o tsv --probe never shed.link
assert_not_contains "quote.sh never echoes the API key" "pk1_secretvalue" "$OUT$ERR"
assert_not_contains "quote.sh never echoes the secret key" "sk1_secretvalue" "$OUT$ERR"

try env DS_DATA_DIR="$E2E_DATA" bash "$SCRIPTS_DIR/quote.sh" -o nonsense shed.link
assert_rc "quote.sh rejects an unknown --format" 2 "$RC"
try env DS_DATA_DIR="$E2E_DATA" bash "$SCRIPTS_DIR/quote.sh" --probe sideways shed.link
assert_rc "quote.sh rejects an unknown --probe mode" 2 "$RC"
try env DS_DATA_DIR="$E2E_DATA" bash "$SCRIPTS_DIR/quote.sh" -m 0.5 shed.link
assert_rc "quote.sh rejects a premium multiple below 1" 2 "$RC"

try env DS_QUOTE_NO_MAIN=1 DS_DATA_DIR="$E2E_DATA" \
	bash -c '. "$1"; _dq_verdict yes no 100 100 10 10' _ "$SCRIPTS_DIR/quote.sh"
assert_contains "the premium rule is unit-testable in isolation" "PREMIUM" "$OUT"
try env DS_QUOTE_NO_MAIN=1 DS_DATA_DIR="$E2E_DATA" \
	bash -c '. "$1"; _dq_verdict yes no 10.50 10.50 10 10' _ "$SCRIPTS_DIR/quote.sh"
assert_contains "a small price difference is not a premium" "AVAILABLE" "$OUT"

# ---------------------------------------------------------------------------
# SECTION 15: SKILL.md is safe to load with arguments
# ---------------------------------------------------------------------------
#
# Regression. Skill runners may substitute $0-$9 in a skill body with words from
# invocation arguments, so a bare positional can be silently rewritten at load time.
# SKILL.md previously embedded an awk price-join; invoking
# "/domain-search find an available .com" turned `p[$1] = $2 "\t" $3` into
# `p[an] = available "\t" .com`, and the documented pricing step was corrupt for
# every argument-bearing invocation. Prices written as $2.57 were mangled too.
#
# The fix was to move the awk into scripts/price-join.sh and quote prices as USD.
# Nothing in SKILL.md may reintroduce a bare $<digit>.

section "SKILL.md argument safety"

SKILL_MD="$DS_ROOT_DIR/SKILL.md"
if [ -f "$SKILL_MD" ]; then
	bad=$(grep -n '\$[0-9]' "$SKILL_MD" || true)
	assert_eq "SKILL.md contains no \$<digit> (args would clobber it)" "" "$bad"
	assert_contains "SKILL.md delegates the price-join to a script" \
		"price-join.sh" "$(cat "$SKILL_MD")"
	assert_contains "SKILL.md uses Claude's loaded skill directory" \
		'${CLAUDE_SKILL_DIR}' "$(cat "$SKILL_MD")"
	assert_contains "SKILL.md handles an unexpanded Claude directory under nounset" \
		"CLAUDE_DS='\${CLAUDE_SKILL_DIR}'" "$(cat "$SKILL_MD")"
	assert_contains "SKILL.md accepts Codex's loaded skill directory" \
		'DOMAINSAVER_HOME' "$(cat "$SKILL_MD")"
	resolver_order=$(awk '
		/CODEX_HOME:-\$HOME\/.agents/ { current = NR }
		/DS="\$HOME\/\.codex\/skills\/domain-search"/ { legacy = NR }
		/CLAUDE_CONFIG_DIR:-\$HOME\/\.claude/ { claude = NR }
		END {
			print (current > 0 && legacy > current && claude > legacy) \
				? "agent-first" : "wrong-order"
		}
	' "$SKILL_MD")
	assert_eq "SKILL.md prefers current and legacy agent installs to a Claude fallback" \
		"agent-first" "$resolver_order"
else
	skip "SKILL.md argument safety" "SKILL.md not found"
fi

# ---------------------------------------------------------------------------
# SECTION 16: install.sh
# ---------------------------------------------------------------------------

section "install.sh"

SKILLS="$TMPDIR_T/skills"
mkdir -p "$SKILLS"

try bash "$DS_ROOT_DIR/install.sh" --help
assert_rc "install.sh --help exits 0" 0 "$RC"
assert_contains "install.sh --help is rendered from its usage block" \
	"INSTALL:" "$OUT"
assert_contains "install.sh --help documents the default target" \
	"default: claude" "$OUT"
assert_contains "install.sh --help documents both invocation forms" \
	'Codex:        $domain-search' "$OUT"
assert_contains "install.sh --help documents the Codex path override" \
	"CODEX_HOME" "$OUT"
assert_not_contains "install.sh does not claim slow RDAP registries require WHOIS" \
	"all Identity Digital TLDs" "$(cat "$DS_ROOT_DIR/install.sh")"
assert_contains "install.sh identifies representative no-RDAP dependencies" \
	"no-RDAP TLDs such as .io, .co, .me and .de" "$(cat "$DS_ROOT_DIR/install.sh")"

INSTALL_ALIAS="$TMPDIR_T/domainsaver-install"
ln -s "$DS_ROOT_DIR/install.sh" "$INSTALL_ALIAS"
try bash "$INSTALL_ALIAS" --help
assert_rc "install.sh --help works through a renamed symlink" 0 "$RC"
assert_contains "install.sh --help derives the invoked script name" \
	"domainsaver-install - install the DomainSaver" "$OUT"

try bash "$DS_ROOT_DIR/install.sh" --version
assert_rc "install.sh --version exits 0" 0 "$RC"
assert_contains "install.sh --version names itself" "install.sh 1.2.0" "$OUT"

try bash "$DS_ROOT_DIR/install.sh" --target
assert_rc "install.sh rejects --target without a value" 2 "$RC"
assert_contains "install.sh usage errors include help" "OPTIONS:" "$ERR"

try bash "$DS_ROOT_DIR/install.sh" --prefix
assert_rc "install.sh rejects --prefix without a value" 2 "$RC"

try env CODEX_HOME="$TMPDIR_T/codex-home" HOME="$TMPDIR_T/fake-home" \
	bash "$DS_ROOT_DIR/install.sh" -t codex --dry-run
assert_rc "install.sh accepts the legacy Codex location override" 0 "$RC"
assert_contains "install.sh accepts the short target option" \
	"target:  codex" "$OUT"
assert_contains "install.sh honors CODEX_HOME/skills when explicitly set" \
	"to:   $TMPDIR_T/codex-home/skills/domain-search" "$OUT"

try env -u CODEX_HOME HOME="$TMPDIR_T/modern-codex-home" \
	bash "$DS_ROOT_DIR/install.sh" --target=codex --dry-run
assert_rc "install.sh accepts the current Codex location" 0 "$RC"
assert_contains "install.sh accepts the equals target form" \
	"target:  codex" "$OUT"
assert_contains "install.sh defaults Codex to HOME/.agents/skills" \
	"to:   $TMPDIR_T/modern-codex-home/.agents/skills/domain-search" "$OUT"

LEGACY_HOME="$TMPDIR_T/legacy-codex-home"
mkdir -p "$LEGACY_HOME/.codex/skills/domain-search"
try env -u CODEX_HOME HOME="$LEGACY_HOME" \
	bash "$DS_ROOT_DIR/install.sh" --target codex --force --dry-run
assert_rc "install.sh accepts an existing legacy Codex installation" 0 "$RC"
assert_contains "install.sh keeps updating an existing HOME/.codex skill" \
	"to:   $LEGACY_HOME/.codex/skills/domain-search" "$OUT"

try env CLAUDE_CONFIG_DIR="$TMPDIR_T/claude-config" HOME="$TMPDIR_T/fake-home" \
	bash "$DS_ROOT_DIR/install.sh" --target claude --dry-run
assert_rc "install.sh accepts the Claude Code location" 0 "$RC"
assert_contains "install.sh honors CLAUDE_CONFIG_DIR/skills" \
	"to:   $TMPDIR_T/claude-config/skills/domain-search" "$OUT"

try env -u CLAUDE_CONFIG_DIR HOME="$TMPDIR_T/default-claude-home" \
	bash "$DS_ROOT_DIR/install.sh" --dry-run
assert_rc "install.sh defaults to Claude Code" 0 "$RC"
assert_contains "the default target uses HOME/.claude/skills" \
	"to:   $TMPDIR_T/default-claude-home/.claude/skills/domain-search" "$OUT"

try bash "$DS_ROOT_DIR/install.sh" --target neither --dry-run
assert_rc "install.sh rejects an unknown target" 2 "$RC"
try bash "$DS_ROOT_DIR/install.sh" --target both --prefix "$SKILLS" --dry-run
assert_rc "install.sh rejects one prefix for two targets" 2 "$RC"

# Both destinations must be validated before either is changed. The second
# target deliberately conflicts so these tests fail if processing starts with
# Claude and only discovers the Codex problem after mutating Claude's install.
PREFLIGHT_INSTALL_HOME="$TMPDIR_T/preflight-install-home"
mkdir -p "$PREFLIGHT_INSTALL_HOME/.agents/skills/domain-search"
printf 'keep me\n' >"$PREFLIGHT_INSTALL_HOME/.agents/skills/domain-search/user-file"
try env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$PREFLIGHT_INSTALL_HOME" \
	bash "$DS_ROOT_DIR/install.sh" --target both -q
assert_rc "install.sh preflights both install targets" 1 "$RC"
if [ ! -e "$PREFLIGHT_INSTALL_HOME/.claude/skills/domain-search" ] && \
	[ ! -h "$PREFLIGHT_INSTALL_HOME/.claude/skills/domain-search" ]; then
	pass "a Codex install conflict leaves the Claude destination untouched"
else
	fail "a Codex install conflict leaves the Claude destination untouched" \
		"the Claude target was created before Codex was validated"
fi
assert_file "preflight preserves the conflicting Codex directory" \
	"$PREFLIGHT_INSTALL_HOME/.agents/skills/domain-search/user-file"

PREFLIGHT_UNINSTALL_HOME="$TMPDIR_T/preflight-uninstall-home"
mkdir -p "$PREFLIGHT_UNINSTALL_HOME/.claude/skills" \
	"$PREFLIGHT_UNINSTALL_HOME/.agents/skills/domain-search"
ln -s "$DS_ROOT_DIR" "$PREFLIGHT_UNINSTALL_HOME/.claude/skills/domain-search"
printf 'keep me\n' >"$PREFLIGHT_UNINSTALL_HOME/.agents/skills/domain-search/user-file"
try env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$PREFLIGHT_UNINSTALL_HOME" \
	bash "$DS_ROOT_DIR/install.sh" --target both --uninstall -q
assert_rc "install.sh preflights both uninstall targets" 1 "$RC"
if [ -L "$PREFLIGHT_UNINSTALL_HOME/.claude/skills/domain-search" ]; then
	pass "a Codex uninstall conflict leaves the Claude install untouched"
else
	fail "a Codex uninstall conflict leaves the Claude install untouched" \
		"the Claude link was removed before Codex was validated"
fi

DUAL_HOME="$TMPDIR_T/dual-home"
mkdir -p "$DUAL_HOME"
try env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$DUAL_HOME" \
	bash "$DS_ROOT_DIR/install.sh" --target both -q
assert_rc "install.sh installs for Claude Code and Codex together" 0 "$RC"
if [ -L "$DUAL_HOME/.claude/skills/domain-search" ] && \
	[ -L "$DUAL_HOME/.agents/skills/domain-search" ]; then
	pass "both targets link the shared skill directory"
else
	fail "both targets link the shared skill directory" "one or both host links are missing"
fi
assert_eq "the Claude link points at the checkout" "$DS_ROOT_DIR" \
	"$(cd -P "$DUAL_HOME/.claude/skills/domain-search" 2>/dev/null && pwd)"
assert_eq "the Codex link points at the checkout" "$DS_ROOT_DIR" \
	"$(cd -P "$DUAL_HOME/.agents/skills/domain-search" 2>/dev/null && pwd)"
try env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$DUAL_HOME" \
	bash "$DS_ROOT_DIR/install.sh" --target both --uninstall -q
assert_rc "install.sh uninstalls both targets together" 0 "$RC"
assert_eq "both target installs are removed" "0" \
	"$(find "$DUAL_HOME" -type l -name domain-search | wc -l | tr -d ' ')"

try bash "$DS_ROOT_DIR/install.sh" --prefix "$SKILLS" --dry-run
assert_rc "install.sh --dry-run exits 0" 0 "$RC"
assert_contains "install.sh --dry-run says what it would do" "would link" "$OUT"
assert_eq "install.sh --dry-run changes nothing" "" "$(ls -A "$SKILLS")"

try bash "$DS_ROOT_DIR/install.sh" --prefix "$SKILLS" -q
assert_rc "install.sh installs cleanly" 0 "$RC"
if [ -L "$SKILLS/domain-search" ]; then
	pass "install.sh links the whole skill directory for agent discovery"
else
	fail "install.sh links the whole skill directory for agent discovery" \
		"the installed skill is not a directory symlink"
fi
assert_eq "the linked install points at the checkout" "$DS_ROOT_DIR" \
	"$(cd -P "$SKILLS/domain-search" 2>/dev/null && pwd)"
if [ ! -L "$SKILLS/domain-search/SKILL.md" ]; then
	pass "install.sh leaves SKILL.md as a regular file for Codex discovery"
else
	fail "install.sh leaves SKILL.md as a regular file for Codex discovery" \
		"SKILL.md is individually symlinked and Codex will skip it"
fi
for item in SKILL.md scripts wordlists; do
	if [ -e "$SKILLS/domain-search/$item" ]; then
		pass "install.sh installs $item"
	else
		fail "install.sh installs $item" "missing from the installed skill"
	fi
done

# The installed copy has to actually work from where it landed.
try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
	DS_RDAP_RETRIES=1 bash "$SKILLS/domain-search/scripts/check.sh" -q --no-price \
	zzq7x4-installed.com
assert_eq "the installed check.sh runs from its install location" "UNREGISTERED" \
	"$(col 2 zzq7x4-installed.com "$OUT")"

try bash "$DS_ROOT_DIR/install.sh" --prefix "$SKILLS" -q
assert_rc "install.sh refuses to clobber an existing install" 1 "$RC"
assert_contains "and says --force is how you mean it" "--force" "$ERR"

try bash "$DS_ROOT_DIR/install.sh" --prefix "$SKILLS" --copy --force -q
assert_rc "install.sh --copy --force replaces an install" 0 "$RC"
assert_file "install.sh writes its marker file for a snapshot" \
	"$SKILLS/domain-search/.domainsaver-install"
if [ -f "$SKILLS/domain-search/scripts/lib.sh" ] && [ ! -L "$SKILLS/domain-search/scripts" ]; then
	pass "install.sh --copy takes a real snapshot, not a symlink"
else
	fail "install.sh --copy takes a real snapshot, not a symlink" "scripts/ is still a link"
fi

try bash "$DS_ROOT_DIR/install.sh" --prefix "$SKILLS" --uninstall -q
assert_rc "install.sh --uninstall exits 0" 0 "$RC"
assert_eq "install.sh --uninstall removes everything it installed" "" "$(ls -A "$SKILLS")"

# Versions 1.0 and 1.1 used a real directory with links to each source item.
# Keep that layout in the fixture so a whole-directory symlink cannot mask a
# regression in marker validation.
LEGACY_SOURCE="$TMPDIR_T/legacy-source"
mkdir -p "$LEGACY_SOURCE/scripts"
cp "$DS_ROOT_DIR/SKILL.md" "$LEGACY_SOURCE/SKILL.md"
printf 'keep the checkout\n' >"$LEGACY_SOURCE/scripts/sentinel"

# Build the on-disk layout written by the old symlink-mode installer.
make_legacy_install() {
	local dest version
	dest="$1"
	version="$2"
	mkdir -p "$dest"
	ln -s "$LEGACY_SOURCE/SKILL.md" "$dest/SKILL.md"
	ln -s "$LEGACY_SOURCE/scripts" "$dest/scripts"
	printf 'skill=domain-search\nsource=%s\nmode=symlink\ninstaller=%s\n' \
		"$LEGACY_SOURCE" "$version" >"$dest/.domainsaver-install"
}

for legacy_version in 1.0.0 1.1.0; do
	for upgrade_mode in symlink copy; do
		LEGACY_SKILLS="$TMPDIR_T/legacy-$legacy_version-$upgrade_mode"
		make_legacy_install "$LEGACY_SKILLS/domain-search" "$legacy_version"
		try bash "$DS_ROOT_DIR/install.sh" --prefix "$LEGACY_SKILLS" -q
		assert_rc "$legacy_version upgrade still requires explicit replacement" 1 "$RC"
		assert_contains "$legacy_version symlink marker is recognised" \
			"It looks like an existing DomainSaver install" "$ERR"
		assert_file "refused $legacy_version upgrade preserves its marker" \
			"$LEGACY_SKILLS/domain-search/.domainsaver-install"

		try bash "$DS_ROOT_DIR/install.sh" --prefix "$LEGACY_SKILLS" "--$upgrade_mode" --force -q
		assert_rc "$legacy_version upgrades to $upgrade_mode mode" 0 "$RC"
		if [ "$upgrade_mode" = symlink ]; then
			assert_eq "legacy upgrade links the whole skill to the current checkout" \
				"$DS_ROOT_DIR" "$(readlink "$LEGACY_SKILLS/domain-search")"
		else
			assert_contains "legacy upgrade writes a copy marker" "mode=copy" \
				"$(cat "$LEGACY_SKILLS/domain-search/.domainsaver-install")"
		fi
		assert_file "$legacy_version upgrade preserves the old source files" \
			"$LEGACY_SOURCE/scripts/sentinel"
	done

	LEGACY_SKILLS="$TMPDIR_T/legacy-$legacy_version-uninstall"
	make_legacy_install "$LEGACY_SKILLS/domain-search" "$legacy_version"
	try bash "$DS_ROOT_DIR/install.sh" --prefix "$LEGACY_SKILLS" --uninstall -q
	assert_rc "$legacy_version symlink install uninstalls without force" 0 "$RC"
	assert_eq "$legacy_version uninstall removes the installation directory" \
		"" "$(ls -A "$LEGACY_SKILLS")"
	assert_file "$legacy_version uninstall preserves the linked source files" \
		"$LEGACY_SOURCE/scripts/sentinel"
	assert_file "$legacy_version uninstall preserves the linked skill" \
		"$LEGACY_SOURCE/SKILL.md"
done

# Accepting legacy markers must not weaken ownership checks for other files.
INVALID_SKILLS="$TMPDIR_T/invalid-marker-skills"
mkdir -p "$INVALID_SKILLS/domain-search"
printf 'keep me\n' >"$INVALID_SKILLS/domain-search/user-file"
for invalid_marker in \
	'mode=symlink' \
	'skill=another-skill|mode=symlink' \
	'skill=domain-search-extra|mode=symlink' \
	'skill=domain-search' \
	'skill=domain-search|mode=unknown' \
	'skill=domain-search|mode=symlink-extra'; do
	printf '%s\n' "$invalid_marker" | tr '|' '\n' \
		>"$INVALID_SKILLS/domain-search/.domainsaver-install"
	try bash "$DS_ROOT_DIR/install.sh" --prefix "$INVALID_SKILLS" --uninstall -q
	assert_rc "uninstall rejects invalid marker: $invalid_marker" 1 "$RC"
	assert_file "invalid marker leaves user files untouched: $invalid_marker" \
		"$INVALID_SKILLS/domain-search/user-file"
done

# A skill name is public metadata, not an ownership marker. An unrelated real
# directory must survive uninstall even if its SKILL.md uses the same name and
# it contains a file with the install marker's filename.
FOREIGN_SKILLS="$TMPDIR_T/foreign-skills"
mkdir -p "$FOREIGN_SKILLS/domain-search"
printf '%s\n' '---' 'name: domain-search' '---' >"$FOREIGN_SKILLS/domain-search/SKILL.md"
printf 'not a DomainSaver marker\n' >"$FOREIGN_SKILLS/domain-search/.domainsaver-install"
printf 'keep me\n' >"$FOREIGN_SKILLS/domain-search/user-file"
try bash "$DS_ROOT_DIR/install.sh" --prefix "$FOREIGN_SKILLS" --uninstall -q
assert_rc "install.sh refuses to uninstall an unmarked real directory" 1 "$RC"
assert_file "uninstall preserves files it cannot prove it owns" \
	"$FOREIGN_SKILLS/domain-search/user-file"
assert_contains "uninstall explains the ownership check" \
	"no valid .domainsaver-install marker" "$ERR"

# ---------------------------------------------------------------------------
# SECTION 16: bash 3.2 portability
# ---------------------------------------------------------------------------

section "bash 3.2 portability"

if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
	try env DS_DATA_DIR="$TMPDIR_T/empty-data" /bin/bash "$SCRIPTS_DIR/generate.sh" --two --tld uk
	assert_eq "generate.sh runs under bash 3.2" "676" "$(printf '%s\n' "$OUT" | grep -c .)"

	try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
		DS_RDAP_RETRIES=1 /bin/bash "$SCRIPTS_DIR/check.sh" -q zzq7x4-nope.com
	assert_eq "check.sh runs under bash 3.2" "UNREGISTERED" "$(col 2 zzq7x4-nope.com "$OUT")"

	try env PATH="$STUB_PATH" DS_DATA_DIR="$E2E_DATA" DS_TEST_FIXTURES="$FIX" \
		DS_RDAP_RETRIES=1 /bin/bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress -r 1 \
		"$TMPDIR_T/sweep-com.txt"
	assert_eq "sweep.sh runs under bash 3.2" "3" "$(printf '%s\n' "$OUT" | grep -vc '^#')"
else
	skip "bash 3.2 portability" "no bash 3.x at /bin/bash on this host"
fi

# ---------------------------------------------------------------------------
# SECTION 17: network (opt-in)
# ---------------------------------------------------------------------------

section "network"

NET_OK=0
if [ "$SKIP_NETWORK" = "1" ]; then
	skip "all network tests" "DS_SKIP_NETWORK=1"
elif ! command -v curl >/dev/null 2>&1; then
	skip "all network tests" "curl is not installed"
elif ! curl -sS --connect-timeout 8 --max-time 20 -o /dev/null \
	https://data.iana.org/rdap/dns.json 2>/dev/null; then
	skip "all network tests" "data.iana.org is unreachable from here"
else
	NET_OK=1
fi

if [ "$NET_OK" = "1" ]; then
	NET_DATA="$TMPDIR_T/net-data"
	mkdir -p "$NET_DATA"

	# --- bootstrap against the real upstreams --------------------------
	try env DS_DATA_DIR="$NET_DATA" bash "$SCRIPTS_DIR/bootstrap.sh" --force -q
	assert_rc "bootstrap.sh --force against the real upstreams exits 0" 0 "$RC"
	assert_ge "the real IANA bootstrap yields >=1000 TLDs" 1000 "$(rows "$NET_DATA/rdap-endpoints.tsv")"
	assert_ge "the real Porkbun list yields >=500 priced TLDs" 500 "$(rows "$NET_DATA/tld-prices.tsv")"
	assert_contains "the real RDAP index resolves .com to an https endpoint" "https://" \
		"$(lib_eval_in "$NET_DATA" 'ds_rdap_endpoint com')"

	# Real prices: renewal is the number that matters, and .bar is the
	# canonical trap (cheap to register, brutal to renew).
	barprice=$(lib_eval_in "$NET_DATA" 'ds_std_price bar')
	if [ -n "$barprice" ]; then
		barreg=$(printf '%s' "$barprice" | cut -f1)
		barren=$(printf '%s' "$barprice" | cut -f2)
		if awk -v r="$barreg" -v n="$barren" 'BEGIN { exit !(n + 0 > r + 0 && n + 0 > 20) }'; then
			pass "live pricing: .bar renewal ($barren) is the trap, not the registration ($barreg)"
		else
			fail "live pricing: .bar renewal is the trap" "reg=$barreg renewal=$barren"
		fi
		assert_eq "live pricing: ds_std_price column 2 matches the payload's renewal" \
			"$(jq -r '.pricing.bar.renewal' "$NET_DATA/porkbun-pricing.json")" "$barren"
		assert_eq "live pricing: ds_std_price column 1 matches the payload's registration" \
			"$(jq -r '.pricing.bar.registration' "$NET_DATA/porkbun-pricing.json")" "$barreg"
	else
		fail "live pricing: .bar is in the Porkbun price list" "ds_std_price bar returned nothing"
	fi

	net() {
		try env DS_DATA_DIR="$NET_DATA" bash "$SCRIPTS_DIR/check.sh" "$@"
	}

	# --- a known-registered name ---------------------------------------
	net -q google.com
	assert_eq "check.sh reports google.com as REGISTERED" "REGISTERED" "$(col 2 google.com "$OUT")"

	# --- a known-unregistered name -------------------------------------
	NONSENSE="zzq7x4v-domainsaver-$$-$(date +%s).com"
	net -q "$NONSENSE"
	assert_eq "check.sh reports $NONSENSE as UNREGISTERED" "UNREGISTERED" "$(col 2 "$NONSENSE" "$OUT")"
	assert_no_word "check.sh never prints AVAILABLE for a live unregistered name" "AVAILABLE" "$OUT"

	net --json "$NONSENSE"
	assert_no_word "check.sh --json never prints AVAILABLE either" "AVAILABLE" "$OUT"
	assert_eq "check.sh --json leaves live purchasability unknown" "null" \
		"$(printf '%s' "$OUT" | jq -r '.results[0].purchasable')"

	# --- the whois fallback, and the .co server regression -------------
	assert_eq "live: .co still resolves to whois.registry.co" "whois.registry.co" \
		"$(lib_eval_in "$NET_DATA" 'ds_whois_server co')"

	try env DS_DATA_DIR="$NET_DATA" DS_QUIET=1 \
		bash -c '. "$1"; ds_probe "$2"' _ "$LIB_SH" google.co
	assert_contains "live: google.co is answered over whois" "whois:whois.registry.co" "$OUT"
	assert_contains "live: google.co is REGISTERED" "REGISTERED|google.co" "$OUT"

	try env DS_DATA_DIR="$NET_DATA" DS_QUIET=1 \
		bash -c '. "$1"; ds_probe "$2"' _ "$LIB_SH" "zzq7x4v-domainsaver-$$.co"
	assert_contains "live: an absent .co name is UNREGISTERED over whois" "UNREGISTERED" "$OUT"

	# --- Nominet's own dialect, against the real server ----------------
	if command -v whois >/dev/null 2>&1; then
		try env DS_DATA_DIR="$NET_DATA" DS_QUIET=1 \
			bash -c '. "$1"; ds_probe_whois "$2" whois.nic.uk' _ "$LIB_SH" google.co.uk
		assert_contains "live: Nominet 'Registered on:' is REGISTERED" "REGISTERED|google.co.uk" "$OUT"

		try env DS_DATA_DIR="$NET_DATA" DS_QUIET=1 \
			bash -c '. "$1"; ds_probe_whois "$2" whois.nic.uk' _ "$LIB_SH" \
			"zzq7x4v-domainsaver-$$.co.uk"
		assert_contains "live: Nominet 'No match for' is UNREGISTERED" "UNREGISTERED" "$OUT"
	else
		skip "live Nominet whois" "whois is not installed"
	fi

	# --- a small real sweep --------------------------------------------
	printf 'google.com\nzzq7x4v-domainsaver-%s.com\ngoogle.co\n' "$$" >"$TMPDIR_T/net-sweep.txt"
	try env DS_DATA_DIR="$NET_DATA" bash "$SCRIPTS_DIR/sweep.sh" -q --no-progress \
		-p 4 "$TMPDIR_T/net-sweep.txt"
	assert_rc "a live sweep exits 0" 0 "$RC"
	assert_eq "a live sweep emits one row per name" "3" "$(printf '%s\n' "$OUT" | grep -vc '^#')"
	assert_no_word "a live sweep never prints AVAILABLE" "AVAILABLE" "$OUT"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

printf '\n---\n%d run, %d failed, %d skipped\n' "$RUN" "$FAILED" "$SKIPPED"
if [ "$FAILED" -ne 0 ]; then
	printf 'FAILED\n'
	exit 1
fi
printf 'PASSED\n'
exit 0
