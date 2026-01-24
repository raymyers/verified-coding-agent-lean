#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "tiktoken",
# ]
# ///
"""
Test BPE tokenization against tiktoken's cl100k_base.

This script:
1. Tokenizes test strings with tiktoken
2. Shows the token IDs and decoded pieces
3. Can export a subset of the vocabulary for Lean testing

Run with: uv run scripts/test_bpe_tiktoken.py
"""

import tiktoken
import json
from pathlib import Path

def test_tiktoken():
    """Run basic tiktoken tests and show results."""
    enc = tiktoken.get_encoding("cl100k_base")

    test_cases = [
        "hello",
        "Hello",
        "hello world",
        "in",
        "input",
        "The quick brown fox",
        "tokenization",
        "BPE",
        " ",  # space
        "\n",  # newline
        "123",
        "こんにちは",  # Japanese
    ]

    print("=" * 60)
    print("tiktoken cl100k_base tokenization tests")
    print("=" * 60)

    for text in test_cases:
        tokens = enc.encode(text)
        # Decode each token individually to see the pieces
        pieces = [enc.decode([t]) for t in tokens]
        print(f"\nInput: {repr(text)}")
        print(f"Tokens: {tokens}")
        print(f"Pieces: {pieces}")
        print(f"Count: {len(tokens)}")


def export_vocab_subset(output_path: Path, max_tokens: int = 1000):
    """
    Export a subset of cl100k_base vocabulary for Lean testing.

    Format: JSON with {token_bytes_hex: token_id}
    """
    enc = tiktoken.get_encoding("cl100k_base")

    vocab = {}
    # Get the mergeable ranks (the BPE vocabulary)
    for token_bytes, rank in list(enc._mergeable_ranks.items())[:max_tokens]:
        # Convert bytes to hex string for JSON compatibility
        hex_str = token_bytes.hex()
        vocab[hex_str] = rank

    # Also include special tokens
    special = {}
    for token_str, token_id in enc._special_tokens.items():
        special[token_str] = token_id

    output = {
        "name": "cl100k_base_subset",
        "max_tokens": max_tokens,
        "vocab": vocab,
        "special_tokens": special,
    }

    with open(output_path, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"Exported {len(vocab)} tokens to {output_path}")
    return output


def show_bpe_merges():
    """Show how BPE merges work in cl100k_base."""
    enc = tiktoken.get_encoding("cl100k_base")

    print("\n" + "=" * 60)
    print("BPE merge examples")
    print("=" * 60)

    # Show some example tokens and their byte representations
    examples = [
        b"in",
        b"the",
        b"ing",
        b" the",  # space + the
        b"tion",
    ]

    for token_bytes in examples:
        if token_bytes in enc._mergeable_ranks:
            rank = enc._mergeable_ranks[token_bytes]
            print(f"  {repr(token_bytes):20} -> token {rank}")
        else:
            print(f"  {repr(token_bytes):20} -> NOT in vocabulary")


def verify_roundtrip():
    """Verify that encode -> decode is identity."""
    enc = tiktoken.get_encoding("cl100k_base")

    print("\n" + "=" * 60)
    print("Roundtrip verification")
    print("=" * 60)

    test_strings = [
        "Hello, world!",
        "The quick brown fox jumps over the lazy dog.",
        "def hello():\n    print('Hello')\n",
        "Unicode: 日本語 emoji: 🎉",
    ]

    all_pass = True
    for s in test_strings:
        tokens = enc.encode(s)
        decoded = enc.decode(tokens)
        passed = s == decoded
        all_pass = all_pass and passed
        status = "✓" if passed else "✗"
        print(f"  {status} {repr(s)[:40]}...")

    print(f"\nAll roundtrips passed: {all_pass}")
    return all_pass


def generate_lean_test_cases():
    """Generate test cases that can be pasted into Lean."""
    enc = tiktoken.get_encoding("cl100k_base")

    print("\n" + "=" * 60)
    print("Lean test cases (for manual verification)")
    print("=" * 60)

    test_cases = [
        ("hello", "hello"),
        ("in", "in"),
        ("input", "input"),
    ]

    print("""
-- To test with cl100k_base in Lean, you would need to:
-- 1. Load the vocabulary from the exported JSON
-- 2. Create a Vocab structure
-- 3. Compare encode results

-- Expected results from tiktoken cl100k_base:
""")

    for name, text in test_cases:
        tokens = enc.encode(text)
        bytes_list = [b for b in text.encode('utf-8')]
        print(f"-- {name}: \"{text}\"")
        print(f"--   UTF-8 bytes: {bytes_list}")
        print(f"--   cl100k_base tokens: {tokens}")
        print()


if __name__ == "__main__":
    # Run tests
    test_tiktoken()
    show_bpe_merges()
    verify_roundtrip()
    generate_lean_test_cases()

    # Export vocabulary subset
    script_dir = Path(__file__).parent
    vocab_path = script_dir / "cl100k_base_subset.json"
    export_vocab_subset(vocab_path, max_tokens=500)
