# salvage — install, uninstall, test
#
# Everything installs under PREFIX, which defaults to ~/.local so no sudo is
# needed. Override for a system install:
#
#   make install PREFIX=/opt/homebrew
#   sudo make install PREFIX=/usr/local

PREFIX  ?= $(HOME)/.local
BINDIR   = $(DESTDIR)$(PREFIX)/bin
MANDIR   = $(DESTDIR)$(PREFIX)/share/man/man1
ZSHDIR   = $(DESTDIR)$(PREFIX)/share/zsh/site-functions
BASHDIR  = $(DESTDIR)$(PREFIX)/share/bash-completion/completions

.DEFAULT_GOAL := help
.PHONY: help install uninstall link unlink test list-tests lint lint-tools deps demo check-version dist hooks unhooks

T ?=

help: ## Show this help
	@printf 'salvage — targets\n\n'
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@printf '\nPREFIX is %s (override with make install PREFIX=...)\n' '$(PREFIX)'

install: ## Copy salvage, its man page and completions into PREFIX
	@mkdir -p $(BINDIR) $(MANDIR) $(ZSHDIR) $(BASHDIR)
	install -m 0755 salvage                  $(BINDIR)/salvage
	install -m 0644 doc/salvage.1            $(MANDIR)/salvage.1
	install -m 0644 completions/_salvage     $(ZSHDIR)/_salvage
	install -m 0644 completions/salvage.bash $(BASHDIR)/salvage
	@printf '\ninstalled to %s\n' '$(PREFIX)'
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
		*) printf '\n  NOTE: %s/bin is not on your PATH. Add:\n    export PATH="%s/bin:$$PATH"\n' '$(PREFIX)' '$(PREFIX)' ;; \
	esac
	@printf '\n  For zsh completion, ensure this is in ~/.zshrc before compinit:\n'
	@printf '    fpath=(%s/share/zsh/site-functions $$fpath)\n' '$(PREFIX)'
	@if [ -d "$$HOME/.oh-my-zsh/completions" ]; then \
		printf '\n  Or, since you use oh-my-zsh, simply:\n'; \
		printf '    ln -sf %s/share/zsh/site-functions/_salvage ~/.oh-my-zsh/completions/_salvage\n' '$(PREFIX)'; \
	fi
	@printf '\n  Then: salvage --help    man salvage\n\n'

uninstall: ## Remove everything install placed
	rm -f $(BINDIR)/salvage $(MANDIR)/salvage.1 $(ZSHDIR)/_salvage $(BASHDIR)/salvage
	@printf 'removed salvage from %s\n' '$(PREFIX)'

link: ## Symlink salvage into PREFIX/bin for development
	@mkdir -p $(BINDIR)
	ln -sf $(CURDIR)/salvage $(BINDIR)/salvage
	@printf 'linked %s -> %s\n' '$(BINDIR)/salvage' '$(CURDIR)/salvage'
	@printf 'NOTE: the repo must stay at this path or the link dangles.\n'

unlink: ## Remove the development symlink
	rm -f $(BINDIR)/salvage

test: ## Run the test suite (T="5 22" or T="-k newline" to select)
	@./tests/run.sh $(T)

list-tests: ## List the test groups
	@./tests/run.sh -l

SHELL_FILES = salvage tests/run.sh

# One entry point for static analysis, run byte-identically here and in CI.
# Severity and suppressions live in .shellcheckrc, not in this command line,
# so there is nothing to keep in sync between the two.
#
# A missing tool is an ERROR, not a skip. A linter that quietly does nothing
# is worse than no linter: CI stays green while checking less than you think.
# Use `make lint SKIP_MISSING=1` to downgrade that to a warning.
lint: ## Static analysis — shellcheck + actionlint (exactly what CI runs)
	@fail=0; \
	for f in $(SHELL_FILES); do \
		bash -n "$$f" || fail=1; \
	done; \
	printf '  ok       bash -n (%s)\n' '$(SHELL_FILES)'; \
	if command -v shellcheck >/dev/null 2>&1; then \
		if shellcheck $(SHELL_FILES); then \
			printf '  ok       shellcheck %s, severity=style\n' \
				"$$(shellcheck --version | awk '/^version:/{print $$2}')"; \
		else fail=1; fi; \
	elif [ -n "$(SKIP_MISSING)" ]; then \
		printf '  skipped  shellcheck (not installed)\n'; \
	else \
		printf '  MISSING  shellcheck — brew install shellcheck\n' >&2; fail=1; \
	fi; \
	if command -v actionlint >/dev/null 2>&1; then \
		if actionlint; then \
			printf '  ok       actionlint %s\n' "$$(actionlint --version | head -1)"; \
		else fail=1; fi; \
	elif [ -n "$(SKIP_MISSING)" ]; then \
		printf '  skipped  actionlint (not installed)\n'; \
	else \
		printf '  MISSING  actionlint — brew install actionlint\n' >&2; fail=1; \
	fi; \
	if [ $$fail -eq 0 ]; then printf 'static analysis clean\n'; \
	else printf 'static analysis FAILED\n' >&2; fi; \
	exit $$fail

# core.hooksPath is per-clone git config, not something a checkout can carry, so
# this has to be run once per machine. The hooks themselves are committed.
hooks: ## Enable the committed git hooks (once per clone)
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@printf 'hooks enabled — pre-commit runs lint, pre-push runs the full suite\n'

unhooks: ## Disable the committed git hooks
	@git config --unset core.hooksPath || true
	@printf 'hooks disabled\n'

lint-tools: ## Install the static analysis tools
	brew install shellcheck actionlint

deps: ## Check for rmlint and jq
	@for c in rmlint jq; do \
		if command -v $$c >/dev/null 2>&1; then printf '  ok      %s\n' "$$c"; \
		else printf '  MISSING %s\n' "$$c"; fi; \
	done
	@printf '\ninstall with: brew install rmlint jq\n'

demo: ## Run salvage against the bundled example
	@./salvage examples/project -r examples/backup || true

VERSION = $(shell sed -n 's/^VERSION="\(.*\)"/\1/p' salvage)

check-version: ## Verify the version agrees across the script and the man page
	@script_v='$(VERSION)'; \
	man_v=$$(sed -n '1s/.*"salvage \([0-9][0-9.]*\)".*/\1/p' doc/salvage.1); \
	if [ -z "$$script_v" ]; then echo "could not read VERSION from salvage" >&2; exit 1; fi; \
	if [ "$$script_v" != "$$man_v" ]; then \
		echo "version mismatch: salvage=$$script_v doc/salvage.1=$$man_v" >&2; exit 1; \
	fi; \
	if [ -n "$(EXPECT)" ] && [ "$(EXPECT)" != "$$script_v" ]; then \
		echo "version mismatch: tag=$(EXPECT) salvage=$$script_v" >&2; exit 1; \
	fi; \
	echo "version $$script_v consistent"

dist: check-version ## Build a release tarball in dist/
	@rm -rf dist && mkdir -p dist/salvage-$(VERSION)
	@cp -R salvage README.md LICENSE Makefile doc completions examples dist/salvage-$(VERSION)/
	@tar -czf dist/salvage-$(VERSION).tar.gz -C dist salvage-$(VERSION)
	@cp salvage dist/salvage
	@rm -rf dist/salvage-$(VERSION)
	@cd dist && shasum -a 256 salvage salvage-$(VERSION).tar.gz > SHA256SUMS
	@echo "built:"; ls -1 dist
