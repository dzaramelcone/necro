"""necro.Model - the base model class for request/response shapes.

Feels like pydantic, but validation happens in Zig for speed.
Schema generation stays in Python (introspecting annotations).
"""

import inspect
import types
import typing
from datetime import datetime
from typing import Any, ClassVar, get_type_hints

registry: dict[str, type[Model]] = {}


class _TrackedList(list[Any]):
    __slots__ = ("_necro_root",)

    def __init__(self, values: list[Any], root: "Model") -> None:
        super().__init__(values)
        self._necro_root = root

    def _detach_root(self) -> None:
        object.__setattr__(self._necro_root, "_necro_attached_row", None)

    def __setitem__(self, index: Any, value: Any) -> None:
        if isinstance(index, slice):
            value = [_track_mutable_value(item, self._necro_root) for item in value]
        else:
            value = _track_mutable_value(value, self._necro_root)
        super().__setitem__(index, value)
        self._detach_root()

    def __delitem__(self, index: Any) -> None:
        super().__delitem__(index)
        self._detach_root()

    def __iadd__(self, values: Any) -> "_TrackedList":
        values = [_track_mutable_value(item, self._necro_root) for item in values]
        result = super().__iadd__(values)
        self._detach_root()
        return result

    def __imul__(self, count: int) -> "_TrackedList":
        result = super().__imul__(count)
        self._detach_root()
        return result

    def append(self, value: Any) -> None:
        value = _track_mutable_value(value, self._necro_root)
        super().append(value)
        self._detach_root()

    def clear(self) -> None:
        super().clear()
        self._detach_root()

    def extend(self, values: Any) -> None:
        values = [_track_mutable_value(item, self._necro_root) for item in values]
        super().extend(values)
        self._detach_root()

    def insert(self, index: int, value: Any) -> None:
        value = _track_mutable_value(value, self._necro_root)
        super().insert(index, value)
        self._detach_root()

    def pop(self, index: int = -1) -> Any:
        value = super().pop(index)
        self._detach_root()
        return value

    def remove(self, value: Any) -> None:
        super().remove(value)
        self._detach_root()

    def reverse(self) -> None:
        super().reverse()
        self._detach_root()

    def sort(self, /, *args: Any, **kwargs: Any) -> None:
        super().sort(*args, **kwargs)
        self._detach_root()


class Model:
    """Base class for necro data models.

    Subclass this to define request bodies, response shapes, and
    any structured data that crosses the Python/Zig boundary.

    Validation is dispatched to the Zig runtime via the C extension.
    Schema generation uses Python's typing introspection so OpenAPI
    docs stay in pure Python with zero Zig calls.
    """

    _schema_cache: ClassVar[dict | None] = None
    _field_hints_cache: ClassVar[dict[str, Any] | None] = None

    def __init_subclass__(cls, **kwargs: Any) -> None:
        super().__init_subclass__(**kwargs)
        qualname = f"{cls.__module__}.{cls.__qualname__}"
        registry[qualname] = cls
        cls._schema_cache = None
        cls._field_hints_cache = None
        # Trigger schema compilation in Zig at import time.
        # The C extension walks cls.__annotations__ via get_type_hints
        # and builds a SchemaNode tree for fused decode+validate.
        _compile_schema_in_zig(cls)

    @classmethod
    def _model_fields(cls) -> dict[str, Any]:
        if cls._field_hints_cache is None:
            module = inspect.getmodule(cls)
            namespace = dict(vars(module)) if module is not None else {}
            namespace.setdefault("Any", Any)
            namespace.setdefault("ClassVar", ClassVar)
            namespace.setdefault("typing", typing)
            hints = get_type_hints(
                cls, globalns=namespace, localns=namespace, include_extras=True
            )
            cls._field_hints_cache = {
                name: hint
                for name, hint in hints.items()
                if not name.startswith("_") and not _is_classvar(hint)
            }
        return cls._field_hints_cache

    def __init__(self, **data: Any) -> None:
        hints = self.__class__._model_fields()
        for name, _hint in hints.items():
            value = data.get(name, getattr(self.__class__, name, _MISSING))
            if value is _MISSING:
                raise ValueError(f"missing required field: {name}")
            object.__setattr__(self, name, value)

    @classmethod
    def _necro_from_row(cls, row: Any, root: "Model | None" = None) -> "Model":
        obj = cls.__new__(cls)
        object.__setattr__(obj, "_necro_row", row)
        if root is None:
            object.__setattr__(obj, "_necro_attached_row", row)
        else:
            object.__setattr__(obj, "_necro_root", root)
        return obj

    def __setattr__(self, name: str, value: Any) -> None:
        if not name.startswith("_"):
            root = self.__dict__.get("_necro_root", self)
            object.__setattr__(root, "_necro_attached_row", None)
        object.__setattr__(self, name, value)

    def __delattr__(self, name: str) -> None:
        if not name.startswith("_"):
            root = self.__dict__.get("_necro_root", self)
            object.__setattr__(root, "_necro_attached_row", None)
        object.__delattr__(self, name)

    def __getattr__(self, name: str) -> Any:
        row = self.__dict__.get("_necro_row")
        if row is None:
            raise AttributeError(
                f"{self.__class__.__name__!s} has no attribute {name!r}"
            )

        nested = getattr(self.__class__, "__necro_nested__", None)
        if nested and name in nested:
            model_cls, nullable, field_names, field_indexes = nested[name]
            subrow = row.subrow(field_names, field_indexes, nullable)
            if subrow is None:
                object.__setattr__(self, name, None)
                return None
            value = model_cls._necro_from_row(
                subrow, self.__dict__.get("_necro_root", self)
            )
            object.__setattr__(self, name, value)
            return value

        hint = self.__class__._model_fields().get(name, _MISSING)
        if hint is _MISSING:
            raise AttributeError(
                f"{self.__class__.__name__!s} has no attribute {name!r}"
            )

        value = getattr(row, name)
        coerced = _coerce_model_value(
            hint, value, self.__dict__.get("_necro_root", self)
        )
        object.__setattr__(self, name, coerced)
        return coerced

    def raw(self, name: str) -> memoryview:
        row = self.__dict__.get("_necro_row")
        if row is None:
            raise AttributeError(
                "raw() is only available for PG-backed model instances"
            )
        root = self.__dict__.get("_necro_root", self)
        if root.__dict__.get("_necro_attached_row") is None:
            raise RuntimeError("raw() is unavailable after the model has been mutated")
        return row.raw(name)

    @classmethod
    def model_json_schema(cls) -> dict:
        """Return a JSON Schema dict for this model.

        Uses cached result after first call. The schema follows
        JSON Schema draft 2020-12, compatible with OpenAPI 3.1.

        Calls the Zig schema serializer when the C extension is loaded,
        falls back to pure-Python introspection otherwise.
        """
        if cls._schema_cache is not None:
            return cls._schema_cache

        hints = cls._model_fields()
        properties: dict[str, Any] = {}
        required: list[str] = []

        for name, hint in hints.items():
            prop_schema = _type_to_schema(hint)
            properties[name] = prop_schema

            # Field is required if the class has no default for it
            if not hasattr(cls, name):
                required.append(name)

        schema: dict[str, Any] = {
            "type": "object",
            "title": cls.__name__,
            "properties": properties,
        }
        if required:
            schema["required"] = required

        cls._schema_cache = schema
        return schema

    @classmethod
    def model_validate(cls, data: dict) -> "Model":
        """Validate a dict and return a model instance.

        In production this dispatches to Zig for fused decode+validate.
        The Python fallback does basic construction.
        """
        return cls(**data)

    def model_dump(self) -> dict:
        """Serialize this model instance to a plain dict."""
        hints = self.__class__._model_fields()
        out: dict[str, Any] = {}
        for name in hints:
            value = getattr(self, name)
            if isinstance(value, Model):
                value = value.model_dump()
            out[name] = value
        return out

    def json(self) -> str:
        """Serialize to a JSON string."""
        import json

        return json.dumps(self.model_dump(), default=str)

    def dict(self, *, exclude_none: bool = False) -> dict:
        """Alias for model_dump with optional None filtering."""
        d = self.model_dump()
        if exclude_none:
            return {k: v for k, v in d.items() if v is not None}
        return d


class _MissingSentinel:
    """Sentinel for missing field values."""


_MISSING = _MissingSentinel()


def _compile_schema_in_zig(cls: type) -> None:
    """Trigger Zig-side schema compilation for a Model subclass.

    Called from __init_subclass__. When the C extension is loaded, this
    calls _necro.register_model(cls) which runs SchemaBuilder.inspectAnnotations
    to build and cache a SchemaNode tree for fused decode+validate.
    """
    # Stub: import _necro and call _necro.register_model(cls)
    # Silently no-op if the C extension isn't loaded yet (pure-Python mode).
    ...


def _is_classvar(hint: Any) -> bool:
    return typing.get_origin(hint) is ClassVar


def _coerce_model_value(hint: Any, value: Any, root: Model | None = None) -> Any:
    if value is None or hint is Any:
        return value

    origin = typing.get_origin(hint)
    if origin is typing.Annotated:
        return _coerce_model_value(typing.get_args(hint)[0], value, root)

    if origin in (typing.Union, types.UnionType):
        args = typing.get_args(hint)
        non_none = [arg for arg in args if arg is not type(None)]
        if len(non_none) != len(args) and value is None:
            return None
        if non_none:
            return _coerce_model_value(non_none[0], value, root)
        return value

    if origin is list:
        (item_hint,) = typing.get_args(hint) or (Any,)
        if isinstance(value, list):
            return _track_mutable_value(
                [_coerce_model_value(item_hint, item, root) for item in value],
                root,
            )
        items = _parse_pg_array_text(_to_text_value(value))
        return _track_mutable_value(
            [_coerce_model_value(item_hint, item, root) for item in items],
            root,
        )

    if isinstance(hint, type) and issubclass(hint, Model):
        if isinstance(value, hint):
            return value
        if isinstance(value, dict):
            return hint.model_validate(value)
        return value

    text = _to_text_value(value)

    if hint is str:
        return text
    if hint is int:
        return int(text)
    if hint is float:
        return float(text)
    if hint is bool:
        lowered = text.lower()
        if lowered in {"t", "true", "1"}:
            return True
        if lowered in {"f", "false", "0"}:
            return False
        raise ValueError(f"invalid boolean literal: {text!r}")
    if hint is datetime:
        return datetime.fromisoformat(text)

    return value


