#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>

"""Back up EFS in TWRP, renew the legacy Google attestation root, and reboot."""

import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE = ROOT / "security/attestation/google-hardware-attestation-root-2042.der"
CERTIFICATE_SHA256 = "cedb1cb6dc896ae5ec797348bce9286753c2b38ee71ce0fbe34a9a1248800dfc"
PUBLIC_KEY_SHA256 = "feb2ea7551ee316ed4bb443c8293b884dbfdea40b603ee3e4f4a897e4580fbae"
PARTITION = "/dev/block/by-name/efs"
PREFIXES = ("gakeccert", "gakrsacert", "sgakeccert", "sgakrsacert")
CERTIFICATES = tuple(f"DAK/{prefix}2.der" for prefix in PREFIXES)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_signature(child, parent):
    require(child.issuer == parent.subject, "Certificate issuer does not match parent")
    public = parent.public_key()
    if isinstance(public, rsa.RSAPublicKey):
        public.verify(child.signature, child.tbs_certificate_bytes, padding.PKCS1v15(),
                      child.signature_hash_algorithm)
    elif isinstance(public, ec.EllipticCurvePublicKey):
        public.verify(child.signature, child.tbs_certificate_bytes,
                      ec.ECDSA(child.signature_hash_algorithm))
    else:
        raise ValueError("Unsupported certificate signing algorithm")


def load_replacement():
    data = CERTIFICATE.read_bytes()
    require(sha256(data) == CERTIFICATE_SHA256, "Bundled root certificate SHA-256 mismatch")
    certificate = x509.load_der_x509_certificate(data)
    public = certificate.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    require(sha256(public) == PUBLIC_KEY_SHA256, "Unexpected Google root public key")
    verify_signature(certificate, certificate)
    now = datetime.now(timezone.utc)
    require(certificate.not_valid_before_utc <= now <= certificate.not_valid_after_utc,
            "Bundled root certificate is outside its validity period")
    return data, certificate


class Device:
    def __init__(self, serial):
        self.serial = serial
        self.mountpoint = f"/tmp/creckerrom-efs-{uuid.uuid4().hex}"
        self.stage = self.mountpoint + ".der"
        self.mounted = False
        self.prepared = False

    def adb(self, *args, **kwargs):
        return subprocess.run(["adb", "-s", self.serial, *args], check=True, **kwargs)

    def shell(self, command):
        return self.adb("shell", command, capture_output=True, text=True).stdout.strip()

    def prepare(self):
        require(self.shell("id -u") == "0", "Recovery adbd must run as root")
        require(bool(self.shell("getprop ro.twrp.version")), "Boot the phone into TWRP first")
        resolved = self.shell(f"readlink -f {PARTITION}")
        require(resolved.startswith("/dev/block/"), "Cannot resolve the EFS block device")
        self.shell(f"test -b {shlex.quote(resolved)}")
        # The raw backup must be taken while EFS is unmounted and stable.
        mounts = []
        for line in self.shell("cat /proc/mounts").splitlines():
            source, target = line.split()[:2]
            if source.startswith("/dev/block/"):
                if self.shell(f"readlink -f {shlex.quote(source)}") == resolved:
                    require(target in ("/efs", "/mnt/vendor/efs"),
                            f"EFS is mounted at unexpected location {target}; unmount it first")
                    mounts.append(target)
        self.shell("sync")
        for target in reversed(mounts):
            self.shell(f"umount {shlex.quote(target)}")
        self.shell(f"mkdir -m 700 {self.mountpoint}")
        self.prepared = True

    def partition_size(self):
        return int(self.shell(f"blockdev --getsize64 {PARTITION}"))

    def partition_hash(self):
        return self.shell(f"sha256sum {PARTITION}").split()[0]

    def copy_partition(self, destination):
        with destination.open("xb") as stream:
            os.chmod(destination, 0o600)
            self.adb("exec-out", f"cat {PARTITION}", stdout=stream, stderr=subprocess.PIPE)
            stream.flush()
            os.fsync(stream.fileno())

    def mount(self, readonly):
        require(not self.mounted, "EFS already mounted by this script")
        options = "ro,noload" if readonly else "rw"
        self.shell(f"mount -t ext4 -o {options} {PARTITION} {self.mountpoint}")
        self.mounted = True

    def unmount(self):
        if self.mounted:
            self.shell(f"sync && umount {self.mountpoint}")
            self.mounted = False

    def read(self, relative):
        path = f"{self.mountpoint}/{relative}"
        self.shell(f"test -f {path} && test ! -L {path}")
        return self.adb("exec-out", f"cat {self.mountpoint}/{relative}",
                        capture_output=True).stdout

    def metadata(self, relative):
        path = f"{self.mountpoint}/{relative}"
        owner_mode = self.shell(f"stat -c '%u %g %a' {path}")
        fields = self.shell(f"ls -ldnZ {path}").split()
        contexts = [field for field in fields if field.startswith("u:object_r:")]
        require(len(contexts) == 1, f"Cannot read SELinux context for {relative}")
        return owner_mode, contexts[0]

    def manifest(self):
        result = {}
        command = f"find {self.mountpoint} -type f -exec sha256sum {{}} \\;"
        for line in self.shell(command).splitlines():
            digest, path = line.split(maxsplit=1)
            require(len(digest) == 64, "Invalid EFS file hash")
            result[path.removeprefix(self.mountpoint + "/")] = digest
        return result

    def replace(self, relative, local):
        self.adb("push", str(local), self.stage, capture_output=True)
        remote_hash = self.shell(f"sha256sum {self.stage}").split()[0]
        require(remote_hash == file_sha256(local), "Staged certificate SHA-256 mismatch")
        # Preserve the existing inode, ownership, permissions and extended attributes.
        self.shell(f"cat {self.stage} > {self.mountpoint}/{relative}")

    def cleanup(self):
        self.unmount()
        if self.prepared:
            self.shell(f"rm -f {self.stage} && rmdir {self.mountpoint}")

    def reboot(self):
        self.adb("reboot")


