#!/usr/bin/env bash
# shellcheck shell=bash
#
# generate.sh - DomainSaver candidate name generator.
#
# Emits candidate domain names on stdout, one per line. Nothing in this file
# touches the network: generating names is free, CHECKING them is what costs
# you. Every line this script prints is one future RDAP or whois query against
# a registry that rate-limits, so the count is reported on stderr and a large
# run is warned about.
#
# A name that comes out of here is a CANDIDATE and nothing more. Even after a
# probe returns UNREGISTERED it may be registry-reserved or premium-priced -
# see the header of lib.sh for why "unregistered" and "purchasable" are
# different things, and why only a real quote may promote one to the other.
#
# DESIGN CONSTRAINTS (shared with lib.sh; deliberate, do not "modernise" away):
#   * Portable to bash 3.2 (the /bin/bash macOS ships). No associative arrays,
#     no `declare -A`, no `readarray`, no `${var^^}`. Lookup and cross-product
#     work is done in awk, which is both portable and much faster here.
#   * POSIX-ish external tools only: awk, tr, cat. No GNU-only flags, and never
#     `sed -i` (BSD sed requires an argument to -i).
#   * stdout carries data and nothing else. Every diagnostic - counts, skipped
#     input, TLD price notes - goes to stderr, so that
#     `generate.sh ... > candidates.txt` always yields a clean file.
#
# Exit status: 0 candidates produced, 1 runtime error, 2 usage error,
#              3 nothing survived validation and filtering.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Byte semantics everywhere. awk character classes, tr case folding and shell
# glob ranges are all locale-sensitive; the whole pipeline is ASCII by
# definition (internationalised names must arrive already punycoded), so pin
# the locale rather than inherit whatever the user has set.
LC_ALL=C
export LC_ALL

GEN_VERSION="1.0.0"
_GEN_SELF=$(basename "$0")

# ---------------------------------------------------------------------------
# SECTION 1: defaults
# ---------------------------------------------------------------------------

GEN_MODE=""             # words | cvc | cvcv | two | compound | affix
GEN_WORDS_FILE=""       # --words
GEN_COMPOUND_A=""       # --compound <A> <B>
GEN_COMPOUND_B=""
GEN_PREFIX_FILE=""      # --prefixes
GEN_SUFFIX_FILE=""      # --suffixes
GEN_AFFIX_WORDS=""      # --affix, newline-separated, repeatable
GEN_AFFIX_BOTH=0        # --affix-both
GEN_TLDS=""             # space-separated, deduped, normalised
GEN_JOIN=""             # --join, glue for --compound / --affix
GEN_LIMIT=0             # --limit, 0 = unlimited
GEN_MIN_LEN=1           # --min-len, label characters
GEN_MAX_LEN=63          # --max-len, label characters (63 = DNS maximum)
GEN_COUNT_ONLY=0        # --count
GEN_TLD_NOTES=1         # --no-tld-notes

# --cvc / --cvcv alphabets. Onsets drop q (needs a u) and x (does not open an
# English syllable). Codas drop h, j, q and v, which do not close a bare
# English syllable. w and y stay as codas because -aw and -ay are everywhere:
# saw, paw, law, bay, day, toy.
GEN_ONSETS="bcdfghjklmnprstvwyz"   # 19
GEN_VOWELS="aeiou"                 # 5
GEN_CODAS="bcdfgklmnprstwxyz"      # 17

# Working state.
_GEN_TMPDIR=""
_GEN_SEQ=0
_GEN_CLEANED=""      # out-param of _gen_clean_list
_GEN_CLEAN_WORDS=""
_GEN_CLEAN_A=""
_GEN_CLEAN_B=""
_GEN_CLEAN_PRE=""
_GEN_CLEAN_SUF=""

# ---------------------------------------------------------------------------
# SECTION 2: usage
# ---------------------------------------------------------------------------

# _gen_usage_short
#   One-screen reminder, written to STDERR. Used on argument errors.
_gen_usage_short() {
	cat >&2 <<EOF
usage: $_GEN_SELF <mode> [options]

modes:
  --words <file> --tlds <list>
  --cvc  --tld <tld>
  --cvcv --tld <tld>
  --two  --tld <tld>
  --compound <fileA> <fileB> --tlds <list>
  --affix <word> --prefixes <file> --suffixes <file> --tlds <list>

run '$_GEN_SELF --help' for the full description and a worked example of each.
EOF
	return 0
}

