/-
# Tool Executor

Executes agent tools (bash, read_file, write_file, file_editor) and returns observations.
-/

import Lean.Data.Json

namespace Tools

open Lean (Json)

/-! ## File Editor Helpers -/

/-- Maximum number of lines before output is clipped. -/
def maxOutputLines : Nat := 500

/-- Clip long output and append a marker if truncated. -/
def clipOutput (output : String) : String :=
  let lines := output.splitOn "\n"
  if lines.length > maxOutputLines then
    let clipped := lines.take maxOutputLines
    "\n".intercalate clipped ++ "\n<response clipped>"
  else
    output

/-- Format a line number with padding and tab. -/
def fmtLine (num : Nat) (line : String) : String :=
  let pad := if num < 10 then "     " else if num < 100 then "    " else if num < 1000 then "   " else "  "
  s!"{pad}{num}\t{line}"

/-- Number lines starting from a given offset. -/
def numberLines (lines : List String) (startNum : Nat := 1) : List String :=
  lines.zipIdx startNum |>.map fun (line, num) => fmtLine num line

/-- Add line numbers to content (like `cat -n`). -/
private def addLineNumbers (content : String) : String :=
  let lines := content.splitOn "\n"
  "\n".intercalate (numberLines lines)

/-- Add line numbers to a range of lines (1-indexed, inclusive). -/
private def addLineNumbersRange (content : String) (startLine endLine : Int) : Except String String := do
  let lines := content.splitOn "\n"
  let totalLines := lines.length
  if totalLines == 0 then
    return "(empty file)"
  let startIdx := if startLine < 1 then 0 else startLine.toNat - 1
  let endIdx := if endLine < 0 then totalLines - 1 else endLine.toNat - 1
  if startIdx >= totalLines then
    throw s!"Invalid view_range: start line {startLine} is beyond the file length ({totalLines} lines)"
  let endIdx := min endIdx (totalLines - 1)
  if startIdx > endIdx then
    throw s!"Invalid view_range: start line {startLine} is after end line {endLine}"
  let selectedLines := lines.drop startIdx |>.take (endIdx - startIdx + 1)
  return "\n".intercalate (numberLines selectedLines (startIdx + 1))

/-- View a file with line numbers or list a directory. -/
private def fileView (path : String) (viewRange : Option (Int × Int)) : IO String := do
  let pathObj : System.FilePath := path
  let isDir ← pathObj.isDir
  if isDir then
    -- List directory (non-hidden, up to 2 levels)
    let output ← IO.Process.output {
      cmd := "find"
      args := #[path, "-maxdepth", "2", "-not", "-name", ".*", "-not", "-path", "*/.*"]
    }
    return clipOutput output.stdout
  else
    let result ← IO.FS.readFile path |>.toBaseIO
    match result with
    | .error e => return s!"Error reading file: {e}"
    | .ok content =>
      match viewRange with
      | none => return clipOutput (addLineNumbers content)
      | some (startLine, endLine) =>
        match addLineNumbersRange content startLine endLine with
        | .ok s => return clipOutput s
        | .error e => return s!"Error: {e}"

/-- Create a new file (only if it doesn't already exist). -/
private def fileCreate (path : String) (fileText : String) : IO String := do
  let pathObj : System.FilePath := path
  let exists_ ← pathObj.pathExists
  if exists_ then
    return s!"Error: File already exists at: {path}. Cannot overwrite files using command `create`."
  else
    -- Check that the parent directory exists
    match pathObj.parent with
    | some parentDir =>
      let parentExists ← parentDir.pathExists
      if !parentExists then
        return s!"Error: Directory {parentDir} does not exist. Please create it first or verify the path."
      pure ()
    | none => pure ()
    let result ← (IO.FS.writeFile path fileText) |>.toBaseIO
    match result with
    | .ok _ => return s!"File created successfully at: {path}"
    | .error e => return s!"Error creating file: {e}"

/-- Save backup before mutating a file. -/
private def saveBackup (path : String) : IO Unit := do
  let backupPath := path ++ ".file_editor_backup"
  let content ← IO.FS.readFile path
  IO.FS.writeFile backupPath content

/-- Show a numbered snippet of lines around a region. -/
private def showSnippet (path : String) (content : String) (around : Nat) (span : Nat) : String :=
  let allLines := content.splitOn "\n"
  let snippetStart := if around > 5 then around - 5 else 0
  let snippetEnd := min (around + span + 5) allLines.length
  let snippet := allLines.drop snippetStart |>.take (snippetEnd - snippetStart)
  let snippetStr := "\n".intercalate (numberLines snippet (snippetStart + 1))
  s!"The file {path} has been edited. Here's the result of running `cat -n` on a snippet of the edited file:\n{snippetStr}\n"

/-- Replace an exact string in a file. Fails if not found or not unique. -/
private def fileStrReplace (path : String) (oldStr newStr : String) : IO String := do
  let result ← IO.FS.readFile path |>.toBaseIO
  match result with
  | .error e => return s!"Error reading file: {e}"
  | .ok content =>
    if oldStr == newStr then
      return "Error: new_str and old_str must be different"
    -- Count occurrences
    let parts := content.splitOn oldStr
    let count := parts.length - 1
    if count == 0 then
      return s!"Error: No match found for old_str in {path}. Make sure the old_str is an exact match of the content including whitespace."
    if count > 1 then
      return s!"Error: Found {count} matches for old_str in {path}. The old_str must uniquely identify a single location. Include more context to make it unique."
    -- Exactly one match - save backup and replace
    saveBackup path
    let newContent := parts.head! ++ newStr ++ parts.tail!.head!
    let writeResult ← (IO.FS.writeFile path newContent) |>.toBaseIO
    match writeResult with
    | .ok _ =>
      let prefixLines := parts.head!.splitOn "\n"
      let replacementStart := prefixLines.length
      let newStrLineCount := (newStr.splitOn "\n").length
      return showSnippet path newContent replacementStart newStrLineCount
    | .error e => return s!"Error writing file: {e}"

/-- Insert text after a given line number (0 = beginning of file). -/
private def fileInsert (path : String) (insertLine : Nat) (newStr : String) : IO String := do
  let result ← IO.FS.readFile path |>.toBaseIO
  match result with
  | .error e => return s!"Error reading file: {e}"
  | .ok content =>
    let lines := content.splitOn "\n"
    if insertLine > lines.length then
      return s!"Error: insert_line {insertLine} is beyond the file length ({lines.length} lines)"
    saveBackup path
    let before := lines.take insertLine
    let after := lines.drop insertLine
    let newLines := before ++ newStr.splitOn "\n" ++ after
    let newContent := "\n".intercalate newLines
    let writeResult ← (IO.FS.writeFile path newContent) |>.toBaseIO
    match writeResult with
    | .ok _ =>
      let insertedLineCount := (newStr.splitOn "\n").length
      return showSnippet path newContent insertLine insertedLineCount
    | .error e => return s!"Error writing file: {e}"

/-- Undo the last edit to a file by restoring from backup. -/
private def fileUndoEdit (path : String) : IO String := do
  let backupPath := path ++ ".file_editor_backup"
  let backupObj : System.FilePath := backupPath
  let exists_ ← backupObj.pathExists
  if !exists_ then
    return s!"Error: No edit history found for {path}"
  else
    let result ← IO.FS.readFile backupPath |>.toBaseIO
    match result with
    | .error e => return s!"Error reading backup: {e}"
    | .ok content =>
      let writeResult ← (IO.FS.writeFile path content) |>.toBaseIO
      match writeResult with
      | .ok _ =>
        let removeResult ← (IO.FS.removeFile backupPath) |>.toBaseIO
        match removeResult with
        | .ok _ => return s!"Last edit to {path} undone successfully."
        | .error _ => return s!"Last edit to {path} undone successfully (backup retained)."
      | .error e => return s!"Error restoring file: {e}"

/-- Parse view_range from string like "11,20" or "11,-1". -/
private def parseViewRange (s : String) : Option (Int × Int) :=
  match s.splitOn "," with
  | [a, b] =>
    match (a.trimAscii.toString.toInt?, b.trimAscii.toString.toInt?) with
    | (some startVal, some endVal) => some (startVal, endVal)
    | _ => none
  | _ => none

/-- Execute the file_editor tool with JSON arguments. -/
private def executeFileEditor (argsStr : String) : IO String := do
  match Json.parse argsStr with
  | .error e => return s!"Error parsing file_editor arguments: {e}"
  | .ok json =>
    let command := json.getObjValAs? String "command" |>.toOption |>.getD ""
    let path := json.getObjValAs? String "path" |>.toOption |>.getD ""
    if path.isEmpty then
      return "Error: 'path' is required for all file_editor commands"
    match command with
    | "view" =>
      let viewRangeStr := json.getObjValAs? String "view_range" |>.toOption
      let viewRange := viewRangeStr.bind parseViewRange
      fileView path viewRange
    | "create" =>
      match json.getObjValAs? String "file_text" with
      | .ok fileText => fileCreate path fileText
      | .error _ => return "Error: 'file_text' is required for the create command"
    | "str_replace" =>
      match json.getObjValAs? String "old_str" with
      | .ok oldStr =>
        let newStr := json.getObjValAs? String "new_str" |>.toOption |>.getD ""
        fileStrReplace path oldStr newStr
      | .error _ => return "Error: 'old_str' is required for the str_replace command"
    | "insert" =>
      match json.getObjValAs? String "new_str" with
      | .ok newStr =>
        -- Try parsing insert_line as number from either int or string
        let insertLine := (json.getObjValAs? Nat "insert_line" |>.toOption).orElse
          fun _ => json.getObjValAs? String "insert_line" |>.toOption |>.bind (·.toNat?)
        match insertLine with
        | some line => fileInsert path line newStr
        | none => return "Error: 'insert_line' (a number) is required for the insert command"
      | .error _ => return "Error: 'new_str' is required for the insert command"
    | "undo_edit" => fileUndoEdit path
    | "" => return "Error: 'command' is required"
    | other => return s!"Error: Unknown command '{other}'. Expected: view, create, str_replace, insert, undo_edit"

/-! ## Main Executor -/

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
  | "file_editor" => executeFileEditor args
  | _ => return s!"Unknown tool: {name}"

/-! ## Pure Cores of Mutation Operations -/

/-- Pure core of str_replace: validate and perform string replacement. -/
def strReplace (content oldStr newStr : String) : Except String String :=
  if oldStr == newStr then
    .error "new_str and old_str must be different"
  else
    let parts := content.splitOn oldStr
    match parts with
    | [_] => .error "no match found"
    | [before, after] => .ok (before ++ newStr ++ after)
    | _ => .error "multiple matches"

/-- Pure core of insert: splice new text after a given line. -/
def insertAtLine (content : String) (insertLine : Nat) (newStr : String) : Except String String :=
  let lines := content.splitOn "\n"
  if insertLine > lines.length then
    .error s!"insert_line {insertLine} is beyond the file length ({lines.length} lines)"
  else
    let before := lines.take insertLine
    let after := lines.drop insertLine
    let newLines := before ++ newStr.splitOn "\n" ++ after
    .ok ("\n".intercalate newLines)

/-! ## Properties -/

/-- numberLines preserves the number of lines. -/
theorem numberLines_length (lines : List String) (startNum : Nat) :
    (numberLines lines startNum).length = lines.length := by
  simp [numberLines, List.length_map, List.length_zipIdx]

/-- clipOutput is identity when input has ≤ maxOutputLines lines. -/
theorem clipOutput_short (s : String) (h : (s.splitOn "\n").length ≤ maxOutputLines) :
    clipOutput s = s := by
  simp only [clipOutput, maxOutputLines] at h ⊢
  have : ¬ (s.splitOn "\n").length > 500 := by omega
  simp [this]

/-- In the non-clipped path, clipOutput returns the input unchanged. -/
theorem clipOutput_eq_or_clipped (s : String) :
    clipOutput s = s ∨
    clipOutput s = "\n".intercalate ((s.splitOn "\n").take maxOutputLines) ++
      "\n<response clipped>" := by
  simp only [clipOutput]
  split
  · right; rfl
  · left; rfl

/-- strReplace errors when old and new strings are equal. -/
theorem strReplace_eq_err (content s : String) :
    (strReplace content s s).isOk = false := by
  simp [strReplace, beq_self_eq_true, Except.isOk, Except.toBool]

/-- Successful strReplace decomposes the original content. -/
theorem strReplace_result (content oldStr newStr result : String)
    (h : strReplace content oldStr newStr = .ok result) :
    ∃ before after, content.splitOn oldStr = [before, after] ∧
    result = before ++ newStr ++ after := by
  simp only [strReplace] at h
  split at h
  · exact absurd h (by simp)
  · next hne =>
    match hparts : content.splitOn oldStr, h with
    | [before, after], h =>
      simp at h
      exact ⟨before, after, rfl, h.symm⟩

/-- strReplace succeeds iff oldStr ≠ newStr and oldStr occurs exactly once. -/
theorem strReplace_ok_iff (content oldStr newStr : String) :
    (strReplace content oldStr newStr).isOk = true ↔
    (oldStr == newStr) = false ∧ (content.splitOn oldStr).length = 2 := by
  constructor
  · -- Forward: isOk → conditions
    intro h
    unfold strReplace at h
    split at h
    · simp [Except.isOk, Except.toBool] at h
    · next hne =>
      constructor
      · simpa using hne
      · revert h
        match content.splitOn oldStr with
        | [_] => simp [Except.isOk, Except.toBool]
        | [_, _] => simp
        | _ :: _ :: _ :: _ => simp [Except.isOk, Except.toBool]
        | [] => simp [Except.isOk, Except.toBool]
  · -- Backward: conditions → isOk
    intro ⟨hne, hlen⟩
    unfold strReplace
    simp only [hne, ite_false]
    match hparts : content.splitOn oldStr, hlen with
    | [_, _], _ => simp [Except.isOk, Except.toBool]

/-- insertAtLine produces: original prefix ++ new content ++ original suffix. -/
theorem insertAtLine_result (content : String) (n : Nat) (newStr : String)
    (h : n ≤ (content.splitOn "\n").length) :
    insertAtLine content n newStr = .ok ("\n".intercalate
      ((content.splitOn "\n").take n ++
       newStr.splitOn "\n" ++
       (content.splitOn "\n").drop n)) := by
  simp only [insertAtLine]
  have : ¬ n > (content.splitOn "\n").length := by omega
  simp [this]

/-- insertAtLine result line count = original + inserted. -/
theorem insertAtLine_line_count (content : String) (n : Nat) (newStr : String)
    (h : n ≤ (content.splitOn "\n").length) :
    ((content.splitOn "\n").take n ++
     newStr.splitOn "\n" ++
     (content.splitOn "\n").drop n).length =
    (content.splitOn "\n").length + (newStr.splitOn "\n").length := by
  simp [List.length_append, List.length_take, List.length_drop]
  omega

/-- insertAtLine preserves the prefix (list-level). -/
theorem insertAtLine_take (content : String) (n : Nat) (newStr : String)
    (h : n ≤ (content.splitOn "\n").length) :
    ((content.splitOn "\n").take n ++
     newStr.splitOn "\n" ++
     (content.splitOn "\n").drop n).take n =
    (content.splitOn "\n").take n := by
  rw [List.append_assoc]
  rw [List.take_append_of_le_length (by simp [List.length_take]; omega)]
  simp [List.take_take, Nat.min_self]

/-- insertAtLine preserves the suffix (list-level). -/
theorem insertAtLine_drop (content : String) (n : Nat) (newStr : String)
    (h : n ≤ (content.splitOn "\n").length) :
    ((content.splitOn "\n").take n ++
     newStr.splitOn "\n" ++
     (content.splitOn "\n").drop n).drop
      (n + (newStr.splitOn "\n").length) =
    (content.splitOn "\n").drop n := by
  rw [List.append_assoc, ← List.append_assoc ((content.splitOn "\n").take n)]
  have hlen : ((content.splitOn "\n").take n ++ newStr.splitOn "\n").length =
    n + (newStr.splitOn "\n").length := by simp [List.length_append, List.length_take]; omega
  rw [show n + (newStr.splitOn "\n").length =
    ((content.splitOn "\n").take n ++ newStr.splitOn "\n").length from hlen.symm]
  exact List.drop_left

end Tools
