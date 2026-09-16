.PHONY: hooks
hooks:
	chmod +x $(realpath ./hooks/pre-commit.sh)
	ln -sf $(realpath ./hooks/pre-commit.sh) $(CURDIR)/.git/hooks/pre-commit

# the only reason is i'm using this over "zig build --watch" is because
# this clears the terminal on every change, less noisy.
SEED_ARG := $(if $(SEED),--seed=$(SEED))
FILTER_ARG := $(if $(FILTER),-Dtest-filter=$(FILTER))

.PHONY: dev
dev:
	watchexec -e zig -- "clear && setarch $(uname -m) -R zig build test $(FILTER_ARG) $(SEED_ARG)"
