"""Exercise the real shell clear helper against a local HTTP server only."""
import http.server
import pathlib
import subprocess
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class FileCacheHTTP(unittest.TestCase):
    def check_responses(self, get, post, expected_methods, success):
        calls = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def handle_request(self):
                calls.append((self.command, self.path))
                code, body = get if self.command == 'GET' else post
                self.send_response(code)
                self.end_headers()
                self.wfile.write(body.encode())
            do_GET = handle_request
            do_POST = handle_request
            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(['bash', '-c',
                'source engines/doris_engine.sh; be_http_port="$1"; user=root; password=""; '
                'clear_doris_file_cache_on_be 127.0.0.1', 'bash', str(server.server_port)],
                cwd=ROOT, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
            self.assertEqual([method for method, _ in calls], expected_methods)
            self.assertTrue(all(path == '/api/file_cache?op=clear&sync=true' for _, path in calls))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_cloud_get(self):
        self.check_responses((200, '{"status":"OK","msg":"cleared"}'), (500, ''), ['GET'], True)
    def test_local_404_then_post(self):
        self.check_responses((404, 'not found'), (200, '{"status":"OK","msg":"cleared"}'), ['GET','POST'], True)
    def test_method_405_then_post(self):
        self.check_responses((405, 'method'), (200, '{"status":"OK"}'), ['GET','POST'], True)
    def test_auth_failure_no_fallback(self):
        self.check_responses((401, 'unauthorized'), (200, '{"status":"OK"}'), ['GET'], False)
    def test_server_failure_no_fallback(self):
        self.check_responses((500, 'failed'), (200, '{"status":"OK"}'), ['GET'], False)
    def test_post_still_missing_fails(self):
        self.check_responses((404, 'missing'), (404, 'missing'), ['GET','POST'], False)
    def test_json_error_fails(self):
        self.check_responses((404, 'missing'), (200, '{"status":"ERROR"}'), ['GET','POST'], False)
    def test_invalid_json_fails(self):
        self.check_responses((200, 'not JSON'), (200, '{"status":"OK"}'), ['GET'], False)
    def test_json_list_fails(self):
        self.check_responses((200, '["OK"]'), (200, '{"status":"OK"}'), ['GET'], False)

if __name__ == '__main__':
    unittest.main()
