#!/usr/bin/env python3
"""Immutable backup upload + complete private readback; standard library only.

No billing/limit configuration, upsert, deletion, or deployment operation exists.
CLI credentials come only from SUPABASE_SERVICE_ROLE_KEY. Tests inject a loopback
transport, never the production origins. See SUPABASE_BACKUP_TOOL.md.
"""

import argparse
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

PROJECT = "zqxgmqygirtpttnrvjpf"
BUCKET = "castreader-tts-backups"
READ_ORIGIN = f"https://{PROJECT}.supabase.co"
UPLOAD_ORIGIN = f"https://{PROJECT}.storage.supabase.co"
TUS_PATH = "/storage/v1/upload/resumable"
TUS_CHUNK = 6 * 1024 * 1024  # Supabase's documented size, not a file limit.
READ_CHUNK = 1024 * 1024


class BackupError(RuntimeError):
    """Only static, credential-free details may reach the CLI."""


class TransferError(BackupError):
    def __init__(self, method, status=None):
        self.status = status
        self.retryable = status is None or status in (408, 409, 429, 500, 502, 503, 504)
        detail = f"HTTP {status}" if status is not None else "network failure"
        if status == 413:
            detail += "; file limit reached: use an explicit smaller part_bytes plan; no settings changed"
        super().__init__(f"{method} {detail}")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def file_identity(path):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode):
        raise BackupError("Every input must be a regular file")
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def object_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._/-]+", value):
        raise BackupError("Invalid backup object name")
    pieces = value.split("/")
    if (len(pieces) < 4 or pieces[0] != "runtime-releases" or pieces[1] not in ("us", "cn")
            or any(piece in ("", ".", "..") for piece in pieces)):
        raise BackupError("Object must name a release inside runtime-releases/us or cn")
    return value


def make_plan(spec):
    if not isinstance(spec, dict) or set(spec) != {"files"} or not spec["files"]:
        raise BackupError("Spec must contain a nonempty explicit files list")
    files, used_objects = [], set()
    for entry in spec["files"]:
        if not isinstance(entry, dict) or set(entry) - {"path", "object", "part_bytes", "content_type"}:
            raise BackupError("Invalid file specification")
        path = Path(entry["path"])
        if not path.is_absolute() or path.is_symlink():
            raise BackupError("Input paths must be absolute regular files, not symlinks")
        identity = file_identity(path)
        total = identity[2]
        base = object_name(entry["object"])
        part_bytes = entry.get("part_bytes")
        if part_bytes is not None and (type(part_bytes) is not int or part_bytes <= 0):
            raise BackupError("part_bytes must be a positive integer")
        part_size = part_bytes or max(1, total)
        content_type = entry.get("content_type", "application/octet-stream")
        if not isinstance(content_type, str) or not re.fullmatch(r"[A-Za-z0-9.+/-]+", content_type):
            raise BackupError("Invalid content_type")
        whole = hashlib.sha256()
        parts = []
        with path.open("rb") as source:
            offset = 0
            while offset < total or not parts:
                length = min(part_size, total - offset)
                part_hash = hashlib.sha256()
                remaining = length
                while remaining:
                    data = source.read(min(READ_CHUNK, remaining))
                    if not data:
                        raise BackupError("Input shortened while hashing")
                    whole.update(data)
                    part_hash.update(data)
                    remaining -= len(data)
                name = f"{base}.parts/{len(parts):06d}" if total > part_size else base
                if name in used_objects:
                    raise BackupError("Duplicate destination object")
                used_objects.add(name)
                parts.append({"object": name, "offset": offset, "bytes": length, "sha256": part_hash.hexdigest()})
                offset += length
            if source.read(1) or file_identity(path) != identity:
                raise BackupError("Input changed while hashing")
        files.append({"path": str(path), "name": path.name, "object_base": base,
                      "bytes": total, "sha256": whole.hexdigest(), "identity": identity,
                      "content_type": content_type, "parts": parts})
    return {"schema": "castreader.backup-upload-plan.v1", "project_ref": PROJECT,
            "bucket": BUCKET, "files": files,
            "expected_objects": len(used_objects), "expected_bytes": sum(f["bytes"] for f in files)}