# _gen_help
#   Full help, written to STDOUT (it is the requested output of --help).
_gen_help() {
	cat <<'EOF'
generate.sh - DomainSaver candidate name generator

Produces candidate domain names on stdout, one per line. It checks nothing:
generation is free, checking is rate-limited. Every name printed here is one
future registry query.

A name from this script is a CANDIDATE. Even when a probe later says
UNREGISTERED, the name may be registry-reserved or premium-priced - only a real
price quote can promote it to AVAILABLE. (shed.link looked free and quoted at
$819.27/yr against a $7.72 list price.)

USAGE
  generate.sh <mode> [options]
  generate.sh --help

MODES (choose exactly one)

  --words <file> --tlds <list>
      Cross product of a wordlist with TLDs. Use '-' to read the list on stdin.

        $ ./scripts/generate.sh --words wordlists/dev-wrapper.txt --tlds link,dev,sh
        shed.link
        shed.dev
        shed.sh
        hut.link
        hut.dev
        ...

  --cvc --tld <tld>
      Every pronounceable three-letter consonant-vowel-consonant label:
      19 onsets x 5 vowels x 17 codas = 1615 labels per TLD.
      Onsets are bcdfghjklmnprstvwyz - no q (it needs a u) and no x (it does
      not open an English syllable). Codas are bcdfgklmnprstwxyz - no h, j, q
      or v, which do not close one. w and y stay because -aw and -ay are
      everywhere (saw, paw, law, bay, day, toy). Override any of the three with
      --onsets / --vowels / --codas.

        $ ./scripts/generate.sh --cvc --tld dev --limit 5
        bab.dev
        bac.dev
        bad.dev
        baf.dev
        bag.dev

  --cvcv --tld <tld>
      Pronounceable four-letter consonant-vowel-consonant-vowel labels (kobo,
      vela, nira). Both consonant slots are followed by a vowel, so both use
      the ONSET set: 19 x 5 x 19 x 5 = 9025 labels per TLD.

        $ ./scripts/generate.sh --cvcv --tld io --limit 200 > candidates.txt

  --two --tld <tld>
      All 676 two-letter labels, aa through zz.

        $ ./scripts/generate.sh --two --tld uk | wc -l
        676

      Read the result as a pricing survey, not a shopping list. 633 of the 676
      two-letter .foo names look unregistered because the registry reserves
      them; all 676 two-letter .uk names are registered precisely because
      Nominet has no premium tier, so investors could buy them at list price.
      High apparent availability at short lengths is a premium-pricing signal.

  --compound <fileA> <fileB> --tlds <list>
      Every entry of A concatenated with every entry of B, A-major.

        $ ./scripts/generate.sh --compound wordlists/qualifiers.txt \
            wordlists/places.txt --tlds dev
        protoshed.dev
        protoloft.dev
        protoyard.dev
        ...
        betashed.dev
        ...

      Add --join - for hyphenated compounds (proto-shed.dev), which are easier
      to read but worse to dictate over the phone.

  --affix <word> --prefixes <file> --suffixes <file> --tlds <list>
      Wrap a word you already like. Emits the bare word, then every
      <prefix><word>, then every <word><suffix>. At least one of --prefixes and
      --suffixes is required; --affix may be repeated for several words.

        $ ./scripts/generate.sh --affix shed --prefixes wordlists/prefixes.txt \
            --suffixes wordlists/suffixes.txt --tlds com
        shed.com
        myshed.com
        theshed.com
        getshed.com
        ...
        shedhq.com
        shedlab.com
        ...

      --affix-both additionally emits <prefix><word><suffix> (myshedhq), which
      multiplies the two lists together - check the count before you run it.

OPTIONS
  --tlds <list>       one or more TLDs, comma- or space-separated, leading dots
                      optional: "com,net"  ".dev .io"  "co.uk". Repeatable.
                      Multi-label suffixes such as co.uk are supported.
  --tld <tld>         synonym for --tlds; reads better in the single-TLD modes.
  --limit <n>         stop after n candidates.
  --min-len <n>       drop labels shorter than n characters (default 1).
  --max-len <n>       drop labels longer than n characters (default 63).
  --join <str>        glue for --compound and --affix (default none; use "-").
  --count             print only how many candidates would be produced.
  --onsets <letters>  override the --cvc / --cvcv consonant and vowel sets.
  --vowels <letters>
  --codas <letters>
  --affix-both        see --affix above.
  --no-tld-notes      suppress the per-TLD price and reputation notes.
  -h, --help          this text.
  --version           print script and library versions.

ENVIRONMENT
  DS_QUIET=1          suppress informational stderr output (warnings still show)
  DS_DEBUG=1          verbose tracing

OUTPUT
  Lowercase, deduplicated, one domain per line, label-major: every TLD for the
  first label, then the next label. The interleaving is deliberate -
  consecutive queries then hit different registries, which is far kinder to
  per-registry rate limits than marching through one TLD at a time.

  Labels are validated as DNS labels: a-z, 0-9 and hyphen; no leading or
  trailing hyphen; no reserved '--' in positions 3-4 unless the label is a real
  xn-- A-label; 63 characters maximum, and 253 for the whole name. Anything
  else is dropped and counted on stderr rather than silently mangled.

  Per-TLD notes (renewal price, SPAM_ASSOCIATED, RENEWAL_TRAP ...) are printed
  on stderr when the price cache exists. Run scripts/bootstrap.sh to populate
  it; without it this script still works, it just says less.

EXIT STATUS
  0  candidates were produced
  1  runtime error (unreadable file, missing tool)
  2  usage error
  3  nothing survived validation and filtering
EOF
	return 0
}

