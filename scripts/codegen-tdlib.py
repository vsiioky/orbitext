#!/usr/bin/env python3
"""
codegen-tdlib.py - generate typed Swift bindings from a TDLib td_api.tl schema.

Reads the .tl schema (text format used by TDLib), parses the constructor / class
declarations from the ---types--- section (everything before ---functions---),
keeps the types named in a roots file plus everything they reference (minus the
fields the roots file skips), and emits two Swift files under the output
directory:

  TDLibSchema.swift   - Namespaced typed models (enum TDApi { ... }).
                        Abstract parents with >1 constructor become enums with
                        one case per constructor. Singletons become structs.
  TDLibDecoders.swift - func init?(dict:) for every struct and decode(_:) for
                        every abstract enum that switches on the "@type" tag.

Inputs:

  --input   td_api.tl, vendored verbatim from a TDLib commit.
  --source  provenance of the schema (version, commit, sha256); defaults to
            <input>.source. The sha256 must match the schema, so a vendored
            schema cannot be edited by hand unnoticed.
  --roots   the types the app decodes (syntax in scripts/codegen-roots.txt).
            Without it every type in the schema is generated, which is only
            useful for diagnostics.

Generated files are committed to git (no CI codegen step); scripts/check-codegen.sh
fails when they differ from this script's output. To refresh, run
scripts/codegen.sh.

The schema grammar we accept (one declaration per line, optionally wrapped):

    constructorName field:Type other:vector<X> = ParentClass;

Comment lines beginning with `//` (including //@description) are skipped.
The ---functions--- section is skipped entirely - we only model the types
that appear in TDLib JSON responses / updates.

Output is deterministic: declaration order follows the schema file, abstract
enums are sorted by name, and nothing depends on hashing or on the clock.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


class CodegenError(Exception):
    """A problem with the inputs; reported without a traceback."""


PRIMITIVES = {
    "int32": "Int32",
    "int53": "Int64",
    "int64": "Int64",
    "long": "Int64",
    "double": "Double",
    "string": "String",
    "Bool": "Bool",
    # Qualified: the schema has a constructor named `data`, whose TDApi.Data
    # would otherwise shadow Foundation.Data inside enum TDApi.
    "bytes": "Foundation.Data",
}

# How each primitive is coerced out of a JSON dict (helpers in emit_decoders).
PRIMITIVE_DECODERS = {
    "int32": "Self.int32",
    "int53": "Self.int64",
    "int64": "Self.int64",
    "long": "Self.int64",
    "double": "Self.double",
    "string": "Self.string",
    "Bool": "Self.bool",
    "bytes": "Self.bytes",
}

# Swift names the emitted code writes unqualified. A schema type with the same
# name would shadow them inside enum TDApi, so generation refuses to proceed.
UNQUALIFIED_SWIFT_NAMES = {
    "Any", "Bool", "Double", "Int32", "Int64", "NSNumber", "Sendable", "String",
}

# TL builtins we never emit. These are declared in the header of td_api.tl
# (lines 1-13) and are not real TDLib constructors.
BUILTIN_SKIP = {
    "double", "string", "int32", "int53", "int64", "bytes",
    "boolFalse", "boolTrue", "vector",
}


@dataclasses.dataclass
class Field:
    name: str            # original tl name (snake_case)
    swift_name: str      # camelCase
    tl_type: str         # raw, e.g. "vector<int32>"
    swift_type: str      # mapped, e.g. "[Int32]"
    is_primitive: bool
    is_vector: bool
    vector_depth: int
    element_type: str    # leaf swift type (for vectors), else swift_type


@dataclasses.dataclass
class Constructor:
    name: str            # lowercase tl name, e.g. updateChatTitle
    swift_name: str      # UpperCamel, e.g. UpdateChatTitle
    parent: str          # original parent class, e.g. Update
    fields: List[Field]


@dataclasses.dataclass
class SchemaSource:
    """Provenance of the vendored schema (scripts/td_api.tl.source)."""
    version: str
    commit: str
    sha256: str


@dataclasses.dataclass
class RootEntry:
    """One root line of the roots file: a type, optionally limited to constructors."""
    name: str
    constructors: Optional[List[str]]  # None: every constructor of the type
    line: int


@dataclasses.dataclass
class SkipEntry:
    """One `constructor.field` of a skip line: a field left out of the models."""
    constructor: str
    field: str
    line: int


@dataclasses.dataclass
class RootsSpec:
    roots: List[RootEntry]
    skips: List[SkipEntry]


# ---------- TL schema parsing ----------

SWIFT_RESERVED = {
    "class", "let", "var", "func", "default", "where", "repeat", "return",
    "for", "case", "in", "is", "as", "if", "else", "do", "try", "throw",
    "catch", "nil", "true", "false", "self", "Self", "super", "init",
    "protocol", "extension", "enum", "struct", "import", "inout",
    "operator", "rethrows", "throws", "typealias", "associatedtype",
    "fileprivate", "internal", "public", "private", "open", "guard",
    "switch", "break", "continue", "fallthrough", "deinit", "subscript",
    "Type", "Any",
}


def snake_to_lower_camel(s: str) -> str:
    parts = s.split("_")
    name = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    if name in SWIFT_RESERVED:
        return f"`{name}`"
    return name


def lower_to_upper_camel(s: str) -> str:
    return s[:1].upper() + s[1:]


def strip_vectors(tl_type: str) -> Tuple[str, int]:
    """Returns (leaf tl type, vector depth) for e.g. vector<vector<int32>>."""
    depth = 0
    inner = tl_type
    while inner.startswith("vector<") and inner.endswith(">"):
        inner = inner[len("vector<"):-1]
        depth += 1
    return inner, depth


def map_swift_type(tl_type: str) -> Tuple[str, bool, int, str]:
    """Returns (swift_type, is_primitive, vector_depth, element_swift_type)."""
    inner, depth = strip_vectors(tl_type)
    if inner in PRIMITIVES:
        leaf = PRIMITIVES[inner]
        is_prim = True
    else:
        # Reference to another tl class. Names that start lowercase are
        # concrete constructors; names that start uppercase are abstract
        # parents. We map both to TDApi.<UpperCamel(inner)>.
        leaf = "TDApi." + lower_to_upper_camel(inner)
        is_prim = False
    swift = leaf
    for _ in range(depth):
        swift = f"[{swift}]"
    return swift, is_prim, depth, leaf


def parse_schema(text: str) -> Tuple[List[Constructor], Dict[str, List[Constructor]]]:
    # Truncate at functions section.
    cut = text.find("---functions---")
    if cut >= 0:
        text = text[:cut]

    # Strip comments. We keep blank lines as separators.
    cleaned_lines = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("//"):
            continue
        cleaned_lines.append(raw)
    cleaned = "\n".join(cleaned_lines)

    constructors: List[Constructor] = []
    parents: Dict[str, List[Constructor]] = {}

    # Each declaration ends with ';'. Split on ';' for robustness against
    # multi-line declarations (TDLib has a few).
    for raw_decl in cleaned.split(";"):
        decl = raw_decl.strip()
        if not decl:
            continue
        # Skip header lines that match `name = Type` with no fields and
        # are builtins. Pattern: name [fields...] = Parent
        if "=" not in decl:
            continue
        lhs, rhs = decl.rsplit("=", 1)
        parent_raw = rhs.strip()
        # parent may include `Vector t` for the vector builtin - skip.
        if " " in parent_raw:
            continue
        parent = parent_raw

        tokens = lhs.split()
        if not tokens:
            continue
        cname = tokens[0]
        if cname in BUILTIN_SKIP:
            continue
        # Defensive: skip if the name has weird chars (templates like
        # `vector {t:Type} #`).
        if not re.match(r"^[A-Za-z][A-Za-z0-9_]*$", cname):
            continue

        fields: List[Field] = []
        for tok in tokens[1:]:
            if ":" not in tok:
                continue
            fname, ftype = tok.split(":", 1)
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", fname):
                continue
            swift_type, is_prim, depth, leaf = map_swift_type(ftype)
            fields.append(Field(
                name=fname,
                swift_name=snake_to_lower_camel(fname),
                tl_type=ftype,
                swift_type=swift_type,
                is_primitive=is_prim,
                is_vector=depth > 0,
                vector_depth=depth,
                element_type=leaf,
            ))

        ctor = Constructor(
            name=cname,
            swift_name=lower_to_upper_camel(cname),
            parent=parent,
            fields=fields,
        )
        constructors.append(ctor)
        parents.setdefault(parent, []).append(ctor)

    return constructors, parents


# ---------- Provenance and roots ----------

def load_source(path: Path, schema_bytes: bytes) -> SchemaSource:
    """Reads <schema>.source and checks that it describes this exact schema."""
    if not path.is_file():
        raise CodegenError(f"{path}: schema provenance file not found")
    values: Dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise CodegenError(f"{path}:{number}: expected key=value")
        values[key.strip()] = value.strip()
    for key in ("version", "commit", "sha256"):
        if not values.get(key):
            raise CodegenError(f"{path}: missing '{key}'")
    if not re.fullmatch(r"[0-9a-f]{40}", values["commit"]):
        raise CodegenError(f"{path}: commit must be a full 40-digit hex sha")
    actual = hashlib.sha256(schema_bytes).hexdigest()
    if actual != values["sha256"]:
        raise CodegenError(
            f"{path}: sha256 does not match the schema ({actual}); the vendored "
            "schema must be a verbatim copy, update the .source file with it"
        )
    return SchemaSource(values["version"], values["commit"], values["sha256"])


def load_roots(path: Path) -> RootsSpec:
    """Parses the roots file.

        # comment
        Message                        a root: the type and everything it references
        Update = updateChatTitle ...   a root limited to the listed constructors
        skip message.reply_markup ...  fields left out of the generated structs

    A line starting with whitespace continues the previous line.
    """
    logical: List[Tuple[int, str]] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line[0].isspace():
            if not logical:
                raise CodegenError(f"{path}:{number}: continuation without a preceding entry")
            logical[-1] = (logical[-1][0], logical[-1][1] + " " + line.strip())
        else:
            logical.append((number, line.strip()))

    roots: List[RootEntry] = []
    skips: List[SkipEntry] = []
    for number, line in logical:
        words = line.split()
        if words[0] == "skip":
            if len(words) == 1:
                raise CodegenError(f"{path}:{number}: 'skip' lists no fields")
            for word in words[1:]:
                ctor_name, dot, field_name = word.partition(".")
                if not dot or not ctor_name or not field_name:
                    raise CodegenError(f"{path}:{number}: expected constructor.field, got '{word}'")
                skips.append(SkipEntry(ctor_name, field_name, number))
            continue
        name, sep, rest = line.partition("=")
        name = name.strip()
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
            raise CodegenError(f"{path}:{number}: bad type name '{name}'")
        constructors: Optional[List[str]] = None
        if sep:
            constructors = rest.split()
            if not constructors:
                raise CodegenError(f"{path}:{number}: '{name} =' lists no constructors")
        roots.append(RootEntry(name=name, constructors=constructors, line=number))
    return RootsSpec(roots=roots, skips=skips)


def select_constructors(
    roots_path: Path,
    spec: RootsSpec,
    constructors: List[Constructor],
    parents: Dict[str, List[Constructor]],
) -> List[Constructor]:
    """The constructors reachable from the roots, in schema order.

    A class listed with `=` keeps only the named constructors wherever it is
    reached from; every other constructor decodes to `.unknown(tag:)`. Any
    other class keeps all of its constructors. Skipped fields are dropped from
    their constructor and do not pull their types in.
    """
    by_name = {c.name: c for c in constructors}
    restricted: Dict[str, Set[str]] = {}
    seen_roots: Set[str] = set()
    queue: List[str] = []

    for entry in spec.roots:
        where = f"{roots_path}:{entry.line}"
        if entry.name in seen_roots:
            raise CodegenError(f"{where}: '{entry.name}' is listed twice")
        seen_roots.add(entry.name)
        if entry.name not in parents and entry.name not in by_name:
            raise CodegenError(f"{where}: '{entry.name}' is not a type of the schema")
        if entry.constructors is not None:
            if entry.name not in parents:
                raise CodegenError(f"{where}: '{entry.name}' is a constructor; only classes take '='")
            for ctor_name in entry.constructors:
                ctor = by_name.get(ctor_name)
                if ctor is None or ctor.parent != entry.name:
                    raise CodegenError(f"{where}: '{ctor_name}' is not a constructor of {entry.name}")
            restricted[entry.name] = set(entry.constructors)
        queue.append(entry.name)

    skipped: Dict[str, Set[str]] = {}
    for skip in spec.skips:
        where = f"{roots_path}:{skip.line}"
        ctor = by_name.get(skip.constructor)
        if ctor is None:
            raise CodegenError(f"{where}: '{skip.constructor}' is not a constructor of the schema")
        if skip.field not in {f.name for f in ctor.fields}:
            raise CodegenError(f"{where}: {skip.constructor} has no field '{skip.field}'")
        skipped.setdefault(skip.constructor, set()).add(skip.field)

    kept: Dict[str, Constructor] = {}
    visited: Set[str] = set()
    while queue:
        type_name = queue.pop()
        if type_name in visited:
            continue
        visited.add(type_name)
        if type_name in parents:
            allowed = restricted.get(type_name)
            members = [c for c in parents[type_name] if allowed is None or c.name in allowed]
        elif type_name in by_name:
            members = [by_name[type_name]]
        else:
            raise CodegenError(f"schema references the undefined type '{type_name}'")
        for ctor in members:
            if ctor.name in kept:
                continue
            left_out = skipped.get(ctor.name, set())
            fields = [f for f in ctor.fields if f.name not in left_out]
            kept[ctor.name] = dataclasses.replace(ctor, fields=fields)
            for f in fields:
                leaf, _ = strip_vectors(f.tl_type)
                if leaf not in PRIMITIVES:
                    queue.append(leaf)

    return [kept[c.name] for c in constructors if c.name in kept]


def check_swift_names(
    constructors: List[Constructor], parents: Dict[str, List[Constructor]]
) -> None:
    """Refuses schemas whose type names would break the emitted Swift."""
    names = [c.swift_name for c in constructors]
    enums = {lower_to_upper_camel(p) for p in kept_abstract_parents(constructors, parents)}
    seen: Set[str] = set()
    for name in names:
        if name in seen:
            raise CodegenError(f"two constructors map to the Swift type TDApi.{name}")
        seen.add(name)
    for name in sorted(seen & enums):
        raise CodegenError(f"TDApi.{name} would be both a struct and an enum")
    for name in sorted((seen | enums) & UNQUALIFIED_SWIFT_NAMES):
        raise CodegenError(
            f"TDApi.{name} would shadow the Swift type used unqualified by the generated code"
        )


# ---------- Swift emission ----------

HEADER_TEMPLATE = """// GENERATED by scripts/codegen-tdlib.py from td_api.tl (TDLib {version}, commit {commit}).
// DO NOT EDIT. Re-run scripts/codegen.sh to refresh.
//
// Schema vendored at scripts/td_api.tl, types selected by scripts/codegen-roots.txt.
// Models are namespaced under enum TDApi to avoid collisions with the
// existing hand-rolled domain models in Orbitext/Models.

