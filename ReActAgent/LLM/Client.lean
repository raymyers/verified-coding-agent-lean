/-
# LLM Client

OpenAI-compatible API client for LLM communication with tool calling support.
-/

import ReActAgent.LLM.Json
import ReActAgent.LLM.Http

namespace LLM

open Lean (Json ToJson FromJson)

/-! ## Message Types -/

/-- A chat message for the OpenAI API. -/
structure ChatMessage where
  role : String
  content : Option String := none
  toolCalls : Option (Array Json) := none
  toolCallId : Option String := none
  name : Option String := none

/-- Build a user or system message. -/
def ChatMessage.text (role content : String) : ChatMessage :=
  { role, content := some content }

/-- Build an assistant message with tool calls. -/
def ChatMessage.withToolCalls (toolCalls : Array Json) : ChatMessage :=
  { role := "assistant", toolCalls := some toolCalls }

/-- Build a tool result message. -/
def ChatMessage.toolResult (toolCallId name content : String) : ChatMessage :=
  { role := "tool", content := some content, toolCallId := some toolCallId, name := some name }

instance : ToJson ChatMessage where
  toJson m :=
    let pairs : List (String × Json) := [("role", Json.str m.role)]
    let pairs := match m.content with
      | some c => pairs ++ [("content", Json.str c)]
      | none => pairs
    let pairs := match m.toolCalls with
      | some tc => pairs ++ [("tool_calls", Json.arr tc)]
      | none => pairs
    let pairs := match m.toolCallId with
      | some id => pairs ++ [("tool_call_id", Json.str id)]
      | none => pairs
    let pairs := match m.name with
      | some n => pairs ++ [("name", Json.str n)]
      | none => pairs
    Json.mkObj pairs

/-! ## Tool Definitions -/

/-- A tool function parameter. -/
structure ToolParam where
  name : String
  type : String
  description : String
  enumValues : Option (List String) := none

/-- A tool function definition. -/
structure ToolFunction where
  name : String
  description : String
  parameters : List ToolParam
  required : List String

/-- Convert ToolFunction to JSON schema format. -/
def ToolFunction.toJson (f : ToolFunction) : Json :=
  let props := f.parameters.map fun p =>
    let baseObj : List (String × Json) := [
      ("type", p.type),
      ("description", p.description)
    ]
    let obj := match p.enumValues with
      | some vals => baseObj ++ [("enum", Json.arr (vals.map Json.str).toArray)]
      | none => baseObj
    (p.name, Json.mkObj obj)
  Json.mkObj [
    ("type", "function"),
    ("function", Json.mkObj [
      ("name", f.name),
      ("description", f.description),
      ("parameters", Json.mkObj [
        ("type", "object"),
        ("properties", Json.mkObj props),
        ("required", Json.arr (f.required.map Json.str).toArray)
      ])
    ])
  ]

/-! ## Tool Call Response -/

/-- A tool call from the LLM response. -/
structure ToolCall where
  id : String
  name : String
  arguments : String  -- JSON string of arguments
  deriving Repr

/-- Parse a tool call from JSON. -/
def ToolCall.fromJson? (j : Json) : Option ToolCall := do
  let id ← j.getObjValAs? String "id" |>.toOption
  let fn ← j.getObjValAs? Json "function" |>.toOption
  let name ← fn.getObjValAs? String "name" |>.toOption
  let args ← fn.getObjValAs? String "arguments" |>.toOption
  return { id, name, arguments := args }

/-- Extract tool call ID from JSON (returns "" if not found). -/
def ToolCall.idFromJson (j : Json) : String :=
  j.getObjValAs? String "id" |>.toOption |>.getD ""

/-- If fromJson? succeeds, idFromJson returns the same ID. -/
theorem ToolCall.idFromJson_eq_of_fromJson (j : Json) (tc : ToolCall)
    (h : ToolCall.fromJson? j = some tc) : ToolCall.idFromJson j = tc.id := by
  unfold fromJson? at h
  simp only [bind, Option.bind] at h
  -- Case split on each nested option
  cases hid : (j.getObjValAs? String "id").toOption with
  | none => simp [hid] at h
  | some id =>
    cases hfn : (j.getObjValAs? Json "function").toOption with
    | none => simp [hid, hfn] at h
    | some fn =>
      cases hname : (fn.getObjValAs? String "name").toOption with
      | none => simp [hid, hfn, hname] at h
      | some name =>
        cases hargs : (fn.getObjValAs? String "arguments").toOption with
        | none => simp [hid, hfn, hname, hargs] at h
        | some args =>
          -- h : some { id, name, arguments := args } = some tc
          simp [hid, hfn, hname, hargs] at h
          simp only [idFromJson, hid, Option.getD]
          rw [← h]

/-- Extract all tool call IDs from a JSON array. -/
def extractToolCallIds (toolCalls : Array Json) : List String :=
  toolCalls.toList.map ToolCall.idFromJson

/-! ## LLM Response -/

/-- A parsed tool call paired with its original JSON. -/
structure ParsedToolCall where
  call : ToolCall
  raw : Json
  consistent : ToolCall.idFromJson raw = call.id

/-- Parsed LLM response - either content or tool calls. -/
inductive Response where
  | content (text : String)
  | toolCalls (calls : Array ParsedToolCall)

/-! ## Configuration -/

/-- Configuration for LLM API. -/
structure Config where
  endpoint : String
  model : String
  apiKey : String := ""

/-! ## Request -/