# _gen_die_usage <message...>
#   Fatal argument error: message plus a pointer to --help, then exit 2.
_gen_die_usage() {
	printf '[ds] FATAL: %s\n' "$*" >&2
	printf "[ds] run: %s --help\n" "$_GEN_SELF" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# SECTION 3: temp files and cleanup
# ---------------------------------------------------------------------------

# _gen_cleanup
#   EXIT/INT/TERM handler. Removes the temp directory if one was created.
_gen_cleanup() {
	if [ -n "${_GEN_TMPDIR:-}" ] && [ -d "${_GEN_TMPDIR:-}" ]; then
		rm -rf "$_GEN_TMPDIR"
	fi
	return 0
}
trap _gen_cleanup EXIT
trap 'trap - EXIT; _gen_cleanup; exit 130' INT
trap 'trap - EXIT; _gen_cleanup; exit 143' TERM

# _gen_tmpdir
#   Creates the temp directory on first use. Sets $_GEN_TMPDIR.
_gen_tmpdir() {
	if [ -z "$_GEN_TMPDIR" ]; then
		_GEN_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/domainsaver-gen.XXXXXXXX") ||
			ds_die "cannot create a temporary directory under ${TMPDIR:-/tmp}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 4: argument parsing
# ---------------------------------------------------------------------------

# _gen_set_mode <mode>
#   Records the generation mode. Re-selecting the SAME mode is fine (--affix is
#   repeatable); selecting a second, different mode is a usage error.
_gen_set_mode() {
	if [ -n "$GEN_MODE" ] && [ "$GEN_MODE" != "$1" ]; then
		_gen_die_usage "modes --$GEN_MODE and --$1 are mutually exclusive; pick one"
	fi
	GEN_MODE="$1"
	return 0
}

# _gen_require_value <flag> <value>
#   Rejects a missing value, or one that is obviously the next option. Called
#   as a statement (never inside $( )) so that its exit really exits.
_gen_require_value() {
	case "${2:-}" in
	"") _gen_die_usage "$1 requires a value" ;;
	--*) _gen_die_usage "$1 requires a value (got the option '$2')" ;;
	esac
	return 0
}

# _gen_require_uint <flag> <value> <min> <max>
#   Validates a non-negative integer argument and its range.
_gen_require_uint() {
	case "${2:-}" in
	"" | *[!0-9]*) _gen_die_usage "$1 requires a whole number, got '${2:-}'" ;;
	esac
	if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
		_gen_die_usage "$1 must be between $3 and $4, got '$2'"
	fi
	return 0
}

# _gen_lower <string>
#   Stdout: the string lowercased with all whitespace removed.
_gen_lower() {
	printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
	printf '\n'
	return 0
}

# _gen_valid_suffix <suffix>
#   True (exit 0) when every dot-separated label of <suffix> is a valid DNS
#   label. Accepts multi-label public suffixes such as co.uk.
_gen_valid_suffix() {
	printf '%s\n' "${1:-}" | awk -F'.' '
		NF == 0 { exit 1 }
		{
			for (i = 1; i <= NF; i++)
				if ($i !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) exit 1
		}
	'
}

