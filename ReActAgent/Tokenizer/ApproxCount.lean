/-
# Approximate Token Counting

Simple approximation: 4 characters ≈ 1 token.

This is a common rule of thumb for LLM token estimation:
- English text averages ~4 chars/token
- Code tends to be slightly higher (3-5 chars/token)
- Good enough for budget estimation in condensers

For exact counts, use the API's token counting endpoint.
-/

namespace Tokenizer

/-- Approximate token count: 4 characters = 1 token (rounded up) -/
def approxTokenCount (s : String) : Nat :=
  (s.length + 3) / 4

/-- Approximate token count for ByteArray -/
def approxTokenCountBytes (bs : ByteArray) : Nat :=
  (bs.size + 3) / 4

/-- Check if content is under a token budget -/
def underBudget (s : String) (maxTokens : Nat) : Bool :=
  approxTokenCount s ≤ maxTokens

/-- Estimate tokens remaining in budget after content -/
def remainingBudget (s : String) (maxTokens : Nat) : Int :=
  maxTokens - approxTokenCount s

-- Examples
#eval approxTokenCount ""           -- 0
#eval approxTokenCount "hi"         -- 1 (2 chars → 1 token)
#eval approxTokenCount "hello"      -- 2 (5 chars → 2 tokens)
#eval approxTokenCount "hello world" -- 3 (11 chars → 3 tokens)
#eval approxTokenCount "The quick brown fox jumps over the lazy dog."
  -- 11 (44 chars → 11 tokens)

-- Budget checks
#eval underBudget "hello" 10        -- true
#eval underBudget "hello" 1         -- false
#eval remainingBudget "hello" 10    -- 8

end Tokenizer