def private_json(path, value, *, replace=False):
    data = json.dumps(value, indent=2, sort_keys=True).encode() + b"\n"
    descriptor, temporary = tempfile.mkstemp(prefix=".backup-state-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as target:
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        if replace:
            os.replace(temporary, path)
        else:
            # Publish the complete fsynced JSON exclusively, never a partial
            # receipt or an overwrite of an existing immutable receipt.
            os.link(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)  # Only our exact freshly-created temporary file.


class StorageHTTP:
    read_origin = READ_ORIGIN
    upload_origin = UPLOAD_ORIGIN

    def __init__(self, key):
        if not key or not key.isascii() or any(c.isspace() for c in key):
            raise BackupError("A valid SUPABASE_SERVICE_ROLE_KEY environment value is required")
        self._headers = {"Authorization": f"Bearer {key}", "apikey": key}
        # No environment proxy may receive this production credential.
        self._opener = build_opener(ProxyHandler({}), NoRedirect())

    def validate_url(self, url, *, tus=False):
        parsed = urlsplit(url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        if (origin not in {self.read_origin, self.upload_origin} or parsed.username
                or parsed.password or parsed.query or parsed.fragment):
            raise BackupError("Storage URL is outside the fixed project origins")
        if not parsed.path.startswith(TUS_PATH + "/") and tus:
            raise BackupError("Invalid TUS upload resource path")
        if not parsed.path.startswith("/storage/v1/"):
            raise BackupError("Invalid Storage API path")
        return url

    def request(self, method, url, *, data=None, headers=None):
        self.validate_url(url)
        request = Request(url, method=method, data=data,
                          headers={**self._headers, **(headers or {})})
        try:
            return self._opener.open(request, timeout=30)
        except HTTPError as error:
            status = error.code
            error.close()
            raise TransferError(method, status) from None
        except (URLError, OSError, HTTPException):
            raise TransferError(method) from None

    def private_bucket(self):
        with self.request("GET", f"{self.read_origin}/storage/v1/bucket/{BUCKET}") as response:
            if response.status != 200:
                raise TransferError("GET bucket", response.status)
            info = json.loads(response.read(128 * 1024))
        if info.get("id") != BUCKET or info.get("public") is not False:
            raise BackupError("Expected private backup bucket was not confirmed")

    def object_url(self, name):
        return f"{self.read_origin}/storage/v1/object/authenticated/{BUCKET}/{quote(name, safe='/')}"


def tus_headers(response):
    if response.headers.get("Tus-Resumable") != "1.0.0":
        raise BackupError("Missing or incompatible TUS version")


def tus_offset(http, url, size):
    with http.request("HEAD", url, headers={"Tus-Resumable": "1.0.0", "Cache-Control": "no-store"}) as response:
        if response.status not in (200, 204):
            raise TransferError("HEAD", response.status)
        tus_headers(response)
        try:
            offset = int(response.headers["Upload-Offset"])
            length = int(response.headers["Upload-Length"])
        except (ValueError, TypeError, KeyError):
            raise BackupError("TUS HEAD omitted valid length/offset") from None
        if not 0 <= offset <= size or length != size:
            raise BackupError("TUS HEAD disagrees with the complete expected object")
        return offset


def upload_part(http, file, part, state_dir, *, retry_delays=(1, 3, 5, 10)):
    binding = {"project_ref": PROJECT, "bucket": BUCKET, **part}
    fingerprint = hashlib.sha256(canonical(binding)).hexdigest()
    state_path = state_dir / f"{fingerprint}.tus.json"
    if state_path.exists():
        if state_path.is_symlink() or stat.S_IMODE(state_path.stat().st_mode) & 0o077:
            raise BackupError("TUS resume state must be a private regular file")
        state = json.loads(state_path.read_text())
        if state.get("binding") != binding:
            raise BackupError("TUS resume state does not match the expected object")
        url = http.validate_url(state["url"], tus=True)
        if state.get("uploaded") is True:
            return  # Still subject to mandatory full GET readback below.
    else:
        metadata = {"bucketName": BUCKET, "objectName": part["object"],
                    "contentType": file["content_type"], "cacheControl": "3600"}
        encoded = ",".join(f"{name} {base64.b64encode(value.encode()).decode()}" for name, value in metadata.items())
        endpoint = http.upload_origin + TUS_PATH
        with http.request("POST", endpoint, data=b"", headers={
            "Tus-Resumable": "1.0.0", "Upload-Length": str(part["bytes"]),
            "Upload-Metadata": encoded,
        }) as response:
            if response.status != 201:
                raise TransferError("POST", response.status)
            tus_headers(response)
            location = response.headers.get("Location")
            if not location:
                raise BackupError("TUS creation omitted its resource")
            url = http.validate_url(urljoin(endpoint, location), tus=True)
        state = {"binding": binding, "url": url, "uploaded": False}
        private_json(state_path, state)
    offset = tus_offset(http, url, part["bytes"])
    failures = 0
    with Path(file["path"]).open("rb") as source:
        while offset < part["bytes"]:
            source.seek(part["offset"] + offset)
            data = source.read(min(TUS_CHUNK, part["bytes"] - offset))
            if not data:
                raise BackupError("Input shortened during upload")
            try:
                with http.request("PATCH", url, data=data, headers={
                    "Tus-Resumable": "1.0.0", "Upload-Offset": str(offset),
                    "Content-Type": "application/offset+octet-stream",
                }) as response:
                    if response.status != 204:
                        raise TransferError("PATCH", response.status)
                    tus_headers(response)
                    if response.headers.get("Upload-Offset") != str(offset + len(data)):
                        raise BackupError("TUS PATCH returned an unexpected offset")
                offset += len(data)
                failures = 0
            except TransferError as error:
                if not error.retryable or failures >= len(retry_delays):
                    raise
                time.sleep(retry_delays[failures])
                failures += 1
                # An acknowledgement may be lost after the server stored bytes.
                # Never blindly replay PATCH from the previous client offset.
                confirmed = tus_offset(http, url, part["bytes"])
                if not offset <= confirmed <= offset + len(data):
                    raise BackupError("TUS recovery offset is outside the attempted chunk")
                offset = confirmed
    if tus_offset(http, url, part["bytes"]) != part["bytes"]:
        raise BackupError("TUS object did not reach its complete length")
    state["uploaded"] = True
    private_json(state_path, state, replace=True)


def verify_file(http, file):
    whole = hashlib.sha256()
    downloaded, parts = 0, []
    for part in file["parts"]:
        if part["offset"] != downloaded:
            raise BackupError("Archive parts are missing, duplicated, or reordered")
        digest, count = hashlib.sha256(), 0
        try:
            with http.request("GET", http.object_url(part["object"]), headers={
                "Cache-Control": "no-cache", "Accept-Encoding": "identity",
            }) as response:
                if response.status != 200:
                    raise TransferError("GET readback", response.status)
                if response.headers.get("Content-Encoding", "identity") != "identity":
                    raise BackupError("Readback content encoding was unexpectedly changed")
                length = response.headers.get("Content-Length")
                if length is not None and length != str(part["bytes"]):
                    raise BackupError("Readback Content-Length does not match expected bytes")
                while True:
                    data = response.read(READ_CHUNK)
                    if not data:
                        break
                    count += len(data)
                    if count > part["bytes"]:
                        raise BackupError("Readback exceeded expected object bytes")
                    digest.update(data)
                    whole.update(data)
        except (OSError, HTTPException):
            raise TransferError("GET readback") from None
        if count != part["bytes"] or digest.hexdigest() != part["sha256"]:
            raise BackupError("Complete object readback SHA-256 or byte count mismatch")
        downloaded += count
        parts.append({**part, "downloaded_bytes": count, "readback_sha256": digest.hexdigest(), "verified": True})
    if downloaded != file["bytes"] or whole.hexdigest() != file["sha256"]:
        raise BackupError("Reassembled complete archive SHA-256 or byte count mismatch")
    return {"name": file["name"], "object_base": file["object_base"], "bytes": file["bytes"],
            "sha256": file["sha256"], "downloaded_bytes": downloaded,
            "readback_sha256": whole.hexdigest(), "parts": parts, "verified": True}


def run_backup(spec, state_dir, receipt_path, http, *, verify_only=False, progress=None):
    state_dir, receipt_path = Path(state_dir), Path(receipt_path)
    if receipt_path.exists() or receipt_path.is_symlink():
        raise BackupError("Receipt already exists; choose a new immutable receipt path")
    if state_dir.is_symlink():
        raise BackupError("State directory cannot be a symlink")
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = state_dir.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise BackupError("State directory must be owned by this user with mode 0700")
    lock_fd = os.open(state_dir / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BackupError("Another backup process owns this state directory") from None
        plan = make_plan(spec)
        plan_path = state_dir / "plan.json"
        if plan_path.exists():
            if plan_path.is_symlink() or json.loads(plan_path.read_text()) != plan:
                raise BackupError("Resume plan differs from current files or destinations")
        else:
            private_json(plan_path, plan)
        http.private_bucket()  # Privacy/identity only; no billing or limit precheck.
        if not verify_only:
            for file in plan["files"]:
                for part in file["parts"]:
                    upload_part(http, file, part, state_dir)
                    if progress:
                        progress({"phase": "uploaded-not-verified", "object": part["object"], "bytes": part["bytes"]})
        verified = []
        for file in plan["files"]:
            verified.append(verify_file(http, file))
            if progress:
                progress({"phase": "full-file-readback", "object_base": file["object_base"], "bytes": file["bytes"]})
        # Rehash all sources, not only stat them. Upload/readback must still
        # describe the complete immutable local files supplied at the start.
        if make_plan(spec) != plan:
            raise BackupError("Local source changed during upload/readback")
        count = sum(len(file["parts"]) for file in verified)
        size = sum(file["downloaded_bytes"] for file in verified)
        if count != plan["expected_objects"] or size != plan["expected_bytes"]:
            raise BackupError("Not all expected objects and bytes were verified")
        receipt = {"schema": "castreader.backup-readback.v1", "created_at": datetime.now(timezone.utc).isoformat(),
                   "project_ref": PROJECT, "bucket": BUCKET, "public": False,
                   "plan_sha256": hashlib.sha256(canonical(plan)).hexdigest(),
                   "expected_files": len(plan["files"]), "verified_files": len(verified),
                   "expected_objects": plan["expected_objects"], "verified_objects": count,
                   "expected_bytes": plan["expected_bytes"], "downloaded_bytes": size,
                   "files": verified, "verified": True}
        private_json(receipt_path, receipt)
        return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--spec", type=Path, help="Explicit JSON files list (preferred for archive + all metadata)")
    inputs.add_argument("--file", type=Path, help="One file; --object required")
    parser.add_argument("--object")
    parser.add_argument("--part-bytes", type=int, help="Explicit split size; no automatic file-limit workaround")
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        if os.environ.get("SUPABASE_URL", READ_ORIGIN) not in (READ_ORIGIN, UPLOAD_ORIGIN):
            raise BackupError("SUPABASE_URL is not this backup project")
        if args.spec:
            if args.object or args.part_bytes is not None:
                raise BackupError("Use per-file object/part_bytes inside --spec")
            spec = json.loads(args.spec.read_text())
        else:
            if not args.object:
                raise BackupError("--file requires --object")
            entry = {"path": str(args.file), "object": args.object}
            if args.part_bytes is not None:
                entry["part_bytes"] = args.part_bytes
            spec = {"files": [entry]}
        http = StorageHTTP(os.environ.get("SUPABASE_SERVICE_ROLE_KEY"))
        receipt = run_backup(spec, args.state_dir, args.receipt, http,
                             verify_only=args.verify_only,
                             progress=lambda value: print(json.dumps(value), flush=True))
        print(json.dumps({key: receipt[key] for key in ("verified", "expected_files", "verified_files",
                         "expected_objects", "verified_objects", "expected_bytes", "downloaded_bytes")}))
        return 0
    except Exception as error:
        # Never print request/response bodies, URLs, tracebacks or raw exceptions.
        message = str(error) if isinstance(error, BackupError) else "Local backup input/state or transfer failed"
        print(json.dumps({"verified": False, "error": message}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
