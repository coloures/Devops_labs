# quotes-scraper

Скрапер на Python + Playwright, который открывает
<https://quotes.toscrape.com/scroll> в Chromium, доскролливает до конца
(данные подгружаются JS) и собирает цитаты. В лабораторной работе 2 он
работает как воркер: получает задание из SQS, сохраняет результат в S3 и
удаляет сообщение только после успешной записи.

## Архитектура

```
make run
   │  send_job.py: SendMessage + проверка результата
   ▼
┌──────────────┐   receive    ┌──────────────────┐   put_object   ┌──────────────┐
│ SQS quotes-  │ ───────────► │ scraper (worker) │ ─────────────► │ S3 quotes-   │
│ jobs         │              │ Playwright       │                │ results      │
└──────────────┘ ◄─────────── └──────────────────┘                └──────────────┘
                   delete_message (только после успешной записи)
```

Floci (`floci/floci:2.2.0`) эмулирует AWS локально на
`http://localhost:4566`. S3 bucket и SQS queue создаёт OpenTofu из
каталога `infra/`. Параметры подключения передаются приложению через
переменные окружения, endpoint и имена ресурсов в коде не зашиты.

## Структура

```
├── Dockerfile                 # multistage: deps -> browser -> runtime
├── Makefile                   # единственная точка входа
├── compose.yaml               # floci + scraper
├── infra/                     # OpenTofu: S3 bucket, SQS queue
│   ├── versions.tf
│   ├── provider.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── .terraform.lock.hcl    # коммитится
├── src/
│   ├── scrape.py              # Playwright-скрапер (lab 1)
│   ├── worker.py              # SQS -> scrape -> S3 -> delete
│   └── send_job.py            # отправка задания и проверка результата
├── out/                       # локальный результат (в git не коммитится)
└── .github/workflows/ci.yml
```

## Требования

- Docker с плагином `docker compose`;
- GNU Make;
- OpenTofu >= 1.6 (`tofu` в `PATH`, установка: <https://opentofu.org/docs/intro/install/>).

## Команды

```bash
make provision   # поднять Floci и создать bucket + queue через OpenTofu
make deploy      # собрать образ и запустить воркер с env-параметрами
make run         # отправить одно задание и дождаться результата в S3
make destroy     # удалить ресурсы OpenTofu и остановить окружение
make build       # только собрать образ
make clean       # удалить контейнер воркера, образ и out/
make fmt         # отформатировать OpenTofu-конфигурацию
make fmt-check   # проверка форматирования (используется в CI)
make validate    # tofu init -backend=false + tofu validate
make plan        # показать план изменений
make ci          # fmt-check + validate + provision + plan-check + build
```

### Быстрый старт

```bash
make provision
make deploy
make run
make destroy
```

`make run` печатает ключ объекта, проверяет, что в S3 лежит непустой
JSON-массив, и что обработанное сообщение удалено из очереди. Повторный
`make provision` не меняет инфраструктуру (`No changes`), повторный
`make destroy` завершается без ошибки.

### Переменные окружения

| Переменная | Где задаётся | Назначение | Значение по умолчанию |
|---|---|---|---|
| `AWS_ENDPOINT_URL` | `compose.yaml` | endpoint Floci внутри compose-сети | `http://floci:4566` |
| `AWS_DEFAULT_REGION` | `compose.yaml` | регион | `us-east-1` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `compose.yaml` | тестовые credentials | `test` |
| `SQS_QUEUE_NAME` | `compose.yaml` / environment | имя очереди | `quotes-jobs` |
| `S3_BUCKET` | `compose.yaml` / environment | имя bucket | `quotes-results` |
| `SCRAPE_URL` | `compose.yaml` / environment | страница для скрапинга | `https://quotes.toscrape.com/scroll` |
| `SQS_WAIT_TIME_SECONDS` | `compose.yaml` / environment | long polling | `10` |

Endpoint в коде не зашит: приложение читает `AWS_ENDPOINT_URL`.
Переменные OpenTofu (`aws_endpoint_url`, `bucket_name`, `queue_name` и
др.) имеют те же значения по умолчанию и описаны в `infra/variables.tf`.

При запуске на хосте (без compose) достаточно указать
`AWS_ENDPOINT_URL=http://localhost:4566`.

## Состояние OpenTofu

- State хранится локально в `infra/terraform.tfstate` и в git не попадает.
- `.terraform.lock.hcl` коммитится, чтобы зафиксировать версию и хеши
  провайдера `hashicorp/aws`.
- `infra/.terraform/`, `*.tfstate`, `*.tfvars`, `.tools/` и `out/`
  перечислены в `.gitignore`.
- `make destroy` удаляет ресурсы через OpenTofu и останавливает контейнеры;
  состояние эмулятора хранится в памяти, поэтому следующая установка
  начинается с чистого окружения.

## Локальный запуск скрапера (лабораторная 1)

```bash
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
playwright install --with-deps chromium
python src/scrape.py           # результат в out/result.json
```

Образ собирается от `python:3.12-slim-bookworm` в три стадии
(deps -> browser -> runtime), поэтому правка кода не пересобирает
Chromium и зависимости.

## CI

GitHub Actions (`.github/workflows/ci.yml`) на PR и push в `main`
устанавливает OpenTofu и запускает `make ci` — ту же точку входа, что и
локально. `plan-check` использует `tofu plan -detailed-exitcode`: если
инфраструктура разошлась с конфигурацией, CI падает.

## Запуск на Windows

`make` должен запускаться из **Git Bash или WSL**: цель `clean`
использует `rm -rf`. Остальные команды работают и из PowerShell, если
`tofu` и `docker` есть в `PATH`.