# _gen_add_tlds <list>
#   Parses a comma-, semicolon-, space- or newline-separated TLD list, strips
#   leading dots, lowercases, validates and appends to $GEN_TLDS, skipping
#   duplicates. Repeatable across several --tlds flags.
_gen_add_tlds() {
	_gat_list=$(printf '%s\n' "${1:-}" | tr -s ',;[:space:]' '\n')
	while IFS= read -r _gat_t; do
		[ -n "$_gat_t" ] || continue
		_gat_t=$(ds_normalize_tld "$_gat_t")
		[ -n "$_gat_t" ] || continue
		if ! _gen_valid_suffix "$_gat_t"; then
			_gen_die_usage "not a usable TLD: '$_gat_t' (expected letters, digits and hyphens, e.g. dev or co.uk)"
		fi
		case " $GEN_TLDS " in
		*" $_gat_t "*) continue ;;
		esac
		GEN_TLDS="$GEN_TLDS $_gat_t"
	done <<EOF
$_gat_list
EOF
	unset _gat_list _gat_t
	return 0
}

# _gen_add_affix_word <word>
#   Normalises and validates a --affix word, appending it to the newline-
#   separated $GEN_AFFIX_WORDS.
_gen_add_affix_word() {
	_gaw_w=$(_gen_lower "${1:-}")
	case "$_gaw_w" in
	"" | *[!a-z0-9-]*)
		_gen_die_usage "--affix '$1' is not a usable label (letters, digits and hyphens only)"
		;;
	esac
	if [ "${#_gaw_w}" -gt 63 ]; then
		_gen_die_usage "--affix '$1' is longer than the 63-character DNS label limit"
	fi
	GEN_AFFIX_WORDS="$GEN_AFFIX_WORDS$_gaw_w
"
	unset _gaw_w
	return 0
}

# _gen_parse_args <argv...>
#   Fills the GEN_* globals. Exits 2 on any argument problem.
_gen_parse_args() {
	if [ "$#" -eq 0 ]; then
		_gen_usage_short
		exit 2
	fi

	while [ "$#" -gt 0 ]; do
		case "$1" in
		-h | --help)
			_gen_help
			exit 0
			;;
		--version)
			printf '%s %s (lib.sh %s)\n' "$_GEN_SELF" "$GEN_VERSION" "$DS_LIB_VERSION"
			exit 0
			;;

		# --- modes ---
		--words)
			_gen_set_mode words
			_gen_require_value --words "${2:-}"
			GEN_WORDS_FILE="$2"
			shift 2
			;;
		--cvc)
			_gen_set_mode cvc
			shift
			;;
		--cvcv)
			_gen_set_mode cvcv
			shift
			;;
		--two | --two-letter)
			_gen_set_mode two
			shift
			;;
		--compound)
			_gen_set_mode compound
			_gen_require_value --compound "${2:-}"
			_gen_require_value --compound "${3:-}"
			GEN_COMPOUND_A="$2"
			GEN_COMPOUND_B="$3"
			shift 3
			;;
		--affix)
			_gen_set_mode affix
			_gen_require_value --affix "${2:-}"
			_gen_add_affix_word "$2"
			shift 2
			;;

		# --- mode inputs ---
		--prefixes)
			_gen_require_value --prefixes "${2:-}"
			GEN_PREFIX_FILE="$2"
			shift 2
			;;
		--suffixes)
			_gen_require_value --suffixes "${2:-}"
			GEN_SUFFIX_FILE="$2"
			shift 2
			;;
		--affix-both)
			GEN_AFFIX_BOTH=1
			shift
			;;

		# --- shared options ---
		--tlds | --tld)
			_gen_require_value "$1" "${2:-}"
			_gen_add_tlds "$2"
			shift 2
			;;
		--limit)
			_gen_require_uint --limit "${2:-}" 1 100000000
			GEN_LIMIT="$2"
			shift 2
			;;
		--min-len)
			_gen_require_uint --min-len "${2:-}" 1 63
			GEN_MIN_LEN="$2"
			shift 2
			;;
		--max-len)
			_gen_require_uint --max-len "${2:-}" 1 63
			GEN_MAX_LEN="$2"
			shift 2
			;;
		--join)
			# An empty glue is legitimate, so --join is allowed to take "".
			if [ "$#" -lt 2 ]; then
				_gen_die_usage "--join requires a value (use '' for none)"
			fi
			GEN_JOIN=$(_gen_lower "$2")
			case "$GEN_JOIN" in
			*[!a-z0-9-]*)
				_gen_die_usage "--join '$2' must be letters, digits or hyphens (usually '-')"
				;;
			esac
			shift 2
			;;
		--count)
			GEN_COUNT_ONLY=1
			shift
			;;
		--onsets)
			_gen_require_value --onsets "${2:-}"
			GEN_ONSETS=$(_gen_lower "$2")
			shift 2
			;;
		--vowels)
			_gen_require_value --vowels "${2:-}"
			GEN_VOWELS=$(_gen_lower "$2")
			shift 2
			;;
		--codas)
			_gen_require_value --codas "${2:-}"
			GEN_CODAS=$(_gen_lower "$2")
			shift 2
			;;
		--no-tld-notes)
			GEN_TLD_NOTES=0
			shift
			;;

		--)
			shift
			[ "$#" -eq 0 ] || _gen_die_usage "unexpected argument: '$1'"
			;;
		-*)
			_gen_die_usage "unknown option: '$1'"
			;;
		*)
			_gen_die_usage "unexpected argument: '$1' (options must be named, e.g. --tlds $1)"
			;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 5: validation
