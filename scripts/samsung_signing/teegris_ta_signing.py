#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Creeeeger <104427569+Creeeeger@users.noreply.github.com>
"""Authenticate the stock-ABI FKeyMaster SEC3 package with a persistent ROM CA."""

import argparse
import fcntl
import os
import struct
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import ExtensionOID, NameOID, SignatureAlgorithmOID

from apply_binary_patches import load_patch_rows
from teegris_elf import properties, sha256, ta_payload

FKEYMASTER_UUID = bytes.fromhex('000000000000000000004662436b6d52')
FKEYMASTER_AUTHORITY = b'samsung_ta:samsung_ta'
SOURCE_TA_SHA256 = '3568db8c24ae4e75ff1a1f98837964612db590293ada19cccfc969e8ac722fa9'
# Checked-in keys are intentionally public development material. A private
# build selects its own directory with TARGET_SAMSUNG_SIGNING_KEY_DIR.
DEFAULT_KEYS_DIR = Path(__file__).resolve().parents[2] / 'security/samsung/exynos9830_crecker'
ROOT_PATCH_TABLE = DEFAULT_KEYS_DIR.parent / 'patches/tzar_root_task_selected_patches.tsv'
ROOT_TASK_SHA256 = {
    '65313d0e7ab3edb93ad4e17efff52fa8ccf2afc3c36c1aa2fa3bff2370c6aa85',
    '0409fdb7e9d5bb7ce5300ed057bf75a49bba139e56610246ca9ef981caa0c673',
}
ROOT_CERT_OFFSET = 0x13400
ROOT_CERT_CAPACITY = 0x1000
ROOT_CERT_LENGTH_OFFSET = 0x133f0
PSS_SHA256 = padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32)


@dataclass(frozen=True)
class Package:
    magic: bytes
    image: bytes
    security: bytes
    authority: bytes
    signature: bytes
    certificate: bytes

    @property
    def signed_data(self):
        # root_task hashes exactly img_len + sec_len starting at the ELF.
        return self.image + self.security


def parse_package(data):
    if data[:4] not in (b'SEC2', b'SEC3'):
        raise ValueError('Expected a plaintext SEC2 or SEC3 package')
    image = ta_payload(data)
    offset = 8 + len(image)

    def take(size):
        nonlocal offset
        if size < 0 or offset + size > len(data):
            raise ValueError('Truncated TA authentication block')
        result = data[offset:offset + size]
        offset += size
        return result

    security = take(8) if data[:4] == b'SEC3' else b''
    if security and (security[:4] != b'\0\0\0\x04' or int.from_bytes(security[4:], 'big') == 0):
        raise ValueError('Invalid SEC3 rollback version')
    authority = take(take(1)[0])
    parts = authority.split(b':')
    if not 1 <= len(parts) <= 2 or any(not 1 <= len(p) <= 16 for p in parts):
        raise ValueError('Invalid TA authority/profile')
    signature = take(int.from_bytes(take(2), 'big'))
    certificate = take(int.from_bytes(take(2), 'big'))
    if offset != len(data) or not signature or not certificate:
        raise ValueError('Invalid TA authentication extent')
    return Package(data[:4], image, security, authority, signature, certificate)


def rsa2048(key):
    public = key.public_key() if isinstance(key, rsa.RSAPrivateKey) else key
    if not isinstance(public, rsa.RSAPublicKey) or public.key_size != 2048 or public.public_numbers().e != 65537:
        raise ValueError('TEEGRIS 4 TA authentication requires RSA-2048 with exponent 65537')
    return public


def verify_certificate(certificate, root):
    public = rsa2048(root.public_key())
    rsa2048(certificate.public_key())
    if certificate.signature_algorithm_oid != SignatureAlgorithmOID.RSA_WITH_SHA256:
        raise ValueError('TEEGRIS 4 requires sha256WithRSAEncryption certificates')
    if certificate.issuer != root.subject:
        raise ValueError('TA certificate issuer differs from ROM root')
    public.verify(certificate.signature, certificate.tbs_certificate_bytes, padding.PKCS1v15(), hashes.SHA256())


