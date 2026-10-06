IMAGE_NAME ?= quotes-scraper
OUT_DIR    ?= out

.PHONY: build run clean ci

build:
	docker build -t $(IMAGE_NAME) .

run: build
	docker run --rm -v "$(CURDIR)/$(OUT_DIR)":/app/out $(IMAGE_NAME)

clean:
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
	rm -rf $(OUT_DIR)

ci: build run