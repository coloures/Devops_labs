"""Redis Streams worker: read a scraping job, save JSON on disk, then XACK.

Лабораторная 3. Задание — запись stream ``jobs`` с полями ``job_id`` и ``url``.
Воркер входит в consumer group ``scrapers``. Порядок операций подобран так,
чтобы падение контейнера не могло потерять задание:

1. запись забирается через ``XREADGROUP`` и попадает в pending entries list (PEL);
2. результат скрапится, пишется во временный файл в том же каталоге, делается
   ``fsync`` и атомарное переименование в ``<job_id>.json``;
3. и только после этого отправляется ``XACK``.

Если контейнер умрёт между шагами 1 и 3, запись останется pending и будет
перехвачена через ``XAUTOCLAIM`` при следующем старте. Запись файла до ``XACK``
делает операцию идемпотентной: повторно доставленное задание, чей результат уже
лежит на диске, только подтверждается, существующий файл не трогается.

Переменные окружения (у всех есть значения по умолчанию):

``REDIS_HOST`` / ``REDIS_PORT``  адрес Redis (``redis`` / ``6379``)
``REDIS_STREAM``                 имя stream (``jobs``)
``REDIS_GROUP``                  consumer group (``scrapers``)
``REDIS_CONSUMER``               имя консьюмера (``scraper-1``)
``RESULTS_DIR``                  каталог результатов (``/srv/quotes-scraper/results``)
``SCRAPE_URL``                   URL по умолчанию, если его нет в задании
``SCRAPER_FAULT``                ``crash_before_ack`` — выйти сразу после доставки,
                                 не подтверждая запись (для ``make fault-test``)
``SCRAPER_ONCE``                 если задано — выйти после одного задания
"""

import json
import logging
import os
import signal
import time

import redis

from scrape import URL as DEFAULT_URL
from scrape import scrape_quotes

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("worker")

STREAM = os.environ.get("REDIS_STREAM", "jobs")
GROUP = os.environ.get("REDIS_GROUP", "scrapers")
CONSUMER = os.environ.get("REDIS_CONSUMER", "scraper-1")
BLOCK_MS = int(os.environ.get("REDIS_BLOCK_MS", "5000"))
RESULTS_DIR = os.environ.get("RESULTS_DIR", "/srv/quotes-scraper/results")
DEFAULT_URL = os.environ.get("SCRAPE_URL", DEFAULT_URL)

# Хуки для тестов. По умолчанию пустые, ничего не инжектируется.
SCRAPER_FAULT = os.environ.get("SCRAPER_FAULT", "")
SCRAPER_ONCE = os.environ.get("SCRAPER_ONCE", "")


def connect() -> "redis.Redis":
    """Подключиться к Redis, повторяя попытки, пока сервер не поднимется."""
    host = os.environ.get("REDIS_HOST", "redis")
    port = int(os.environ.get("REDIS_PORT", "6379"))
    last_error = None
    for attempt in range(1, 31):
        try:
            client = redis.Redis(host=host, port=port, decode_responses=True)
            client.ping()
            return client
        except redis.RedisError as error:
            last_error = error
            log.warning("redis %s:%s is not ready (attempt %d): %s", host, port, attempt, error)
            time.sleep(2)
    raise SystemExit(f"could not connect to redis {host}:{port}: {last_error}")


def ensure_group(client) -> None:
    """Создать consumer group один раз; ``BUSYGROUP`` означает, что она уже есть."""
    try:
        client.xgroup_create(STREAM, GROUP, id="0", mkstream=True)
        log.info("created consumer group %s on stream %s", GROUP, STREAM)
    except redis.ResponseError as error:
        if "BUSYGROUP" not in str(error):
            raise


def result_path(job_id: str) -> str:
    return os.path.join(RESULTS_DIR, f"{job_id}.json")


def result_is_valid(path: str) -> bool:
    """Результат валиден, если это непустой JSON-массив."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return False
    return isinstance(data, list) and len(data) > 0


def write_result(path: str, quotes: list) -> None:
    """Записать JSON во временный файл, затем атомарно переименовать.

    Оба имени лежат в одном каталоге, поэтому ``os.replace`` на POSIX — это
    атомарное переименование: читатель (Nginx) видит либо старый файл, либо
    полный новый, но никогда не «полуфайл».
    """
    os.makedirs(RESULTS_DIR, exist_ok=True)
    temporary = f"{path}.tmp-{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(quotes, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def handle_message(client, message_id: str, fields: dict) -> None:
    job_id = fields.get("job_id")
    url = fields.get("url") or DEFAULT_URL
    if not job_id:
        log.error("message %s has no job_id; acknowledging it", message_id)
        client.xack(STREAM, GROUP, message_id)
        return

    path = result_path(job_id)

    # Идемпотентность: повторно доставленное задание, чей результат уже есть,
    # только подтверждается, существующий файл не трогается.
    if result_is_valid(path):
        log.info("job %s already has a valid result in %s, skipping", job_id, path)
        client.xack(STREAM, GROUP, message_id)
        return

    log.info("job %s: scraping %s", job_id, url)
    quotes = scrape_quotes(url)
    write_result(path, quotes)
    log.info("job %s: wrote %d quotes to %s", job_id, len(quotes), path)

    # XACK — последний шаг: он уходит только после того, как файл уже на диске.
    client.xack(STREAM, GROUP, message_id)
    log.info("job %s: acknowledged", job_id)


def fetch_messages(client) -> list:
    """Вернуть не более одной записи: сначала перехваченную pending, потом новую.

    ``XAUTOCLAIM`` с ``min_idle_time=0`` возвращает записи из PEL (в том числе
    оставшиеся после падения), ``XREADGROUP`` с ``>`` — новые. Так воркер
    всегда сначала доигрывает «зависшие» задания, а потом берёт новые.
    """
    claimed = client.xautoclaim(
        STREAM, GROUP, CONSUMER, min_idle_time=0, start_id="0-0", count=1
    )
    if claimed and claimed[1]:
        return claimed[1]

    response = client.xreadgroup(GROUP, CONSUMER, {STREAM: ">"}, count=1, block=BLOCK_MS)
    if not response:
        return []
    return response[0][1]


def main() -> None:
    client = connect()
    ensure_group(client)
    log.info(
        "worker started: stream=%s group=%s consumer=%s results=%s",
        STREAM,
        GROUP,
        CONSUMER,
        RESULTS_DIR,
    )

    stop = False

    def handle_signal(signum, _frame):
        nonlocal stop
        log.info("received signal %s, finishing current job", signum)
        stop = True

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    while not stop:
        for message_id, fields in fetch_messages(client):
            if SCRAPER_FAULT == "crash_before_ack":
                # Имитация падения между доставкой и XACK: запись остаётся в PEL,
                # её перехватит этот же консьюмер после рестарта.
                log.warning(
                    "fault injection: exiting after delivery of %s without XACK",
                    message_id,
                )
                os._exit(42)

            try:
                handle_message(client, message_id, fields)
            except Exception:  # noqa: BLE001 - воркер не должен падать целиком
                log.exception("job %s failed; leaving it pending for a retry", message_id)
                time.sleep(1)
                continue

            if SCRAPER_ONCE:
                log.info("SCRAPER_ONCE is set, exiting after one job")
                return

    log.info("worker stopped")


if __name__ == "__main__":
    main()