def load_root_certificate(keys_dir):
    data = (Path(keys_dir) / 'ta_signing/root.der').read_bytes()
    root = x509.load_der_x509_certificate(data)
    if root.public_bytes(serialization.Encoding.DER) != data or len(data) > ROOT_CERT_CAPACITY:
        raise ValueError('Invalid ROM root certificate encoding/size')
    verify_certificate(root, root)
    if not root.extensions.get_extension_for_oid(ExtensionOID.BASIC_CONSTRAINTS).value.ca:
        raise ValueError('ROM root is not a CA')
    if not root.extensions.get_extension_for_oid(ExtensionOID.KEY_USAGE).value.key_cert_sign:
        raise ValueError('ROM root cannot sign certificates')
    return root


def load_identity(keys_dir):
    folder = Path(keys_dir) / 'ta_signing'
    root = load_root_certificate(keys_dir)
    certificate = x509.load_der_x509_certificate((folder / 'fkeymaster.der').read_bytes())
    verify_certificate(certificate, root)
    key = serialization.load_pem_private_key((folder / 'fkeymaster-private.pem').read_bytes(), password=None)
    root_key = serialization.load_pem_private_key((folder / 'root-private.pem').read_bytes(), password=None)
    for private, cert in ((key, certificate), (root_key, root)):
        if not isinstance(private, rsa.RSAPrivateKey) or rsa2048(private).public_numbers() != cert.public_key().public_numbers():
            raise ValueError('TA signing key does not match its certificate')
    common_names = certificate.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    if len(common_names) != 1 or common_names[0].value.encode() != FKEYMASTER_AUTHORITY:
        raise ValueError('ROM FKeyMaster certificate has a different authority')
    if certificate.extensions.get_extension_for_oid(ExtensionOID.BASIC_CONSTRAINTS).value.ca:
        raise ValueError('FKeyMaster signing certificate must be a leaf')
    if not certificate.extensions.get_extension_for_oid(ExtensionOID.KEY_USAGE).value.digital_signature:
        raise ValueError('FKeyMaster certificate cannot sign packages')
    return key, certificate, root


def ensure_identity(keys_dir, donor_certificate):
    """Generate once, under a process lock; never rotate keys during a rebuild."""
    keys_dir = Path(keys_dir)
    if not keys_dir.is_dir():
        raise ValueError('Missing Samsung signing key directory: ' + str(keys_dir))
    folder = keys_dir / 'ta_signing'
    descriptor = os.open(keys_dir / '.ta-signing.lock', os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if folder.exists():
            return load_identity(keys_dir)
        donor = x509.load_der_x509_certificate(donor_certificate)
        names = donor.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
        if len(names) != 1 or names[0].value.encode() != FKEYMASTER_AUTHORITY:
            raise ValueError('Unexpected donor certificate authority')
        root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'CreckerROM FKeyMaster Root')])
        start = datetime(2020, 1, 1, tzinfo=timezone.utc)
        end = datetime(2120, 1, 1, tzinfo=timezone.utc)
        root = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(root_key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(start).not_valid_after(end)
                .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
                .add_extension(x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False)
                .sign(root_key, hashes.SHA256()))
        builder = (x509.CertificateBuilder().subject_name(donor.subject).issuer_name(root.subject)
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(start).not_valid_after(end))
        for extension in donor.extensions:
            value = extension.value
            if extension.oid == ExtensionOID.SUBJECT_KEY_IDENTIFIER:
                value = x509.SubjectKeyIdentifier.from_public_key(key.public_key())
            elif extension.oid == ExtensionOID.AUTHORITY_KEY_IDENTIFIER:
                value = x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key())
            # Preserve Samsung's private device-policy extensions verbatim.
            builder = builder.add_extension(value, critical=extension.critical)
        certificate = builder.sign(root_key, hashes.SHA256())
        with tempfile.TemporaryDirectory(prefix='.ta-signing-', dir=keys_dir) as temporary:
            staging = Path(temporary)
            os.chmod(staging, 0o700)
            for name, value in (('root-private.pem', root_key), ('fkeymaster-private.pem', key)):
                path = staging / name
                path.write_bytes(value.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                      serialization.NoEncryption()))
                path.chmod(0o600)
            for name, value in (('root.der', root), ('fkeymaster.der', certificate)):
                (staging / name).write_bytes(value.public_bytes(serialization.Encoding.DER))
            os.rename(staging, folder)
        return load_identity(keys_dir)


