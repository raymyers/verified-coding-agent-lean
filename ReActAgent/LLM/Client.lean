/-
# LLM Client

OpenAI-compatible API client for LLM communication.
-/

import ReActAgent.LLM.Json
import ReActAgent.LLM.Http

namespace LLM

open Lean (Json ToJson FromJson)

/-- A chat message for the OpenAI API. -/
structure ChatMessage where
  role : String
  content : String
  deriving Repr

instance : ToJson ChatMessage where
  toJson m := Json.mkObj [("role", m.role), ("content", m.content)]

/-- Configuration for LLM API. -/
structure Config where
  endpoint : String
  model : String
  apiKey : String := ""

/-- Call LLM API with a list of messages. -/
def call (cfg : Config) (messages : List ChatMessage) : IO String := do
  let messagesJson := mkArr (messages.map ToJson.toJson)
  let body := mkObj [
    ("model", cfg.model),
    ("messages", messagesJson)
  ]
  let headers := [
    ("Content-Type", "application/json")
  ] ++ (if cfg.apiKey.isEmpty then [] else [("Authorization", s!"Bearer {cfg.apiKey}")])
  let response ← Http.post cfg.endpoint (render body) headers
  return response

/-- Extract content from OpenAI-style JSON response. -/
def extractContent (response : String) : IO String := do
  match Json.parse response with
  | .error e => throw <| IO.userError s!"Failed to parse JSON: {e}"
  | .ok json =>
      -- Navigate: .choices[0].message.content
      match json.getObjValAs? (Array Json) "choices" with
      | .error _ => throw <| IO.userError s!"Missing 'choices' in response: {response.take 200}"
      | .ok choices =>
          if h : choices.size > 0 then
            let firstChoice := choices[0]
            match firstChoice.getObjValAs? Json "message" with
            | .error _ => throw <| IO.userError s!"Missing 'message' in choice"
            | .ok message =>
                match message.getObjValAs? String "content" with
                | .error _ => throw <| IO.userError s!"Missing 'content' in message"
                | .ok content => return content
          else
            throw <| IO.userError "Empty 'choices' array in response"

end LLM
