#!/usr/bin/env bash
# shellcheck shell=bash
#
# price-join.sh - attach standard TLD pricing and reputation flags to sweep
# results. Offline, instant, free: a local join against the bootstrap caches.
#
# This is the step that makes a quote budget go far. quote.sh costs about 11
# seconds and one API call per name, so eliminating whole-TLD renewal traps
# here - before spending any of that - is what keeps a broad search cheap.
#
# IMPORTANT: this reports the TLD's STANDARD list price, which is not a quote
# for the specific name. An UNREGISTERED name may still be registry-reserved or
# premium-priced; only quote.sh can tell you. Nothing here ever says AVAILABLE.
#
# Usage:
#   price-join.sh swept.tsv
#   sweep.sh candidates.txt | price-join.sh -
#   price-join.sh --status REGISTERED swept.tsv    # what did I already own?
#   price-join.sh --all swept.tsv                  # every row, whatever status
#
# Output (TSV, cheapest renewal first):
#   domain <TAB> standard_registration <TAB> standard_renewal <TAB> flags
set -u

_PJ_SELF=$(basename "$0")
_PJ_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh disable=SC1091
. "$_PJ_DIR/lib.sh"

PJ_STATUS="UNREGISTERED"
PJ_INPUT=""
PJ_SORT=1

_pj_usage() {
	cat <<EOF
$_PJ_SELF - attach standard TLD prices and reputation flags to sweep results.

USAGE
  $_PJ_SELF [options] <swept.tsv>
  <sweep.sh output> | $_PJ_SELF -

OPTIONS
  --status <STATUS>   Which sweep status to keep (default: UNREGISTERED).
  --all               Keep every row regardless of status.
  --no-sort           Preserve input order instead of sorting by renewal.
  -h, --help          This help.

OUTPUT
  TSV: domain, standard_registration, standard_renewal, flags
  Sorted by renewal price ascending unless --no-sort.

  RENEWAL is the number that matters. A TLD can be cheap for a year and
  brutal forever after - .bar renews at roughly twenty times its first-year
  price - and those TLDs are flagged RENEWAL_TRAP here.

  These are the TLD's list prices, NOT a quote for the individual name.
  Run quote.sh on the shortlist to find out what a name actually costs.

EXAMPLE
  $_PJ_SELF swept.tsv | head
  labattic.com	11.08	11.08	NO_PREMIUM_REGISTRY
  scratch.bar	2.57	52.01	RENEWAL_TRAP
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--status)
		[ $# -ge 2 ] || ds_die "--status needs a value"
		PJ_STATUS="$2"
		shift 2
		;;
	--all)
		PJ_STATUS=""
		shift
		;;
	--no-sort)
		PJ_SORT=0
		shift
		;;
	-h | --help)
		_pj_usage
		exit 0
		;;
	-)
		# Must precede the -* catch-all: a lone dash means stdin, not a flag.
		[ -z "$PJ_INPUT" ] || ds_die "give exactly one input (got '$PJ_INPUT' and stdin)"
		PJ_INPUT="-"
		shift
		;;
	-*)
		ds_warn "unknown option: $1"
		_pj_usage >&2
		exit 2
		;;
	*)
		[ -z "$PJ_INPUT" ] || ds_die "give exactly one input file (got '$PJ_INPUT' and '$1')"
		PJ_INPUT="$1"
		shift
		;;
	esac
done

[ -n "$PJ_INPUT" ] || PJ_INPUT="-"
if [ "$PJ_INPUT" != "-" ] && [ ! -r "$PJ_INPUT" ]; then
	ds_die "cannot read '$PJ_INPUT'"
fi

for _pj_cache in "$DS_PRICE_INDEX_TSV" "$DS_TLD_FLAGS_TSV"; do
	[ -s "$_pj_cache" ] || ds_die "missing cache $_pj_cache - run $DS_ROOT/scripts/bootstrap.sh"
done

# Read stdin once into a temp file so awk can take three file arguments.
_pj_tmp=""
if [ "$PJ_INPUT" = "-" ]; then
	_pj_tmp=$(mktemp "${TMPDIR:-/tmp}/domainsaver-pj.XXXXXXXX") || ds_die "mktemp failed"
	cat >"$_pj_tmp"
	PJ_INPUT="$_pj_tmp"
fi

_pj_out=$(awk -F'\t' -v OFS='\t' -v want="$PJ_STATUS" '
	FILENAME ~ /tld-prices/ { price[$1] = $2 OFS $3; next }
	FILENAME ~ /tld-flags/  { if ($0 !~ /^#/ && NF >= 2) flag[$1] = $2; next }
	/^#/ || NF < 3          { next }
	want != "" && $1 != want { next }
	{
		# Sweep rows carry the registry TLD in field 3, but registrars can
		# price a longer public suffix independently (for example, co.uk).
		# Prefer that two-label suffix when the price table has one; flags
		# remain keyed by the registry TLD below.
		price_key = $3
		n = split($2, labels, ".")
		if (n >= 3) {
			two_label_key = labels[n - 1] "." $3
			if (two_label_key in price) price_key = two_label_key
		}
		p = (price_key in price) ? price[price_key] : "-" OFS "-"
		f = ($3 in flag)  ? flag[$3]  : "-"
		print $2, p, f
	}
' "$DS_PRICE_INDEX_TSV" "$DS_TLD_FLAGS_TSV" "$PJ_INPUT")

[ -n "$_pj_tmp" ] && rm -f "$_pj_tmp"

if [ -z "$_pj_out" ]; then
	ds_warn "no rows matched${PJ_STATUS:+ status $PJ_STATUS}"
	exit 0
fi

if [ "$PJ_SORT" = "1" ]; then
	printf '%s\n' "$_pj_out" | sort -t"$(printf '\t')" -k3,3n
else
	printf '%s\n' "$_pj_out"
fi

ds_log "priced $(printf '%s\n' "$_pj_out" | grep -c .) name(s); renewal is column 3"
ds_log "these are TLD list prices, not per-name quotes - run quote.sh on the shortlist"
