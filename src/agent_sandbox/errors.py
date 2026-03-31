from __future__ import annotations


class AgentSandboxError(RuntimeError):
    """Base project error."""


class ConfigurationError(AgentSandboxError):
    """Raised when configuration is invalid."""


class CommandExecutionError(AgentSandboxError):
    """Raised when an external command fails."""


class ProviderProbeError(AgentSandboxError):
    """Raised when a provider probe fails."""
