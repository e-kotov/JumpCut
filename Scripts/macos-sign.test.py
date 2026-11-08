"""Native regression: updated signed code can read the first build's Keychain item.

JumpCut is distributed as source and installed ad-hoc by most users; this suite
proves the persistent Apple Development identity keeps a stable code identity
across builds, including for the real login Keychain where the Accessibility
permission identity lives. Adapted from e-kotov/t3code's
scripts/fork-macos-sign.test.py.
"""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import shutil
import subprocess
import unittest
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("signing", Path(__file__).with_name("macos-sign.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)

FIXTURE = r'''
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    SecKeychainSetUserInteractionAllowed(false);
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainOpen(argv[1], &keychain);
    const char *service = argv[3];
    const char *account = "fixture";
    const char *secret = "fixture-secret";
    if (!status && strcmp(argv[2], "write") == 0) {
        status = SecKeychainAddGenericPassword(keychain, strlen(service), service,
            strlen(account), account, strlen(secret), secret, NULL);
    } else if (!status) {
        UInt32 length = 0;
        void *value = NULL;
        SecKeychainItemRef item = NULL;
        status = SecKeychainFindGenericPassword(keychain, strlen(service), service,
            strlen(account), account, &length, &value, &item);
        if (!status) {
            if (length != strlen(secret) || memcmp(value, secret, length) != 0) status = -1;
            SecKeychainItemFreeContent(NULL, value);
            if (!status && strcmp(argv[2], "delete") == 0) status = SecKeychainItemDelete(item);
        }
        if (item) CFRelease(item);
    }
    if (keychain) CFRelease(keychain);
    printf("build %d: %d\n", REVISION, (int)status);
    return status ? 1 : 0;
}
'''


def fixture(root, version, revision):
    app = root / signing.APP_NAME
    executable = app / "Contents/MacOS/Fixture"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": signing.APP_ID,
        "CFBundleExecutable": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(revision),
    }))
    source = root / "fixture.c"
    source.write_text(FIXTURE)
    signing.run("cc", "-Wno-deprecated-declarations", f"-DREVISION={revision}", source,
                "-framework", "Security", "-framework", "CoreFoundation", "-o", executable)
    return app, executable


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("FORK_MACOS_APPLE_CERTIFICATE_BASE64"),
                     "Native signing/Keychain regression runs in the Mac signing job.")
class MacSigningTest(unittest.TestCase):
    def test_updated_build_retains_keychain_access_and_app_keeps_signature(self):
        original_search_list = signing.run("security", "list-keychains", "-d", "user")
        certificate = base64.b64decode(os.environ["FORK_MACOS_APPLE_CERTIFICATE_BASE64"], validate=True)
        with signing.scratch("jumpcut-signing-test-") as directory:
            root = Path(directory)
            with signing.signing_keychain(certificate, os.environ["FORK_MACOS_APPLE_CERTIFICATE_PASSWORD"]) as keychain:
                first, first_exe = fixture(root / "first", "0.1.0", 1)
                updated, updated_exe = fixture(root / "updated", "0.1.0", 2)
                signing.sign_app(first, keychain, "0.1.0")
                signing.sign_app(updated, keychain, "0.1.0")
                self.assertNotEqual(first_exe.read_bytes(), updated_exe.read_bytes())
                # A Keychain item written by one build stays readable by the next.
                service = f"jumpcut-signing-test-{uuid.uuid4()}"
                self.assertIn(b"build 1: 0", signing.run(first_exe, keychain, "write", service))
                self.assertIn(b"build 2: 0", signing.run(updated_exe, keychain, "read", service))
                # The login keychain has partition ACLs; a newly created legacy keychain does not.
                login_keychain = Path.home() / "Library/Keychains/login.keychain-db"
                active = root / "active" / signing.APP_NAME
                active.parent.mkdir()
                shutil.copytree(first, active)
                live_exe = active / "Contents/MacOS/Fixture"
                try:
                    self.assertIn(b"build 1: 0", signing.run(live_exe, login_keychain, "write", service))
                    shutil.rmtree(active)
                    shutil.copytree(updated, active)
                    self.assertIn(b"build 2: 0", signing.run(live_exe, login_keychain, "read", service))
                finally:
                    shutil.rmtree(active)
                    shutil.copytree(first, active)
                    result = subprocess.run([str(live_exe), str(login_keychain), "delete", service],
                                            capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
                # Tampering breaks the signature; an ad-hoc replacement fails the requirement.
                (updated / "Contents/Info.plist").write_bytes(b"tampered")
                with self.assertRaises(RuntimeError):
                    signing.run("codesign", "--verify", "--strict", updated)
                signing.run("codesign", "--force", "--sign", "-", first)
                with self.assertRaises(RuntimeError):
                    signing.verify_app(first, "0.1.0")
                keychain_path = keychain
            self.assertFalse(keychain_path.exists())
        self.assertEqual(signing.run("security", "list-keychains", "-d", "user"), original_search_list)


if __name__ == "__main__":
    unittest.main()
