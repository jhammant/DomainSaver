---
name: domain-search
description: Search broadly for a domain when the name, the TLD or even the shape is still open - guided suggestion plus large-scale registry scans, costed on renewal price and safe against registry rate limits. Use when the user wants help finding or brainstorming a domain, is choosing between TLDs, needs a short or wrapper domain for projects, asks what a domain or TLD will cost, wants hundreds or thousands of candidates checked at once, worries about premium or reserved names or renewal traps, or asks whether a specific name is available. A name must never be reported as available on a registry lookup alone - an RDAP 404 also covers registry-reserved and premium-priced names, and only a real quote can tell them apart.
---

# domain-search

Finding a domain is a **funnel, not a lookup**. The user usually arrives with a
vague idea ("something for my side projects") and needs help converging. Your
job is to run that funnel: propose directions, scan widely and cheaply, cost
what survives, and quote only the finalists.

Generating names is free. Scanning is rate-limited. Quoting spends real API
calls. Spend them in that order, and the search stays fast and cheap.

## Who does what

**You** do the two things a script cannot: invent candidate names with meaning,
and interpret what a sweep is telling you. **The scripts** do the one thing you
must never do from memory or guesswork: decide whether a name is taken, and
what it costs.

Never assert availability you have not run. Never ask a script to be creative.

## The funnel

### 1. Frame it — ask at most two or three questions

Only ask what changes the search. Usually:

- **What is it for, and how long will it live?** A wrapper for throwaway
  projects has different needs from a product name.
- **Does anyone else have to see it?** Client-facing pushes towards `.com` and
  away from spam-associated TLDs; a private wrapper does not care.
- **Budget shape?** "Cheapest that works" and "must be `.com`" lead to
  completely different searches.

Country matters more than people expect: a UK user gets `.uk` at roughly half
the price of `.com`, with no premium tier. Infer it rather than asking.

If the user already named a candidate, skip to step 4 — but still offer
directions afterwards, because the first idea is rarely the best one.

### 2. Propose directions, not names

This is the step that makes the search feel guided. Offer **four to six naming
*directions* with two or three examples each**, and let the user react. Reacting
to a direction is far easier than reviewing 200 names.

Directions that work for developer/project domains:

- **Literal** — what it does (`sideprojects`, `betalab`, `demoshed`)
- **Temporary by design** — for things that will not last (`thelayby`,
  `holdingbay`, `stopgapapps`, `transientapps`)
- **Place/container** — where things are kept (`shed`, `attic`, `yard`,
  `depot`, `allotment`, `pottingshed`)
- **Honest/self-aware** — often the most memorable (`unfinishedapps`,
  `showyourworking`, `stuffibuilt`)
- **Personal** — surname or initials (`hammantlabs`, `jonsshed`); zero
  trademark risk and it survives a project graduating
- **Numeric/specific** — a true fact about them (`lab268` for 268 repos)

Then iterate. "I like the lab one" or "not `.uk`" is a strong signal — regenerate
inside that direction rather than starting over.

### 3. Generate broadly

Write the interesting labels yourself, then expand mechanically. Aim for
**hundreds** of candidates per round — availability rates for good names run
about 10% in `.com` and 80% in `.uk`, so a 20-name list mostly returns nothing.

```bash
# Always use the directory of this loaded skill when the host supplies it.
# Claude Code expands CLAUDE_SKILL_DIR before running the block. In Codex, set
# DOMAINSAVER_HOME from the SKILL.md path in the loaded skill metadata; the
# standard-location fallbacks below keep direct shell use convenient.
CLAUDE_DS='${CLAUDE_SKILL_DIR}'
case "$CLAUDE_DS" in
'$'{CLAUDE_SKILL_DIR}) CLAUDE_DS="" ;;
esac
DS="${DOMAINSAVER_HOME:-$CLAUDE_DS}"
[ -n "$DS" ] && [ -d "$DS/scripts" ] || DS="${CODEX_HOME:-$HOME/.agents}/skills/domain-search"
[ -d "$DS/scripts" ] || DS="$HOME/.codex/skills/domain-search"
[ -d "$DS/scripts" ] || DS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/domain-search"
unset CLAUDE_DS

# your own labels, crossed with plausible TLDs
printf 'shed\nloft\nyard\nattic\ndepot\n' \
  | "$DS/scripts/generate.sh" --words - --tlds com,uk,link > candidates.txt

# wrap a name the user already likes (betalab -> betalabhq, mybetalab, ...)
"$DS/scripts/generate.sh" --affix betalab \
  --prefixes "$DS/wordlists/prefixes.txt" \
  --suffixes "$DS/wordlists/suffixes.txt" --tlds com > candidates.txt

# glue two concept lists (qualifier + place -> protoshed)
"$DS/scripts/generate.sh" --compound "$DS/wordlists/qualifiers.txt" \
  "$DS/wordlists/places.txt" --tlds com,uk > candidates.txt

# exhaustive spaces, when the user wants "the shortest thing available"
"$DS/scripts/generate.sh" --cvc  --tld uk    # 1615 pronounceable 3-letter
"$DS/scripts/generate.sh" --two  --tld uk    # all 676 two-letter

# ALWAYS size it before running it
"$DS/scripts/generate.sh" --cvc --tld uk --count
```

Wordlists that ship with the toolkit: `dev-wrapper.txt`, `places.txt`,
`qualifiers.txt`, `prefixes.txt`, `suffixes.txt`.

### 4. Scan — and do not get rate limited

