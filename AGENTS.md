# Contributor instructions

Keep this project independent of Lantern and other repositories. Preserve Cosmos DB for NoSQL, validated access JWTs and server-managed authorization. Never trust a client partition or return Cosmos credentials. Atomic write guarantees stop at one logical partition. Do not provision paid resources or publish packages as part of development. Public visibility, first publication and license decisions require user authorization.

Document visible behavior in docs/spec before substantial work. Keep docs/protocol.md, adapters and tests aligned. Use Conventional Commits. Run the BFF and Dart tests for protocol changes; use the CI checks as the portable reference. Do not add authentication bypasses to production code.
