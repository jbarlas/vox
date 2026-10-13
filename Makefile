.DEFAULT_GOAL := help

SWIFT ?= swift
MODEL ?= small.en
# /usr/local is Homebrew's own prefix (and thus user-writable) on Intel, but
# on Apple Silicon Homebrew lives at /opt/homebrew and /usr/local is left
# root-owned, so `make install` fails without sudo. Match whichever prefix
# Homebrew is actually using; fall back to /usr/local when Homebrew isn't
# installed.
PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)
CONFIGURATION ?= release
VOX := .build/$(CONFIGURATION)/vox
WHISPER_LIB := vendor/whisper.cpp/install/lib/libvox-whisper.a
# Records the submodule commit the library was built from, so a submodule
# update rebuilds it. Written only after a successful build, and read from the
# submodule then, since build-whisper.sh may initialize it during the build.
WHISPER_STAMP := vendor/whisper.cpp/install/.vox-commit
WHISPER_COMMIT := $(shell [ -e vendor/whisper.cpp/.git ] && git -C vendor/whisper.cpp rev-parse HEAD 2>/dev/null)
WHISPER_BUILT := $(shell cat $(WHISPER_STAMP) 2>/dev/null)
APP_BUNDLE ?= dist/Vox.app

# Every target must run from the repo root: Package.swift's whisper link flags
# are relative paths.
.PHONY: FORCE help setup whisper cli config-init model app sign notarize brew-formula test test-update lint format install uninstall clean distclean

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: cli config-init model ## Build the CLI, write a starter config, download the default model
	@echo "==> Ready. Try: $(VOX) record --output json"

whisper: $(WHISPER_LIB) ## Build the vendored whisper.cpp static library

$(WHISPER_LIB): $(if $(WHISPER_COMMIT),$(if $(filter $(WHISPER_COMMIT),$(WHISPER_BUILT)),,FORCE),FORCE)
	./scripts/build-whisper.sh
	@mkdir -p $(dir $(WHISPER_STAMP))
	@git -C vendor/whisper.cpp rev-parse HEAD > $(WHISPER_STAMP)

cli: whisper ## Build the vox CLI
	$(SWIFT) build -c $(CONFIGURATION) --product vox

config-init: cli ## Write a starter config if none exists
	$(VOX) config init --model $(MODEL)

model: ## Download the default model ($(MODEL))
	./scripts/download-model.sh $(MODEL)

app: whisper ## Build the menu bar app bundle into $(APP_BUNDLE)
	$(SWIFT) build -c $(CONFIGURATION) --product VoxApp
	$(SWIFT) build -c $(CONFIGURATION) --product vox
	CONFIGURATION=$(CONFIGURATION) VOX_APP_BUNDLE="$(APP_BUNDLE)" ./scripts/bundle-app.sh
	@installed="$$(command -v vox 2>/dev/null)"; \
	if [ -n "$$installed" ] && ! cmp -s "$(VOX)" "$$installed" 2>/dev/null; then \
		echo "==> Note: $$installed is out of date with the CLI just built; run 'make install' too, or the app and the installed vox will read/write config.json on different schemas."; \
	fi

sign: ## Sign $(APP_BUNDLE) (CODE_SIGN_IDENTITY or DEVELOPER_ID; otherwise ad-hoc)
	VOX_APP_BUNDLE="$(APP_BUNDLE)" ./scripts/sign.sh

notarize: ## Notarize and staple $(APP_BUNDLE)
	VOX_APP_BUNDLE="$(APP_BUNDLE)" ./scripts/notarize.sh

brew-formula: ## Generate dist/vox.rb for a Homebrew tap
	./scripts/generate-brew-formula.sh

test: ## Run the test suite
	$(SWIFT) test

test-update: ## Run the updater integration tests (scripts/update.sh, ~2 min)
	./scripts/test-update.py

lint: ## Check formatting (swift-format)
	@command -v swift-format >/dev/null \
		&& swift-format lint --recursive --strict Sources Tests \
		|| echo "swift-format not installed; skipping (brew install swift-format)"

format: ## Reformat sources in place
	@command -v swift-format >/dev/null \
		&& swift-format --in-place --recursive Sources Tests \
		|| echo "swift-format not installed; skipping (brew install swift-format)"

install: cli ## Install the CLI into $(PREFIX)/bin
	install -d "$(PREFIX)/bin"
	install -m 0755 "$(VOX)" "$(PREFIX)/bin/vox"
	@echo "==> Installed $(PREFIX)/bin/vox"

uninstall: ## Remove the installed CLI
	rm -f $(PREFIX)/bin/vox

clean: ## Remove Swift build products
	$(SWIFT) package clean
	rm -rf .build dist

distclean: clean ## Also remove the whisper.cpp build and install trees
	rm -rf vendor/whisper.cpp/build vendor/whisper.cpp/install
