#!/usr/bin/env python3
"""Empty and delete a Scaleway Object Storage bucket using pure Python stdlib."""

import datetime
import hashlib
import hmac
import sys
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET

NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _signature_key(secret: str, date: str, region: str, service: str) -> bytes:
    return _sign(
        _sign(
            _sign(
                _sign(("AWS4" + secret).encode(), date),
                region,
            ),
            service,
        ),
        "aws4_request",
    )


def _auth_headers(method: str, path: str, query: str, body: bytes,
                  host: str, access_key: str, secret_key: str, region: str) -> dict:
    now = datetime.datetime.now(datetime.UTC)
    date = now.strftime("%Y%m%d")
    xdate = now.strftime("%Y%m%dT%H%M%SZ")
    payload_hash = hashlib.sha256(body).hexdigest()

    canonical = "\n".join([
        method,
        path,
        query,
        f"host:{host}",
        f"x-amz-content-sha256:{payload_hash}",
        f"x-amz-date:{xdate}",
        "",
        "host;x-amz-content-sha256;x-amz-date",
        payload_hash,
    ])
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        xdate,
        f"{date}/{region}/s3/aws4_request",
        hashlib.sha256(canonical.encode()).hexdigest(),
    ])
    sig_key = _signature_key(secret_key, date, region, "s3")
    signature = hmac.new(sig_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    return {
        "Host": host,
        "x-amz-date": xdate,
        "x-amz-content-sha256": payload_hash,
        "Authorization": (
            f"AWS4-HMAC-SHA256 Credential={access_key}/{date}/{region}/s3/aws4_request, "
            f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={signature}"
        ),
    }


def list_objects(host: str, access_key: str, secret_key: str, region: str) -> list[str] | None:
    """Returns list of keys, or None if the bucket does not exist."""
    import urllib.parse
    keys = []
    continuation = None
    while True:
        query = "list-type=2"
        if continuation:
            query += f"&continuation-token={urllib.parse.quote(continuation)}"
        headers = _auth_headers("GET", "/", query, b"", host, access_key, secret_key, region)
        req = urllib.request.Request(f"https://{host}/?{query}", headers=headers)
        try:
            with urllib.request.urlopen(req) as r:
                root = ET.fromstring(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise
        keys += [c.find(f"{NS}Key").text for c in root.findall(f"{NS}Contents")]
        truncated = root.findtext(f"{NS}IsTruncated", "false")
        if truncated.lower() != "true":
            break
        continuation = root.findtext(f"{NS}NextContinuationToken")
    return keys


def delete_objects(host: str, access_key: str, secret_key: str, region: str, keys: list[str]) -> None:
    # S3 bulk delete: max 1000 keys per request
    import urllib.parse
    for i in range(0, len(keys), 1000):
        chunk = keys[i:i + 1000]
        objects_xml = "".join(f"<Object><Key>{k}</Key></Object>" for k in chunk)
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f"<Delete><Quiet>true</Quiet>{objects_xml}</Delete>"
        ).encode()
        md5 = __import__("base64").b64encode(
            __import__("hashlib").md5(body).digest()
        ).decode()
        headers = _auth_headers("POST", "/", "delete=", body, host, access_key, secret_key, region)
        headers["Content-Type"] = "application/xml"
        headers["Content-MD5"] = md5
        headers["Content-Length"] = str(len(body))
        req = urllib.request.Request(
            f"https://{host}/?delete", data=body, headers=headers, method="POST"
        )
        with urllib.request.urlopen(req) as r:
            r.read()
        print(f"  Deleted {len(chunk)} object(s).")


def delete_bucket(host: str, access_key: str, secret_key: str, region: str) -> None:
    headers = _auth_headers("DELETE", "/", "", b"", host, access_key, secret_key, region)
    req = urllib.request.Request(f"https://{host}/", headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(req):
            pass
        print("Bucket deleted.")
    except urllib.error.HTTPError as e:
        if e.code == 204:
            print("Bucket deleted.")
        else:
            raise


def main() -> None:
    import os
    access_key = os.environ.get("BUCKET_ACCESS_KEY") or os.environ.get("ONBOARDING_ACCESS_KEY")
    secret_key = os.environ.get("BUCKET_SECRET_KEY") or os.environ.get("ONBOARDING_SECRET_KEY")
    region = os.environ.get("BUCKET_REGION", "fr-par")
    endpoint = os.environ.get("BUCKET_ENDPOINT", "s3.fr-par.scw.cloud")

    if len(sys.argv) < 2:
        print("Usage: empty-bucket.py <bucket-name>", file=sys.stderr)
        sys.exit(1)
    if not access_key or not secret_key:
        print("Error: BUCKET_ACCESS_KEY and BUCKET_SECRET_KEY must be set.", file=sys.stderr)
        sys.exit(1)

    bucket = sys.argv[1]
    host = f"{bucket}.{endpoint}"

    print(f"Listing objects in '{bucket}'...")
    keys = list_objects(host, access_key, secret_key, region)

    if keys is None:
        print("Bucket does not exist, nothing to do.")
        return

    print(f"Found {len(keys)} object(s).")
    if keys:
        print("Deleting objects...")
        delete_objects(host, access_key, secret_key, region, keys)

    print("Deleting bucket...")
    delete_bucket(host, access_key, secret_key, region)


if __name__ == "__main__":
    main()
