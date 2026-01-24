# BPE Tokenizer Lean Formalization Progress

This document tracks the progress on formalizing the BPE (Byte Pair Encoding) tokenizer algorithm in Lean 4.

**File:** `ReActAgent/Tokenizer/BPE.lean`

## Summary

The formalization takes a parametric approach where the vocabulary is a parameter, allowing:
- Small test vocabularies for proofs (e.g., `baseVocab` with just 256 byte tokens)
- Full vocabularies loaded at runtime

## Proven Theorems

### Core Algorithm Properties

| Theorem | Description |
|---------|-------------|
| `mergeOnce_decreases` | Each merge step strictly decreases piece count |
| `findMergeablePairs_valid_idx` | Indices returned by findMergeablePairs are valid |
| `findBestMerge_mem` | Best merge is a member of candidates |
| `applyMerge_length` | Merge reduces list length by exactly 1 |

### Base Vocabulary Properties

| Theorem | Description |
|---------|-------------|
| `baseVocab_wellFormed` | baseVocab satisfies `Vocab.WellFormed` |
| `baseVocab_no_merges` | No merges possible with baseVocab on single-byte pieces |
| `baseVocab_mergeOnce_none` | mergeOnce returns none for baseVocab |
| `bytesToPieces_size_one` | bytesToPieces creates single-byte pieces |

### Helper Lemmas

| Theorem | Description |
|---------|-------------|
| `findBestMergeStep_preserves_some` | foldl step preserves Some |
| `foldl_findBestMergeStep_some` | foldl produces Some when started with Some |
| `findBestMerge_cons` | findBestMerge on non-empty list is Some |
| `findMergeablePairs_go_valid` | Inner loop produces valid indices |
| `applyMerge_go_length_aux` | Helper for applyMerge length proof |

## Remaining Sorries (5)

### 1. `mergeAll_concat` (Line 334)

```lean
theorem mergeAll_concat (vocab : Vocab) (pieces : List Piece) :
    concatPieces (mergeAll vocab pieces) = concatPieces pieces
```

**Blocker:** `mergeAll` is `partial`, preventing standard induction.

**Approach:** Use well-founded induction with `mergeOnce_decreases` as the termination proof.

### 2. `byteArray_toList_eq` (Line 339)

```lean
private theorem byteArray_toList_eq (bs : ByteArray) : bs.toList = bs.data.toList
```

**Blocker:** Requires induction on `ByteArray.toList.loop`, which is marked `@[irreducible]`.

**Approach:**
- Use `ByteArray.toList.loop.induct` with careful case analysis
- Or find an existing lemma in Batteries/Mathlib
- Or prove via extensionality on indices

### 3. `mergeAll_lookup_some` (Line 375)

```lean
theorem mergeAll_lookup_some (vocab : Vocab) (hw : vocab.WellFormed) (pieces : List Piece)
    (hinit : ∀ p ∈ pieces, p.size = 1) :
    ∀ p ∈ mergeAll vocab pieces, ∃ tid, vocab.lookup p = some tid
```

**Blocker:** Same as `mergeAll_concat` - needs induction on partial `mergeAll`.

**Approach:** Well-founded induction showing pieces either:
1. Stay as single bytes (covered by `covers_bytes`)
2. Are results of merges (were in vocab to be merged)

### 4. `encode_decode_roundtrip` (Line 381)

```lean
theorem encode_decode_roundtrip (vocab : Vocab) (hw : vocab.WellFormed) (input : ByteArray) :
    decode vocab (encode vocab input) = some input
```

**Blocker:** Depends on `mergeAll_concat`, `mergeAll_lookup_some`, and `bytesToPieces_concat`.

**Approach:** Once dependencies are proven:
1. `bytesToPieces` creates single-byte pieces
2. `mergeAll` preserves concatenation
3. All merged pieces have tokens (well-formedness)
4. `decode` inverts `lookup` (by `decode_inv`)
5. Pieces concatenate to original

### 5. `baseVocab_encode` (Line 491)

```lean
theorem baseVocab_encode (input : ByteArray) :
    encode baseVocab input = input.toList.map (·.toNat)
```

**Blocker:** Needs to show `mergeAll baseVocab pieces = pieces` when no merges possible.