import Foundation

"""


def is_abstract(parent: str, parents: Dict[str, List[Constructor]]) -> bool:
    """A parent name represents an abstract enum iff >1 constructor maps to it
    in the schema. This is decided on the full schema, so restricting an
    abstract class to few constructors keeps it an enum.
    """
    return len(parents.get(parent, [])) > 1


def kept_abstract_parents(
    kept: List[Constructor], parents: Dict[str, List[Constructor]]
) -> Dict[str, List[Constructor]]:
    """Abstract parents with at least one kept constructor, name -> kept constructors."""
    by_parent: Dict[str, List[Constructor]] = {}
    for ctor in kept:
        if is_abstract(ctor.parent, parents):
            by_parent.setdefault(ctor.parent, []).append(ctor)
    return dict(sorted(by_parent.items()))


def emit_schema(
    kept: List[Constructor], parents: Dict[str, List[Constructor]], header: str
) -> str:
    out: List[str] = [header]
    out.append("public enum TDApi {\n")

    # 1. Abstract enums (parent with multiple constructors).
    for parent, cases in kept_abstract_parents(kept, parents).items():
        # `indirect` so cases that contain associated values referencing
        # the enum itself (RichText, PageBlock, ...) don't blow up "infinite
        # size" stored property checks. Minor perf overhead for enums that
        # don't need it; acceptable for codegen simplicity.
        out.append(f"    public indirect enum {lower_to_upper_camel(parent)}: Sendable {{\n")
        for ctor in cases:
            out.append(f"        case {snake_to_lower_camel(ctor.name)}({ctor.swift_name})\n")
        out.append("        case unknown(tag: String)\n")
        out.append("    }\n\n")

    # 2. Struct per constructor.
    for ctor in kept:
        out.append(f"    public struct {ctor.swift_name}: Sendable {{\n")
        if not ctor.fields:
            out.append("        public init() {}\n")
        else:
            for f in ctor.fields:
                # Make non-vector object references optional. Primitives and
                # vectors get a default at decode time.
                if f.is_primitive or f.is_vector:
                    out.append(f"        public let {f.swift_name}: {f.swift_type}\n")
                else:
                    out.append(f"        public let {f.swift_name}: {f.swift_type}?\n")
            args = []
            for f in ctor.fields:
                ty = f.swift_type if (f.is_primitive or f.is_vector) else (f.swift_type + "?")
                args.append(f"{f.swift_name}: {ty}")
            out.append("        public init(" + ", ".join(args) + ") {\n")
            for f in ctor.fields:
                out.append(f"            self.{f.swift_name} = {f.swift_name}\n")
            out.append("        }\n")
        out.append("    }\n\n")

    out.append("}\n")
    return "".join(out)


DECODER_HELPERS = """    // MARK: - Primitive coercion helpers

    @inlinable
    static func int32(_ any: Any?) -> Int32 {
        if let n = any as? Int32 { return n }
        if let n = any as? Int { return Int32(truncatingIfNeeded: n) }
        if let n = any as? Int64 { return Int32(truncatingIfNeeded: n) }
        if let n = any as? NSNumber { return n.int32Value }
        if let s = any as? String, let v = Int32(s) { return v }
        return 0
    }

    @inlinable
    static func int64(_ any: Any?) -> Int64 {
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let n = any as? Int32 { return Int64(n) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let v = Int64(s) { return v }
        return 0
    }

    @inlinable
    static func double(_ any: Any?) -> Double {
        if let n = any as? Double { return n }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let v = Double(s) { return v }
        return 0
    }

    @inlinable
    static func bool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String { return s == "true" || s == "1" }
        return false
    }

    @inlinable
    static func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    @inlinable
    static func bytes(_ any: Any?) -> Foundation.Data {
        if let d = any as? Foundation.Data { return d }
        if let s = any as? String, let d = Foundation.Data(base64Encoded: s) { return d }
        return Foundation.Data()
    }

    @inlinable
    static func dict(_ any: Any?) -> [String: Any]? {
        return any as? [String: Any]
    }

    @inlinable
    static func array(_ any: Any?) -> [Any] {
        return (any as? [Any]) ?? []
    }

