SCHEME := VikunjaExtension

.DEFAULT_GOAL := build
.PHONY: build release test test-live install install-restart package logs clean

build:
	@./scripts/tuna-extension build --scheme $(SCHEME)

release:
	@./scripts/tuna-extension build --scheme $(SCHEME) --release

test:
	@./scripts/tuna-extension test --scheme $(SCHEME)

# Also runs the live API tests, which create, complete, and delete a task on your server.
test-live:
	@TEST_RUNNER_VIKUNJA_LIVE_TESTS=1 ./scripts/tuna-extension test --scheme $(SCHEME)

install:
	@./scripts/tuna-extension install --scheme $(SCHEME)

install-restart:
	@./scripts/tuna-extension install --scheme $(SCHEME) --restart

package:
	@./scripts/tuna-extension package --scheme $(SCHEME)

logs:
	@./scripts/tuna-extension logs --last 20m

clean:
	rm -rf ./build ./dist
