"""Security gates and bounded I/O regressions; no Azure calls or credentials."""

import copy
from contextlib import ExitStack
import http.server
import json
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from unittest.mock import patch

import live_azure_contract as contract
import live_azure_preflight as preflight


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.manifest = preflight.load_manifest(contract.ROOT / "ops/azure/environment.example.json")

    def approved_manifest(self):
        value = copy.deepcopy(self.manifest)
        value["targetApprovalReference"] = "fixture-owner-target-selection"
        value["liveWriteApprovalReference"] = "fixture-owner-retained-write-selection"
        value["azure"].update({"tenantId": "11111111-1111-4111-8111-111111111111",
                              "subscriptionId": "22222222-2222-4222-8222-222222222222",
                              "resourceGroup": "isolated-fixture", "account": "isolated-fixture",
                              "endpoint": "https://isolated-fixture.documents.azure.com/"})
        value["oidc"].update({"issuer": "https://fixture-issuer.example/", "audience": "fixture-api"})
        for role, principal in value["testPrincipals"].items():
            principal.update({"tenant": "fixture-tenant",
                              "subject": role + "-fixture"})
        value["budget"].update({"ceilingAmount": 1, "testDataRetentionAcknowledged": True})
        return value

    def test_negative_principal_can_share_trusted_tenant_but_must_be_distinct(self):
        value = self.approved_manifest()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "manifest.json"
            path.write_text(json.dumps(value))
            self.assertEqual(preflight.load_manifest(path)["testPrincipals"]["outsider"]["tenant"],
                             "fixture-tenant")
            for role in ("writer", "reader"):
                invalid = copy.deepcopy(value)
                invalid["testPrincipals"]["outsider"].update(invalid["testPrincipals"][role])
                path.write_text(json.dumps(invalid))
                with self.subTest(role=role), self.assertRaises(preflight.GateError):
                    preflight.load_manifest(path)
            value["testPrincipals"]["outsider"]["tenant"] = "foreign-fixture"
            path.write_text(json.dumps(value))
            preflight.load_manifest(path)

    def test_write_execution_refuses_unapproved_manifest_before_tokens_or_azure(self):
        with patch.object(contract, "load_private_token") as token, patch.object(contract, "inspect_target") as azure:
            with self.assertRaises(preflight.GateError):
                contract.execute(self.manifest)
            token.assert_not_called()
            azure.assert_not_called()

    def test_target_inspection_refuses_unselected_target_without_cli(self):
        with patch.object(preflight, "az_json") as cli:
            with self.assertRaises(preflight.GateError):
                preflight.inspect_target(self.manifest)
            cli.assert_not_called()

    def test_write_requires_separate_cost_and_retention_approvals(self):
        approved = self.approved_manifest()
        contract.require_write_approval(approved)
        for change in ({"ceilingAmount": 0}, {"testDataRetentionAcknowledged": False}):
            value = copy.deepcopy(approved)
            value["budget"].update(change)
            with self.assertRaises(preflight.GateError):
                contract.require_write_approval(value)
        approved["liveWriteApprovalReference"] = ""
        with self.assertRaises(preflight.GateError):
            contract.require_write_approval(approved)

    def test_impossible_request_budget_is_rejected_before_credentials_or_azure(self):
        manifest = self.approved_manifest()
        for budget in (25, 30):
            manifest["budget"]["maxProtocolRequests"] = budget
            with self.subTest(budget=budget), patch.object(contract, "load_private_token") as tokens, \
                    patch.object(contract, "inspect_target") as azure:
                with self.assertRaises(preflight.GateError):
                    contract.execute(manifest)
                tokens.assert_not_called()
                azure.assert_not_called()
        manifest["budget"]["maxProtocolRequests"] = 31
        contract.require_write_approval(manifest)

    def test_metadata_rejects_unsafe_live_topologies_and_partition_expiry(self):
        manifest = self.approved_manifest()
        subscription = {"id": manifest["azure"]["subscriptionId"],
                        "tenantId": manifest["azure"]["tenantId"], "state": "Enabled"}
        account = {"kind": "GlobalDocumentDB", "endpoint": manifest["azure"]["endpoint"],
                   "multiWrite": False, "consistency": "Session", "writeLocations": [{}],
                   "readLocations": [{}], "disableLocalAuth": True}
        container = {"partitionPaths": ["/scopeId"], "ttl": None}
        self.assertTrue(preflight.assess_metadata(manifest, account, container, subscription)["productionGuardCompatible"])
        for change in ({"multiWrite": True}, {"multiWrite": None}, {"consistency": "Eventual"},
                       {"writeLocations": []}, {"endpoint": "https://other.documents.azure.com/"}):
            with self.subTest(change=change), self.assertRaises(preflight.GateError):
                preflight.assess_metadata(manifest, {**account, **change}, container, subscription)
        for change in ({"partitionPaths": ["/tenant"]}, {"ttl": 3600}):
            with self.subTest(change=change), self.assertRaises(preflight.GateError):
                preflight.assess_metadata(manifest, account, {**container, **change}, subscription)

    def test_cli_context_mismatch_never_switches_global_account(self):
        with patch.object(preflight, "az_json", return_value={"id": "different", "tenantId": "different"}) as cli:
            with self.assertRaises(preflight.GateError):
                preflight.check_cli_default(self.approved_manifest())
            self.assertEqual(cli.call_args.args[0], ["account", "show"])

    def test_private_token_permissions_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "token.jwt"
            path.write_text("a" * 24 + "." + "b" * 24 + "." + "c" * 24)
            path.chmod(0o644)
            with self.assertRaises(preflight.GateError):
                contract.load_private_token(path)
            path.chmod(0o600)
            self.assertEqual(contract.load_private_token(path).count("."), 2)

    def test_request_bound_blocks_before_another_connection(self):
        client = contract.Client([1, 2], ssl.create_default_context(), {"maxRuntimeSeconds": 30, "maxProtocolRequests": 1})
        client.requests = 1
        with patch.object(contract.http.client, "HTTPSConnection") as connection:
            with self.assertRaises(preflight.GateError):
                client.connection(0)
            connection.assert_not_called()

    def test_response_completed_after_absolute_deadline_is_rejected(self):
        clock = [0]

        class Response:
            status = 200

            def read(self, _):
                clock[0] = 33
                return b'{"status":"ok"}'

        class Connection:
            closed = False

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                clock[0] = 29
                return Response()

            def close(self):
                self.closed = True

        with patch.object(contract.time, "monotonic", side_effect=lambda: clock[0]):
            client = contract.Client([1, 2], object(), {"maxRuntimeSeconds": 30, "maxProtocolRequests": 31})
            clock[0] = 25
            connection = Connection()
            with patch.object(client, "connection", return_value=connection):
                with self.assertRaisesRegex(preflight.GateError, "runtime bound"):
                    client.request(0, "GET", "/healthz")
            self.assertTrue(connection.closed)

    def test_sse_completed_line_after_absolute_deadline_is_rejected(self):
        clock = [0]

        class Response:
            status = 200

            def getheader(self, *_args):
                return "text/event-stream"

            def readline(self, _):
                clock[0] = 31
                return b'id: late-event\n'

        class Connection:
            closed = False

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                clock[0] = 29
                return Response()

            def close(self):
                self.closed = True

        with patch.object(contract.time, "monotonic", side_effect=lambda: clock[0]):
            client = contract.Client([1, 2], object(), {"maxRuntimeSeconds": 30, "maxProtocolRequests": 31})
            clock[0] = 25
            connection = Connection()
            session = {"scopeId": "scope", "principalId": "principal", "scopeMode": "tenant", "permissionVersion": "1"}
            with patch.object(client, "connection", return_value=connection):
                with self.assertRaisesRegex(preflight.GateError, "runtime bound"):
                    client.event(0, "fixture-token", session, "fixture-cursor")
            self.assertTrue(connection.closed)

    def test_watchdog_stops_owned_process_and_active_socket_without_http_progress(self):
        process_stopped, socket_stopped = threading.Event(), threading.Event()

        class Process:
            def poll(self):
                return None

            def kill(self):
                process_stopped.set()

        class Socket:
            def shutdown(self, _):
                socket_stopped.set()

        window = contract.LiveWindow(0.02)
        try:
            window.add_process(Process())
            window.add_socket(Socket())
            self.assertTrue(process_stopped.wait(timeout=1))
            self.assertTrue(socket_stopped.wait(timeout=1))
            self.assertTrue(window.expired.is_set())
        finally:
            window.close()

    def test_partial_evidence_survives_os_error_interrupt_and_cleanup_failure(self):
        class Process:
            running = True

            def poll(self):
                return None if self.running else 0

            def terminate(self):
                self.running = False

            def kill(self):
                self.running = False

            def wait(self, **_kwargs):
                return 0

        class Probe:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                pass

            def settimeout(self, _):
                pass

            def connect_ex(self, _):
                return 0

        def prepare_tls(arguments, **_kwargs):
            for option in ("-keyout", "-out"):
                Path(arguments[arguments.index(option) + 1]).write_text("fixture-only")

        def health(client, *_args, **_kwargs):
            client.requests += 1
            return {"status": "ok"}

        for failure in ("os", "interrupt", "cleanup"):
            def contract_failure(client, *_args, **_kwargs):
                client.results.append("fixture-accepted-write")
                client.requests += 1
                client.write_attempted = True
                if failure == "os":
                    raise OSError("private-credential-must-not-appear")
                if failure == "interrupt":
                    raise KeyboardInterrupt()

            with self.subTest(failure=failure), ExitStack() as patches:
                patches.enter_context(patch.object(contract, "load_private_token", return_value="private-fixture-jwt"))
                patches.enter_context(patch.object(contract, "check_cli_default"))
                patches.enter_context(patch.object(contract, "inspect_target", return_value={"productionGuardCompatible": True}))
                patches.enter_context(patch.object(contract, "run_command", side_effect=prepare_tls))
                patches.enter_context(patch.object(contract, "choose_port", side_effect=[1234, 1235]))
                patches.enter_context(patch.object(contract.ssl, "create_default_context", return_value=object()))
                patches.enter_context(patch.object(contract.socket, "socket", return_value=Probe()))
                patches.enter_context(patch.object(contract.subprocess, "Popen", side_effect=lambda *_args, **_kwargs: Process()))
                patches.enter_context(patch.object(contract.Client, "request", autospec=True, side_effect=health))
                patches.enter_context(patch.object(contract, "exercise_contract", side_effect=contract_failure))
                if failure == "cleanup":
                    patches.enter_context(patch.object(contract, "stop_process", side_effect=OSError("private-cleanup-detail")))
                with self.assertRaises(preflight.GateError) as captured:
                    contract.execute(self.approved_manifest(), binary=Path(__file__))
                error = captured.exception
                self.assertTrue(error.evidence["retainedTestDocumentId"].startswith("live-"))
                self.assertTrue(error.evidence["testDataMayBeRetained"])
                self.assertEqual(error.evidence["passed"], ["fixture-accepted-write"])
                self.assertEqual(error.evidence["protocolRequests"], 3)
                self.assertEqual(error.exit_code, 130 if failure == "interrupt" else 2)
                self.assertNotIn("private-", str(error))

    def test_http_connection_is_closed_and_consistency_is_forwarded_without_token_urls(self):
        class Response:
            status = 200

            def read(self, maximum):
                return b'{"changes": [], "cursor": "cursor", "hasMore": false}'

            def getheader(self, name):
                return "signed-envelope" if name == contract.SESSION_HEADER else None

        class Connection:
            closed = False
            headers = None
            path = None

            def request(self, method, path, body, headers):
                self.headers, self.path = headers, path

            def getresponse(self):
                return Response()

            def close(self):
                self.closed = True

        connection = Connection()
        session = {"scopeId": "scope", "principalId": "principal", "scopeMode": "tenant", "permissionVersion": "1"}
        client = contract.Client([1, 2], ssl.create_default_context(), {"maxRuntimeSeconds": 30, "maxProtocolRequests": 5})
        with patch.object(client, "connection", return_value=connection):
            client.request(0, "GET", "/v1/sync", token="private-jwt", session=session)
            self.assertTrue(connection.closed)
            client.request(1, "GET", "/v1/sync?cursor=cursor", token="private-jwt", session=session)
        self.assertEqual(connection.headers[contract.SESSION_HEADER], "signed-envelope")
        self.assertEqual(connection.headers["Authorization"], "Bearer private-jwt")
        self.assertNotIn("private-jwt", connection.path)

    def test_real_local_tls_http_and_sse_preserve_verification_and_close(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                if self.path.startswith("/v1/events?"):
                    body = b'id: hint-id\nevent: change\ndata: {"cursor":"hint-id"}\n\n'
                    content_type = "text/event-stream"
                else:
                    body, content_type = b'{"status":"ok"}', "application/json"
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()

            def log_message(self, *_):
                pass

        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            certificate, key = directory / "tls.pem", directory / "tls.key"
            contract.run_command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                                  "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                                  "-keyout", str(key), "-out", str(certificate)])
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(certificate, key)
            server.socket = tls.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                ports = [server.server_port, server.server_port]
                budget = {"maxRuntimeSeconds": 30, "maxProtocolRequests": 5}
                client = contract.Client(ports, ssl.create_default_context(cafile=str(certificate)), budget)
                self.assertEqual(client.request(0, "GET", "/healthz"), {"status": "ok"})
                session = {"scopeId": "fixture-scope", "principalId": "fixture-principal",
                           "scopeMode": "tenant", "permissionVersion": "1"}
                self.assertEqual(client.event(1, "fixture-private-jwt", session, "data-cursor"),
                                 ("change", "hint-id", {"cursor": "hint-id"}))
                untrusted = contract.Client(ports, ssl.create_default_context(), budget)
                with self.assertRaises(preflight.GateError):
                    untrusted.request(0, "GET", "/healthz")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