"""


def emit_decoders(
    kept: List[Constructor], parents: Dict[str, List[Constructor]], header: str
) -> str:
    out: List[str] = [header]
    out.append("extension TDApi {\n\n")
    out.append(DECODER_HELPERS)

    # struct initializers
    for ctor in kept:
        out.append(f"    // MARK: {ctor.name} -> {lower_to_upper_camel(ctor.parent)}\n")
        out.append(f"    public static func decode{ctor.swift_name}(_ dict: [String: Any]) -> {ctor.swift_name} {{\n")
        if not ctor.fields:
            out.append(f"        return {ctor.swift_name}()\n")
            out.append("    }\n\n")
            continue
        out.append(f"        return {ctor.swift_name}(\n")
        last = len(ctor.fields) - 1
        for i, f in enumerate(ctor.fields):
            comma = "," if i < last else ""
            expr = decode_field_expr(f, parents)
            out.append(f"            {f.swift_name}: {expr}{comma}\n")
        out.append("        )\n")
        out.append("    }\n\n")

    # abstract decoders
    for parent, cases in kept_abstract_parents(kept, parents).items():
        upper = lower_to_upper_camel(parent)
        out.append(f"    // MARK: {parent} (abstract)\n")
        out.append(f"    public static func decode{upper}(_ dict: [String: Any]) -> {upper} {{\n")
        out.append("        let tag = (dict[\"@type\"] as? String) ?? \"\"\n")
        out.append("        switch tag {\n")
        for ctor in cases:
            out.append(f"        case \"{ctor.name}\": return .{snake_to_lower_camel(ctor.name)}(decode{ctor.swift_name}(dict))\n")
        out.append("        default: return .unknown(tag: tag)\n")
        out.append("        }\n")
        out.append("    }\n\n")

    out.append("}\n")
    return "".join(out)


def decoder_name(tl_type: str, parents: Dict[str, List[Constructor]]) -> str:
    """Name of the TDApi.decode* function for a (non-primitive) TL type."""
    if tl_type in parents:
        if len(parents[tl_type]) > 1:
            return "decode" + lower_to_upper_camel(tl_type)
        # Singleton parent: it is modelled by its only constructor's struct.
        return "decode" + parents[tl_type][0].swift_name
    # Reference to a lowercase constructor directly.
    return "decode" + lower_to_upper_camel(tl_type)


def decode_field_expr(f: Field, parents: Dict[str, List[Constructor]]) -> str:
    key = f'"{f.name}"'
    if f.is_vector:
        return vector_expr(f, parents)
    if f.is_primitive:
        return f"{PRIMITIVE_DECODERS[f.tl_type]}(dict[{key}])"
    return f"Self.dict(dict[{key}]).map {{ Self.{decoder_name(f.tl_type, parents)}($0) }}"


def vector_expr(f: Field, parents: Dict[str, List[Constructor]]) -> str:
    """Build a (possibly nested) array decode expression."""
    key = f'"{f.name}"'
    inner, _ = strip_vectors(f.tl_type)

    def coerce(elem_expr: str) -> str:
        if inner in PRIMITIVES:
            return f"{PRIMITIVE_DECODERS[inner]}({elem_expr})"
        return f"(Self.dict({elem_expr}).map {{ Self.{decoder_name(inner, parents)}($0) }})"

    # We build from the outside in. The outermost array is over Any.
    # For primitives, map with coercion (which always returns non-nil) is
    # fine. For objects, the inner expr produces an optional; compactMap.
    each = "map" if inner in PRIMITIVES else "compactMap"
    if f.vector_depth == 1:
        return f"Self.array(dict[{key}]).{each} {{ {coerce('$0')} }}"
    if f.vector_depth == 2:
        # vector<vector<X>>
        return (f"Self.array(dict[{key}]).map {{ Self.array($0).{each} {{ "
                f"{coerce('$0')} }} }}")
    # >2 unlikely in TDLib schema; fallback to flat empty.
    return f"[] // codegen: vector depth {f.vector_depth} not supported for {f.name}"


def generate(
    schema_path: Path, source_path: Path, roots_path: Optional[Path]
) -> Tuple[str, str, int, int]:
    """Returns (schema swift, decoders swift, constructor count, enum count)."""
    schema_bytes = schema_path.read_bytes()
    source = load_source(source_path, schema_bytes)
    constructors, parents = parse_schema(schema_bytes.decode("utf-8"))

    if roots_path is None:
        kept = constructors
    else:
        spec = load_roots(roots_path)
        if not spec.roots:
            raise CodegenError(f"{roots_path}: no roots listed")
        kept = select_constructors(roots_path, spec, constructors, parents)
    check_swift_names(kept, parents)

    header = HEADER_TEMPLATE.format(version=source.version, commit=source.commit)
    return (
        emit_schema(kept, parents, header),
        emit_decoders(kept, parents, header),
        len(kept),
        len(kept_abstract_parents(kept, parents)),
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Path to the vendored td_api.tl")
    ap.add_argument("--source", help="Schema provenance file (default: <input>.source)")
    ap.add_argument("--roots", help="Roots file; without it the whole schema is generated")
    ap.add_argument("--output", required=True, help="Directory to write generated Swift files into")
    args = ap.parse_args()

    schema_path = Path(args.input)
    source_path = Path(args.source) if args.source else schema_path.with_name(schema_path.name + ".source")
    roots_path = Path(args.roots) if args.roots else None
    out_dir = Path(args.output)

    try:
        schema_swift, decoders_swift, ctor_count, enum_count = generate(schema_path, source_path, roots_path)
    except CodegenError as err:
        print(f"codegen-tdlib: {err}", file=sys.stderr)
        return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "TDLibSchema.swift").write_text(schema_swift, encoding="utf-8")
    (out_dir / "TDLibDecoders.swift").write_text(decoders_swift, encoding="utf-8")

    print(f"Generated {ctor_count} constructors, {enum_count} abstract enums")
    print(f"  -> {out_dir / 'TDLibSchema.swift'}")
    print(f"  -> {out_dir / 'TDLibDecoders.swift'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
