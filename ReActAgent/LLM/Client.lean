/-
# LLM Client

OpenAI-compatible API client for LLM communication.
-/

import ReActAgent.LLM.Json
import ReActAgent.LLM.Http

namespace LLM

/-- A chat message for the OpenAI API. -/
structure ChatMessage where
  role : String
  content : String

/-- Convert ChatMessage to JSON. -/
def ChatMessage.toJson (m : ChatMessage) : String :=
  Json.object [("role", Json.string m.role), ("content", Json.string m.content)]

/-- Configuration for LLM API. -/
structure Config where
  endpoint : String
  model : String
  apiKey : String := ""

/-- Call LLM API with a list of messages. -/
def call (cfg : Config) (messages : List ChatMessage) : IO String := do
  let messagesJson := Json.array (messages.map ChatMessage.toJson)
  let body := Json.object [
    ("model", Json.string cfg.model),
    ("messages", messagesJson)
  ]
  let headers := [
    ("Content-Type", "application/json")
  ] ++ (if cfg.apiKey.isEmpty then [] else [("Authorization", s!"Bearer {cfg.apiKey}")])
  let response ← Http.post cfg.endpoint body headers
  return response

/-- Extract content from OpenAI-style JSON response (simple parsing). -/
def extractContent (response : String) : IO String := do
  -- Simple extraction: find "content": "..." pattern
  -- This is fragile but avoids needing a full JSON parser
  let contentKey := "\"content\":"
  match response.splitOn contentKey with
  | _ :: rest :: _ =>
      let afterKey := rest.trimLeft
      if afterKey.startsWith "\"" then
        let inner := afterKey.drop 1
        -- Find closing quote (not escaped)
        let mut result := ""
        let mut escaped := false
        for c in inner.toList do
          if escaped then
            match c with
            | 'n' => result := result.push '\n'
            | 'r' => result := result.push '\r'
            | 't' => result := result.push '\t'
            | _ => result := result.push c
            escaped := false
          else if c == '\\' then
            escaped := true
          else if c == '"' then
            return result
          else
            result := result.push c
        return result
      else
        throw <| IO.userError s!"Expected string after content key, got: {afterKey.take 50}"
  | _ => throw <| IO.userError s!"Could not find content in response: {response.take 200}"

end LLM
