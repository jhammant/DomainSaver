#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# USAGE:
#   __SCRIPT_NAME__ - install the DomainSaver domain-search skill for Claude or Codex
#
# INSTALL:
#   ./__SCRIPT_NAME__                         # Claude Code (the default)
#   ./__SCRIPT_NAME__ --target codex          # Codex
#   ./__SCRIPT_NAME__ --target both           # both hosts, one shared checkout
#   ./__SCRIPT_NAME__ --copy --target codex   # snapshot instead of a link
#
# UNINSTALL:
#   ./__SCRIPT_NAME__ --uninstall                         # Claude Code
#   ./__SCRIPT_NAME__ --uninstall --target codex          # Codex
#   ./__SCRIPT_NAME__ --uninstall --target both           # both hosts
#
# OPTIONS:
#   -t, --target TARGET  Install for claude, codex or both (default: claude).
#                        Fresh Codex installs use ~/.agents/skills; an existing
#                        ~/.codex/skills/domain-search install stays there.
#                        Claude Code uses
#                        ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills.
#       --copy           Copy the toolkit instead of symlinking it. Use this
#                        when the checkout will be moved or deleted; re-run the
#                        installer to pick up later changes. With target both,
#                        this creates two independent snapshots.
#       --symlink        Link to this checkout (the default). A git pull updates
#                        the installed skill, and data/ caches are shared.
#       --uninstall      Remove an installed skill and exit.
#   -p, --prefix DIR     Install into this skills directory. Valid with one
#                        target only; overrides that target's default path.
#   -f, --force          Replace an existing installation. With --uninstall,
#                        also remove a directory not recognised as DomainSaver.
#   -n, --dry-run        Print what would happen and change nothing.
#   -q, --quiet          Print only warnings and errors.
#   -h, --help           Show this help text.
#   -V, --version        Show the installer version.
#
# ENVIRONMENT:
#   CLAUDE_CONFIG_DIR    Override Claude Code's ~/.claude configuration root.
#   CODEX_HOME           Compatibility override for the Codex skills root;
#                        the installer uses $CODEX_HOME/skills.
#   PORKBUN_API_KEY      Optional public key used later by quote.sh.
#   PORKBUN_SECRET_KEY   Optional secret key used later by quote.sh.
#
# AFTER INSTALLING:
#   1. Populate the public-data caches:
#        <skill-dir>/scripts/bootstrap.sh
#   2. Optionally export PORKBUN_API_KEY and PORKBUN_SECRET_KEY for real
#      per-name quotes. Keep both credentials out of the repository.
#   3. Start or restart the selected host, then invoke the skill as:
#        Claude Code:  /domain-search
#        Codex:        $domain-search
#
# EXIT STATUS:
#   0  Installed, uninstalled, or nothing to do
#   1  Failure (bad path, refused overwrite, or missing files)
#   2  Usage error
# ENDUSAGE
# ---------------------------------------------------------------------------
#
# WHAT IT INSTALLS
#   <skills-dir>/domain-search/
#     SKILL.md      the skill definition the agent reads
#     scripts/      bootstrap.sh, generate.sh, check.sh, sweep.sh, quote.sh, lib.sh
#     wordlists/    curated candidate wordlists
#     data/         the derived caches (created by bootstrap.sh if absent)
#
#   SYMLINK MODE (default) links the skill directory to this checkout, so
#   `git pull` updates the installed skill and the caches in data/ are shared
#   with the repo. Both hosts support linked skill directories; linking the
#   package as a whole also avoids host-specific treatment of a linked SKILL.md.
#   COPY MODE takes a snapshot, which survives the checkout being moved or
#   deleted but has to be re-installed to update.
#
# DESIGN CONSTRAINTS (same as the rest of the toolkit, deliberate):
#   * bash 3.2 compatible - no associative arrays, no `declare -A`, no readarray.
#   * POSIX-ish tools only, no GNU-only flags, never `sed -i`.
#   * Idempotent, and never destructive by surprise: an existing installation is
#     only replaced with --force, and --uninstall refuses to delete a directory
#     it cannot prove it created.
#   * No credentials are read, written or needed. PORKBUN_API_KEY /
#     PORKBUN_SECRET_KEY stay in your shell, and only quote.sh ever reads them.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly IN_VERSION="1.2.0"
readonly IN_SKILL_NAME="domain-search"
readonly IN_MARKER=".domainsaver-install"