/-- An LLM API request with messages and optional tools. -/
structure Request where
  messages : List ChatMessage
  tools : List ToolFunction := []

/-- Check if a list of messages starts with tool results matching the given IDs in order. -/
def toolResultsMatch (ids : List String) (messages : List ChatMessage) : Bool :=
  match ids, messages with
  | [], _ => true
  | id :: restIds, msg :: restMsgs =>
      msg.role == "tool" && msg.toolCallId == some id && toolResultsMatch restIds restMsgs
  | _ :: _, [] => false

/-- Check that all tool calls in a message list have matching tool results.
    For each assistant message with tool_calls, the immediately following messages
    must be tool results with matching IDs in the same order.

    Note: This is a Bool-valued predicate for decidability. -/
def toolCallsWellFormed : List ChatMessage → Bool
  | [] => true
  | msg :: rest =>
      match msg.toolCalls with
      | none => toolCallsWellFormed rest
      | some tcs =>
          let ids := extractToolCallIds tcs
          -- Check that rest starts with matching tool results, then recurse on remainder
          toolResultsMatch ids rest && toolCallsWellFormed (rest.drop ids.length)
termination_by msgs => msgs.length
decreasing_by
  all_goals simp_wf
  all_goals omega

/-- A request is valid if:
    1. It contains at least one non-system message (required by Anthropic API)
    2. All tool calls have matching tool results in order -/
def Request.valid (req : Request) : Prop :=
  (∃ m ∈ req.messages, m.role ≠ "system") ∧
  toolCallsWellFormed req.messages

/-! ## Request Validity Theorems -/

/-- Empty message list is well-formed. -/
theorem toolCallsWellFormed_nil : toolCallsWellFormed [] = true := by simp [toolCallsWellFormed]

/-- A message without tool calls preserves well-formedness. -/
theorem toolCallsWellFormed_cons_noToolCalls (msg : ChatMessage) (rest : List ChatMessage)
    (hno : msg.toolCalls = none) (hwf : toolCallsWellFormed rest = true) :
    toolCallsWellFormed (msg :: rest) = true := by
  simp only [toolCallsWellFormed, hno, hwf]

/-- A request with a user message is valid if the rest is well-formed. -/
theorem Request.valid_of_user (content : String) (rest : List ChatMessage)
    (tools : List ToolFunction) (hwf : toolCallsWellFormed rest = true) :
    Request.valid ⟨ChatMessage.text "user" content :: rest, tools⟩ := by
  constructor
  · exact ⟨ChatMessage.text "user" content, .head _, by simp [ChatMessage.text]⟩
  · simp only [toolCallsWellFormed, ChatMessage.text, hwf]

/-- A request with a user message and empty rest is valid. -/
theorem Request.valid_of_user_nil (content : String) (tools : List ToolFunction) :
    Request.valid ⟨[ChatMessage.text "user" content], tools⟩ := by
  constructor
  · exact ⟨ChatMessage.text "user" content, .head _, by simp [ChatMessage.text]⟩
  · simp only [toolCallsWellFormed, ChatMessage.text]

/-! ## API Calls -/

/-- Call LLM API with a request. -/
def call (cfg : Config) (req : Request) : IO String := do
  let messagesJson := mkArr (req.messages.map ToJson.toJson)
  let basePairs : List (String × Json) := [
    ("model", cfg.model),
    ("messages", messagesJson)
  ]
  let pairs := if req.tools.isEmpty then basePairs
    else basePairs ++ [
      ("tools", Json.arr (req.tools.map ToolFunction.toJson).toArray),
      ("tool_choice", "auto")
    ]
  let body := mkObj pairs
  let headers := [
    ("Content-Type", "application/json")
  ] ++ (if cfg.apiKey.isEmpty then [] else [("Authorization", s!"Bearer {cfg.apiKey}")])
  let response ← Http.post cfg.endpoint (render body) headers
  return response

/-- Parse a JSON array into ParsedToolCall pairs with consistency proofs. -/
def parseToolCalls (toolCallsJson : Array Json) : Array ParsedToolCall :=
  toolCallsJson.filterMap fun raw =>
    match h : ToolCall.fromJson? raw with
    | none => none
    | some call => some ⟨call, raw, ToolCall.idFromJson_eq_of_fromJson raw call h⟩

/-- Parse LLM response to extract content or tool calls. -/
def parseResponse (response : String) : IO Response := do
  match Json.parse response with
  | .error e => throw <| IO.userError s!"Failed to parse JSON: {e}"
  | .ok json =>
      match json.getObjValAs? (Array Json) "choices" with
      | .error _ => throw <| IO.userError s!"Missing 'choices' in response: {response.take 200}"
      | .ok choices =>
          if h : choices.size > 0 then
            let firstChoice := choices[0]
            match firstChoice.getObjValAs? Json "message" with
            | .error _ => throw <| IO.userError s!"Missing 'message' in choice"
            | .ok message =>
                -- Check for tool_calls first
                match message.getObjValAs? (Array Json) "tool_calls" with
                | .ok toolCallsJson =>
                    let toolCalls := parseToolCalls toolCallsJson
                    if toolCalls.isEmpty then
                      throw <| IO.userError "Failed to parse tool calls"
                    return .toolCalls toolCalls
                | .error _ =>
                    -- Fall back to content
                    match message.getObjValAs? String "content" with
                    | .ok content => return .content content
                    | .error _ => throw <| IO.userError "No content or tool_calls in response"
          else
            throw <| IO.userError "Empty 'choices' array in response"

end LLM
