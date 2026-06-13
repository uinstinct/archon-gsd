#!/usr/bin/env python3
"""Dependency-free extractor for the Shell workflow YAML.

We deliberately avoid PyYAML so the tests run on any stock python3 (CI runners,
the container, a laptop) with nothing to install. The workflow file is authored
by us with a regular shape — 2-space `- id:` node headers, 4-space node fields,
and 6-space block-scalar bodies — so a focused parser is enough and far more
portable than pulling a YAML dependency into a docs-shaped repo.

Usage:
    wf.py bash  <workflow.yaml> <node-id>     # print a node's `bash:` body
    wf.py field <workflow.yaml> <node-id> <k> # print a scalar field (e.g. when)
    wf.py deps  <workflow.yaml> <node-id>     # print depends_on entries, one per line
"""
import sys

NODE_HEADER_INDENT = 2  # "  - id: ..."
FIELD_INDENT = 4        # "    bash: |"
BLOCK_INDENT = 6        # block-scalar body lines


def _node_block(lines, node_id):
    """Return the lines belonging to `- id: <node_id>` (excluding the header)."""
    start = None
    header = f"{' ' * NODE_HEADER_INDENT}- id: {node_id}"
    for i, line in enumerate(lines):
        if line.rstrip() == header or line.rstrip() == header.rstrip():
            start = i
            break
        # tolerate trailing whitespace / exact match on the id token
        if line.startswith(f"{' ' * NODE_HEADER_INDENT}- id:"):
            if line.split("- id:", 1)[1].strip() == node_id:
                start = i
                break
    if start is None:
        sys.stderr.write(f"wf.py: node not found: {node_id}\n")
        sys.exit(2)
    block = []
    for line in lines[start + 1:]:
        if line.startswith(f"{' ' * NODE_HEADER_INDENT}- id:"):
            break
        block.append(line)
    return block


def cmd_bash(path, node_id):
    lines = open(path, encoding="utf-8").read().splitlines()
    block = _node_block(lines, node_id)
    body, collecting = [], False
    for line in block:
        if not collecting:
            stripped = line.strip()
            if stripped.startswith("bash:"):
                # only block-scalar form is supported (bash: | / |- / |+)
                if "|" not in stripped.split("bash:", 1)[1]:
                    sys.stderr.write("wf.py: node bash is not a block scalar\n")
                    sys.exit(2)
                collecting = True
            continue
        # Block scalar continues while lines are blank or indented past the field.
        if line.strip() == "":
            body.append("")
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent < BLOCK_INDENT:
            break
        body.append(line[BLOCK_INDENT:])
    # drop trailing blank lines introduced by the scalar
    while body and body[-1] == "":
        body.pop()
    sys.stdout.write("\n".join(body) + ("\n" if body else ""))


def cmd_field(path, node_id, key):
    lines = open(path, encoding="utf-8").read().splitlines()
    block = _node_block(lines, node_id)
    prefix = f"{' ' * FIELD_INDENT}{key}:"
    for line in block:
        if line.startswith(prefix):
            val = line[len(prefix):].strip()
            if (val.startswith('"') and val.endswith('"')) or (
                val.startswith("'") and val.endswith("'")
            ):
                val = val[1:-1]
            print(val)
            return
    sys.stderr.write(f"wf.py: field not found: {node_id}.{key}\n")
    sys.exit(2)


def cmd_deps(path, node_id):
    val_line = None
    lines = open(path, encoding="utf-8").read().splitlines()
    block = _node_block(lines, node_id)
    prefix = f"{' ' * FIELD_INDENT}depends_on:"
    for line in block:
        if line.startswith(prefix):
            val_line = line[len(prefix):].strip()
            break
    if val_line is None:
        return  # no deps is valid
    val_line = val_line.strip("[]")
    for item in val_line.split(","):
        item = item.strip()
        if item:
            print(item)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__)
        sys.exit(2)
    op, path, node_id = sys.argv[1], sys.argv[2], sys.argv[3]
    if op == "bash":
        cmd_bash(path, node_id)
    elif op == "field":
        cmd_field(path, node_id, sys.argv[4])
    elif op == "deps":
        cmd_deps(path, node_id)
    else:
        sys.stderr.write(f"wf.py: unknown op: {op}\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
