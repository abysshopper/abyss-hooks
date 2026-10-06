"""Canonical bound-v5 config schema and ConfigBoundsV2 wire commitments."""
from eth_abi import encode
from eth_utils import keccak

POSITION_TYPE = "(int24,int24,uint128,bytes32,uint256)[]"
BASE_TYPES = "uint16,uint24,int24,uint160,uint24,uint8,uint8,address,bool,bytes32"
AUTHOR_TYPES = "bytes32,bytes32,address,uint16"
BOUNDS_TYPE = "(int24,int24,uint16,uint16,uint8)"
BOUND_LIMITS = {
    "minimumTickSpacing": (1, 32767),
    "maximumTickSpacing": (1, 32767),
    "maximumPositions": (1, 32),
    "maximumOracleCardinality": (2, 4096),
    "feeModeFlags": (1, 3),
}


def config_type(version):
    if type(version) is not int or version != 5:
        raise ValueError("Only bound-v5 configs are supported")
    return f"({BASE_TYPES},bytes32,{AUTHOR_TYPES},{POSITION_TYPE})"


def config_schema(version):
    return keccak(text=config_type(version))


def bounds_tuple(bounds):
    if not isinstance(bounds, dict) or set(bounds) != set(BOUND_LIMITS):
        raise ValueError("Exact five-member registry bounds required")
    for name, (minimum, maximum) in BOUND_LIMITS.items():
        if type(bounds[name]) is not int or not minimum <= bounds[name] <= maximum:
            raise ValueError(f"bounds.{name} must be an integer in {minimum}..{maximum}")
    if bounds["minimumTickSpacing"] > bounds["maximumTickSpacing"]:
        raise ValueError("Reversed tick-spacing bounds")
    return tuple(bounds[name] for name in BOUND_LIMITS)


def encode_bounds(bounds):
    return encode([BOUNDS_TYPE], [bounds_tuple(bounds)])


def config_bounds_digest(bounds):
    return keccak(encode_bounds(bounds))