**Approach:**
- Need equation lemma for `mergeAll` (partial function)
- Or inline the definition manually with `mergeOnce` returning `none`

## Key Data Structures

```lean
structure Vocab where
  lookup : Piece → Option TokenId
  decode : TokenId → Option Piece

structure Vocab.WellFormed (v : Vocab) : Prop where
  covers_bytes : ∀ b : UInt8, ∃ tid, v.lookup (ByteArray.mk #[b]) = some tid
  decode_inv : ∀ piece tid, v.lookup piece = some tid → v.decode tid = some piece
```

## Options for Completing Proofs

### Option A: Well-Founded Induction on mergeAll

Convert `mergeAll` proofs to use well-founded recursion:

```lean
theorem mergeAll_concat (vocab : Vocab) (pieces : List Piece) :
    concatPieces (mergeAll vocab pieces) = concatPieces pieces := by
  -- Use Nat.lt_wfRel on pieces.length
  induction h : pieces.length using Nat.strongRecOn generalizing pieces with
  | ind n ih =>
    cases hm : mergeOnce vocab pieces with
    | none => simp [mergeAll, hm]
    | some pieces' =>
      have hdec := mergeOnce_decreases vocab pieces pieces' hm
      simp [mergeAll, hm]
      rw [applyMerge_concat]  -- needs to be proven
      exact ih pieces'.length hdec pieces' rfl
```

### Option B: Refactor mergeAll with Termination Proof

Change `mergeAll` from `partial` to use explicit termination:

```lean
def mergeAll (vocab : Vocab) (pieces : List Piece) : List Piece :=
  match h : mergeOnce vocab pieces with
  | none => pieces
  | some pieces' => mergeAll vocab pieces'
termination_by pieces.length
decreasing_by exact mergeOnce_decreases vocab pieces pieces' h
```

This would enable standard equation lemmas and induction.

### Option C: Axiomatize for Now

Add the remaining theorems as axioms to unblock dependent work:

```lean
axiom mergeAll_concat : ∀ vocab pieces, concatPieces (mergeAll vocab pieces) = concatPieces pieces
```

Not recommended for final version, but useful for prototyping.

## Test Vocabularies

Two test vocabularies are defined:

1. **baseVocab** - 256 single-byte tokens only
2. **tinyVocab** - baseVocab + one merge: "in" → 256

## Next Steps

1. **Easiest win:** Fix `byteArray_toList_eq` - search Mathlib/Batteries for existing lemma
2. **Most impactful:** Refactor `mergeAll` with termination proof (Option B)
3. **Then:** Prove `mergeAll_concat` and `mergeAll_lookup_some` via standard induction
4. **Finally:** Complete `encode_decode_roundtrip`

## Executable Tests

### Lean Tests (in BPE.lean)

The file includes `#eval!` tests that verify the algorithm:

```
-- tinyVocab tests (single merge: "in" → 256)
"in"    → [256]                    ✓
"input" → [256, 112, 117, 116]     ✓  (in + p + u + t)
"hello" → [104, 101, 108, 108, 111] ✓  (no merges)

-- testVocab tests (multi-level merges)
"in"    → [256]       ✓  (i+n merged)
"the"   → [258]       ✓  (t+h → th, th+e → the)
"ing"   → [259]       ✓  (i+n → in, in+g → ing)
"thing" → [257, 259]  ✓  (th + ing)

-- Roundtrips all pass: decode(encode(x)) = x
```

### Python/tiktoken Tests

Script: `scripts/test_bpe_tiktoken.py`

Run with:
```bash
uv run scripts/test_bpe_tiktoken.py
```

This script:
1. Tests tiktoken's cl100k_base on various inputs
2. Exports a vocabulary subset to JSON
3. Verifies encode/decode roundtrips

Example cl100k_base results:
- "hello" → [15339] (single token)
- "in" → [258]
- "input" → [1379] (single token, not in+put)
- "tokenization" → [5963, 2065] (token + ization)

## References

- Main file: `ReActAgent/Tokenizer/BPE.lean`
- Test script: `scripts/test_bpe_tiktoken.py`
- Token counting docs: `docs/TOKEN_COUNT.md`
- tiktoken reference: https://github.com/openai/tiktoken
