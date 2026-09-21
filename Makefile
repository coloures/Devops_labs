IMAGE_NAME ?= quotes-scraper
OUT_DIR    ?= out

.PHONY: build run clean ci

build:
	docker build -t $(IMAGE_NAME) .

run:
	@mkdir -p $(OUT_DIR)
	docker run --rm -v "$$(pwd)/$(OUT_DIR)":/app/out $(IMAGE_NAME)

clean:
	docker rmi $(IMAGE_NAME) 2>/dev/null || true
	rm -rf $(OUT_DIR)

ci: build run
	@python -c "import json,sys; d=json.load(open('$(OUT_DIR)/result.json', encoding='utf-8')); assert isinstance(d,list) and len(d)>0, 'empty result'; print('CI OK:', len(d), 'quotes')"