# ---------------------------------------------------------------------------

# _gen_check_readable <path> <what>
#   Fatal unless <path> is a readable, non-empty input. '-' means stdin, and
#   pipes / process substitutions are accepted (they have no size to check).
_gen_check_readable() {
	[ "$1" = "-" ] && return 0
	if [ ! -e "$1" ]; then
		ds_die "$2 not found: $1"
	fi
	if [ -d "$1" ]; then
		ds_die "$2 is a directory, not a wordlist: $1"
	fi
	if [ ! -r "$1" ]; then
		ds_die "$2 is not readable: $1"
	fi
	if [ -f "$1" ] && [ ! -s "$1" ]; then
		ds_die "$2 is empty: $1"
	fi
	return 0
}

# _gen_check_alphabet <name> <letters>
#   Fatal unless an --onsets/--vowels/--codas override is a non-empty run of
#   letters and digits.
_gen_check_alphabet() {
	case "${2:-}" in
	"") _gen_die_usage "--$1 must not be empty" ;;
	*[!a-z0-9]*) _gen_die_usage "--$1 must be letters or digits only, got '$2'" ;;
	esac
	return 0
}

# _gen_validate
#   Cross-checks the parsed options: exactly one mode, its required inputs
#   present, and the shared options coherent.
_gen_validate() {
	if [ -z "$GEN_MODE" ]; then
		_gen_usage_short
		exit 2
	fi
	if [ "$GEN_MIN_LEN" -gt "$GEN_MAX_LEN" ]; then
		_gen_die_usage "--min-len ($GEN_MIN_LEN) is greater than --max-len ($GEN_MAX_LEN)"
	fi
	if [ -z "$GEN_TLDS" ]; then
		_gen_die_usage "--$GEN_MODE also needs --tlds (or --tld), e.g. --tlds com,dev"
	fi

	case "$GEN_MODE" in
	words)
		_gen_check_readable "$GEN_WORDS_FILE" "--words wordlist"
		;;
	compound)
		_gen_check_readable "$GEN_COMPOUND_A" "--compound first wordlist"
		_gen_check_readable "$GEN_COMPOUND_B" "--compound second wordlist"
		;;
	affix)
		if [ -z "$GEN_PREFIX_FILE" ] && [ -z "$GEN_SUFFIX_FILE" ]; then
			_gen_die_usage "--affix needs at least one of --prefixes <file> / --suffixes <file>"
		fi
		if [ "$GEN_AFFIX_BOTH" = "1" ] && { [ -z "$GEN_PREFIX_FILE" ] || [ -z "$GEN_SUFFIX_FILE" ]; }; then
			_gen_die_usage "--affix-both needs BOTH --prefixes and --suffixes"
		fi
		[ -n "$GEN_PREFIX_FILE" ] && _gen_check_readable "$GEN_PREFIX_FILE" "--prefixes wordlist"
		[ -n "$GEN_SUFFIX_FILE" ] && _gen_check_readable "$GEN_SUFFIX_FILE" "--suffixes wordlist"
		;;
	cvc | cvcv)
		_gen_check_alphabet onsets "$GEN_ONSETS"
		_gen_check_alphabet vowels "$GEN_VOWELS"
		[ "$GEN_MODE" = "cvc" ] && _gen_check_alphabet codas "$GEN_CODAS"
		;;
	esac

	# Options that belong to a mode other than the one selected: warn rather
	# than fail, because they are harmless, but silence would hide a typo.
	case "$GEN_MODE" in
	affix) ;;
	*)
		if [ -n "$GEN_PREFIX_FILE" ] || [ -n "$GEN_SUFFIX_FILE" ] || [ "$GEN_AFFIX_BOTH" = "1" ]; then
			ds_warn "--prefixes/--suffixes/--affix-both only apply to --affix; ignored"
		fi
		;;
	esac
	case "$GEN_MODE" in
	compound | affix) ;;
	*)
		if [ -n "$GEN_JOIN" ]; then
			ds_warn "--join only applies to --compound and --affix; ignored"
		fi
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 6: input cleaning
# ---------------------------------------------------------------------------