def verified_backup(device, folder):
    size = device.partition_size()
    require(size > 0, "Invalid EFS partition size")
    require(shutil.disk_usage(folder).free >= size + 1024 * 1024,
            "Insufficient space for a complete EFS backup")
    before = device.partition_hash()
    image = folder / "efs-before-certificate-update.img"
    device.copy_partition(image)
    require(image.stat().st_size == size, "EFS backup size mismatch; no certificates changed")
    digest = file_sha256(image)
    require(before == digest == device.partition_hash(),
            "EFS backup SHA-256 mismatch; no certificates changed")
    (folder / (image.name + ".sha256")).write_text(f"{digest}  {image.name}\n")
    information = {"device_serial": device.serial, "partition": PARTITION,
                   "bytes": size, "sha256": digest, "backup_verified": True}
    (folder / "backup-info.json").write_text(json.dumps(information, indent=2) + "\n")
    print(f"Verified complete EFS backup: {image}", flush=True)
    return information


def update_certificates(device, folder, replacement, root):
    originals = {}
    metadata = {}
    written = False
    device.mount(readonly=True)
    try:
        before = device.manifest()
        for relative in CERTIFICATES:
            data = device.read(relative)
            original = x509.load_der_x509_certificate(data)
            require(original.subject == root.subject and
                    original.public_key().public_numbers() == root.public_key().public_numbers(),
                    f"{relative} does not contain the expected legacy Google root")
            verify_signature(original, original)
            # Validate each existing stored chain with the new root before writing anything.
            parent = root
            for index in (1, 0):
                child = x509.load_der_x509_certificate(device.read(relative[:-5] + f"{index}.der"))
                verify_signature(child, parent)
                parent = child
            originals[relative] = data
            metadata[relative] = device.metadata(relative)
        saved = folder / "original-public-certificates"
        saved.mkdir()
        for relative, data in originals.items():
            (saved / Path(relative).name).write_bytes(data)
        (folder / "efs-file-hashes-before.json").write_text(json.dumps(before, indent=2) + "\n")
        (folder / "certificate-metadata-before.json").write_text(json.dumps(metadata, indent=2) + "\n")
        expected = dict(before)
        for relative in CERTIFICATES:
            expected[relative] = sha256(replacement)
        local = folder / "google-hardware-attestation-root-2042.der"
        local.write_bytes(replacement)

        def verify(expected_manifest, expected_contents):
            require(device.manifest() == expected_manifest,
                    "EFS file hashes differ from the expected update")
            for relative in CERTIFICATES:
                require(device.read(relative) == expected_contents[relative],
                        f"Certificate readback failed: {relative}")
                require(device.metadata(relative) == metadata[relative],
                        f"Ownership, mode or SELinux context changed: {relative}")

        device.unmount()
        device.mount(readonly=False)
        try:
            for relative in CERTIFICATES:
                if originals[relative] != replacement:
                    written = True  # Includes a failed/partial write to the current file.
                    device.replace(relative, local)
            contents = dict.fromkeys(CERTIFICATES, replacement)
            verify(expected, contents)
            device.unmount()
            device.mount(readonly=True)
            verify(expected, contents)
        except BaseException as failure:
            if written:
                print("Update failed; restoring the original public certificates.", file=sys.stderr)
                try:
                    device.unmount()
                    device.mount(readonly=False)
                    for relative in CERTIFICATES:
                        device.replace(relative, saved / Path(relative).name)
                    verify(before, originals)
                    device.unmount()
                    device.mount(readonly=True)
                    verify(before, originals)
                except BaseException as rollback_failure:
                    raise RuntimeError(
                        f"Update failed ({failure}); rollback could not be verified ({rollback_failure}). "
                        f"Remain in recovery. Full EFS backup: {folder}") from failure
                raise RuntimeError("Update failed; original certificates restored and verified. "
                                   f"Phone remains in recovery. Cause: {failure}") from failure
            raise
        result = {"device_serial": device.serial,
                  "updated_at_utc": datetime.now(timezone.utc).isoformat(),
                  "changed_files": [p for p in CERTIFICATES if originals[p] != replacement],
                  "replacement_sha256": sha256(replacement),
                  "replacement_not_after": root.not_valid_after_utc.isoformat(),
                  "persisted_readback_verified": True,
                  "other_file_contents_unchanged": True,
                  "metadata_preserved": True}
        (folder / "certificate-update-result.json").write_text(json.dumps(result, indent=2) + "\n")
        return result
    finally:
        device.unmount()


