/-
# JSON Helpers

Simple JSON serialization utilities for LLM API communication.
-/

namespace LLM.Json

/-- Escape a string for JSON. -/
def escape (s : String) : String :=
  s.replace "\\" "\\\\"
   |>.replace "\"" "\\\""
   |>.replace "\n" "\\n"
   |>.replace "\r" "\\r"
   |>.replace "\t" "\\t"

/-- Build a JSON string value. -/
def string (s : String) : String := s!"\"{escape s}\""

/-- Build a JSON object from key-value pairs. -/
def object (pairs : List (String × String)) : String :=
  let inner := pairs.map (fun (k, v) => s!"\"{k}\": {v}") |> String.intercalate ", "
  s!"\{{inner}}"

/-- Build a JSON array. -/
def array (items : List String) : String :=
  s!"[{String.intercalate ", " items}]"

end LLM.Json