# Everything installed, in order. Missing optional items are skipped with a
# note rather than failing the install.
IN_REQUIRED_ITEMS="SKILL.md scripts"
IN_OPTIONAL_ITEMS="wordlists data README.md LICENSE"

IN_MODE="symlink" # symlink | copy
IN_ACTION="install"
IN_TARGET="claude" # claude | codex | both
IN_FORCE=0
IN_DRYRUN=0
IN_QUIET=0
IN_SKILLS_DIR=""

# Print an informational message unless quiet mode is enabled.
info() {
	[ "$IN_QUIET" = "1" ] && return 0
	printf '%s\n' "$*"
	return 0
}

# Print a warning message to stderr.
warning() {
	printf 'WARN: %s\n' "$*" >&2
	return 0
}

# Print an error message to stderr.
error() {
	printf 'ERROR: %s\n' "$*" >&2
	return 0
}

# Print an error message and exit with a general failure status.
die() {
	error "$*"
	exit 1
}

# _in_run <description> <command...>
#   Runs a command, or prints it under --dry-run. Every filesystem mutation in
#   this script goes through here, so --dry-run is genuinely side-effect free.
_in_run() {
	local what="$1"
	shift
	if [ "$IN_DRYRUN" = "1" ]; then
		info "would $what"
		return 0
	fi
	"$@" || die "failed to $what"
	return 0
}

# Print the embedded usage text from the script header.
usage() {
	awk -v script_name="$SCRIPT_NAME" '
		BEGIN { printing = 0 }
		/^# USAGE:/ { printing = 1; next }
		printing && /^# ENDUSAGE/ { exit }
		printing {
			sub(/^#[ ]?/, "", $0)
			gsub(/__SCRIPT_NAME__/, script_name, $0)
			print
		}
	' "$SELF_PATH"
}

# Print an argument error with usage and exit with status 2.
_in_usage_error() {
	error "$*"
	printf '\n' >&2
	usage >&2
	exit 2
}

# Parse installer options into the global installation settings.
_in_parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-t | --target)
			[ "$#" -ge 2 ] || _in_usage_error "$1 needs codex, claude or both"
			IN_TARGET="$2"
			shift 2
			;;
		--target=*)
			IN_TARGET="${1#*=}"
			shift
			;;
		--copy)
			IN_MODE="copy"
			shift
			;;
		--symlink | --link)
			IN_MODE="symlink"
			shift
			;;
		--uninstall | --remove)
			IN_ACTION="uninstall"
			shift
			;;
		-f | --force)
			IN_FORCE=1
			shift
			;;
		-n | --dry-run)
			IN_DRYRUN=1
			shift
			;;
		-q | --quiet)
			IN_QUIET=1
			shift
			;;
		-p | --prefix)
			[ "$#" -ge 2 ] || _in_usage_error "--prefix needs a directory"
			IN_SKILLS_DIR="$2"
			shift 2
			;;
		--prefix=*)
			IN_SKILLS_DIR="${1#*=}"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			printf '%s %s (DomainSaver)\n' "$SCRIPT_NAME" "$IN_VERSION"
			exit 0
			;;
		--)
			shift
			[ "$#" -eq 0 ] || _in_usage_error "unexpected argument: $1"
			break
			;;
		-*) _in_usage_error "unknown option: $1" ;;
		*) _in_usage_error "unexpected argument: $1 (this script takes options only)" ;;
		esac
	done

	case "$IN_TARGET" in
	codex | claude | both) ;;
	*) _in_usage_error "unknown target '$IN_TARGET' (expected codex, claude or both)" ;;
	esac
	if [ "$IN_TARGET" = "both" ] && [ -n "$IN_SKILLS_DIR" ]; then
		_in_usage_error "--prefix cannot be combined with --target both; select one target at a time for custom paths"
	fi
	return 0
}