def desktop_directory():
    if shutil.which("xdg-user-dir"):
        result = subprocess.run(["xdg-user-dir", "DESKTOP"], capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            path = Path(result.stdout.strip())
            if path.is_dir() and path != Path.home():
                return path
    for name in ("Schreibtisch", "Desktop"):
        path = Path.home() / name
        if path.is_dir():
            return path
    raise ValueError("Cannot locate the desktop; specify --backup-dir")


def select_device(serial):
    result = subprocess.run(["adb", "devices"], capture_output=True, text=True, check=True)
    devices = [line.split()[:2] for line in result.stdout.splitlines()[1:] if line.strip()]
    if serial:
        require([serial, "recovery"] in devices, f"Device {serial} is not connected in recovery")
        return serial
    require(len(devices) == 1 and devices[0][1] == "recovery",
            "Connect exactly one phone in TWRP, or select it with --serial")
    return devices[0][0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="ADB serial when more than one device is connected")
    parser.add_argument("--backup-dir", type=Path, help="Parent for a new backup folder (default: desktop)")
    parser.add_argument("--no-reboot", action="store_true", help="Leave the phone in TWRP after verification")
    args = parser.parse_args()
    os.umask(0o077)  # EFS backups contain device-specific secrets.
    folder = None
    try:
        replacement, root = load_replacement()
        device = Device(select_device(args.serial))
        parent = args.backup_dir or desktop_directory()
        parent = parent.expanduser().resolve(strict=True)
        folder = parent / ("CreckerROM-EFS-Backup-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
        folder.mkdir(mode=0o700)
        try:
            device.prepare()
            verified_backup(device, folder)
            result = update_certificates(device, folder, replacement, root)
        finally:
            device.cleanup()
        print(f"Verified {len(result['changed_files'])} certificate replacements; all other EFS files unchanged.")
        if not args.no_reboot:
            print("Rebooting into Android.", flush=True)
            device.reboot()
        else:
            print("Phone remains in TWRP (--no-reboot).")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        if folder:
            print(f"Backup/diagnostic directory: {folder}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
