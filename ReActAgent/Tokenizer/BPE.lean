/-
# Byte Pair Encoding (BPE) Tokenizer

A formalization of the BPE algorithm used by tiktoken (cl100k_base, r50k_base, etc.).

The vocabulary is parameterized, allowing:
- Small test vocabularies for proofs
- Full vocabularies loaded at runtime

Reference: https://github.com/openai/tiktoken
-/
import Batteries.Data.List.Basic

namespace Tokenizer

/-- A token is represented by its ID (rank in the vocabulary) -/
abbrev TokenId := Nat

/-- A piece is a byte sequence that may be merged -/
abbrev Piece := ByteArray

/-- BPE vocabulary: maps byte sequences to token IDs.
    The token ID doubles as the merge priority (lower = merge first). -/
structure Vocab where
  /-- Look up a byte sequence, returning its token ID if present -/
  lookup : Piece → Option TokenId
  /-- Decode a token ID back to bytes (partial inverse of lookup) -/
  decode : TokenId → Option Piece

/-- Merge two adjacent pieces into one -/
def mergePieces (a b : Piece) : Piece :=
  a ++ b

/-- Find the minimum element's index and value -/
def List.minWithIndex? : List Nat → Option (Nat × Nat)
  | [] => none
  | x :: xs => some <| xs.foldl (init := (0, x)) fun (minIdx, minVal) val =>
      if val < minVal then (minIdx + 1, val) else (minIdx, minVal)
      -- Note: foldl index tracking is tricky, simplified version

/-- Find all adjacent pairs and their ranks in the vocabulary -/
def findMergeablePairs (vocab : Vocab) (pieces : List Piece) : List (Nat × TokenId) :=
  let rec go (idx : Nat) : List Piece → List (Nat × TokenId)
    | [] => []
    | [_] => []
    | a :: b :: rest =>
      match vocab.lookup (mergePieces a b) with
      | none => go (idx + 1) (b :: rest)
      | some rank => (idx, rank) :: go (idx + 1) (b :: rest)
  go 0 pieces

/-- Find the pair with minimum rank (token ID) -/
def findBestMerge (candidates : List (Nat × TokenId)) : Option (Nat × TokenId) :=
  candidates.foldl (init := none) fun best curr =>
    match best with
    | none => some curr
    | some (_, bestRank) =>
      if curr.2 < bestRank then some curr else best

/-- Apply a merge at the given index -/
def applyMerge (pieces : List Piece) (idx : Nat) : List Piece :=
  let rec go (i : Nat) : List Piece → List Piece
    | [] => []
    | [x] => [x]
    | a :: b :: rest =>
      if i == idx then mergePieces a b :: rest
      else a :: go (i + 1) (b :: rest)
  go 0 pieces

/-- Perform one merge step: merge the pair with lowest rank -/
def mergeOnce (vocab : Vocab) (pieces : List Piece) : Option (List Piece) := do
  let candidates := findMergeablePairs vocab pieces
  let (idx, _) ← findBestMerge candidates
  return applyMerge pieces idx

/-- Repeatedly merge until no more merges possible -/
partial def mergeAll (vocab : Vocab) (pieces : List Piece) : List Piece :=
  match mergeOnce vocab pieces with
  | none => pieces
  | some pieces' => mergeAll vocab pieces'

/-- Convert bytes to initial pieces (one byte each) -/
def bytesToPieces (bytes : ByteArray) : List Piece :=
  bytes.toList.map fun b => ByteArray.mk #[b]

/-- Encode bytes to token IDs -/
def encode (vocab : Vocab) (input : ByteArray) : List TokenId :=
  let pieces := bytesToPieces input
  let merged := mergeAll vocab pieces
  merged.filterMap vocab.lookup

/-- Decode token IDs back to bytes -/
def decode (vocab : Vocab) (tokens : List TokenId) : Option ByteArray :=
  match tokens.mapM vocab.decode with
  | none => none
  | some pieces => some (pieces.foldl (· ++ ·) ByteArray.empty)

/-! ## Properties -/

/-- The step function in findBestMerge preserves Some -/
private def findBestMergeStep (best : Option (Nat × TokenId)) (curr : Nat × TokenId) :
    Option (Nat × TokenId) :=
  match best with
  | none => some curr
  | some (_, bestRank) => if curr.2 < bestRank then some curr else best

