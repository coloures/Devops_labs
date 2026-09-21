# quotes-scraper

Скрапер на Python + Playwright, который открывает
<https://quotes.toscrape.com/scroll> в Chromium, доскролливает до конца
(данные подгружаются JS) и сохраняет цитаты в `out/result.json`.

## Структура

```
├── Dockerfile          # multistage: deps -> browser -> runtime
├── Makefile            # единственная точка входа: build / run / clean / ci
├── src/scrape.py       # код скрапера
├── requirements.txt
├── out/                # результат (в git не коммитится)
└── .github/workflows/ci.yml
```

## Локальное окружение для разработки

```bash
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
playwright install --with-deps chromium
python src/scrape.py
```

## Продакшн-образ

Образ собирается сам, без готовых playwright-образов, от
`python:3.12-slim-bookworm`. Слои упорядочены от стабильного к
меняющемуся: зависимости -> браузер -> код, поэтому правка кода
не пересобирает ни браузер, ни зависимости.

```bash
make build   # собрать образ
make run     # запустить, результат в out/result.json
make clean   # удалить образ и out/
make ci      # build + run + валидация JSON (также вызывается из CI)
```

Если `make` не установлен на Windows: `choco install make` или через WSL.

## CI

GitHub Actions (`.github/workflows/ci.yml`) на PR и push в `main`
запускает `make ci` — ту же точку входа, что и локально.