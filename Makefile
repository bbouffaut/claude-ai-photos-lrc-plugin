YARN ?= yarn
SERVER_DIR := server
TEST_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))

.PHONY: install build dev start health test clean

install:
	$(YARN) --cwd $(SERVER_DIR) install

build:
	$(YARN) --cwd $(SERVER_DIR) build

dev:
	$(YARN) --cwd $(SERVER_DIR) dev

start: build
	$(YARN) --cwd $(SERVER_DIR) start

health:
	curl http://localhost:3000/health

test:
	$(YARN) --cwd $(SERVER_DIR) test $(TEST_ARGS)

clean:
	rm -rf $(SERVER_DIR)/dist

%:
	@:
