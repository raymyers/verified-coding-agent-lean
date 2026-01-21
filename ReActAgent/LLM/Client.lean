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

/-! ## LLM Response -/

/-- Parsed LLM response - either content or tool calls. -/
inductive Response where
  | content (text : String)
  | toolCalls (calls : Array ToolCall) (raw : Array Json)

/-! ## Configuration -/

/-- Configuration for LLM API. -/
structure Config where
  endpoint : String
  model : String
  apiKey : String := ""

/-! ## API Calls -/

/-- Call LLM API with messages and optional tools. -/
def call (cfg : Config) (messages : List ChatMessage) (tools : List ToolFunction := [])
    : IO String := do
  let messagesJson := mkArr (messages.map ToJson.toJson)
  let basePairs : List (String × Json) := [
    ("model", cfg.model),
    ("messages", messagesJson)
  ]
  let pairs := if tools.isEmpty then basePairs
    else basePairs ++ [
      ("tools", Json.arr (tools.map ToolFunction.toJson).toArray),
      ("tool_choice", "auto")
    ]
  let body := mkObj pairs
  let headers := [
    ("Content-Type", "application/json")
  ] ++ (if cfg.apiKey.isEmpty then [] else [("Authorization", s!"Bearer {cfg.apiKey}")])
  let response ← Http.post cfg.endpoint (render body) headers
  return response

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
                    let toolCalls := toolCallsJson.filterMap ToolCall.fromJson?
                    if toolCalls.isEmpty then
                      throw <| IO.userError "Failed to parse tool calls"
                    return .toolCalls toolCalls toolCallsJson
                | .error _ =>
                    -- Fall back to content
                    match message.getObjValAs? String "content" with
                    | .ok content => return .content content
                    | .error _ => throw <| IO.userError "No content or tool_calls in response"
          else
            throw <| IO.userError "Empty 'choices' array in response"

end LLM