# _gen_clean_list <path-or-dash> <human label>
#   Reads a wordlist, strips CR line endings, '#' comments and surrounding
#   whitespace, lowercases, drops entries that could never form a DNS label,
#   and writes the survivors to a temp file. Sets $_GEN_CLEANED to its path.
#
#   Entries are checked here only for their character set and length; hyphen
#   placement is checked later, on the ASSEMBLED label, so that a suffix list
#   may legitimately contain "-hq".
#
#   Skipped entries are counted and reported once, not line by line: pointing a
#   generator at /usr/share/dict/words should produce one warning, not 30,000.
_gen_clean_list() {
	_gcl_src="$1"
	_gcl_what="$2"
	_gen_tmpdir
	_GEN_SEQ=$((_GEN_SEQ + 1))
	_gcl_out="$_GEN_TMPDIR/list.$_GEN_SEQ"

	_gcl_in="$_gcl_src"
	[ "$_gcl_in" = "-" ] && _gcl_in="/dev/stdin"

	awk -v what="$_gcl_what" '
		{
			sub(/\r$/, "")
			sub(/#.*$/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
		}
		$0 == "" { next }
		{ e = tolower($0) }
		e ~ /[^a-z0-9-]/ { bad++; next }
		length(e) > 63   { toolong++; next }
		{ print e }
		END {
			if (bad > 0)
				printf("[ds] WARN: %s: skipped %d entr%s outside [a-z0-9-] - entries are labels, not domains, and internationalised names must already be punycode (xn--...)\n",
					what, bad, (bad == 1 ? "y" : "ies")) > "/dev/stderr"
			if (toolong > 0)
				printf("[ds] WARN: %s: skipped %d entr%s over the 63-character DNS label limit\n",
					what, toolong, (toolong == 1 ? "y" : "ies")) > "/dev/stderr"
		}
	' "$_gcl_in" >"$_gcl_out" || ds_die "failed to read $_gcl_what: $_gcl_src"

	if [ ! -s "$_gcl_out" ]; then
		ds_die "$_gcl_what has no usable entries: $_gcl_src"
	fi

	_GEN_CLEANED="$_gcl_out"
	ds_debug "$_gcl_what: $(wc -l <"$_gcl_out" | tr -d ' ') usable entries"
	unset _gcl_src _gcl_what _gcl_in _gcl_out
	return 0
}

# _gen_prepare
#   Cleans whichever wordlists the selected mode needs, once, up front - so
#   that a bad file fails before any output is produced, and so stdin is
#   consumed before generation starts.
_gen_prepare() {
	case "$GEN_MODE" in
	words)
		_gen_clean_list "$GEN_WORDS_FILE" "--words $GEN_WORDS_FILE"
		_GEN_CLEAN_WORDS="$_GEN_CLEANED"
		;;
	compound)
		_gen_clean_list "$GEN_COMPOUND_A" "--compound $GEN_COMPOUND_A"
		_GEN_CLEAN_A="$_GEN_CLEANED"
		_gen_clean_list "$GEN_COMPOUND_B" "--compound $GEN_COMPOUND_B"
		_GEN_CLEAN_B="$_GEN_CLEANED"
		;;
	affix)
		if [ -n "$GEN_PREFIX_FILE" ]; then
			_gen_clean_list "$GEN_PREFIX_FILE" "--prefixes $GEN_PREFIX_FILE"
			_GEN_CLEAN_PRE="$_GEN_CLEANED"
		fi
		if [ -n "$GEN_SUFFIX_FILE" ]; then
			_gen_clean_list "$GEN_SUFFIX_FILE" "--suffixes $GEN_SUFFIX_FILE"
			_GEN_CLEAN_SUF="$_GEN_CLEANED"
		fi
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: TLD notes
# ---------------------------------------------------------------------------

