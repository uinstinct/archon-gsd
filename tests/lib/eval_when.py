#!/usr/bin/env python3
"""Evaluate a workflow `when:` guard against a stubbed node output.

A faithful-enough reimplementation of Archon's condition evaluator for the
single-comparison forms this Shell uses: `$node.output.field == 'value'` and
`!=`. The point is to assert routing wiring deterministically — stub
size-classify's `scope` to `small`/`large` and check which handoff guard passes —
without booting the Archon runtime or asserting any real LLM judgment.

Usage:
    eval_when.py "<when expression>" <node-id> <field> <value>
Exit 0 if the guard is TRUE for that stub, 1 if FALSE.
"""
import sys


def main():
    expr, node_id, field, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    # Resolve the only reference this Shell uses: $<node>.output.<field>.
    ref = f"${node_id}.output.{field}"
    if ref not in expr:
        sys.stderr.write(f"eval_when.py: expression does not reference {ref}\n")
        sys.exit(2)
    resolved = expr.replace(ref, repr(value))  # repr -> single-quoted literal

    for op in ("==", "!="):
        if op in resolved:
            lhs, rhs = (s.strip() for s in resolved.split(op, 1))
            lhs = lhs.strip("'\"")
            rhs = rhs.strip("'\"")
            ok = (lhs == rhs) if op == "==" else (lhs != rhs)
            sys.exit(0 if ok else 1)

    sys.stderr.write(f"eval_when.py: unsupported expression: {expr}\n")
    sys.exit(2)


if __name__ == "__main__":
    main()