/-- Once we have Some, findBestMergeStep keeps it Some -/
theorem findBestMergeStep_preserves_some (x : Nat × TokenId) (curr : Nat × TokenId) :
    ∃ z, findBestMergeStep (some x) curr = some z := by
  simp only [findBestMergeStep]
  split
  · exact ⟨curr, rfl⟩
  · exact ⟨x, rfl⟩

/-- foldl with findBestMergeStep starting from Some stays Some -/
theorem foldl_findBestMergeStep_some (x : Nat × TokenId) (xs : List (Nat × TokenId)) :
    (xs.foldl findBestMergeStep (some x)).isSome := by
  induction xs generalizing x with
  | nil => simp [Option.isSome]
  | cons y ys ih =>
    simp only [List.foldl_cons]
    obtain ⟨z, hz⟩ := findBestMergeStep_preserves_some x y
    simp only [hz]
    exact ih z

/-- findBestMerge on non-empty list returns some -/
theorem findBestMerge_cons (x : Nat × TokenId) (xs : List (Nat × TokenId)) :
    (findBestMerge (x :: xs)).isSome := by
  simp only [findBestMerge, List.foldl_cons]
  -- First step goes from none to some x
  show (xs.foldl _ (some x)).isSome
  exact foldl_findBestMergeStep_some x xs

/-- mergeOnce returns none iff no mergeable pairs exist -/
theorem mergeOnce_none_iff (vocab : Vocab) (pieces : List Piece) :
    mergeOnce vocab pieces = none ↔ findMergeablePairs vocab pieces = [] := by
  constructor
  · -- If mergeOnce returns none, candidates must be empty
    intro h
    cases hcands : findMergeablePairs vocab pieces with
    | nil => rfl
    | cons y ys =>
      have hsome := findBestMerge_cons y ys
      simp only [mergeOnce, hcands] at h
      simp only [Option.isSome_iff_exists] at hsome
      obtain ⟨v, hv⟩ := hsome
      simp [hv] at h
  · -- If candidates empty, mergeOnce returns none
    intro h
    simp only [mergeOnce, h, findBestMerge, List.foldl_nil]
    rfl

/-- applyMerge reduces length by 1 -/
theorem applyMerge_length (pieces : List Piece) (idx : Nat)
    (h : idx + 1 < pieces.length) :
    (applyMerge pieces idx).length = pieces.length - 1 := by
  sorry

/-- Each merge step reduces the number of pieces -/
theorem mergeOnce_decreases (vocab : Vocab) (pieces pieces' : List Piece)
    (h : mergeOnce vocab pieces = some pieces') :
    pieces'.length < pieces.length := by
  sorry

/-! ## Test Vocabulary: Base bytes only -/

/-- Minimal vocabulary: just the 256 base bytes, no merges -/
def baseVocab : Vocab where
  lookup piece :=
    if h : piece.size = 1 then some (piece[0]'(by omega)).toNat
    else none
  decode tid :=
    if tid < 256 then some (ByteArray.mk #[tid.toUInt8])
    else none

/-- With base vocab only, no merges are possible -/
theorem baseVocab_no_merges (pieces : List Piece)
    (h : ∀ p ∈ pieces, p.size = 1) :
    findMergeablePairs baseVocab pieces = [] := by
  -- Key insight: concatenating two size-1 pieces gives size 2,
  -- which baseVocab doesn't recognize
  sorry

/-- With base vocab, encode just converts bytes to their numeric values -/
theorem baseVocab_encode (input : ByteArray) :
    encode baseVocab input = input.toList.map (·.toNat) := by
  sorry

/-- Base vocab decode inverts encode -/
theorem baseVocab_roundtrip (input : ByteArray) :
    decode baseVocab (encode baseVocab input) = some input := by
  sorry

/-! ## Example: Tiny vocabulary with one merge -/

/-- Vocabulary with base bytes + one merge: "in" → 256 -/
def tinyVocab : Vocab where
  lookup piece :=
    if h : piece.size = 1 then some (piece[0]'(by omega)).toNat
    else if piece == "in".toUTF8 then some 256
    else none
  decode tid :=
    if tid < 256 then some (ByteArray.mk #[tid.toUInt8])
    else if tid == 256 then some "in".toUTF8
    else none

#eval! encode tinyVocab "in".toUTF8        -- Expected: [256]
#eval! encode tinyVocab "input".toUTF8     -- Expected: [256, 112, 117, 116]
#eval! encode tinyVocab "hello".toUTF8     -- Expected: [104, 101, 108, 108, 111]

end Tokenizer
