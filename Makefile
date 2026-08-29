.PHONY: hooks
hooks:
	chmod +x $(realpath ./hooks/pre-commit.sh)
	ln -sf $(realpath ./hooks/pre-commit.sh) $(CURDIR)/.git/hooks/pre-commit

# the only reason is i'm using this over "zig build --watch" is because
# this clears the terminal on every change, less noisy.
.PHONY: dev
dev:
	watchexec -e zig -- "clear && zig build test"
