# ---------- Стадия 1: зависимости приложения ----------
# Ставим зависимости в отдельный venv. Стадия независима от браузерной,
# поэтому изменение requirements.txt НЕ перекачивает Chromium.
FROM python:3.12-slim-bookworm AS deps
WORKDIR /app
RUN python -m venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---------- Стадия 2: браузер ----------
# Вторая независимая стадия от того же базового образа (параллельно deps).
# Ставит playwright (он же CLI) и качает Chromium + системные библиотеки.
FROM python:3.12-slim-bookworm AS browser
RUN pip install --no-cache-dir playwright \
 && playwright install --with-deps chromium

# ---------- Стадия 3: рантайм ----------
# База — среда браузера (Chromium + системные библиотеки apt).
# Из стадии deps подкладываем venv с зависимостями приложения.
# Код копируется последним: правка кода не трогает ни браузер, ни зависимости.
FROM browser AS runtime
COPY --from=deps /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
WORKDIR /app
COPY src/ ./src/
ENV OUT_DIR=/app/out
CMD ["python", "src/scrape.py"]