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
.PHONY: help install uninstall link unlink test lint deps demo

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

test: ## Run the test suite
	@./tests/run.sh

lint: ## Run shellcheck if installed
	@command -v shellcheck >/dev/null 2>&1 \
		&& shellcheck -S warning salvage tests/run.sh && printf 'shellcheck clean\n' \
		|| printf 'shellcheck not installed — brew install shellcheck\n'

deps: ## Check for rmlint and jq
	@for c in rmlint jq; do \
		if command -v $$c >/dev/null 2>&1; then printf '  ok      %s\n' "$$c"; \
		else printf '  MISSING %s\n' "$$c"; fi; \
	done
	@printf '\ninstall with: brew install rmlint jq\n'

demo: ## Run salvage against the bundled example
	@./salvage examples/project -r examples/backup || true
