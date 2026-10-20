"""SQS worker: receive a scraping job, save the result to S3, delete the message.

The queue and the bucket are discovered at runtime from environment variables;
no endpoint, queue URL or bucket name is hardcoded.
"""

import json
import logging
import os
import signal
from urllib.parse import urlsplit, urlunsplit

import boto3

from scrape import URL as DEFAULT_URL
from scrape import scrape_quotes

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("worker")

DEFAULT_RESULT_PREFIX = "quotes"


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Environment variable {name} is required")
    return value


def boto_client(service: str):
    """Build a client that talks to the endpoint from AWS_ENDPOINT_URL."""
    return boto3.client(
        service,
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL"),
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    )


def use_local_endpoint(url: str, endpoint: str | None) -> str:
    """Replace the host of a queue URL returned by the emulator.

    Floci returns URLs based on its own base URL (http://localhost:4566).
    Inside the compose network the same emulator is reachable as
    http://floci:4566, so the host has to be rewritten.
    """
    if not endpoint:
        return url
    endpoint_parts = urlsplit(endpoint)
    url_parts = urlsplit(url)
    return urlunsplit(
        (
            endpoint_parts.scheme,
            endpoint_parts.netloc,
            url_parts.path,
            url_parts.query,
            url_parts.fragment,
        )
    )


def main() -> None:
    endpoint = os.environ.get("AWS_ENDPOINT_URL")
    bucket = require_env("S3_BUCKET")
    queue_name = require_env("SQS_QUEUE_NAME")
    wait_time = int(os.environ.get("SQS_WAIT_TIME_SECONDS", "10"))
    default_url = os.environ.get("SCRAPE_URL", DEFAULT_URL)

    sqs = boto_client("sqs")
    s3 = boto_client("s3")

    queue_url = use_local_endpoint(
        sqs.get_queue_url(QueueName=queue_name)["QueueUrl"], endpoint
    )
    log.info("worker started: queue=%s bucket=%s", queue_name, bucket)

    stop = False

    def handle_signal(signum, _frame):
        nonlocal stop
        log.info("received signal %s, finishing current job", signum)
        stop = True

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    while not stop:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=wait_time,
        )

        for message in response.get("Messages", []):
            message_id = message["MessageId"]
            try:
                job = json.loads(message.get("Body") or "{}")
                url = job.get("url") or default_url
                result_key = job.get("result_key") or (
                    f"{DEFAULT_RESULT_PREFIX}/{message_id}.json"
                )

                log.info("job %s: scraping %s", message_id, url)
                quotes = scrape_quotes(url)

                payload = json.dumps(quotes, ensure_ascii=False, indent=2) + "\n"
                s3.put_object(
                    Bucket=bucket,
                    Key=result_key,
                    Body=payload.encode("utf-8"),
                    ContentType="application/json",
                )
                log.info(
                    "job %s: saved %d quotes to s3://%s/%s",
                    message_id,
                    len(quotes),
                    bucket,
                    result_key,
                )

                # Удаляем сообщение только после успешной записи в S3.
                # Если put_object упал, сообщение вернётся в очередь после
                # visibility timeout и задание будет обработано повторно.
                sqs.delete_message(
                    QueueUrl=queue_url, ReceiptHandle=message["ReceiptHandle"]
                )
                log.info("job %s: message deleted from queue", message_id)
            except Exception:
                log.exception("job %s failed, message is kept in the queue", message_id)

    log.info("worker stopped")


if __name__ == "__main__":
    main()
