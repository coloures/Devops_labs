"""Send one scraping job to SQS and verify the end-to-end result.

Used by ``make run``: the script waits until the worker writes a non-empty
JSON array to S3 and deletes the processed message from the queue.
"""

import json
import os
import sys
import time
import uuid
from urllib.parse import urlsplit, urlunsplit

import boto3
from botocore.exceptions import ClientError

from scrape import URL as DEFAULT_URL

RESULT_TIMEOUT_SECONDS = int(os.environ.get("RESULT_TIMEOUT_SECONDS", "180"))
POLL_INTERVAL_SECONDS = 1


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Environment variable {name} is required")
    return value


def boto_client(service: str):
    return boto3.client(
        service,
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL"),
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    )


def use_local_endpoint(url: str, endpoint: str | None) -> str:
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


def wait_for_result(s3, bucket: str, key: str) -> None:
    deadline = time.monotonic() + RESULT_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            response = s3.get_object(Bucket=bucket, Key=key)
        except ClientError as error:
            code = error.response.get("Error", {}).get("Code", "")
            if code not in {"NoSuchKey", "404", "NotFound"}:
                raise
        else:
            quotes = json.loads(response["Body"].read())
            if not isinstance(quotes, list) or not quotes:
                raise SystemExit(f"s3://{bucket}/{key} does not contain a non-empty JSON array")
            print(f"OK: s3://{bucket}/{key} contains {len(quotes)} quotes")
            return
        time.sleep(POLL_INTERVAL_SECONDS)
    raise SystemExit(f"timeout: s3://{bucket}/{key} was not created")


def wait_for_empty_queue(sqs, queue_url: str) -> None:
    deadline = time.monotonic() + RESULT_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        attributes = sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=[
                "ApproximateNumberOfMessages",
                "ApproximateNumberOfMessagesNotVisible",
            ],
        )["Attributes"]
        visible = int(attributes.get("ApproximateNumberOfMessages", "0"))
        in_flight = int(attributes.get("ApproximateNumberOfMessagesNotVisible", "0"))
        if visible == 0 and in_flight == 0:
            print("OK: queue is empty, message was deleted")
            return
        time.sleep(POLL_INTERVAL_SECONDS)
    raise SystemExit("timeout: processed message is still in the queue")


def main() -> None:
    endpoint = os.environ.get("AWS_ENDPOINT_URL")
    bucket = require_env("S3_BUCKET")
    queue_name = require_env("SQS_QUEUE_NAME")

    sqs = boto_client("sqs")
    s3 = boto_client("s3")

    queue_url = use_local_endpoint(
        sqs.get_queue_url(QueueName=queue_name)["QueueUrl"], endpoint
    )
    result_key = f"quotes/{uuid.uuid4().hex}.json"
    job = {
        "url": os.environ.get("SCRAPE_URL", DEFAULT_URL),
        "result_key": result_key,
    }

    response = sqs.send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps(job, ensure_ascii=False),
    )
    print(f"sent job {response['MessageId']} -> {queue_name}")
    print(f"waiting for s3://{bucket}/{result_key}")

    wait_for_result(s3, bucket, result_key)
    wait_for_empty_queue(sqs, queue_url)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
