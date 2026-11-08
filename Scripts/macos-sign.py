#!/usr/bin/env python3
"""Sign JumpCut's Mac app bundle with the pinned Apple Development identity.

The app ships as source and is normally ad-hoc signed (Scripts/bundle.sh), which
changes its code identity on every rebuild and makes macOS treat each build as a
new app for Accessibility permission. This script re-signs an already-built
bundle with the persistent Apple Development identity pinned below, so the code
identity stays stable across builds. Adapted from e-kotov/t3code's
scripts/fork-macos-sign.py.
"""
import argparse
import base64
from contextlib import contextmanager
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import subprocess
import tempfile

APP_ID = "dev.ekotov.jumpcut"
APP_NAME = "JumpCut.app"
CERTIFICATE_SHA1 = "b895b5d41ee6565fc7134fd1fbac080dac14b8ce"
TEAM_ID = "2MC7X68AVT"
REQUIREMENT = (f'identifier "{APP_ID}" and anchor apple generic and '
               f'certificate leaf[subject.OU] = "{TEAM_ID}" and '
               'certificate leaf[field.1.2.840.113635.100.6.1.12] exists')
MACHO_MAGICS = {
    bytes.fromhex(value)
    for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
}


def run(*arguments):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True)
    if result.returncode:
        # security's arguments include passwords; never include argv in errors.
        raise RuntimeError(f"{arguments[0]} failed: {result.stderr.decode(errors='replace')}")
    return result.stdout


def scratch(prefix):
    root = Path(os.environ.get("RUNNER_TEMP", str(Path.home() / "tmp")))
    root.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(prefix=prefix, dir=root)


@contextmanager
def signing_keychain(certificate, password):
    original = shlex.split(run("security", "list-keychains", "-d", "user").decode())
    with scratch("jumpcut-signing-") as directory:
        root = Path(directory)
        keychain = root / "signing.keychain-db"
        archive = root / "certificate.p12"
        archive.write_bytes(certificate)
        archive.chmod(0o600)
        keychain_password = secrets.token_urlsafe(40)
        created = False
        try:
            run("security", "create-keychain", "-p", keychain_password, keychain)
            created = True
            # codesign also locates the private key through the user search list.
            run("security", "list-keychains", "-d", "user", "-s", keychain, *original)
            run("security", "set-keychain-settings", "-lut", "21600", keychain)
            run("security", "unlock-keychain", "-p", keychain_password, keychain)
            run("security", "import", archive, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign")
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, keychain)
            identities = run("security", "find-certificate", "-a", "-Z", keychain).decode().lower()
            if f"sha-1 hash: {CERTIFICATE_SHA1}" not in identities:
                raise ValueError("The Mac signing secret does not contain the pinned JumpCut certificate.")
            yield keychain
        finally:
            try:
                if created:
                    run("security", "delete-keychain", keychain)
            finally:
                run("security", "list-keychains", "-d", "user", "-s", *original)


def expected_version():
    version = (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip()
    if not version:
        raise ValueError("The VERSION file is empty.")
    return version


def verify_app(app, version):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleShortVersionString") != version:
        raise ValueError("Mac app identity or version does not match the VERSION file.")
    run("codesign", "--verify", "--deep", "--strict", "-R", f"={REQUIREMENT}", app)


def sign_app(app, keychain, version):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleShortVersionString") != version:
        raise ValueError("Refusing to sign an unexpected app or version.")
    # JumpCut's bundle is a single executable, but keep the generic walk so
    # nested code added later is still signed innermost first.
    paths = [path for path in app.rglob("*") if not path.is_symlink()]
    for path in paths:
        if path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in MACHO_MAGICS:
                run("codesign", "--force", "--sign", CERTIFICATE_SHA1, "--keychain", keychain,
                    "--timestamp=none", "--preserve-metadata=identifier,entitlements", path)
    bundles = [path for path in paths if path.is_dir() and path.suffix in (".app", ".framework", ".xpc")]
    for path in sorted(bundles, key=lambda item: len(item.parts), reverse=True) + [app]:
        run("codesign", "--force", "--sign", CERTIFICATE_SHA1, "--keychain", keychain,
            "--timestamp=none", "--preserve-metadata=entitlements", path)
    verify_app(app, version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=Path("build") / APP_NAME)
    parser.add_argument("--version", help="Override the version read from the VERSION file.")
    args = parser.parse_args()
    app = args.app.resolve()
    if not app.is_dir():
        raise ValueError(f"No app bundle found at {app}; run Scripts/bundle.sh first.")
    version = args.version or expected_version()
    certificate = base64.b64decode(os.environ["FORK_MACOS_APPLE_CERTIFICATE_BASE64"], validate=True)
    password = os.environ["FORK_MACOS_APPLE_CERTIFICATE_PASSWORD"]
    if not certificate or not password:
        raise ValueError("Both persistent Mac signing secrets are required.")
    with signing_keychain(certificate, password) as keychain:
        sign_app(app, keychain, version)
    print(f"Verified {APP_NAME} for {version}; signer {CERTIFICATE_SHA1}.")


if __name__ == "__main__":
    main()
