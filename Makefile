SHELL := /bin/bash
.PHONY: test syntax lint dry-run

test:
	bash tests/run.sh

syntax:
	@find . -type f \( -name '*.sh' -o -path './bin/alwayswork' \) -print0 \
		| xargs -0 -n1 bash -n && echo "syntax ok"

lint:
	shellcheck -x install.sh bin/alwayswork lib/*.sh commands/*.sh capabilities/*/*.sh

dry-run:
	@AW_ROOT="${PWD}" AW_TEST=1 AW_ETC=./tmp/etc AW_STATE=./tmp/state \
		AW_CONFIG=./tmp/etc/worker.yaml ./bin/alwayswork --dry-run bootstrap || true
