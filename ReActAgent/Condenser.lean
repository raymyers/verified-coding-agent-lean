/-
# Conversation Condenser

Given a conversation of any size and a token limit, produce a valid
condensed view that is provably under that limit.

Strategy: Keep system prompt + recent messages, summarize/drop old ones.
-/

import ReActAgent.Tokenizer.ApproxCount
import ReActAgent.LLM.Client

namespace Condenser

open LLM Tokenizer

/-! ## Message Token Counting -/

/-- foldl with addition starting from n equals n + foldl starting from 0 -/
theorem foldl_add_start (msgs : List ChatMessage) (f : ChatMessage → Nat) (n : Nat) :
    msgs.foldl (fun acc m => acc + f m) n = n + msgs.foldl (fun acc m => acc + f m) 0 := by
  induction msgs generalizing n with
  | nil => simp
  | cons m rest ih =>
    simp only [List.foldl_cons]
    rw [ih, ih (0 + f m)]
    omega

/-- Approximate token count for a chat message -/
def messageTokens (msg : ChatMessage) : Nat :=
  -- role + content + overhead
  let roleTokens := approxTokenCount msg.role
  let contentTokens := match msg.content with
    | some c => approxTokenCount c
    | none => 0
  let toolCallTokens := match msg.toolCalls with
    | some tcs => tcs.size * 20  -- rough estimate per tool call
    | none => 0
  roleTokens + contentTokens + toolCallTokens + 4  -- message overhead

/-- Total tokens for a list of messages -/
def totalTokens (msgs : List ChatMessage) : Nat :=
  msgs.foldl (· + messageTokens ·) 0

/-- totalTokens of cons equals messageTokens + totalTokens of tail -/
theorem totalTokens_cons (m : ChatMessage) (msgs : List ChatMessage) :
    totalTokens (m :: msgs) = messageTokens m + totalTokens msgs := by
  unfold totalTokens
  simp only [List.foldl_cons]
  rw [foldl_add_start]
  simp

/-- totalTokens distributes over append -/
theorem totalTokens_append (xs ys : List ChatMessage) :
    totalTokens (xs ++ ys) = totalTokens xs + totalTokens ys := by
  induction xs with
  | nil => simp [totalTokens]
  | cons x rest ih =>
    simp only [List.cons_append, totalTokens_cons, ih]
    omega

/-- totalTokens is invariant under reverse -/
theorem totalTokens_reverse (msgs : List ChatMessage) :
    totalTokens msgs.reverse = totalTokens msgs := by
  induction msgs with
  | nil => simp [totalTokens]
  | cons m rest ih =>
    simp only [List.reverse_cons, totalTokens_append, totalTokens_cons, ih]
    simp [totalTokens]
    omega

/-! ## Condensed View -/

/-- A condensed view of a conversation that fits within a token budget.
    The proof field guarantees the budget constraint. -/
structure CondensedView where
  /-- The condensed messages -/
  messages : List ChatMessage
  /-- The token budget this was condensed to -/
  budget : Nat
  /-- Proof that we're within budget -/
  withinBudget : totalTokens messages ≤ budget

/-- A condensed view is valid if it has at least one non-system message
    (required by Anthropic API) -/
def CondensedView.valid (cv : CondensedView) : Prop :=
  ∃ m ∈ cv.messages, m.role ≠ "system"

/-! ## Condensing Strategies -/

/-- Take messages from the end until we exceed budget, then stop -/
def takeRecentUnderBudget (msgs : List ChatMessage) (budget : Nat) : List ChatMessage :=
  let rec go (remaining : List ChatMessage) (acc : List ChatMessage) (used : Nat) : List ChatMessage :=
    match remaining with
    | [] => acc
    | m :: rest =>
      let msgCost := messageTokens m
      if used + msgCost ≤ budget then
        go rest (m :: acc) (used + msgCost)
      else
        acc
  -- Process from end (reverse, accumulate, already reversed back)
  go msgs.reverse [] 0

