#!/usr/bin/env python3
"""Authenticated JSON requests used by configure-keycloak-web.sh."""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def admin_token(base_url, refresh=False):
    cache = os.environ.get("KEYCLOAK_ADMIN_TOKEN_CACHE")
    if cache and not refresh:
        try:
            with open(cache) as source:
                saved = json.load(source)
            if saved["expires_at"] > time.time() + 10:
                return saved["access_token"]
        except (FileNotFoundError, KeyError, ValueError):
            pass
    body = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": "admin-cli",
        "username": os.environ.get("KEYCLOAK_ADMIN_USERNAME", "admin"),
        "password": os.environ["KEYCLOAK_ADMIN_PASSWORD"],
    }).encode()
    request = urllib.request.Request(
        base_url + "/realms/master/protocol/openid-connect/token", data=body
    )
    issued_at = time.time()
    with urllib.request.urlopen(request, timeout=25) as response:
        result = json.load(response)
    if cache:
        saved = {"access_token": result["access_token"], "expires_at": issued_at + result["expires_in"]}
        fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as target:
            json.dump(saved, target)
    return result["access_token"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-fsS", action="store_true")
    parser.add_argument("-X", dest="method")
    parser.add_argument("-o", dest="output", choices=["/dev/null"])
    parser.add_argument("-d", dest="data")
    parser.add_argument("url")
    args = parser.parse_args(argv)
    base_url = os.environ["KEYCLOAK_BASE_URL"].rstrip("/")
    if not args.url.startswith(base_url + "/admin/realms/"):
        parser.error("Only the configured Keycloak admin API is allowed")
    body = None if args.data is None else (
        sys.stdin.buffer.read() if args.data == "@-" else args.data.encode()
    )
    try:
        for attempt in range(2):
            request = urllib.request.Request(
                args.url, data=body, method=args.method,
                headers={
                    "Authorization": "Bearer " + admin_token(base_url, refresh=bool(attempt)),
                    "Content-Type": "application/json",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=25) as response:
                    result = b"" if args.output else response.read()
                if not args.output:
                    sys.stdout.buffer.write(result)
                return 0
            except urllib.error.HTTPError as error:
                # A rejected token has not executed the request. Refresh once,
                # retaining the original body, including payloads read from stdin.
                if error.code != 401 or attempt:
                    raise
                error.close()
    except urllib.error.HTTPError as error:
        error.close()
        print(f"Keycloak HTTP {error.code}: {urllib.parse.urlsplit(args.url).path}", file=sys.stderr)
        return 22
    except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as error:
        # No exception payload: it may contain a server response or credentials.
        print(f"Keycloak request failed ({type(error).__name__})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
