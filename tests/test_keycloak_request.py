import io
import os
import pathlib
import runpy
import tempfile
import unittest
import urllib.error
from unittest import mock

MAIN = runpy.run_path(str(pathlib.Path(__file__).parents[1] / "scripts/keycloak-request.py"))["main"]
BASE = "https://keycloak.example"
URL = BASE + "/admin/realms/congenia/roles"


class KeycloakRequestTests(unittest.TestCase):
    def setUp(self):
        self.stdout = mock.Mock(buffer=io.BytesIO())
        self.stderr = io.StringIO()
        for patch in [
            mock.patch.dict(os.environ, KEYCLOAK_BASE_URL=BASE, KEYCLOAK_ADMIN_PASSWORD="test-password"),
            mock.patch("sys.stdout", self.stdout),
            mock.patch("sys.stderr", self.stderr),
        ]:
            patch.start()
            self.addCleanup(patch.stop)

    def test_rejected_token_is_refreshed_and_stdin_body_is_preserved(self):
        payload = b'{"name":"medico"}'
        responses = [
            io.BytesIO(b'{"access_token":"first-token"}'),
            urllib.error.HTTPError(URL, 401, "Unauthorized", {}, None),
            io.BytesIO(b'{"access_token":"second-token"}'),
            io.BytesIO(b'{}'),
        ]
        with mock.patch("urllib.request.urlopen", side_effect=responses) as send, \
                mock.patch("sys.stdin", mock.Mock(buffer=io.BytesIO(payload))):
            self.assertEqual(MAIN(["-fsS", "-X", "POST", "-d", "@-", URL]), 0)
        requests = [call.args[0] for call in send.call_args_list]
        self.assertEqual(requests[1].data, payload)
        self.assertEqual(requests[3].data, payload)
        self.assertEqual(requests[3].get_header("Authorization"), "Bearer second-token")
        self.assertEqual(self.stdout.buffer.getvalue(), b'{}')
        self.assertEqual(self.stderr.getvalue(), "")

    def test_forbidden_request_does_not_retry_or_print_response_secrets(self):
        with mock.patch("urllib.request.urlopen", side_effect=[
            io.BytesIO(b'{"access_token":"private-token"}'),
            urllib.error.HTTPError(URL, 403, "private-server-response", {}, None),
        ]) as send:
            self.assertEqual(MAIN(["-fsS", URL]), 22)
        self.assertEqual(send.call_count, 2)
        self.assertEqual(self.stdout.buffer.getvalue(), b'')
        self.assertIn("HTTP 403", self.stderr.getvalue())
        self.assertNotIn("private", self.stderr.getvalue())

    def test_admin_token_cannot_be_sent_to_another_host(self):
        with mock.patch("urllib.request.urlopen") as send, self.assertRaises(SystemExit):
            MAIN(["-fsS", "https://another.example/admin/realms/congenia"])
        send.assert_not_called()

    def test_subsequent_process_calls_share_private_cache_and_refresh_expiry(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = pathlib.Path(directory) / "token.json"
            with mock.patch.dict(os.environ, KEYCLOAK_ADMIN_TOKEN_CACHE=str(cache)), \
                    mock.patch("urllib.request.urlopen", side_effect=[
                        io.BytesIO(b'{"access_token":"cached-token","expires_in":60}'),
                        io.BytesIO(b'{}'), io.BytesIO(b'{}'),
                        io.BytesIO(b'{"access_token":"renewed-token","expires_in":60}'),
                        io.BytesIO(b'{}'),
                    ]) as send:
                self.assertEqual(MAIN(["-fsS", URL]), 0)
                self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
                self.assertEqual(MAIN(["-fsS", URL]), 0)
                self.assertEqual(send.call_count, 3)
                cache.write_text('{"access_token":"expired-token","expires_at":0}')
                self.assertEqual(MAIN(["-fsS", URL]), 0)
                self.assertEqual(send.call_count, 5)
                request = send.call_args.args[0]
                self.assertEqual(request.get_header("Authorization"), "Bearer renewed-token")