/-- Tokens used by takeRecentUnderBudget -/
theorem takeRecentUnderBudget_within_budget (msgs : List ChatMessage) (budget : Nat) :
    totalTokens (takeRecentUnderBudget msgs budget) ≤ budget := by
  unfold takeRecentUnderBudget
  -- The go function maintains the invariant that used ≤ budget
  -- and acc only contains messages counted in used
  suffices h : ∀ remaining acc used,
      used ≤ budget →
      totalTokens acc = used →
      totalTokens (takeRecentUnderBudget.go budget remaining acc used) ≤ budget by
    exact h msgs.reverse [] 0 (Nat.zero_le _) rfl
  intro remaining acc used hBound hInv
  induction remaining generalizing acc used with
  | nil =>
    simp only [takeRecentUnderBudget.go]
    rw [hInv]
    exact hBound
  | cons m rest ih =>
    simp only [takeRecentUnderBudget.go]
    split
    · -- used + msgCost ≤ budget, so we add m
      rename_i hAdd
      apply ih
      · exact hAdd
      · rw [totalTokens_cons, hInv]; omega
    · -- would exceed budget, return acc
      rw [hInv]
      exact hBound

/-- Keep system messages + recent non-system messages -/
def condenseWithSystem (msgs : List ChatMessage) (budget : Nat) : List ChatMessage :=
  let systemMsgs := msgs.filter (·.role == "system")
  let nonSystemMsgs := msgs.filter (·.role != "system")
  let systemCost := totalTokens systemMsgs
  if systemCost ≥ budget then
    -- System messages alone exceed budget; truncate system
    takeRecentUnderBudget systemMsgs budget
  else
    -- Keep all system messages, fill rest with recent non-system
    let remaining := budget - systemCost
    let recentNonSystem := takeRecentUnderBudget nonSystemMsgs remaining
    systemMsgs ++ recentNonSystem

/-- condenseWithSystem stays within budget -/
theorem condenseWithSystem_within_budget (msgs : List ChatMessage) (budget : Nat) :
    totalTokens (condenseWithSystem msgs budget) ≤ budget := by
  unfold condenseWithSystem
  simp only []
  split
  · -- System messages exceed budget
    exact takeRecentUnderBudget_within_budget _ _
  · -- System + recent non-system
    rename_i hNotExceed
    rw [totalTokens_append]
    have hRecent := takeRecentUnderBudget_within_budget
      (msgs.filter (·.role != "system"))
      (budget - totalTokens (msgs.filter (·.role == "system")))
    have hLt : totalTokens (msgs.filter (·.role == "system")) < budget := Nat.lt_of_not_le hNotExceed
    omega

/-! ## Main Condense Function -/

/-- Condense a conversation to fit within a token budget.
    Returns a CondensedView with proof of budget compliance. -/
def condense (msgs : List ChatMessage) (budget : Nat) : CondensedView :=
  let condensed := takeRecentUnderBudget msgs budget
  ⟨condensed, budget, takeRecentUnderBudget_within_budget msgs budget⟩

/-- Condense with system message preservation -/
def condensePreservingSystem (msgs : List ChatMessage) (budget : Nat) : CondensedView :=
  let condensed := condenseWithSystem msgs budget
  ⟨condensed, budget, condenseWithSystem_within_budget msgs budget⟩

/-! ## Properties -/

/-- Any condensed view is within its stated budget -/
theorem condense_within_budget (msgs : List ChatMessage) (budget : Nat) :
    totalTokens (condense msgs budget).messages ≤ (condense msgs budget).budget := by
  exact (condense msgs budget).withinBudget

/-- Empty input produces empty output (within any budget) -/
theorem condense_empty (budget : Nat) :
    (condense [] budget).messages = [] := by
  simp [condense, takeRecentUnderBudget, takeRecentUnderBudget.go]

/-- Helper: go keeps all messages when they fit -/
theorem takeRecentUnderBudget_go_identity (remaining acc : List ChatMessage) (used budget : Nat)
    (hFit : used + totalTokens remaining ≤ budget) :
    takeRecentUnderBudget.go budget remaining acc used = remaining.reverse ++ acc := by
  induction remaining generalizing acc used with
  | nil => simp [takeRecentUnderBudget.go]
  | cons m rest ih =>
    simp only [takeRecentUnderBudget.go]
    have hAdd : used + messageTokens m ≤ budget := by
      have : totalTokens (m :: rest) = messageTokens m + totalTokens rest := totalTokens_cons m rest
      omega
    simp only [hAdd, ↓reduceIte]
    rw [ih]
    · simp [List.reverse_cons, List.append_assoc]
    · rw [totalTokens_cons] at hFit
      omega