def _track_mutable_value(value: Any, root: Model | None) -> Any:
    if root is None:
        return value
    if isinstance(value, _TrackedList):
        return value
    if isinstance(value, list):
        return _TrackedList([_track_mutable_value(item, root) for item in value], root)
    return value


def _to_text_value(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, memoryview):
        return value.tobytes().decode()
    if isinstance(value, bytes):
        return value.decode()
    return str(value)


def _parse_pg_array_text(value: str) -> list[Any]:
    if len(value) < 2 or value[0] != "{" or value[-1] != "}":
        return [value]
    if value == "{}":
        return []

    items: list[Any] = []
    buf: list[str] = []
    in_quotes = False
    escape = False
    item_was_quoted = False

    def flush() -> None:
        nonlocal buf, item_was_quoted
        item = "".join(buf)
        if not item_was_quoted and item == "NULL":
            items.append(None)
        else:
            items.append(item)
        buf = []
        item_was_quoted = False

    for ch in value[1:-1]:
        if escape:
            buf.append(ch)
            escape = False
            continue
        if in_quotes:
            if ch == "\\":
                escape = True
            elif ch == '"':
                in_quotes = False
                item_was_quoted = True
            else:
                buf.append(ch)
            continue
        if ch == '"':
            in_quotes = True
            item_was_quoted = True
            continue
        if ch == ",":
            flush()
            continue
        buf.append(ch)

    if buf or item_was_quoted:
        flush()

    return items


class Field:
    """Field metadata for necro.Model fields.

    Provides default values, aliases, exclusion flags, and descriptions
    for OpenAPI doc generation.
    """

    def __init__(
        self,
        *,
        default: Any = _MISSING,
        alias: str | None = None,
        exclude: bool = False,
        description: str | None = None,
    ) -> None:
        self.default = default
        self.alias = alias
        self.exclude = exclude
        self.description = description


# ── Type-to-JSON-Schema mapping ─────────────────────────────────────

_SIMPLE_MAP: dict[type, dict] = {
    str: {"type": "string"},
    int: {"type": "integer"},
    float: {"type": "number"},
    bool: {"type": "boolean"},
    datetime: {"type": "string", "format": "date-time"},
}


def _type_to_schema(hint: Any) -> dict:
    """Convert a Python type annotation to a JSON Schema fragment."""
    import typing

    origin = getattr(hint, "__origin__", None)

    # Annotated[T, ...metadata] - unwrap and apply constraints
    if origin is typing.Annotated:
        args = hint.__args__
        base_schema = _type_to_schema(args[0])
        for meta in args[1:]:
            base_schema.update(_constraint_to_schema(meta))
        return base_schema

    # Optional / Union with None
    if origin is typing.Union:
        args = [a for a in hint.__args__ if a is not type(None)]
        if len(args) == 1:
            schema = _type_to_schema(args[0])
            schema["nullable"] = True
            return schema
        return {"oneOf": [_type_to_schema(a) for a in args]}

    # list[T]
    if origin is list:
        item_type = hint.__args__[0] if hint.__args__ else Any
        return {"type": "array", "items": _type_to_schema(item_type)}

    # dict[K, V]
    if origin is dict:
        return {"type": "object"}

    # Simple types
    if hint in _SIMPLE_MAP:
        return dict(_SIMPLE_MAP[hint])

    # Model references
    if isinstance(hint, type) and issubclass(hint, Model):
        return {"$ref": f"#/components/schemas/{hint.__name__}"}

    return {}


def _constraint_to_schema(meta: Any) -> dict:
    """Map a necro constraint annotation to JSON Schema keywords."""
    cls_name = type(meta).__name__
    mapping: dict[str, str] = {
        "Gt": "exclusiveMinimum",
        "Ge": "minimum",
        "Lt": "exclusiveMaximum",
        "Le": "maximum",
        "MinLen": "minLength",
        "MaxLen": "maxLength",
        "Pattern": "pattern",
        "Email": "format",
    }
    key = mapping.get(cls_name)
    if key is None:
        return {}
    if cls_name == "Email":
        return {"format": "email"}
    # Constraint objects store their value as the first init arg
    value = getattr(meta, "value", getattr(meta, "v", None))
    if value is None and hasattr(meta, "__args__"):
        value = meta.__args__[0]
    if value is not None:
        return {key: value}
    return {}