**Always use `sweep.sh` for more than ~25 names, and `check.sh` for fewer.**
Never hand-roll `curl` or `whois` loops: `sweep.sh` groups work by registry,
applies a per-registry concurrency budget, backs off on 429s, retries, and
falls back to whois on the final round. Hand-rolled loops get you banned, and
the ban is silent — you get 429s that look like "not registered" if you are
careless.

```bash
"$DS/scripts/sweep.sh" --dry-run candidates.txt      # plan first, ALWAYS
"$DS/scripts/sweep.sh" -p 16 -o swept.tsv candidates.txt
"$DS/scripts/check.sh" betalab.uk hammantlabs.com    # a handful, precisely
```

Rules that keep a big scan safe:

- **Run `--dry-run` first** on anything over a few hundred names and show the
  user the plan (which registries, how long) before spending their time.
- **Do not raise `-p` above 16.** The per-registry budgets do the real work;
  a bigger global number just queues.
- **Some registries are slow by design.** Identity Digital (`.info`, `.pro`,
  `.fyi`, `.rocks` and ~240 more) is capped at one connection because it
  throttles hard. A list full of those will crawl — say so rather than letting
  it look hung. `--explain-limit <host> <transport>` shows why.
- **Exit code 2 means some rows are `ERROR`.** Report those as *unknown*, never
  as free, and offer to re-run just those names.
- Sweeping the same list twice is wasteful — keep `swept.tsv` and reuse it.

### 5. Cost it before you quote it

Join every `UNREGISTERED` result to its TLD's standard price and flags. This is
local, instant and free, and it is what makes the quote budget go far:

```bash
"$DS/scripts/price-join.sh" swept.tsv > priced.tsv        # cheapest renewal first
"$DS/scripts/sweep.sh" cands.txt | "$DS/scripts/price-join.sh" -
"$DS/scripts/price-join.sh" --status REGISTERED swept.tsv  # audit what is owned
```

Output is `domain, standard_registration, standard_renewal, flags`.

**Always report the renewal price, never the first year.** The gap is where the
money is, expressed as USD per year:

| TLD | Year one | Renews at | Multiple |
| --- | --- | --- | --- |
| `.bar` | 2.57 | 52.01 | 20x |
| `.codes` | 4.63 | 57.16 | 12x |
| `.online` / `.site` / `.space` | ~1.96 | 26.26–28.84 | ~15x |
| `.fun` / `.works` / `.zone` | 2.57–8.24 | 31.41 | up to 12x |

`RENEWAL_TRAP` and `SPAM_ASSOCIATED` flags come out of this join — surface both.

### 6. Quote only the finalists

`quote.sh` is the only thing that may say `AVAILABLE`, and it costs about 11
seconds per name. Quote the shortlist — **ten names at most** — after the user
has narrowed by direction and price.

```bash
"$DS/scripts/quote.sh" hammantlabs.com betalab.uk
```

```text
DOMAIN            VERDICT     QUOTE-REG  QUOTE-REN  LIST-REG  LIST-REN   RATIO  NOTES
shed.link         PREMIUM        819.27     819.27      7.72      7.72  106.1x  PRICE_OVER_LIST
hammantlabs.com   AVAILABLE       11.08      11.08     11.08     11.08    1.0x  NO_PREMIUM_REGISTRY
```

Without credentials configured this step cannot run. That is not a failure —
report the shortlist as `UNREGISTERED`, say plainly that purchasability is
unconfirmed, and tell the user a quote is needed. Never promote a name anyway.

### 7. Present, then loop

Give a short ranked table — name, renewal price, any flags — plus **one clear
recommendation with a reason**, not a list of twenty equals. Then invite a
narrowing signal ("more like this one?", "drop `.uk`?") and run the funnel
again from step 2. Two or three tight rounds beat one enormous scan.

## Reading a broad scan

This is the interpretation the scripts cannot do for you.

**High availability at short lengths is a premium-pricing signal, not
opportunity.** Measured: 633 of the 676 two-letter `.foo` domains are
unregistered — and none are for sale, because the registry reserves them.
Meanwhile every one of the 676 two-letter `.uk` names is taken, *precisely
because* Nominet has no premium tier, so investors swept them at list price
years ago.

So when a TLD shows lots of free short names, tell the user it means those
names are expensive, not that they got lucky. And when a TLD shows none, that
is the honest scarcity — the cheap ones really are gone.

Practical consequences worth stating:

- Two-letter names: effectively unobtainable anywhere.
- Three-letter: premium only — expect USD 150+/yr even for invented ones.
- Four to five letters: the floor for standard pricing, and only for words
  obscure enough that investors skipped them.
- Compound names (`betashed`, `thelayby`) sit below every registry's premium
  threshold, so **list price is real price**. This is why "longer but meaningful"
  is usually the right advice.
- `.com`, `.net`, `.org` and `.uk` have no registry premium tier at all: if the
  name is unregistered, it is the list price.

## What each step costs

| Step | Cost | Scale |
| --- | --- | --- |
| Generate | free, offline | unlimited |
| Price-join | free, offline | unlimited |
| `check.sh` | 1 registry query/name | up to ~25 |
| `sweep.sh` | 1 registry query/name, throttled | thousands |
| `quote.sh` | ~11s + an API call/name | ~10 |

## Preflight

Once per session, make sure the caches exist:

```bash
"$DS/scripts/bootstrap.sh"        # refreshes only if older than 7 days
```

If a script reports a missing cache, run that and retry. Every script has a
thorough `--help`; all of them write data to stdout and everything else to
stderr, so piping is always safe.
