/-
# HTTP Client

HTTP client implementation using curl subprocess.
-/

namespace LLM.Http

/-- Make an HTTP POST request using curl subprocess. -/
def post (url : String) (body : String) (headers : List (String × String)) : IO String := do
  let headerArgs := headers.flatMap fun (k, v) => ["-H", s!"{k}: {v}"]
  let args : Array String := #["-s", "-X", "POST"] ++ headerArgs.toArray ++ #["-d", body, url]
  let output ← IO.Process.output { cmd := "curl", args := args }
  if output.exitCode != 0 then
    throw <| IO.userError s!"curl failed (exit {output.exitCode}): {output.stderr}"
  return output.stdout

end LLM.Http