def verify_package(data, root):
    package = parse_package(data)
    certificate = x509.load_der_x509_certificate(package.certificate)
    verify_certificate(certificate, root)
    names = certificate.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    if len(names) != 1 or names[0].value.encode() != package.authority:
        raise ValueError('Certificate and package authorities differ')
    props = properties(package.image)
    if not props or len(props) != 112 or props[:16] != FKEYMASTER_UUID:
        raise ValueError('ROM trust anchor is restricted to stock-layout FKeyMaster')
    mode = PSS_SHA256 if package.magic == b'SEC3' else padding.PKCS1v15()
    rsa2048(certificate.public_key()).verify(package.signature, package.signed_data, mode, hashes.SHA256())
    return package


def resign_fkeymaster(data, keys_dir):
    package = parse_package(data)
    if package.magic != b'SEC3' or package.authority != FKEYMASTER_AUTHORITY:
        raise ValueError('Expected the pinned FKeyMaster SEC3 authority/profile')
    key, certificate, root = ensure_identity(keys_dir, package.certificate)
    donor = x509.load_der_x509_certificate(package.certificate)
    if certificate.subject != donor.subject:
        raise ValueError('Persistent signing identity differs from donor certificate subject')
    for extension in donor.extensions:
        if extension.oid not in (ExtensionOID.SUBJECT_KEY_IDENTIFIER, ExtensionOID.AUTHORITY_KEY_IDENTIFIER):
            if certificate.extensions.get_extension_for_oid(extension.oid) != extension:
                raise ValueError('Persistent signing identity differs from donor certificate policy')
    signature = key.sign(package.signed_data, PSS_SHA256, hashes.SHA256())
    cert = certificate.public_bytes(serialization.Encoding.DER)
    result = (package.magic + struct.pack('>I', len(package.image)) + package.signed_data
              + bytes([len(package.authority)]) + package.authority
              + struct.pack('>H', len(signature)) + signature + struct.pack('>H', len(cert)) + cert)
    verified = verify_package(result, root)
    if (verified.image, verified.security, verified.authority) != (package.image, package.security, package.authority):
        raise ValueError('Re-signing changed the TA payload, rollback version or authority')
    return result


def install_root_certificate(data, root):
    """Reject unrecognized root tasks, including the former authentication bypass."""
    restored = bytearray(data)
    rows, _ = load_patch_rows(ROOT_PATCH_TABLE)
    for row in rows:
        end = row.offset + len(row.new_bytes)
        if restored[row.offset:end] != row.new_bytes:
            raise ValueError('Missing authenticated FKeyMaster trust patch')
        restored[row.offset:end] = row.old_bytes
    restored[ROOT_CERT_OFFSET:ROOT_CERT_OFFSET + ROOT_CERT_CAPACITY] = bytes(ROOT_CERT_CAPACITY)
    restored[ROOT_CERT_LENGTH_OFFSET:ROOT_CERT_LENGTH_OFFSET + 4] = bytes(4)
    if sha256(restored) not in ROOT_TASK_SHA256:
        raise ValueError('Unsupported root_task: only the verified trust-anchor changes are allowed')
    verify_certificate(root, root)
    cert = root.public_bytes(serialization.Encoding.DER)
    if len(cert) > ROOT_CERT_CAPACITY:
        raise ValueError('ROM root certificate exceeds its reserved extent')
    result = bytearray(data)
    result[ROOT_CERT_OFFSET:ROOT_CERT_OFFSET + ROOT_CERT_CAPACITY] = cert.ljust(ROOT_CERT_CAPACITY, b'\0')
    struct.pack_into('<I', result, ROOT_CERT_LENGTH_OFFSET, len(cert))
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    generate = commands.add_parser('generate-keys', help='Create a persistent, independent TA signing identity for a private build')
    generate.add_argument('--keys-dir', type=Path, required=True,
                          help='Samsung signing directory selected by TARGET_SAMSUNG_SIGNING_KEY_DIR')
    generate.add_argument('--donor', type=Path, required=True, help='Pristine pinned FKeyMaster SEC3 container')
    args = parser.parse_args()
    # Keep provisioning tied to the reviewed donor policy, as the adapter is.
    data = args.donor.read_bytes()
    if sha256(data) != SOURCE_TA_SHA256:
        raise ValueError('FKeyMaster donor differs from the pinned source')
    package = parse_package(data)
    args.keys_dir.mkdir(parents=True, exist_ok=True)
    _, _, root = ensure_identity(args.keys_dir, package.certificate)
    print(f'TA identity ready: {args.keys_dir / "ta_signing"}; root SHA256 {root.fingerprint(hashes.SHA256()).hex()}')


if __name__ == '__main__':
    main()
