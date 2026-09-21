# ---------- Стадия 1: зависимости ----------
# Меняется только когда меняется requirements.txt. Кэшируется отдельно,
# поэтому правки кода не переустанавливают зависимости.
FROM python:3.12-slim-bookworm AS deps

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---------- Стадия 2: браузер ----------
# Самый тяжёлый и самый стабильный слой: системные библиотеки + Chromium.
# Качается заново только если изменился requirements.txt (версия playwright).
FROM deps AS browser

RUN playwright install --with-deps chromium

# ---------- Стадия 3: рантайм ----------
# Код копируется последним: правка одной строки кода инвалидирует
# только этот слой, браузер и зависимости берутся из кэша.
FROM browser AS runtime

WORKDIR /app
COPY src/ ./src/

ENV OUT_DIR=/app/out
CMD ["python", "src/scrape.py"]