# _gen_tld_notes
#   Prints one stderr line per TLD: standard registration and renewal price,
#   plus any reputation flags from ds_tld_flags. RENEWAL is the number that
#   matters - .bar registers at $2.57 and renews at $52.01.
#
#   Deliberately silent when the price cache is cold: this is a generator, and
#   nagging about bootstrap.sh on every run of a script that needs no network
#   would be noise. Run scripts/bootstrap.sh and the notes appear.
_gen_tld_notes() {
	[ "$GEN_TLD_NOTES" = "1" ] || return 0
	[ -s "$DS_PRICE_INDEX_TSV" ] || return 0

	while IFS= read -r _gtn_t; do
		[ -n "$_gtn_t" ] || continue
		# Flags and prices are per registry, i.e. per LAST label: co.uk is uk.
		_gtn_last="${_gtn_t##*.}"
		_gtn_note=".$_gtn_t"
		if _gtn_price=$(ds_std_price "$_gtn_last" 2>/dev/null); then
			_gtn_note="$_gtn_note  reg \$$(printf '%s' "$_gtn_price" | cut -f1)"
			_gtn_note="$_gtn_note  renew \$$(printf '%s' "$_gtn_price" | cut -f2)"
		else
			_gtn_note="$_gtn_note  (no price data)"
		fi
		_gtn_flags=$(ds_tld_flags "$_gtn_last")
		if [ -n "$_gtn_flags" ]; then
			case "$_gtn_flags" in
			*RENEWAL_TRAP* | *SPAM_ASSOCIATED*)
				ds_warn "$_gtn_note  $_gtn_flags"
				continue
				;;
			esac
			_gtn_note="$_gtn_note  $_gtn_flags"
		fi
		ds_log "$_gtn_note"
	done <<EOF
$(printf '%s\n' "$GEN_TLDS" | tr ' ' '\n')
EOF
	unset _gtn_t _gtn_last _gtn_note _gtn_price _gtn_flags 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 8: stem generation
# ---------------------------------------------------------------------------
#
# Every mode emits bare LABELS on stdout - no TLD, no validation. Attaching
# TLDs, validating, de-duplicating and limiting all happen once, in
# _gen_emit, so that every mode behaves identically.

# _gen_stems_cvc
#   onset x vowel x coda, in alphabet order.
_gen_stems_cvc() {
	awk -v ons="$GEN_ONSETS" -v vow="$GEN_VOWELS" -v cod="$GEN_CODAS" '
		BEGIN {
			no = length(ons); nv = length(vow); nc = length(cod)
			for (i = 1; i <= no; i++)
				for (j = 1; j <= nv; j++)
					for (k = 1; k <= nc; k++)
						print substr(ons, i, 1) substr(vow, j, 1) substr(cod, k, 1)
		}
	'
}

# _gen_stems_cvcv
#   onset x vowel x onset x vowel. Both consonants precede a vowel, so both
#   come from the onset set.
_gen_stems_cvcv() {
	awk -v ons="$GEN_ONSETS" -v vow="$GEN_VOWELS" '
		BEGIN {
			no = length(ons); nv = length(vow)
			for (i = 1; i <= no; i++)
				for (j = 1; j <= nv; j++)
					for (k = 1; k <= no; k++)
						for (m = 1; m <= nv; m++)
							print substr(ons, i, 1) substr(vow, j, 1) \
								substr(ons, k, 1) substr(vow, m, 1)
		}
	'
}

# _gen_stems_two
#   All 676 two-letter labels, aa..zz.
_gen_stems_two() {
	awk '
		BEGIN {
			a = "abcdefghijklmnopqrstuvwxyz"
			for (i = 1; i <= 26; i++)
				for (j = 1; j <= 26; j++)
					print substr(a, i, 1) substr(a, j, 1)
		}
	'
}

# _gen_stems_compound
#   Every entry of A glued to every entry of B, A-major. B is read into memory
#   first and A is streamed, so the bigger list should be A.
_gen_stems_compound() {
	awk -v join="$GEN_JOIN" '
		NR == FNR { b[++n] = $0; next }
		{ for (i = 1; i <= n; i++) print $0 join b[i] }
	' "$_GEN_CLEAN_B" "$_GEN_CLEAN_A"
}

# _gen_stems_affix
#   For each --affix word: the bare word, then <prefix><word>, then
#   <word><suffix>, then (with --affix-both) <prefix><word><suffix>.
_gen_stems_affix() {
	while IFS= read -r _gsa_w; do
		[ -n "$_gsa_w" ] || continue
		printf '%s\n' "$_gsa_w"
		if [ -n "$_GEN_CLEAN_PRE" ]; then
			awk -v w="$_gsa_w" -v join="$GEN_JOIN" '{ print $0 join w }' "$_GEN_CLEAN_PRE"
		fi
		if [ -n "$_GEN_CLEAN_SUF" ]; then
			awk -v w="$_gsa_w" -v join="$GEN_JOIN" '{ print w join $0 }' "$_GEN_CLEAN_SUF"
		fi
		if [ "$GEN_AFFIX_BOTH" = "1" ]; then
			awk -v w="$_gsa_w" -v join="$GEN_JOIN" '
				NR == FNR { s[++n] = $0; next }
				{ for (i = 1; i <= n; i++) print $0 join w join s[i] }
			' "$_GEN_CLEAN_SUF" "$_GEN_CLEAN_PRE"
		fi
	done <<EOF
$GEN_AFFIX_WORDS
EOF
	return 0
}