# _in_resolve_self_dir
#   Stdout: the absolute directory containing this script, following symlinks,
#   so `~/bin/domainsaver-install -> .../DomainSaver/install.sh` still finds the
#   real checkout.
_in_resolve_self_dir() {
	_ins_src="${BASH_SOURCE[0]:-$0}"
	while [ -h "$_ins_src" ]; do
		_ins_dir=$(cd -P "$(dirname "$_ins_src")" >/dev/null 2>&1 && pwd)
		_ins_src=$(readlink "$_ins_src")
		case "$_ins_src" in
		/*) ;;
		*) _ins_src="$_ins_dir/$_ins_src" ;;
		esac
	done
	cd -P "$(dirname "$_ins_src")" >/dev/null 2>&1 && pwd
}

# _in_skills_dir <target>
#   Stdout: the selected host's personal skills directory. --prefix wins for a
#   single target. CODEX_HOME/skills remains a compatibility override for Codex
#   installations made by DomainSaver 1.1 and older.
_in_skills_dir() {
	if [ -n "$IN_SKILLS_DIR" ]; then
		printf '%s\n' "$IN_SKILLS_DIR"
		return 0
	fi
	case "$1" in
	claude)
		printf '%s/skills\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
		;;
	codex)
		if [ -n "${CODEX_HOME:-}" ]; then
			printf '%s/skills\n' "$CODEX_HOME"
		elif [ -e "$HOME/.codex/skills/$IN_SKILL_NAME" ] || [ -h "$HOME/.codex/skills/$IN_SKILL_NAME" ]; then
			# Keep updating an installation created by DomainSaver 1.1 rather
			# than leaving a duplicate skill at the current official location.
			printf '%s/.codex/skills\n' "$HOME"
		else
			printf '%s/.agents/skills\n' "$HOME"
		fi
		;;
	esac
	return 0
}

# _in_check_source <src>
#   Fatal unless <src> looks like a DomainSaver checkout with a usable skill.
_in_check_source() {
	_inc_src="$1"

	[ -f "$_inc_src/SKILL.md" ] ||
		die "no SKILL.md beside $SCRIPT_NAME ($_inc_src) - run this from a DomainSaver checkout"
	grep -q "^name:[ ]*$IN_SKILL_NAME" "$_inc_src/SKILL.md" ||
		die "$_inc_src/SKILL.md does not declare 'name: $IN_SKILL_NAME'"
	[ -d "$_inc_src/scripts" ] ||
		die "no scripts/ directory in $_inc_src - the checkout is incomplete"

	for _inc_s in lib.sh bootstrap.sh generate.sh check.sh sweep.sh quote.sh; do
		[ -f "$_inc_src/scripts/$_inc_s" ] ||
			die "missing $_inc_src/scripts/$_inc_s - the checkout is incomplete"
	done

	unset _inc_src _inc_s 2>/dev/null || true
	return 0
}

# _in_check_deps
#   Warns about anything the toolkit needs at run time. Never fatal: installing
#   on a machine that has yet to `brew install jq` is entirely reasonable.
_in_check_deps() {
	_ind_missing=""
	for _ind_t in bash curl jq awk whois; do
		command -v "$_ind_t" >/dev/null 2>&1 || _ind_missing="$_ind_missing $_ind_t"
	done
	if [ -n "$_ind_missing" ]; then
		warning "not on PATH:$_ind_missing"
		case "$_ind_missing" in
		*jq*) warning "  jq is required by bootstrap.sh, quote.sh and RDAP response validation" ;;
		esac
		case "$_ind_missing" in
		*whois*) warning "  whois is required for no-RDAP TLDs such as .io, .co, .me and .de" ;;
		esac
		case "$_ind_missing" in
		*curl*) warning "  curl is required for every RDAP lookup" ;;
		esac
	fi
	unset _ind_missing _ind_t 2>/dev/null || true
	return 0
}

# _in_is_ours <dest>
#   Exit 0 for a valid copy or legacy symlink-mode marker, or for a
#   DomainSaver directory symlink that can be unlinked without its target.
_in_is_ours() {
	if [ -h "$1" ]; then
		[ -f "$1/SKILL.md" ] &&
			grep -q "^name:[ ]*$IN_SKILL_NAME" "$1/SKILL.md" 2>/dev/null && return 0
		return 1
	fi

	[ -f "$1/$IN_MARKER" ] || return 1
	grep -qx "skill=$IN_SKILL_NAME" "$1/$IN_MARKER" 2>/dev/null &&
		grep -Eqx 'mode=(copy|symlink)' "$1/$IN_MARKER" 2>/dev/null
}

# _in_preflight_parent <skills-dir>
#   Verifies that an existing skills directory is writable, or that its nearest
#   existing ancestor can create it. No check is needed for a dry run.
_in_preflight_parent() {
	local path parent next
	path="$1"
	[ "$IN_DRYRUN" = "1" ] && return 0

	if [ -e "$path" ] && [ ! -d "$path" ]; then
		die "$path exists but is not a directory"
	fi
	parent="$path"
	while [ ! -d "$parent" ]; do
		next=$(dirname "$parent")
		[ "$next" != "$parent" ] || break
		parent="$next"
	done
	[ -w "$parent" ] || die "$path cannot be created from unwritable parent $parent"
	return 0
}

# _in_preflight_target <target> <source>
#   Validates one destination without changing it. main checks every selected
#   target before processing any of them, preventing partial --target both runs.
_in_preflight_target() {
	local target source skills dest
	target="$1"
	source="$2"
	skills=$(_in_skills_dir "$target")
	dest="$skills/$IN_SKILL_NAME"

	case "$IN_ACTION" in
	install)
		_in_check_source "$source"
		_in_preflight_parent "$skills"
		if [ -e "$dest" ] || [ -h "$dest" ]; then
			if [ "$IN_FORCE" != "1" ]; then
				error "$dest already exists."
				if _in_is_ours "$dest"; then
					printf '       It looks like an existing DomainSaver install; re-run with --force to replace it.\n' >&2
				else
					printf '       It does NOT look like a DomainSaver install, so this script will not touch it.\n' >&2
					printf '       Move it aside, or re-run with --force if you are sure.\n' >&2
				fi
				exit 1
			fi
		fi
		;;
	uninstall)
		if [ -e "$dest" ] || [ -h "$dest" ]; then
			_in_preflight_parent "$skills"
			if ! _in_is_ours "$dest" && [ "$IN_FORCE" != "1" ]; then
				error "$dest is not recognisably a DomainSaver install"
				printf '       (no valid %s marker or DomainSaver skill symlink).\n' "$IN_MARKER" >&2
				printf '       Refusing to delete it. Re-run with --force if you are sure.\n' >&2
				exit 1
			fi
		fi
		;;
	esac
	return 0
}

# _in_remove <dest>
#   Removes an installed skill directory (or a symlink standing in for one).
_in_remove() {
	if [ -h "$1" ]; then
		_in_run "remove symlink $1" rm -f "$1"
	else
		_in_run "remove directory $1" rm -rf "$1"
	fi
	return 0
}

# _in_install_item <src> <dest> <name>
#   Copies one top-level item into a snapshot install. An existing entry of the
#   same name is replaced (the directory itself was already cleared or is new).
_in_install_item() {
	_ini_src="$1/$3"
	_ini_dst="$2/$3"

	[ -e "$_ini_src" ] || return 1

	if [ -e "$_ini_dst" ] || [ -h "$_ini_dst" ]; then
		_in_run "replace $_ini_dst" rm -rf "$_ini_dst"
	fi

	# -R (not -a, not -L): the only spelling portable across BSD and GNU cp.
	# It copies the data/ alias symlinks as symlinks, which is correct - they
	# are relative, so they keep resolving inside the snapshot.
	_in_run "copy $3 -> $_ini_dst" cp -R "$_ini_src" "$_ini_dst"

	unset _ini_src _ini_dst 2>/dev/null || true
	return 0
}

# _in_write_marker <src> <dest>
#   Records what was installed, how and from where in a snapshot install.
#   Linked installs are already self-identifying through their symlink target.
_in_write_marker() {
	if [ "$IN_DRYRUN" = "1" ]; then
		info "would write $2/$IN_MARKER"
		return 0
	fi
	{
		printf '# DomainSaver skill installation marker - safe to delete.\n'
		printf '# Its presence is what lets install.sh --uninstall remove this\n'
		printf '# directory without being asked to --force.\n'
		printf 'skill=%s\n' "$IN_SKILL_NAME"
		printf 'source=%s\n' "$1"
		printf 'mode=%s\n' "$IN_MODE"
		printf 'installer=%s\n' "$IN_VERSION"
		printf 'installed=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
	} >"$2/$IN_MARKER" || die "cannot write $2/$IN_MARKER"
	return 0
}

# _in_do_install <source> <destination> <target>
#   Installs one host's copy or symlink after its destination is resolved.
_in_do_install() {
	_ind_src="$1"
	_ind_dest="$2"
	_ind_target="$3"

	if [ -e "$_ind_dest" ] || [ -h "$_ind_dest" ]; then
		info "replacing existing installation at $_ind_dest"
		_in_remove "$_ind_dest"
	fi

	if [ "$IN_MODE" = "symlink" ]; then
		# Both hosts follow symlinked skill directories. Link the package as one
		# unit so SKILL.md and all of its supporting files stay together.
		_in_run "link $_ind_src -> $_ind_dest" ln -s "$_ind_src" "$_ind_dest"
	else
		_in_run "create $_ind_dest" mkdir -p "$_ind_dest"

		for _ind_item in $IN_REQUIRED_ITEMS; do
			_in_install_item "$_ind_src" "$_ind_dest" "$_ind_item" ||
				die "required item missing from the checkout: $_ind_item"
		done
		for _ind_item in $IN_OPTIONAL_ITEMS; do
			if [ -e "$_ind_src/$_ind_item" ]; then
				_in_install_item "$_ind_src" "$_ind_dest" "$_ind_item" || true
			fi
		done

		_in_write_marker "$_ind_src" "$_ind_dest"
	fi

	# The scripts are run directly by the agent, so make sure they are runnable
	# even from a checkout that lost its permission bits (a zip download will).
	if [ "$IN_MODE" = "copy" ] && [ "$IN_DRYRUN" != "1" ]; then
		chmod 0755 "$_ind_dest"/scripts/*.sh 2>/dev/null || true
	fi

	_in_check_deps

	info ""
	info "installed: $_ind_dest"
	info "  mode:    $IN_MODE ($( [ "$IN_MODE" = symlink ] && printf 'tracks %s' "$_ind_src" || printf 'snapshot of %s' "$_ind_src" ))"
	info "  target:  $_ind_target"
	info ""
	info "Next steps for $_ind_target:"
	info "  1. $_ind_dest/scripts/bootstrap.sh"
	info "       downloads the IANA RDAP map and the public Porkbun price list."
	info "       No credentials needed."
	info "  2. optional, for real per-name quotes (the only way to get a verdict"
	info "     of AVAILABLE instead of UNREGISTERED):"
	info "       export PORKBUN_API_KEY='pk1_...'"
	info "       export PORKBUN_SECRET_KEY='sk1_...'"
	info "       key: https://porkbun.com/account/api  (never commit it)"
	case "$_ind_target" in
	claude) info "  3. start or restart Claude Code, then invoke /$IN_SKILL_NAME." ;;
	codex) info "  3. start or restart Codex, then invoke \$$IN_SKILL_NAME." ;;
	esac
	if [ "$IN_MODE" = "symlink" ]; then
		info ""
		info "Note: this install points at $_ind_src."
		info "      Moving or deleting that checkout breaks the skill; re-run"
		info "      $SCRIPT_NAME --copy --force if you want a standalone snapshot."
	fi

	unset _ind_src _ind_dest _ind_target _ind_item 2>/dev/null || true
	return 0
}

# _in_do_uninstall <destination>
#   Removes one selected host's installation when it is recognisably ours.
_in_do_uninstall() {
	_inu_dest="$1"

	if [ ! -e "$_inu_dest" ] && [ ! -h "$_inu_dest" ]; then
		info "nothing to do: $_inu_dest does not exist"
		return 0
	fi

	_in_remove "$_inu_dest"
	info "removed: $_inu_dest"
	info "note: caches in the original checkout's data/ were not touched."
	unset _inu_dest
	return 0
}

# _in_process_target <target> <source>
#   Resolves one host's destination and performs the requested action.
_in_process_target() {
	_inp_target="$1"
	_inp_src="$2"
	_inp_skills=$(_in_skills_dir "$_inp_target")
	_inp_dest="$_inp_skills/$IN_SKILL_NAME"

	case "$IN_ACTION" in
	uninstall)
		_in_do_uninstall "$_inp_dest"
		;;
	install)
		info "installing the $IN_SKILL_NAME skill for $_inp_target"
		info "  from: $_inp_src"
		info "  to:   $_inp_dest"
		if [ ! -d "$_inp_skills" ]; then
			_in_run "create $_inp_skills" mkdir -p "$_inp_skills"
		fi
		[ -w "$_inp_skills" ] || [ "$IN_DRYRUN" = "1" ] ||
			die "$_inp_skills is not writable"
		_in_do_install "$_inp_src" "$_inp_dest" "$_inp_target"
		;;
	esac

	unset _inp_target _inp_src _inp_skills _inp_dest 2>/dev/null || true
	return 0
}

# Parse arguments and execute the selected host operations.
main() {
	local source_dir targets target

	_in_parse_args "$@"

	source_dir=$(_in_resolve_self_dir) || die "cannot resolve the directory of this script"
	[ "$IN_DRYRUN" = "1" ] && info "dry run: nothing will be changed"

	case "$IN_TARGET" in
	both) targets="claude codex" ;;
	*) targets="$IN_TARGET" ;;
	esac
	for target in $targets; do
		_in_preflight_target "$target" "$source_dir"
	done
	for target in $targets; do
		_in_process_target "$target" "$source_dir"
	done
	return 0
}

main "$@"

# End of install.sh
