"""necro - the fastest Python web framework."""

from importlib.metadata import version

from necro.app import App

__version__ = version("necro")

__all__ = ["App", "__version__"]