# _gen_stems
#   Dispatches to the selected mode.
_gen_stems() {
	case "$GEN_MODE" in
	words) cat "$_GEN_CLEAN_WORDS" ;;
	cvc) _gen_stems_cvc ;;
	cvcv) _gen_stems_cvcv ;;
	two) _gen_stems_two ;;
	compound) _gen_stems_compound ;;
	affix) _gen_stems_affix ;;
	*) ds_die "internal error: unknown mode '$GEN_MODE'" ;;
	esac
}

# ---------------------------------------------------------------------------
# SECTION 9: emit
# ---------------------------------------------------------------------------

# _gen_emit
#   Reads labels on stdin and writes candidate domains on stdout.
#     * de-duplicates labels, preserving first-seen order
#     * applies --min-len / --max-len to the LABEL
#     * enforces DNS label rules, never repairing - a name that has to be
#       mangled to be legal is not the name you meant
#     * crosses each surviving label with every TLD, label-major, so that
#       consecutive queries hit different registries
#     * enforces the 253-character whole-name limit
#     * applies --limit and --count
#   Exit: 0 with output, 3 if nothing survived.
_gen_emit() {
	awk -v tlds="$GEN_TLDS" \
		-v minlen="$GEN_MIN_LEN" -v maxlen="$GEN_MAX_LEN" \
		-v limit="$GEN_LIMIT" -v countonly="$GEN_COUNT_ONLY" \
		-v quiet="${DS_QUIET:-0}" '
		BEGIN { ntld = split(tlds, T, " ") }
		{
			label = $0
			if (label == "") next
			if (seen[label]++) { dup++; next }
			n = length(label)
			if (n < minlen + 0 || n > maxlen + 0) { droplen++; next }
			if (label !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) { dropfmt++; next }
			# RFC 5891: "--" in positions 3-4 is reserved for A-labels.
			if (substr(label, 3, 2) == "--" && substr(label, 1, 4) != "xn--") {
				drophyphen++
				next
			}
			kept++
			for (i = 1; i <= ntld; i++) {
				dom = label "." T[i]
				if (length(dom) > 253) { droptotal++; continue }
				total++
				if (countonly + 0 == 0) print dom
				if (limit + 0 > 0 && total >= limit + 0) { hit = 1; break }
			}
			if (hit) exit
		}
		END {
			if (countonly + 0 == 1) print total + 0

			if (droplen + dropfmt + drophyphen + droptotal > 0) {
				msg = ""
				if (droplen)
					msg = msg sprintf(" %d outside --min-len/--max-len,", droplen)
				if (dropfmt)
					msg = msg sprintf(" %d not valid DNS labels (leading/trailing hyphen or bad character),", dropfmt)
				if (drophyphen)
					msg = msg sprintf(" %d with reserved \"--\" in positions 3-4,", drophyphen)
				if (droptotal)
					msg = msg sprintf(" %d over the 253-character name limit,", droptotal)
				sub(/,$/, "", msg)
				printf("[ds] WARN: dropped%s\n", msg) > "/dev/stderr"
			}

			if (quiet != "1")
				printf("[ds] %d candidate(s): %d label(s) x %d TLD(s)%s\n",
					total + 0, kept + 0, ntld,
					(dup ? sprintf(", %d duplicate label(s) removed", dup) : "")) > "/dev/stderr"

			if (total + 0 > 1000)
				printf("[ds] WARN: %d lookups is a lot - registries rate-limit hard, and Identity Digital TLDs have timed out for 10+ minutes at this volume. Consider --limit, or checking in batches.\n",
					total + 0) > "/dev/stderr"

			if (total + 0 == 0) exit 3
		}
	'
}

# ---------------------------------------------------------------------------
# SECTION 10: main
# ---------------------------------------------------------------------------

main() {
	ds_require awk tr
	_gen_parse_args "$@"
	_gen_validate
	_gen_prepare
	_gen_tld_notes

	_gen_rc=0
	_gen_stems | _gen_emit || _gen_rc=$?
	if [ "$_gen_rc" = "3" ]; then
		ds_warn "no candidates survived validation and filtering (check --min-len/--max-len and your wordlist)"
	fi
	return "$_gen_rc"
}

main "$@"
