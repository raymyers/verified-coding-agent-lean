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

/-- A well-formed vocabulary covers all bytes and decode inverts lookup -/
structure Vocab.WellFormed (v : Vocab) : Prop where
  /-- Every single byte has a token ID -/
  covers_bytes : ∀ b : UInt8, ∃ tid, v.lookup (ByteArray.mk #[b]) = some tid
  /-- Decode is left-inverse of lookup -/
  decode_inv : ∀ piece tid, v.lookup piece = some tid → v.decode tid = some piece

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

/-- Convert bytes to initial pieces (one byte each) -/
def bytesToPieces (bytes : ByteArray) : List Piece :=
  bytes.toList.map fun b => ByteArray.mk #[b]

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

/-- findBestMerge returns an element from the input list -/
theorem findBestMerge_mem (candidates : List (Nat × TokenId)) (p : Nat × TokenId)
    (h : findBestMerge candidates = some p) : p ∈ candidates := by
  simp only [findBestMerge] at h
  -- Prove by induction: foldl maintains that result ∈ accumulated list
  suffices ∀ (acc : Option (Nat × TokenId)) (xs : List (Nat × TokenId)),
      (∀ a, acc = some a → a ∈ candidates) →
      (∀ x, x ∈ xs → x ∈ candidates) →
      ∀ q, xs.foldl findBestMergeStep acc = some q → q ∈ candidates by
    exact this none candidates (fun _ h => by simp at h) (fun x hx => hx) p h
  intro acc xs hacc hxs q hq
  induction xs generalizing acc with
  | nil =>
    simp only [List.foldl_nil] at hq
    exact hacc q hq
  | cons y ys ih =>
    simp only [List.foldl_cons] at hq
    apply ih (findBestMergeStep acc y)
    · -- New accumulator value is in candidates
      intro a ha
      simp only [findBestMergeStep] at ha
      cases acc with
      | none =>
        simp at ha
        rw [← ha]
        exact hxs y (by simp)
      | some b =>
        simp only at ha
        split at ha
        · simp at ha; rw [← ha]; exact hxs y (by simp)
        · simp at ha; rw [← ha]; exact hacc b rfl
    · -- Remaining list elements are in candidates
      intro x hx
      exact hxs x (List.mem_cons_of_mem y hx)
    · exact hq

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

/-- Helper for applyMerge.go length -/
theorem applyMerge_go_length_aux (i idx : Nat) (pieces : List Piece)
    (hbound : i ≤ idx) (hvalid : idx + 1 < i + pieces.length) :
    (applyMerge.go idx i pieces).length + 1 = pieces.length := by
  induction pieces generalizing i with
  | nil =>
    -- hvalid : idx + 1 < i + 0, hbound : i ≤ idx
    -- This is contradictory: idx + 1 < i and i ≤ idx
    simp only [List.length_nil, Nat.add_zero] at hvalid
    omega
  | cons a as ih =>
    cases as with
    | nil =>
      -- hvalid : idx + 1 < i + 1, hbound : i ≤ idx
      -- So idx < i and i ≤ idx, contradiction
      simp only [List.length_cons, List.length_nil] at hvalid
      omega
    | cons b bs =>
      simp only [applyMerge.go]
      split
      · -- i == idx: merge happens here
        simp only [List.length_cons]
      · -- i ≠ idx: recurse
        rename_i hne
        simp only [beq_iff_eq] at hne
        simp only [List.length_cons]
        have hi : i < idx := Nat.lt_of_le_of_ne hbound (fun heq => hne heq)
        have hbound' : i + 1 ≤ idx := hi
        have hvalid' : idx + 1 < (i + 1) + (b :: bs).length := by
          simp only [List.length_cons] at hvalid ⊢
          omega
        have := ih (i + 1) hbound' hvalid'
        simp only [List.length_cons] at this
        omega

/-- applyMerge reduces length by 1 -/
theorem applyMerge_length (pieces : List Piece) (idx : Nat)
    (h : idx + 1 < pieces.length) :
    (applyMerge pieces idx).length = pieces.length - 1 := by
  simp only [applyMerge]
  have := applyMerge_go_length_aux 0 idx pieces (Nat.zero_le _) (by omega)
  omega

/-- Helper: indices from go are bounded -/
theorem findMergeablePairs_go_valid (vocab : Vocab) (i : Nat) (pieces : List Piece)
    (idx : Nat) (rank : TokenId) (hmem : (idx, rank) ∈ findMergeablePairs.go vocab i pieces) :
    i ≤ idx ∧ idx + 1 < i + pieces.length := by
  induction pieces generalizing i with
  | nil => simp [findMergeablePairs.go] at hmem
  | cons a as ih =>
    cases as with
    | nil => simp [findMergeablePairs.go] at hmem
    | cons b bs =>
      simp only [findMergeablePairs.go] at hmem
      cases hvocab : vocab.lookup (mergePieces a b) with
      | none =>
        simp [hvocab] at hmem
        have ⟨hle, hlt⟩ := ih (i + 1) hmem
        constructor
        · omega
        · simp only [List.length_cons] at hlt ⊢; omega
      | some r =>
        simp [hvocab] at hmem
        rcases hmem with ⟨hidx, _⟩ | htail
        · -- idx = i
          constructor
          · omega
          · simp only [List.length_cons]; omega
        · -- (idx, rank) ∈ go (i+1) (b :: bs)
          have ⟨hle, hlt⟩ := ih (i + 1) htail
          constructor
          · omega
          · simp only [List.length_cons] at hlt ⊢; omega

/-- Indices returned by findMergeablePairs are valid -/
theorem findMergeablePairs_valid_idx (vocab : Vocab) (pieces : List Piece)
    (idx : Nat) (rank : TokenId) (hmem : (idx, rank) ∈ findMergeablePairs vocab pieces) :
    idx + 1 < pieces.length := by
  simp only [findMergeablePairs] at hmem
  have ⟨_, hlt⟩ := findMergeablePairs_go_valid vocab 0 pieces idx rank hmem
  omega

/-- Each merge step reduces the number of pieces -/
theorem mergeOnce_decreases (vocab : Vocab) (pieces pieces' : List Piece)
    (h : mergeOnce vocab pieces = some pieces') :
    pieces'.length < pieces.length := by
  simp only [mergeOnce] at h
  -- Extract the index from findBestMerge
  cases hbest : findBestMerge (findMergeablePairs vocab pieces) with
  | none => simp [hbest] at h
  | some p =>
    simp [hbest] at h
    obtain ⟨idx, rank⟩ := p
    -- h : applyMerge pieces idx = pieces'
    rw [← h]
    -- Need: idx + 1 < pieces.length
    have hmem : (idx, rank) ∈ findMergeablePairs vocab pieces :=
      findBestMerge_mem _ _ hbest
    have hvalid := findMergeablePairs_valid_idx vocab pieces idx rank hmem
    have hlen := applyMerge_length pieces idx hvalid
    -- hlen : (applyMerge pieces idx).length = pieces.length - 1
    -- hvalid : idx + 1 < pieces.length, so pieces.length ≥ 2
    have hge2 : pieces.length ≥ 2 := by omega
    rw [hlen]
    omega

/-- Repeatedly merge until no more merges possible -/
def mergeAll (vocab : Vocab) (pieces : List Piece) : List Piece :=
  match h : mergeOnce vocab pieces with
  | none => pieces
  | some pieces' => mergeAll vocab pieces'
termination_by pieces.length
decreasing_by exact mergeOnce_decreases vocab pieces pieces' h

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

/-! ## General Roundtrip Theorem -/

/-- Concatenate all pieces into a single ByteArray -/
def concatPieces (pieces : List Piece) : ByteArray :=
  pieces.foldl (· ++ ·) ByteArray.empty

/-- Merging preserves concatenation -/
theorem applyMerge_concat (pieces : List Piece) (idx : Nat) :
    concatPieces (applyMerge pieces idx) = concatPieces pieces := by
  simp only [applyMerge, concatPieces]
  -- applyMerge.go just regroups, doesn't change total bytes
  suffices ∀ i (acc : ByteArray), (applyMerge.go idx i pieces).foldl (· ++ ·) acc = pieces.foldl (· ++ ·) acc by
    exact this 0 ByteArray.empty
  intro i acc
  induction pieces generalizing i acc with
  | nil => rfl
  | cons a as ih =>
    cases as with
    | nil => simp [applyMerge.go]
    | cons b bs =>
      simp only [applyMerge.go]
      split
      · -- Merge happens: (a ++ b) :: bs
        simp only [List.foldl_cons, mergePieces]
        -- Need: bs.foldl (· ++ ·) (acc ++ (a ++ b)) = bs.foldl (· ++ ·) (acc ++ a ++ b)
        congr 1
        simp only [ByteArray.append_assoc]
      · -- No merge: a :: go (i+1) (b :: bs)
        simp only [List.foldl_cons]
        exact ih (i + 1) (acc ++ a)

/-- mergeAll preserves concatenation -/
theorem mergeAll_concat (vocab : Vocab) (pieces : List Piece) :
    concatPieces (mergeAll vocab pieces) = concatPieces pieces := by
  exact aux vocab pieces.length pieces rfl
where
  aux (vocab : Vocab) : ∀ n (pieces : List Piece), pieces.length = n →
      concatPieces (mergeAll vocab pieces) = concatPieces pieces := by
    intro n
    induction n using Nat.strongRecOn with
    | _ n ih =>
      intro pieces hlen
      unfold mergeAll
      split
      · rfl
      · next pieces' heq =>
        have hdec := mergeOnce_decreases vocab pieces pieces' heq
        rw [ih pieces'.length (by omega) pieces' rfl]
        -- Goal: concatPieces pieces' = concatPieces pieces
        simp only [mergeOnce] at heq
        cases hbest : findBestMerge (findMergeablePairs vocab pieces) with
        | none => simp [hbest] at heq
        | some p =>
          simp [hbest] at heq
          rw [← heq]
          exact applyMerge_concat pieces p.1

private theorem toList_loop_spec (bs : ByteArray) (i : Nat) (r : List UInt8) :
    ByteArray.toList.loop bs i r = r.reverse ++ (bs.data.toList.drop i) := by
  induction i, r using ByteArray.toList.loop.induct bs with
  | case1 i r hi ih =>
    rw [ByteArray.toList.loop.eq_1, if_pos hi, ih]
    have hlen : i < bs.data.toList.length := by rw [Array.length_toList]; exact hi
    rw [List.reverse_cons, List.append_assoc, List.singleton_append]
    congr 1
    rw [List.drop_eq_getElem_cons hlen]
    congr 1
    simp only [ByteArray.get!]
    rw [Array.getElem_toList hi]
    exact getElem!_pos bs.data i hi
  | case2 i r hi =>
    rw [ByteArray.toList.loop.eq_1, if_neg hi]
    have : bs.data.toList.length ≤ i := by rw [Array.length_toList]; exact Nat.not_lt.mp hi
    rw [List.drop_of_length_le this]
    simp [List.append_nil]

/-- Helper: ByteArray.toList equals the underlying array's toList -/
private theorem byteArray_toList_eq (bs : ByteArray) : bs.toList = bs.data.toList := by
  simp only [ByteArray.toList]
  rw [toList_loop_spec]
  simp

/-- bytesToPieces concatenates to the original -/
theorem bytesToPieces_concat (input : ByteArray) :
    concatPieces (bytesToPieces input) = input := by
  -- Mapping each byte to a singleton array then concatenating = original
  simp only [bytesToPieces, concatPieces]
  -- Generalize with accumulator
  have h : ∀ acc : ByteArray, ∀ bytes : List UInt8,
      (bytes.map fun b => ByteArray.mk #[b]).foldl (· ++ ·) acc = acc ++ ByteArray.mk ⟨bytes⟩ := by
    intro acc bytes
    induction bytes generalizing acc with
    | nil =>
      simp only [List.map_nil, List.foldl_nil]
      have hempty : ByteArray.mk ⟨[]⟩ = ByteArray.empty := by native_decide
      rw [hempty]
      exact ByteArray.append_empty.symm
    | cons b bs ih =>
      simp only [List.map_cons, List.foldl_cons]
      rw [ih]
      rw [ByteArray.append_assoc]
      have hcons : ByteArray.mk #[b] ++ ByteArray.mk ⟨bs⟩ = ByteArray.mk ⟨b :: bs⟩ := by
        apply ByteArray.ext
        rfl
      rw [hcons]
  rw [h]
  simp only [ByteArray.empty_append]
  -- Need: ByteArray.mk ⟨input.toList⟩ = input
  rw [byteArray_toList_eq]
  -- Goal: ByteArray.mk ⟨input.data.toList⟩ = input (which is rfl)

/-- applyMerge.go preserves a predicate when the merged pair satisfies it -/
private theorem applyMerge_go_forall (P : Piece → Prop) (idx i : Nat) :
    ∀ (pieces : List Piece),
    (∀ p ∈ pieces, P p) →
    (∀ a b rest, i ≤ idx → List.drop (idx - i) pieces = a :: b :: rest →
      P (mergePieces a b)) →
    ∀ p ∈ applyMerge.go idx i pieces, P p := by
  intro pieces hall hmerge p hp
  induction pieces generalizing i p with
  | nil => simp [applyMerge.go] at hp
  | cons x xs ih =>
    cases xs with
    | nil => exact hall p (by simpa [applyMerge.go] using hp)
    | cons y ys =>
      simp only [applyMerge.go] at hp
      split at hp
      · -- i == idx
        rename_i heq
        have hi : i = idx := beq_iff_eq.mp heq
        simp only [List.mem_cons] at hp
        rcases hp with rfl | htail
        · exact hmerge x y ys (by omega) (by simp [hi, Nat.sub_self])
        · exact hall p (by simp; right; right; exact htail)
      · -- i ≠ idx
        rename_i hne
        simp only [List.mem_cons] at hp
        rcases hp with rfl | htail
        · exact hall p (by simp)
        · have hne' : i ≠ idx := fun h => hne (beq_iff_eq.mpr h)
          exact ih (i + 1) (fun q hq => hall q (List.mem_cons_of_mem _ hq))
            (fun a' b' rest' hle hdrop => by
              apply hmerge a' b' rest' (by omega)
              have : idx - i = (idx - (i + 1)) + 1 := by omega
              rw [this, List.drop_succ_cons]
              exact hdrop)
            p htail

/-- findMergeablePairs.go produces indices ≥ start -/
private theorem findMergeablePairs_go_ge (vocab : Vocab) (start : Nat) (pieces : List Piece)
    (idx : Nat) (rank : TokenId)
    (hmem : (idx, rank) ∈ findMergeablePairs.go vocab start pieces) :
    start ≤ idx := by
  induction pieces generalizing start with
  | nil => simp [findMergeablePairs.go] at hmem
  | cons x xs ih =>
    cases xs with
    | nil => simp [findMergeablePairs.go] at hmem
    | cons y ys =>
      simp only [findMergeablePairs.go] at hmem
      cases hlookup : vocab.lookup (mergePieces x y) with
      | none =>
        simp [hlookup] at hmem
        exact Nat.le_of_succ_le (ih (start + 1) hmem)
      | some r =>
        simp [hlookup] at hmem
        rcases hmem with ⟨h, _⟩ | htail
        · omega
        · exact Nat.le_of_succ_le (ih (start + 1) htail)

/-- findMergeablePairs.go entries correspond to vocab lookups -/
private theorem findMergeablePairs_go_lookup (vocab : Vocab) (start : Nat) (pieces : List Piece)
    (idx : Nat) (rank : TokenId)
    (hmem : (idx, rank) ∈ findMergeablePairs.go vocab start pieces) :
    ∃ a b rest, List.drop (idx - start) pieces = a :: b :: rest ∧
      vocab.lookup (mergePieces a b) = some rank := by
  induction pieces generalizing start with
  | nil => simp [findMergeablePairs.go] at hmem
  | cons x xs ih =>
    cases xs with
    | nil => simp [findMergeablePairs.go] at hmem
    | cons y ys =>
      simp only [findMergeablePairs.go] at hmem
      cases hlookup : vocab.lookup (mergePieces x y) with
      | none =>
        simp [hlookup] at hmem
        have ⟨a, b, rest, hdrop, hlk⟩ := ih (start + 1) hmem
        have hge := findMergeablePairs_go_ge vocab (start + 1) (y :: ys) idx rank hmem
        exact ⟨a, b, rest, by rw [show idx - start = (idx - (start + 1)) + 1 from by omega,
          List.drop_succ_cons]; exact hdrop, hlk⟩
      | some r =>
        simp [hlookup] at hmem
        rcases hmem with ⟨hidx, hrk⟩ | htail
        · subst hidx; subst hrk
          exact ⟨x, y, ys, by simp [Nat.sub_self], hlookup⟩
        · have ⟨a, b, rest, hdrop, hlk⟩ := ih (start + 1) htail
          have hge := findMergeablePairs_go_ge vocab (start + 1) (y :: ys) idx rank htail
          exact ⟨a, b, rest, by rw [show idx - start = (idx - (start + 1)) + 1 from by omega,
            List.drop_succ_cons]; exact hdrop, hlk⟩

/-- mergeOnce preserves the property that all pieces have vocab lookups -/
private theorem mergeOnce_preserves_lookup (vocab : Vocab) (pieces pieces' : List Piece)
    (hall : ∀ p ∈ pieces, ∃ tid, vocab.lookup p = some tid)
    (h : mergeOnce vocab pieces = some pieces') :
    ∀ p ∈ pieces', ∃ tid, vocab.lookup p = some tid := by
  simp only [mergeOnce] at h
  cases hbest : findBestMerge (findMergeablePairs vocab pieces) with
  | none => simp [hbest] at h
  | some pair =>
    simp [hbest] at h
    rw [← h]
    apply applyMerge_go_forall (fun p => ∃ tid, vocab.lookup p = some tid) pair.1 0 pieces hall
    intro a b rest _ hdrop
    have hmem := findBestMerge_mem _ _ hbest
    have ⟨a', b', rest', hdrop', hlk⟩ :=
      findMergeablePairs_go_lookup vocab 0 pieces pair.1 pair.2 hmem
    simp only [Nat.sub_zero] at hdrop hdrop'
    rw [hdrop] at hdrop'
    have := List.cons.inj hdrop'
    rw [this.1, (List.cons.inj this.2).1]
    exact ⟨pair.2, hlk⟩

/-- Helper: bytesToPieces creates single-byte pieces -/
theorem bytesToPieces_size_one (input : ByteArray) :
    ∀ p ∈ bytesToPieces input, p.size = 1 := by
  intro p hp
  simp only [bytesToPieces, List.mem_map] at hp
  obtain ⟨b, _, rfl⟩ := hp
  rfl

/-- For well-formed vocab, all final pieces have token IDs -/
theorem mergeAll_lookup_some (vocab : Vocab) (hw : vocab.WellFormed) (pieces : List Piece)
    (hinit : ∀ p ∈ pieces, p.size = 1) :
    ∀ p ∈ mergeAll vocab pieces, ∃ tid, vocab.lookup p = some tid := by
  -- Generalize: use invariant "all pieces have lookup" instead of "all size 1"
  suffices hinv : ∀ p ∈ pieces, ∃ tid, vocab.lookup p = some tid by
    exact mergeAll_lookup_some_aux vocab pieces.length pieces rfl hinv
  -- Initial condition: single-byte pieces have lookup by covers_bytes
  intro p hp
  have hsize := hinit p hp
  -- p has size 1, so it's a single byte
  have ⟨b, hb⟩ : ∃ b : UInt8, p = ByteArray.mk #[b] := by
    cases p with | mk arr =>
    cases arr with | mk lst =>
    unfold ByteArray.size Array.size at hsize
    match lst with
    | [b] => exact ⟨b, rfl⟩
    | [] => simp at hsize
    | _ :: _ :: _ => simp only [List.length_cons] at hsize; omega
  rw [hb]; exact hw.covers_bytes b
where
  mergeAll_lookup_some_aux (vocab : Vocab) :
      ∀ n (pieces : List Piece), pieces.length = n →
      (∀ p ∈ pieces, ∃ tid, vocab.lookup p = some tid) →
      ∀ p ∈ mergeAll vocab pieces, ∃ tid, vocab.lookup p = some tid := by
    intro n
    induction n using Nat.strongRecOn with
    | _ n ih =>
      intro pieces hlen hall
      unfold mergeAll
      split
      · exact hall
      · next pieces' heq =>
        have hdec := mergeOnce_decreases vocab pieces pieces' heq
        exact ih pieces'.length (by omega) pieces' rfl
          (mergeOnce_preserves_lookup vocab pieces pieces' hall heq)

/-- filterMap lookup then mapM decode recovers the original pieces -/
private theorem filterMap_mapM_roundtrip (vocab : Vocab)
    (hdec : ∀ piece tid, vocab.lookup piece = some tid → vocab.decode tid = some piece)
    (pieces : List Piece)
    (hall : ∀ p ∈ pieces, ∃ tid, vocab.lookup p = some tid) :
    (pieces.filterMap vocab.lookup).mapM vocab.decode = some pieces := by
  induction pieces with
  | nil => rfl
  | cons p ps ih =>
    have ⟨tid, hlk⟩ := hall p (by simp)
    simp only [List.filterMap_cons, hlk, List.mapM_cons]
    rw [hdec p tid hlk, ih (fun q hq => hall q (List.mem_cons_of_mem _ hq))]
    rfl

/-- General roundtrip theorem for well-formed vocabularies -/
theorem encode_decode_roundtrip (vocab : Vocab) (hw : vocab.WellFormed) (input : ByteArray) :
    decode vocab (encode vocab input) = some input := by
  simp only [encode, decode]
  have hmerged := mergeAll_lookup_some vocab hw (bytesToPieces input) (bytesToPieces_size_one input)
  rw [filterMap_mapM_roundtrip vocab hw.decode_inv _ hmerged]
  -- Goal: some (foldl (++) empty (mergeAll ...)) = some input
  simp only [Option.some.injEq]
  -- This is concatPieces (mergeAll vocab (bytesToPieces input)) = input
  have : concatPieces (mergeAll vocab (bytesToPieces input)) = input := by
    rw [mergeAll_concat]; exact bytesToPieces_concat input
  exact this

/-! ## Test Vocabulary: Base bytes only -/

/-- Minimal vocabulary: just the 256 base bytes, no merges -/
def baseVocab : Vocab where
  lookup piece :=
    if h : piece.size = 1 then some (piece[0]'(by omega)).toNat
    else none
  decode tid :=
    if tid < 256 then some (ByteArray.mk #[tid.toUInt8])
    else none

/-- baseVocab is well-formed -/
theorem baseVocab_wellFormed : baseVocab.WellFormed where
  covers_bytes b := ⟨b.toNat, rfl⟩
  decode_inv piece tid h := by
    simp only [baseVocab] at h ⊢
    split at h
    · -- piece.size = 1
      rename_i hsize
      simp only [Option.some.injEq] at h
      rw [← h]
      have htid : (piece[0]'(by omega)).toNat < 256 := (piece[0]'(by omega)).toNat_lt
      simp only [htid, ite_true]
      -- Need: ByteArray.mk #[(piece[0]).toNat.toUInt8] = piece
      -- (piece[0]).toNat.toUInt8 = piece[0] by UInt8.ofNat_toNat
      have hround : (piece[0]'(by omega)).toNat.toUInt8 = piece[0]'(by omega) :=
        UInt8.ofNat_toNat
      simp only [hround]
      -- Now need: some (ByteArray.mk #[piece[0]]) = some piece
      congr 1
      -- Now need: ByteArray.mk #[piece[0]] = piece when piece.size = 1
      -- Use that piece = ⟨piece.data⟩ and piece.data has exactly one element
      cases piece with
      | mk arr =>
        -- arr.size = 1 (from hsize, which is piece.size = 1)
        cases arr with
        | mk lst =>
          -- lst.length = 1
          unfold ByteArray.size Array.size at hsize
          match lst with
          | [x] => rfl
          | [] => exact absurd hsize (by decide)
          | _ :: _ :: _ => simp only [List.length_cons] at hsize; omega
    · simp at h

/-- With base vocab only, no merges are possible -/
theorem baseVocab_no_merges (pieces : List Piece)
    (h : ∀ p ∈ pieces, p.size = 1) :
    findMergeablePairs baseVocab pieces = [] := by
  -- Key insight: concatenating two size-1 pieces gives size 2,
  -- which baseVocab doesn't recognize
  simp only [findMergeablePairs]
  -- Need to show the inner go returns []
  have hgo : ∀ idx, findMergeablePairs.go baseVocab idx pieces = [] := by
    intro idx
    induction pieces generalizing idx with
    | nil => rfl
    | cons a rest ih =>
      cases rest with
      | nil => rfl
      | cons b rest' =>
        simp only [findMergeablePairs.go]
        -- vocab.lookup (mergePieces a b) = none because (a ++ b).size = 2
        have ha : a.size = 1 := h a (by simp)
        have hb : b.size = 1 := h b (by simp)
        have hmerge_size : (mergePieces a b).size = 2 := by
          simp only [mergePieces, ByteArray.size_append, ha, hb]
        have hlookup : baseVocab.lookup (mergePieces a b) = none := by
          simp only [baseVocab]
          -- lookup returns none when size ≠ 1
          simp only [hmerge_size, dif_neg (by decide : ¬2 = 1)]
        simp only [hlookup]
        -- Now apply IH for (b :: rest')
        apply ih
        intro p hp
        -- p ∈ b :: rest' means p = b or p ∈ rest'
        cases List.mem_cons.mp hp with
        | inl heq => rw [heq]; exact hb
        | inr hp' => exact h p (List.mem_cons_of_mem _ (List.mem_cons_of_mem _ hp'))
  exact hgo 0

/-- Helper: mergeOnce returns none when no merges are possible -/
theorem baseVocab_mergeOnce_none (pieces : List Piece) (h : ∀ p ∈ pieces, p.size = 1) :
    mergeOnce baseVocab pieces = none := by
  have hpairs : findMergeablePairs baseVocab pieces = [] := baseVocab_no_merges pieces h
  -- mergeOnce uses do-notation which desugars to bind
  -- When findBestMerge returns none, the whole expression is none
  simp only [mergeOnce, hpairs, findBestMerge, List.foldl_nil]
  rfl

/-- With base vocab, encode just converts bytes to their numeric values -/
theorem baseVocab_encode (input : ByteArray) :
    encode baseVocab input = input.toList.map (·.toNat) := by
  simp only [encode, bytesToPieces]
  -- Key facts:
  -- 1. bytesToPieces creates single-byte pieces
  -- 2. With baseVocab, mergeOnce returns none, so mergeAll is identity
  -- 3. Each byte b maps via baseVocab.lookup to some b.toNat
  -- mergeAll is identity since no merges are possible
  have hsize : ∀ p ∈ (input.toList.map fun b => ByteArray.mk #[b]), p.size = 1 := by
    intro p hp; simp only [List.mem_map] at hp; obtain ⟨_, _, rfl⟩ := hp; rfl
  have hmerge : mergeOnce baseVocab (input.toList.map fun b => ByteArray.mk #[b]) = none :=
    baseVocab_mergeOnce_none _ hsize
  have hid : mergeAll baseVocab (input.toList.map fun b => ByteArray.mk #[b]) =
      input.toList.map fun b => ByteArray.mk #[b] := by
    unfold mergeAll; split
    · rfl
    · next heq => simp [hmerge] at heq
  rw [hid]
  -- Now: filterMap baseVocab.lookup (map ...) = map (·.toNat) ...
  simp only [List.filterMap_map]
  induction input.toList with
  | nil => rfl
  | cons b bs ih =>
    simp only [List.map_cons, List.filterMap_cons, Function.comp]
    have hlookup : baseVocab.lookup (ByteArray.mk #[b]) = some b.toNat := rfl
    rw [hlookup]
    exact congrArg _ ih

/-- mapM baseVocab.decode on encoded byte values reconstructs bytesToPieces -/
private theorem baseVocab_mapM_decode (bytes : List UInt8) :
    (bytes.map (·.toNat)).mapM baseVocab.decode =
    some (bytes.map fun b => ByteArray.mk #[b]) := by
  induction bytes with
  | nil => rfl
  | cons b bs ih =>
    simp only [List.map_cons, List.mapM_cons]
    show (baseVocab.decode b.toNat).bind (fun a =>
      ((List.map (·.toNat) bs).mapM baseVocab.decode).bind (fun bs' =>
        some (a :: bs'))) = _
    have hb : baseVocab.decode b.toNat = some (ByteArray.mk #[b]) := by
      simp [baseVocab, UInt8.toNat_lt, UInt8.ofNat_toNat, b.toNat_lt]
    rw [hb, ih, Option.bind_some, Option.bind_some]

/-- Base vocab decode inverts encode -/
theorem baseVocab_roundtrip (input : ByteArray) :
    decode baseVocab (encode baseVocab input) = some input := by
  rw [baseVocab_encode]
  simp only [decode, baseVocab_mapM_decode]
  -- Now goal: some (foldl (++) empty (map ...)) = some input
  -- This is exactly bytesToPieces_concat
  congr 1
  exact bytesToPieces_concat input

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

/-! ## Test: BPE vocabulary with proper merge hierarchy -/

/-- A vocabulary demonstrating proper BPE merge hierarchy.
    BPE only merges adjacent pairs, so multi-byte tokens require
    intermediate merges. Lower rank = merged first.

    Merge order (by rank):
    256: "in" (i + n)
    257: "th" (t + h)
    258: "the" (th + e) - requires 257 first!
    259: "ing" (in + g) - requires 256 first!
-/
def testVocab : Vocab where
  lookup piece :=
    -- Multi-byte tokens (lower rank = higher priority for merging)
    if piece == "in".toUTF8 then some 256
    else if piece == "th".toUTF8 then some 257
    else if piece == "the".toUTF8 then some 258
    else if piece == "ing".toUTF8 then some 259
    -- Single bytes (ranks 0-255 reserved conceptually)
    else if h : piece.size = 1 then some (piece[0]'(by omega)).toNat
    else none
  decode tid :=
    if tid == 256 then some "in".toUTF8
    else if tid == 257 then some "th".toUTF8
    else if tid == 258 then some "the".toUTF8
    else if tid == 259 then some "ing".toUTF8
    else if tid < 256 then some (ByteArray.mk #[tid.toUInt8])
    else none

-- Test cases showing BPE merge behavior
-- "in" → merge i+n → [256]
#eval! encode testVocab "in".toUTF8

-- "the" → merge t+h → [257, 101] → merge th+e → [258]
#eval! encode testVocab "the".toUTF8

-- "ing" → merge i+n → [256, 103] → merge in+g → [259]
#eval! encode testVocab "ing".toUTF8

-- "thing" → [116, 104, 105, 110, 103]
--        → merge t+h → [257, 105, 110, 103]
--        → merge i+n → [257, 256, 103]
--        → merge in+g → [257, 259]
--        (Note: th+i not in vocab, so stops there)
#eval! encode testVocab "thing".toUTF8

-- Roundtrip verification
#eval! (decode testVocab (encode testVocab "in".toUTF8)).map (·.toList)
#eval! (decode testVocab (encode testVocab "the".toUTF8)).map (·.toList)
#eval! (decode testVocab (encode testVocab "ing".toUTF8)).map (·.toList)
#eval! (decode testVocab (encode testVocab "thing".toUTF8)).map (·.toList)

-- Verify original bytes are recovered
#eval! "in".toUTF8.toList      -- [105, 110]
#eval! "the".toUTF8.toList     -- [116, 104, 101]
#eval! "ing".toUTF8.toList     -- [105, 110, 103]
#eval! "thing".toUTF8.toList   -- [116, 104, 105, 110, 103]

end Tokenizer
