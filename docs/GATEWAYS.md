# Portkey and work gateways

tilde's manager, scribe, dream and background review use your Codex model and provider configuration. They do not replace the model with a built-in name, so gateway aliases survive unchanged. Restart tilde after changing configuration. Workers still use their own harness configuration.

For Portkey, add a custom provider to your user-level Codex `config.toml` (normally `~/.codex/config.toml`, or under `CODEX_HOME`):

```toml
model_provider = "portkey"
model = "@work-openai/your-model"

[model_providers.portkey]
name = "Portkey"
base_url = "https://api.portkey.ai/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
env_http_headers = { "x-portkey-api-key" = "PORTKEY_API_KEY" }
```

Replace `@work-openai/your-model` with the provider slug and model your organization exposes. For a private/work gateway, set `base_url` to its API base, including any path prefix and `/v1`. tilde does not infer routing from the hostname. The gateway and selected model must support streaming Responses, tools, and structured output for memory/review passes; a Chat Completions-only gateway cannot serve Codex.

An alternative to a qualified model is a plain model name with an explicit provider header:

```toml
model = "your-model"
model_provider = "portkey"

[model_providers.portkey]
name = "Work Portkey"
base_url = "https://gateway.example.com/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
http_headers = { "x-portkey-provider" = "@work-openai" }
env_http_headers = { "x-portkey-api-key" = "PORTKEY_API_KEY" }
```

Portkey also supports `x-portkey-config` for a saved routing config and the legacy `x-portkey-virtual-key`. Use the routing method your organization supplies. Direct provider passthrough uses `x-portkey-provider = "openai"` (or the appropriate provider) plus provider authentication, separately from the Portkey API key. Configure that authentication through Codex's environment-backed headers or `env_key`, never literal keys in `http_headers`.

`x-portkey-api-key` authenticates to Portkey. `Authorization: Bearer ...` authenticates to the upstream provider in direct passthrough mode. They are different credentials. Pointing Codex's built-in OpenAI URL at Portkey alone does not supply provider routing.

Make the referenced environment variables available to the tilde process using your normal credential provisioning. A Finder/launchd app does not inherit exports from an unrelated terminal, and tilde only asks your login shell for PATH. Keep credentials out of tilde's notebook, screenshots and command arguments. tilde does not collect or store gateway keys; Codex resolves environment-backed authentication.

For an embedded/headless configuration, `Manager.Config.model` and `modelProvider`, `CodexMemoryModel` and `CodexReviewModel` accept explicit model/provider overrides. Nil uses Codex's configuration. The provider ID names a `model_providers` entry, whereas `x-portkey-provider` names a Portkey route.

Verified documentation:

- [Portkey headers and routing](https://portkey.ai/docs/api-reference/inference-api/headers)
- [Portkey Responses and streaming](https://portkey.ai/docs/integrations/llms/openai#responses-api)
- [Codex custom providers](https://developers.openai.com/codex/config-advanced/#custom-model-providers)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference/)
