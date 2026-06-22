.PHONY: hooks
hooks:
	chmod +x $(realpath ./hooks/pre-commit.sh)
	ln -sf $(realpath ./hooks/pre-commit.sh) $(CURDIR)/.git/hooks/pre-commit
