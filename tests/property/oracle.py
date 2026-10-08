# SPDX-License-Identifier: Apache-2.0
"""Small pure-Python models used as oracles for generated Xen programs."""

from __future__ import annotations

import struct
from typing import Callable


INTEGER_TYPES = {
    "I8": (8, True),
    "U8": (8, False),
    "I16": (16, True),
    "U16": (16, False),
    "I32": (32, True),
    "U32": (32, False),
    "I64": (64, True),
    "U64": (64, False),
    "Int": (64, True),
}


def limits(type_name: str) -> tuple[int, int]:
    bits, signed = INTEGER_TYPES[type_name]
    if signed:
        return -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return 0, (1 << bits) - 1


def wrap_integer(value: int, type_name: str) -> int:
    bits, signed = INTEGER_TYPES[type_name]
    modulus = 1 << bits
    value %= modulus
    if signed and value >= 1 << (bits - 1):
        value -= modulus
    return value


def trunc_div(left: int, right: int) -> int:
    assert right != 0
    quotient = abs(left) // abs(right)
    return -quotient if (left < 0) != (right < 0) else quotient


def trunc_mod(left: int, right: int) -> int:
    return left - trunc_div(left, right) * right


def f32(value: float) -> float:
    return struct.unpack("!f", struct.pack("!f", value))[0]


def float_op(op: str, left: float, right: float, ty: str) -> float:
    round_value: Callable[[float], float] = f32 if ty == "F32" else float
    left, right = round_value(left), round_value(right)
    if op == "+":
        raw = left + right
    elif op == "-":
        raw = left - right
    elif op == "*":
        raw = left * right
    elif op == "/":
        raw = left / right
    else:
        raise ValueError(op)
    return round_value(raw)
