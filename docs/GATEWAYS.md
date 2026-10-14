# Portkey and work gateways

tilde's manager, scribe, dream and background review run on Codex with your own model and provider configuration, so a gateway that works for Codex works for tilde. Model names pass through unchanged, so gateway aliases keep working. Workers use their own harness configuration.

For Portkey, add a provider to your Codex `config.toml` (`~/.codex/config.toml`, or under `CODEX_HOME`):

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

Use the provider slug and model your organization exposes. For another gateway, set `base_url` to its API base, including any path prefix and `/v1`. It must serve the Responses API with streaming, tools and structured output; a gateway that only speaks Chat Completions can't serve Codex.

tilde and its agents get the same environment variables your terminal has (anything your login shell's config exports, such as `PORTKEY_API_KEY`), read when tilde starts. Restart tilde after changing them or `config.toml`. Keep keys in the environment, never in `config.toml` or the notebook.
