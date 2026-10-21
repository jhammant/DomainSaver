# Contributing to DomainSaver

Contributions are very welcome — especially registry quirks, whois formats and
routing corrections, because that knowledge is only obtainable by getting throttled.

This file is the practical bit: how to set up, how to run the tests, and the house
rules a PR is checked against. The *design* constraints (bash 3.2, POSIX-ish tools,
no new runtime dependencies, never invent a status) are in
[README.md](README.md#contributing) — please read those too.

## Setup

```bash
git clone https://github.com/jhammant/DomainSaver.git
cd DomainSaver
brew install jq whois shellcheck markdownlint-cli2  # macOS
# sudo apt-get install -y curl jq whois shellcheck   # Debian / Ubuntu
# npm install --global markdownlint-cli2             # any platform with Node.js
```

Everything in `data/` except the seeded files is a cache you build locally:

```bash
scripts/bootstrap.sh          # downloads the IANA RDAP map + Porkbun price list
scripts/bootstrap.sh --rebuild # offline: rebuild the tables from cached JSON
```

Generated caches are gitignored. The hand-maintained files —
`data/registry-limits.tsv`, `data/rdap-overrides.tsv`, `data/tld-flags.tsv` (and its
`reputation.tsv` alias) — **are** committed, and `bootstrap.sh` never overwrites them.
If you add registry knowledge, that is where it goes.

## Running the tests

```bash
tests/test.sh                          # everything, including network tests
DS_TEST_SKIP_NETWORK=1 tests/test.sh   # offline only - what CI runs
```

The suite is plain bash: `ok` / `FAIL` / `skip` per test, non-zero exit on any
failure. Tests are in two groups:

- **Offline** — the default group. No network, no credentials, no writes outside a
  temp dir. These must pass on a fresh clone with an empty `data/`, because that is
  exactly what CI has.
- **Network** — real registry lookups, skipped when `DS_TEST_SKIP_NETWORK=1`. CI sets
  that, so pull requests never hammer someone's RDAP server. Run them locally before
  you open a PR that touches lookup or parsing code.

Add tests next to the section they belong to, using the existing `assert_eq`,
`assert_contains` and `assert_rc` helpers. Anything needing the network goes in the
network section, behind the same env var — never in the offline group.

Changes to `SKILL.md` or `install.sh` must remain compatible with both Claude Code and Codex. Claude Code is the installer's default target; tests should also exercise `--target codex` and `--target both`. Keep host-specific discovery paths and invocation syntax in the installation docs rather than forking the skill definition.

Lint before pushing (CI runs the same commands):

```bash
shellcheck -x -P scripts -S warning scripts/*.sh tests/*.sh install.sh
markdownlint-cli2 "**/*.md"
```

## Recording the demo

`demo/demo.tape` requires VHS, a signed-in Codex CLI, and the skill installed with `./install.sh --target codex`. Export your Porkbun credentials in the shell for the live quote. Never put them in the tape or recorded terminal.

The tape runs Codex with `danger-full-access` so it can use the network. Run it in a checkout where you are comfortable granting that access:

```bash
vhs demo/demo.tape
```

The recording waits for a specific live price for `shed.link`. If that price changes, update the wait pattern and price captions to match the actual result before recording. Keep repository links pointed at `jhammant/DomainSaver`.

## House rules

- **Markdown code fences must be language-labelled.** Use ` ```bash `, ` ```yaml `,
  ` ```json `, ` ```text ` — never a bare ` ``` `. Unlabelled fences fail markdown
  linting and lose syntax highlighting.
- **Commits follow [Conventional Commits](https://www.conventionalcommits.org/).**
  `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, `perf:`, `ci:`, with an
  optional scope: `fix(sweep): cap Identity Digital at one connection`. Keep the
  subject imperative and under ~72 characters. Reference issues in the PR
  description (`Closes #123`), not in individual commit messages.
- **Branches** are named for what they do: `feat/…`, `fix/…`, `docs/…`, `chore/…`.
- **Never commit credentials** or anything derived from them, and never write them to
  `data/`. `PORKBUN_API_KEY` / `PORKBUN_SECRET_KEY` live in your environment only.

## Pull requests

Keep them focused — one concern per PR. Before opening one:

1. `shellcheck -x -P scripts -S warning scripts/*.sh tests/*.sh install.sh` is clean.
   (`-S warning` matches CI: info-level style notes such as SC2317 on trap
   handlers vary between shellcheck releases and do not gate the build.)
2. `markdownlint-cli2 "**/*.md"` is clean.
3. `tests/test.sh` passes, including the network group if you touched lookup code.
4. New behaviour has a test; a bug fix has a test that fails without the fix.
5. Docs updated if you changed a flag, an env var, an agent-host integration or a data file format.

For registry behaviour, please say how you observed it — "measured: RDAP hangs above
one connection" is worth more than a guess, and that is the kind of note
`data/registry-limits.tsv` exists to record.
