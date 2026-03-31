from __future__ import annotations

APP_NAME = "agent-sandbox"
CONFIG_DIR_NAME = ".agent-sandbox"
CONFIG_FILE_NAME = "config.toml"
PROVIDER_LOCK_FILE_NAME = "provider-lock.json"
DEFAULT_TEMPLATE = "docker/sandbox-templates:opencode"
DEFAULT_POLICY_PROFILE = "balanced"
DEFAULT_SECRET_BACKEND = "env"
DEFAULT_TIMEOUT_SECONDS = 20
DEFAULT_LOG_FILE_NAME = "agent-sandbox.log"
DEFAULT_CONFIG_TEXT = """[project]
name = \"{project_name}\"

[provider]
base_url = \"{base_url}\"
provider_id = \"{provider_id}\"
provider_name = \"{provider_name}\"
model = \"{model}\"
api_key_env = \"OPENAI_COMPAT_API_KEY\"

[sandbox]
template = \"{template}\"
policy_profile = \"{policy_profile}\"
secret_backend = \"{secret_backend}\"
name = \"{sandbox_name}\"
"""

POLICY_PROFILES: dict[str, dict[str, object]] = {
    "open": {"default_policy": "allow", "block_cidrs": [], "block_hosts": []},
    "balanced": {
        "default_policy": "allow",
        "block_cidrs": [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
            "168.63.129.16/32",
            "100.100.100.200/32",
            "fc00::/7",
            "fe80::/10",
            "::1/128",
            "fd00:ec2::254/128",
        ],
        "block_hosts": [],
    },
    "restricted": {"default_policy": "deny", "block_cidrs": [], "block_hosts": []},
}
