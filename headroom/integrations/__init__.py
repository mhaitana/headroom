"""Headroom integrations with popular LLM frameworks.

Available integrations:

Agno (pip install agno):
    - HeadroomAgnoModel: Drop-in wrapper for any Agno model
    - HeadroomPreHook/HeadroomPostHook: Agent-level hooks for tracking
    - create_headroom_hooks: Convenience function to create hook pairs

Example:
    # Agno integration
    from headroom.integrations.agno import HeadroomAgnoModel
"""

# Re-export from agno subpackage (optional dependency)
try:
    from .agno import (
        HeadroomAgnoModel,
        HeadroomPostHook,
        HeadroomPreHook,
        agno_available,
        create_headroom_hooks,
        get_model_name_from_agno,
    )
    from .agno import OptimizationMetrics as AgnoOptimizationMetrics
    from .agno import get_headroom_provider as get_agno_provider
    from .agno import optimize_messages as optimize_agno_messages

    _AGNO_AVAILABLE = True
except ImportError:
    _AGNO_AVAILABLE = False

__all__ = [
    # Agno
    "HeadroomAgnoModel",
    "HeadroomPreHook",
    "HeadroomPostHook",
    "agno_available",
    "create_headroom_hooks",
    "get_agno_provider",
    "get_model_name_from_agno",
    "AgnoOptimizationMetrics",
    "optimize_agno_messages",
]
