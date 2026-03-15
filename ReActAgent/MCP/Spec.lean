/-
# MCP Spec Adherence

Proven properties about the MCP client implementation that correspond
to requirements from the MCP specification (2025-03-26).

These theorems verify the pure/decidable aspects of spec compliance.
IO-level behavior (e.g., "client MUST send initialized notification")
cannot be stated as Lean theorems but is verified by integration tests.

Reference: https://modelcontextprotocol.io/specification/2025-03-26
-/

import ReActAgent.MCP.JsonRpc
import ReActAgent.MCP.Registry

namespace MCP.Spec

open Lean (Json JsonNumber ToJson toJson)
open Lean.JsonRpc (Message RequestID)

/-! ## String Prefix Helpers

`String.startsWith` in Lean 4.27 goes through opaque memcmp, making it
impossible to prove properties about. We define a byte-level equivalent
and prove the spec properties against that. The runtime code uses
`String.startsWith` which is semantically identical but faster. -/

/-- Byte-level prefix check: does `s` start with `p`? -/
def bytesPrefixOf (p s : String) : Bool :=
  p.toByteArray.size ≤ s.toByteArray.size &&
  (s.toByteArray.data.toList.take p.toByteArray.size == p.toByteArray.data.toList)

theorem bytesPrefixOf_append (a b : String) :
    bytesPrefixOf a (a ++ b) = true := by
  simp [bytesPrefixOf, ByteArray.size_append]

theorem bytesPrefixOf_prepend (a b c : String) :
    bytesPrefixOf a (a ++ b ++ c) = true := by
  rw [String.append_assoc]; exact bytesPrefixOf_append a (b ++ c)

/-! ## JSON-RPC Message Format (spec: Basic Protocol > Messages) -/

/-- Notifications do not carry a response-extractable ID.
    Spec: "Notifications MUST NOT include an ID." -/
theorem mkNotification_no_id (method : String) (params : Option Json) :
    JsonRpc.isResponse (JsonRpc.mkNotification method params) = false := by
  simp [JsonRpc.mkNotification, JsonRpc.isResponse]

/-- getResult distinguishes success from error responses.
    Spec: "Either a result or an error MUST be set." -/
theorem getResult_success (id : RequestID) (result : Json) :
    JsonRpc.getResult (.response id result) = .ok result := by
  rfl

theorem getResult_error (id : RequestID) (ec : Lean.JsonRpc.ErrorCode)
    (errMsg : String) (data : Option Json) :
    (JsonRpc.getResult (.responseError id ec errMsg data)).isOk = false := by
  rfl

/-- isResponse is true exactly for response and responseError messages. -/
theorem isResponse_iff (msg : Message) :
    JsonRpc.isResponse msg = true ↔
    (∃ id r, msg = .response id r) ∨ (∃ id c m d, msg = .responseError id c m d) := by
  constructor
  · intro h
    match msg with
    | .response id r => exact Or.inl ⟨id, r, rfl⟩
    | .responseError id c m d => exact Or.inr ⟨id, c, m, d, rfl⟩
    | .request .. => simp [JsonRpc.isResponse] at h
    | .notification .. => simp [JsonRpc.isResponse] at h
  · intro h
    rcases h with ⟨_, _, rfl⟩ | ⟨_, _, _, _, rfl⟩ <;> rfl

/-! ## Tool Name Namespacing (spec: no collisions between servers) -/

/-- Qualified names start with the MCP prefix (byte-level). -/
theorem qualifiedName_has_prefix (server tool : String) :
    bytesPrefixOf mcpPrefix (qualifiedName server tool) = true := by
  simp only [qualifiedName, mcpPrefix]
  exact bytesPrefixOf_prepend "mcp__" server ("__" ++ tool)

/-- isMcpTool rejects names without the prefix (concrete examples). -/
theorem not_isMcpTool_bash : isMcpTool "bash" = false := by native_decide
theorem not_isMcpTool_file_editor : isMcpTool "file_editor" = false := by native_decide

