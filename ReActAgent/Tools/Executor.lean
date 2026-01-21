/-
# Tool Executor

Executes agent tools (bash, read_file, write_file) and returns observations.
-/

namespace Tools

/-- Execute a tool and return observation. -/
def execute (workDir : String) (name : String) (args : String) : IO String := do
  match name with
  | "bash" =>
      let output ← IO.Process.output {
        cmd := "bash"
        args := #["-c", args]
        cwd := some workDir
      }
      if output.exitCode == 0 then
        return output.stdout
      else
        return s!"Error (exit {output.exitCode}): {output.stderr}\n{output.stdout}"
  | "read_file" =>
      let result ← IO.FS.readFile args |>.toBaseIO
      match result with
      | .ok content => return content
      | .error e => return s!"Error reading file: {e}"
  | "write_file" =>
      -- Parse "path content" from args
      match args.splitOn " " with
      | path :: rest =>
          let content := " ".intercalate rest
          let result ← (IO.FS.writeFile path content) |>.toBaseIO
          match result with
          | .ok _ => return s!"Successfully wrote to {path}"
          | .error e => return s!"Error writing file: {e}"
      | _ => return "Error: write_file requires <path> <content>"
  | _ => return s!"Unknown tool: {name}"

end Tools