/-- If input fits in budget, output equals input -/
theorem condense_identity (msgs : List ChatMessage) (budget : Nat)
    (h : totalTokens msgs ≤ budget) :
    (condense msgs budget).messages = msgs.reverse.reverse := by
  simp only [condense, takeRecentUnderBudget]
  have hFit : 0 + totalTokens msgs.reverse ≤ budget := by
    simp only [Nat.zero_add, totalTokens_reverse]
    exact h
  rw [takeRecentUnderBudget_go_identity _ _ _ _ hFit]
  simp

/-! ## Well-Formedness Preservation -/

/-- A message list is "properly formed" if all tool result messages have no tool calls.
    This is always true for messages constructed via ChatMessage.toolResult. -/
def messagesProperlyFormed : List ChatMessage → Bool
  | [] => true
  | m :: rest =>
      (m.role != "tool" || m.toolCalls == none) && messagesProperlyFormed rest

/-- ChatMessage.toolResult produces properly formed messages -/
theorem toolResult_properly_formed (id name content : String) :
    (ChatMessage.toolResult id name content).toolCalls = none := by
  simp [ChatMessage.toolResult]

/-- Dropping from proper messages preserves properness -/
theorem messagesProperlyFormed_drop (msgs : List ChatMessage) (n : Nat)
    (h : messagesProperlyFormed msgs = true) :
    messagesProperlyFormed (msgs.drop n) = true := by
  induction msgs generalizing n with
  | nil => simp [messagesProperlyFormed]
  | cons m rest ih =>
    cases n with
    | zero => simp; exact h
    | succ k =>
      simp only [List.drop_succ_cons]
      unfold messagesProperlyFormed at h
      simp only [Bool.and_eq_true] at h
      exact ih k h.2

/-- Helper: go accumulates a prefix of remaining (reversed) into acc -/
theorem takeRecentUnderBudget_go_prefix (remaining acc : List ChatMessage) (budget used : Nat) :
    ∃ k, takeRecentUnderBudget.go budget remaining acc used =
         (remaining.take k).reverse ++ acc := by
  induction remaining generalizing acc used with
  | nil =>
    exact ⟨0, by simp [takeRecentUnderBudget.go]⟩
  | cons m rest ih =>
    simp only [takeRecentUnderBudget.go]
    split
    · -- Fits in budget: add m to acc and recurse
      obtain ⟨k, hk⟩ := ih (m :: acc) (used + messageTokens m)
      -- hk : go rest (m :: acc) ... = (rest.take k).reverse ++ m :: acc
      -- Need: ∃ k', go rest (m :: acc) ... = ((m :: rest).take k').reverse ++ acc
      -- Use k' = k + 1
      -- (m :: rest).take (k + 1) = m :: rest.take k
      -- ((m :: rest).take (k + 1)).reverse = (rest.take k).reverse ++ [m]
      refine ⟨k + 1, ?_⟩
      simp only [List.take_succ_cons, List.reverse_cons]
      rw [hk]
      simp only [List.append_assoc, List.singleton_append]
    · -- Exceeds budget: return acc
      exact ⟨0, by simp⟩

/-- Taking k from reversed list and reversing back gives a suffix.
    Key insight: (L.reverse.take k).reverse = L.drop (L.length - k) -/