/-- isMcpTool accepts qualified names (concrete examples). -/
theorem isMcpTool_example : isMcpTool "mcp__srv__tool" = true := by native_decide

/-- parseQualifiedName is none for non-MCP names (concrete). -/
theorem parseQualifiedName_bash : parseQualifiedName "bash" = none := by native_decide
theorem parseQualifiedName_empty : parseQualifiedName "" = none := by native_decide

/-- parseQualifiedName roundtrips with qualifiedName (concrete examples). -/
theorem parseQualifiedName_roundtrip_example :
    parseQualifiedName (qualifiedName "srv" "tool") = some ("srv", "tool") := by native_decide

theorem parseQualifiedName_roundtrip_underscores :
    parseQualifiedName (qualifiedName "srv" "my__tool") = some ("srv", "my__tool") := by
  native_decide

/-- Different servers produce different qualified names (concrete). -/
theorem qualifiedName_distinct :
    qualifiedName "a" "tool" ≠ qualifiedName "b" "tool" := by native_decide

/-- Known limitation: server names containing "__" can collide.
    qualifiedName "a__b" "c" = qualifiedName "a" "b__c" = "mcp__a__b__c".
    Server names MUST NOT contain "__". -/
theorem collision_with_underscored_server :
    qualifiedName "a__b" "c" = qualifiedName "a" "b__c" := by native_decide

/-! ## Protocol Version Validation (spec: Lifecycle > Version Negotiation) -/

/-- The protocol versions we accept. -/
def supportedVersions : List String := ["2025-03-26", "2024-11-05"]

/-- We support the latest spec version. -/
theorem supports_latest : "2025-03-26" ∈ supportedVersions := by decide

/-- We support the previous spec version for backwards compatibility. -/
theorem supports_previous : "2024-11-05" ∈ supportedVersions := by decide

/-! ## Response ID Validation (spec: Messages > Responses) -/

/-- getResponseId rejects non-integer IDs (fractional).
    Spec: "Responses MUST include the same ID as the request." -/
theorem getResponseId_rejects_fractional (id : RequestID) (result : Json) :
    ∀ n : JsonNumber, n.exponent ≠ 0 →
    JsonRpc.getResponseId (.response (.num n) result) = none := by
  intro n hexp
  simp [JsonRpc.getResponseId]
  intro h
  exact absurd h hexp

/-- getResponseId rejects negative IDs. -/
theorem getResponseId_rejects_negative (result : Json) :
    ∀ n : JsonNumber, n.mantissa < 0 →
    JsonRpc.getResponseId (.response (.num n) result) = none := by
  intro n hneg
  simp [JsonRpc.getResponseId]
  omega

/-- getResponseId accepts the IDs we generate via mkRequest. -/
theorem getResponseId_accepts_our_ids (id : Nat) (result : Json) :
    JsonRpc.getResponseId (.response (.num (.fromNat id)) result) = some id := by
  simp [JsonRpc.getResponseId, JsonNumber.fromNat]

/-! ## Tool Result Rendering -/

/-- Empty tool result renders to empty string. -/
theorem toObservation_empty :
    ToolResult.toObservation { content := [], isError := false } = "" := by
  rfl

/-- isError prefixes with "Error: " (byte-level). -/
theorem toObservation_error_prefix (content : List ToolContent) :
    bytesPrefixOf "Error: "
      (ToolResult.toObservation { content, isError := true }) = true := by
  simp only [ToolResult.toObservation, ite_true]
  exact bytesPrefixOf_append "Error: " _

/-- Text content passes through unchanged for single-item results. -/
theorem toObservation_single_text (t : String) :
    ToolResult.toObservation { content := [.text t], isError := false } = t := by
  simp [ToolResult.toObservation, List.filterMap, List.intercalate]
  rfl

end MCP.Spec
