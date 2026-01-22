/-
# OpenAI/LiteLLM API Specification Conformance

This module verifies our Client.lean implementation conforms to the OpenAPI spec.

## Spec Source
The constraints are derived from spec/chat-completions-subset.json, which is
extracted from the full OpenAPI spec at https://litellm-api.up.railway.app/openapi.json

To update: see scripts in spec/ directory.

## Verification Approach
We define predicates matching the spec requirements and use native_decide to
verify concrete message examples at compile time. If serialization breaks
conformance, the build fails.
-/

import ReActAgent.LLM.Client

namespace LLM.ApiSpec

open Lean (Json ToJson toJson)

/-! ## Spec Requirements (from spec/chat-completions-subset.json)

Request required fields: ["model", "messages"]
Request optional we use: ["tools", "tool_choice"]

Message schemas:
- user:      required ["role", "content"], role_value "user"
- system:    required ["role", "content"], role_value "system"
- assistant: required ["role"], role_value "assistant", optional ["content", "tool_calls"]
- tool:      required ["role", "content", "tool_call_id"], role_value "tool"
-/

/-! ## JSON Field Checkers -/

def hasField (j : Json) (field : String) : Bool :=
  j.getObjVal? field |>.isOk

def hasFieldStr (j : Json) (field value : String) : Bool :=
  match j.getObjValAs? String field with
  | .ok v => v == value
  | .error _ => false

def hasFieldArray (j : Json) (field : String) : Bool :=
  j.getObjValAs? (Array Json) field |>.isOk

/-! ## Message Validators (matching spec/chat-completions-subset.json) -/

/-- user: required ["role", "content"], role = "user" -/
def validUserMessage (j : Json) : Bool :=
  hasFieldStr j "role" "user" && hasField j "content"

/-- system: required ["role", "content"], role = "system" -/
def validSystemMessage (j : Json) : Bool :=
  hasFieldStr j "role" "system" && hasField j "content"

/-- assistant: required ["role"], role = "assistant", optional content or tool_calls -/
def validAssistantMessage (j : Json) : Bool :=
  hasFieldStr j "role" "assistant" &&
  (hasField j "content" || hasFieldArray j "tool_calls")

/-- tool: required ["role", "content", "tool_call_id"], role = "tool" -/
def validToolMessage (j : Json) : Bool :=
  hasFieldStr j "role" "tool" &&
  hasField j "content" &&
  hasField j "tool_call_id"

/-! ## Conformance Proofs

These theorems verify at compile time that our serialization produces valid JSON.
If any check fails, the build fails.
-/

theorem userMessage_conforms :
    validUserMessage (toJson (ChatMessage.text "user" "hello")) := by native_decide

theorem systemMessage_conforms :
    validSystemMessage (toJson (ChatMessage.text "system" "prompt")) := by native_decide

theorem assistantMessage_conforms :
    validAssistantMessage (toJson (ChatMessage.withToolCalls #[])) := by native_decide

theorem toolMessage_conforms :
    validToolMessage (toJson (ChatMessage.toolResult "id" "name" "result")) := by native_decide

def hasToolType (j : Json) (typeName : String) : Bool :=
  match j.getObjValAs? String "type" with
  | .ok v => v == typeName
  | .error _ => false

theorem toolFunction_conforms :
    hasToolType (ToolFunction.toJson {
      name := "test", description := "desc", parameters := [], required := []
    }) "function" := by native_decide

/-! ## Overall Conformance Result -/

/-- All message types produced by our Client.lean conform to the LiteLLM/OpenAI API spec.

This is the main result: our serialization produces valid JSON for all message types
used in chat completions with tool calling. -/
theorem litellm_api_conformance :
    -- User messages conform
    validUserMessage (toJson (ChatMessage.text "user" "hello")) ∧
    -- System messages conform
    validSystemMessage (toJson (ChatMessage.text "system" "prompt")) ∧
    -- Assistant messages with tool calls conform
    validAssistantMessage (toJson (ChatMessage.withToolCalls #[])) ∧
    -- Tool result messages conform
    validToolMessage (toJson (ChatMessage.toolResult "id" "name" "result")) ∧
    -- Tool function definitions conform
    hasToolType (ToolFunction.toJson {
      name := "test", description := "desc", parameters := [], required := []
    }) "function" :=
  ⟨userMessage_conforms, systemMessage_conforms, assistantMessage_conforms,
   toolMessage_conforms, toolFunction_conforms⟩

end LLM.ApiSpec
