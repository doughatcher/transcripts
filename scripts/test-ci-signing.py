#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ci_signing', Path(__file__).with_name('ci-signing.py'))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

class SigningTests(unittest.TestCase):
    def test_prepare_and_cleanup_restores_original_search_list(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {'ASC_KEY_ID': 'ABC123'}):
            root = Path(d)
            env = root / 'env'
            with patch.object(ci, 'security', return_value='"/Users/doug/Library/Keychains/login.keychain-db"'):
                ci.prepare(root, env)
            self.assertIn('AuthKey_ABC123.p8', env.read_text())
            self.assertEqual((root / 'transcripts-api-keys').stat().st_mode & 0o777, 0o700)
            (root / 'build.keychain-db').touch()
            (root / 'transcripts-api-keys/AuthKey_ABC123.p8').write_text('test-only')
            (root / 'dev.p12').write_text('test-only')
            with patch.object(ci, 'security', return_value='') as security:
                ci.cleanup(root)
            self.assertEqual(security.call_args_list[0].args, ('list-keychains', '-d', 'user', '-s', '/Users/doug/Library/Keychains/login.keychain-db'))
            self.assertFalse((root / 'transcripts-api-keys').exists())
            self.assertFalse((root / 'dev.p12').exists())

    def test_cleanup_without_prepare_leaves_user_state_alone(self):
        with tempfile.TemporaryDirectory() as d, patch.object(ci, 'security') as security:
            ci.cleanup(Path(d))
            security.assert_not_called()

    def test_prepare_refuses_to_overwrite_recovery_state(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'transcripts-signing-state.json').write_text('[]')
            with self.assertRaises(RuntimeError):
                ci.prepare(root, root / 'env')

if __name__ == '__main__':
    unittest.main()
