IMAGE_NAME ?= quotes-scraper
OUT_DIR    ?= out
TF_DIR     := infra
COMPOSE    ?= docker compose

# OpenTofu: если бинарник положили рядом в .tools/, используем его, иначе берём tofu
# из PATH. Путь абсолютный, потому что цели делают `cd $(TF_DIR)` — относительный
# там ломается. Переопределяется: make provision TOFU=tofu
TOFU_LOCAL := $(firstword $(wildcard $(CURDIR)/.tools/tofu.exe) $(wildcard $(CURDIR)/.tools/tofu))
TOFU       ?= $(or $(TOFU_LOCAL),tofu)

.PHONY: build provision deploy run clean destroy ci fmt fmt-check validate plan plan-check check-tofu

# Убедиться, что OpenTofu вообще доступен: понятная ошибка вместо command not found.
check-tofu:
	@$(TOFU) version >/dev/null 2>&1 \
		|| { echo "Ошибка: OpenTofu не найден. Установите tofu в PATH или положите бинарник в .tools/tofu (.exe). TOFU='$(TOFU)'"; exit 1; }

# Собрать образ скрапера-воркера.
build:
	$(COMPOSE) build scraper

# Поднять Floci и создать S3 bucket + SQS queue через OpenTofu.
provision: check-tofu
	$(COMPOSE) up -d --wait floci
	cd $(TF_DIR) && $(TOFU) init -input=false
	cd $(TF_DIR) && $(TOFU) apply -auto-approve -input=false

# Собрать образ и запустить воркер с параметрами подключения из environment.
deploy: provision
	$(COMPOSE) build scraper
	$(COMPOSE) up -d --no-deps --force-recreate scraper

# Отправить одно задание и проверить, что результат появился в S3,
# а сообщение удалено из очереди.
run: deploy
	$(COMPOSE) run --rm --no-deps scraper python src/send_job.py

# Удалить локальные артефакты, не трогая инфраструктуру (для неё есть destroy).
clean:
	-$(COMPOSE) rm -sf scraper
	-docker rmi $(IMAGE_NAME)
	-rm -rf $(OUT_DIR)

# Удалить ресурсы OpenTofu и остановить окружение. Повторный запуск безопасен.
destroy: check-tofu
	-cd $(TF_DIR) && $(TOFU) destroy -auto-approve -input=false
	-$(COMPOSE) down --remove-orphans

ci:
	$(MAKE) fmt-check
	$(MAKE) validate
	$(MAKE) provision
	$(MAKE) plan-check
	$(MAKE) build

fmt: check-tofu
	$(TOFU) fmt -recursive $(TF_DIR)

fmt-check: check-tofu
	$(TOFU) fmt -check -recursive $(TF_DIR)

validate: check-tofu
	cd $(TF_DIR) && $(TOFU) init -backend=false -input=false
	cd $(TF_DIR) && $(TOFU) validate

plan: check-tofu
	cd $(TF_DIR) && $(TOFU) plan -input=false

# -detailed-exitcode: 0 — изменений нет, 2 — есть (для CI это ошибка).
plan-check: check-tofu
	cd $(TF_DIR) && $(TOFU) plan -input=false -detailed-exitcode