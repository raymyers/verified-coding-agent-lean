/-
# JSON Helpers

JSON serialization using Lean.Data.Json.
-/

import Lean.Data.Json

namespace LLM

open Lean (Json ToJson FromJson)

/-- Re-export Lean.Json for convenience. -/
abbrev Json := Lean.Json

/-- Build a JSON object from key-value pairs. -/
def mkObj (pairs : List (String × Json)) : Json :=
  Json.mkObj pairs

/-- Convert a list to a JSON array. -/
def mkArr (items : List Json) : Json :=
  Json.arr items.toArray

/-- Render JSON to a compact string. -/
def render (j : Json) : String :=
  j.compress

end LLM