theorem reverse_take_reverse_eq_drop (L : List α) (k : Nat) (hk : k ≤ L.length) :
    (L.reverse.take k).reverse = L.drop (L.length - k) := by
  -- Induction on L.length - k (how much we're dropping)
  generalize hd : L.length - k = d
  induction d generalizing L k with
  | zero =>
    -- d = 0 means k ≥ L.length, combined with hk means k = L.length
    have hkeq : k = L.length := by omega
    subst hkeq
    simp only [Nat.sub_self, List.drop_zero]
    -- Goal: (L.reverse.take L.length).reverse = L
    have h1 : L.reverse.take L.length = L.reverse.take L.reverse.length := by
      simp [List.length_reverse]
    rw [h1, List.take_length, List.reverse_reverse]
  | succ d' ih =>
    -- d = d' + 1 means we drop at least one element
    cases L with
    | nil => simp at hd
    | cons x xs =>
      simp only [List.reverse_cons, List.length_cons] at *
      -- k ≤ xs.length (because d' + 1 = xs.length + 1 - k means k ≤ xs.length)
      have hk_xs : k ≤ xs.length := by omega
      rw [List.take_append_of_le_length (by simp; exact hk_xs)]
      -- Now: (xs.reverse.take k).reverse = xs.drop (xs.length - k)
      have hd' : xs.length - k = d' := by omega
      have h_sub : xs.length - k + k = xs.length := Nat.sub_add_cancel hk_xs
      rw [ih xs k hk_xs hd']
      -- Need: xs.drop d' = (x :: xs).drop (d' + 1)
      simp only [List.drop_succ_cons]

/-- takeRecentUnderBudget returns a suffix of the input list.
    More precisely: ∃ n, result = msgs.drop n

    This is the key structural property: the condenser produces a suffix. -/
theorem takeRecentUnderBudget_is_suffix (msgs : List ChatMessage) (budget : Nat) :
    ∃ n, takeRecentUnderBudget msgs budget = msgs.drop n := by
  unfold takeRecentUnderBudget
  obtain ⟨k, hk⟩ := takeRecentUnderBudget_go_prefix msgs.reverse [] budget 0
  rw [hk]
  simp only [List.append_nil]
  -- Now need to show: ∃ n, (msgs.reverse.take k).reverse = msgs.drop n
  by_cases hle : k ≤ msgs.length
  · -- k ≤ msgs.length: use reverse_take_reverse_eq_drop
    refine ⟨msgs.length - k, ?_⟩
    -- reverse_take_reverse_eq_drop msgs k hle gives:
    -- (msgs.reverse.take k).reverse = msgs.drop (msgs.length - k)
    exact reverse_take_reverse_eq_drop msgs k hle
  · -- k > msgs.length: take k returns the whole reversed list
    refine ⟨0, ?_⟩
    simp only [List.drop_zero]
    have hge : msgs.length ≤ k := Nat.le_of_not_le hle
    have htake : msgs.reverse.take k = msgs.reverse := List.take_of_length_le (by simp; exact hge)
    rw [htake, List.reverse_reverse]

/-- Helper: if m has no tool calls, well-formedness of (m :: rest) implies well-formedness of rest -/
theorem toolCallsWellFormed_cons_noToolCalls_inv (m : ChatMessage) (rest : List ChatMessage)
    (hno : m.toolCalls = none) (h : toolCallsWellFormed (m :: rest) = true) :
    toolCallsWellFormed rest = true := by
  unfold toolCallsWellFormed at h
  simp only [hno] at h
  exact h

/-- If the first n elements have no tool calls, and the rest is well-formed, the whole is well-formed -/
theorem toolCallsWellFormed_of_drop (msgs : List ChatMessage) (n : Nat)
    (hNoTools : ∀ i (hi : i < n) (hlen : i < msgs.length), (msgs.get ⟨i, hlen⟩).toolCalls = none)
    (hWf : toolCallsWellFormed (msgs.drop n) = true) :
    toolCallsWellFormed msgs = true := by
  induction msgs generalizing n with
  | nil => simp [toolCallsWellFormed]
  | cons m rest ih =>
    cases n with
    | zero => simp at hWf; exact hWf
    | succ k =>
      unfold toolCallsWellFormed
      have hm : m.toolCalls = none := hNoTools 0 (Nat.zero_lt_succ k) (Nat.zero_lt_succ _)
      simp only [hm]
      apply ih k
      · intro i hi hlen
        have hlen' : i + 1 < (m :: rest).length := by simp; omega
        have := hNoTools (i + 1) (by omega) hlen'
        simp only [List.get_cons_succ] at this
        exact this
      · simp only [List.drop_succ_cons] at hWf
        exact hWf

/-- List.get after drop: (L.drop n).get ⟨i, h⟩ = L.get ⟨i + n, ...⟩ -/
theorem get_drop (L : List α) (n i : Nat) (h : i < (L.drop n).length) :
    (L.drop n).get ⟨i, h⟩ = L.get ⟨i + n, by simp [List.length_drop] at h; omega⟩ := by
  induction n generalizing L i with
  | zero => simp
  | succ k ih =>
    cases L with
    | nil => simp at h
    | cons x xs =>
      simp only [List.drop_succ_cons, List.get_cons_succ]
      have h' : i < (xs.drop k).length := by simp [List.length_drop] at h ⊢; omega
      rw [ih xs i h']
      congr 1
      omega

/-- Tool results matched by toolResultsMatch have role "tool" -/
theorem toolResultsMatch_role (ids : List String) (msgs : List ChatMessage) (i : Nat)
    (hMatch : toolResultsMatch ids msgs = true) (hi : i < ids.length) (hlen : i < msgs.length) :
    (msgs.get ⟨i, hlen⟩).role = "tool" := by
  induction ids generalizing msgs i with
  | nil => simp at hi
  | cons id restIds ih =>
    cases msgs with
    | nil => simp at hlen
    | cons m rest =>
      unfold toolResultsMatch at hMatch
      simp only [Bool.and_eq_true, beq_iff_eq] at hMatch
      cases i with
      | zero => exact hMatch.1.1
      | succ j =>
        have hj : j < restIds.length := by simp at hi; omega
        have hjlen : j < rest.length := by simp at hlen; omega
        exact ih rest j hMatch.2 hj hjlen

/-- If messagesProperlyFormed and role = "tool", then toolCalls = none -/
theorem messagesProperlyFormed_tool_noToolCalls (msgs : List ChatMessage) (i : Nat)
    (hProper : messagesProperlyFormed msgs = true) (hlen : i < msgs.length)
    (hRole : (msgs.get ⟨i, hlen⟩).role = "tool") :
    (msgs.get ⟨i, hlen⟩).toolCalls = none := by
  induction msgs generalizing i with
  | nil => simp at hlen
  | cons m rest ih =>
    unfold messagesProperlyFormed at hProper
    simp only [Bool.and_eq_true, Bool.or_eq_true, bne_iff_ne, ne_eq] at hProper
    cases i with
    | zero =>
      simp only [List.get_cons_zero] at hRole ⊢
      cases hProper.1 with
      | inl hne => exact absurd hRole hne
      | inr heq => simp only [beq_iff_eq] at heq; exact heq
    | succ j =>
      simp only [List.get_cons_succ] at hRole ⊢
      have hjlen : j < rest.length := by simp at hlen; omega
      exact ih hProper.2 hjlen hRole

/-- Helper: after processing tool results, the remainder is well-formed -/
theorem toolCallsWellFormed_after_tools (m : ChatMessage) (rest : List ChatMessage)
    (h : toolCallsWellFormed (m :: rest) = true) :
    ∃ k, toolCallsWellFormed (rest.drop k) = true := by
  unfold toolCallsWellFormed at h
  cases hm : m.toolCalls with
  | none =>
    simp only [hm] at h
    exact ⟨0, h⟩
  | some tcs =>
    simp only [hm, Bool.and_eq_true] at h
    exact ⟨(extractToolCallIds tcs).length, h.2⟩

/-- Suffixes of well-formed message lists are well-formed,
    provided all tool result messages have no tool_calls.

    Key insight: if we drop messages from the front, any assistant+tools
    we keep still has its tool results following (they weren't dropped).

    The `messagesProperlyFormed` precondition ensures tool results don't have
    nested tool calls, which is required for the k < ids.length case. -/
theorem toolCallsWellFormed_drop (msgs : List ChatMessage) (n : Nat)
    (h : toolCallsWellFormed msgs = true)
    (hProper : messagesProperlyFormed msgs = true) :
    toolCallsWellFormed (msgs.drop n) = true := by
  -- Induction on (msgs.length, n) with lexicographic ordering
  match msgs, n with
  | [], _ => simp [toolCallsWellFormed]
  | _ :: _, 0 => simp; exact h
  | m :: rest, k + 1 =>
    simp only [List.drop_succ_cons]
    -- Need: toolCallsWellFormed (rest.drop k) = true
    unfold toolCallsWellFormed at h
    unfold messagesProperlyFormed at hProper
    simp only [Bool.and_eq_true] at hProper
    have hProperRest : messagesProperlyFormed rest = true := hProper.2
    match hm : m.toolCalls with
    | none =>
      simp only [hm] at h
      exact toolCallsWellFormed_drop rest k h hProperRest
    | some tcs =>
      simp only [hm, Bool.and_eq_true] at h
      let ⟨_, hWf⟩ := h
      let ids := extractToolCallIds tcs
      if hk : k < ids.length then
        -- k < ids.length: rest.drop k still starts with (ids.length - k) tool results
        -- These tool results have toolCalls = none by hProper
        -- After those, we have rest.drop ids.length which is well-formed by hWf
        apply toolCallsWellFormed_of_drop (rest.drop k) (ids.length - k)
        · -- Show first (ids.length - k) elements have no tool calls
          intro i hi hlen
          -- Position i in (rest.drop k) is position (i + k) in rest
          have hik : i + k < ids.length := by omega
          have hlenRest : i + k < rest.length := by
            simp [List.length_drop] at hlen
            omega
          -- By toolResultsMatch_role, rest[i+k] has role "tool"
          have hRole : (rest.get ⟨i + k, hlenRest⟩).role = "tool" :=
            toolResultsMatch_role ids rest (i + k) h.1 hik hlenRest
          -- By messagesProperlyFormed_tool_noToolCalls, it has toolCalls = none
          have hNone : (rest.get ⟨i + k, hlenRest⟩).toolCalls = none :=
            messagesProperlyFormed_tool_noToolCalls rest (i + k) hProperRest hlenRest hRole
          -- Rewrite using get_drop
          rw [get_drop rest k i hlen]
          convert hNone using 2
          omega
        · -- Show (rest.drop k).drop (ids.length - k) is well-formed
          have heq : (rest.drop k).drop (ids.length - k) = rest.drop ids.length := by
            rw [List.drop_drop]
            congr 1
            omega
          rw [heq]
          exact hWf
      else
        -- k ≥ ids.length: dropped past all tool results
        have hge : ids.length ≤ k := Nat.not_lt.mp hk
        have heq : rest.drop k = (rest.drop ids.length).drop (k - ids.length) := by
          rw [List.drop_drop, Nat.add_sub_cancel' hge]
        rw [heq]
        have hProperDrop : messagesProperlyFormed (rest.drop ids.length) = true :=
          messagesProperlyFormed_drop rest ids.length hProperRest
        exact toolCallsWellFormed_drop (rest.drop ids.length) (k - ids.length) hWf hProperDrop
termination_by msgs.length

/-- A valid condenser preserves tool call well-formedness:
    if the input has all tool calls matched with their results,
    the condensed output must also have this property.

    This is Property A: well-formed in → well-formed out.

    Requires messagesProperlyFormed (tool results don't have nested tool_calls),
    which is always true for messages constructed via ChatMessage.toolResult. -/
theorem condense_preserves_wellFormed (msgs : List ChatMessage) (budget : Nat)
    (h : toolCallsWellFormed msgs = true)
    (hProper : messagesProperlyFormed msgs = true) :
    toolCallsWellFormed (condense msgs budget).messages = true := by
  -- The result is a suffix (msgs.drop n for some n)
  obtain ⟨n, hSuffix⟩ := takeRecentUnderBudget_is_suffix msgs budget
  simp only [condense, hSuffix]
  exact toolCallsWellFormed_drop msgs n h hProper

/-! ## Usage Example -/

#eval messageTokens (ChatMessage.text "user" "Hello, world!")
#eval messageTokens (ChatMessage.text "system" "You are a helpful assistant.")

def exampleMsgs : List ChatMessage :=
  [ ChatMessage.text "system" "You are a helpful assistant."
  , ChatMessage.text "user" "What is 2+2?"
  , ChatMessage.text "assistant" "2+2 equals 4."
  , ChatMessage.text "user" "Thanks!" ]

#eval totalTokens exampleMsgs
#eval (condense exampleMsgs 100).messages.length  -- should keep all
#eval (condense exampleMsgs 20).messages.length   -- should keep fewer

end Condenser
