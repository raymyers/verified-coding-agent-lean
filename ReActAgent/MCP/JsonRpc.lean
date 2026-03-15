/-
# JSON-RPC 2.0

Re-exports Lean's built-in JSON-RPC types and adds MCP-specific helpers.
Messages are newline-delimited JSON over stdio.
-/

import Lean.Data.JsonRpc

namespace MCP.JsonRpc

open Lean (Json JsonNumber ToJson toJson FromJson fromJson?)
open Lean.JsonRpc (Message RequestID ErrorCode)

/-- Convert a Json value to Structured (for request params). -/
private def jsonToStructured (j : Json) : Option Json.Structured :=
  match j with
  | .obj m => some (.obj m)
  | .arr a => some (.arr a)
  | _ => none

/-- Create a JSON-RPC request message. -/
def mkRequest (id : Nat) (method : String) (params : Option Json := none) : Message :=
  .request (.num (.fromNat id)) method (params.bind jsonToStructured)

/-- Create a JSON-RPC notification message. -/
def mkNotification (method : String) (params : Option Json := none) : Message :=
  .notification method (params.bind jsonToStructured)

/-- Extract the result JSON from a response, or an error description. -/
def getResult (msg : Message) : Except String Json :=
  match msg with
  | .response _ result => .ok result
  | .responseError _ code errMsg _ =>
    .error s!"JSON-RPC error ({toJson code}): {errMsg}"
  | _ => .error "Expected a response message"

/-- Extract the request ID from a response.
    Rejects non-integer IDs (exponent must be 0). -/
def getResponseId (msg : Message) : Option Nat :=
  match msg with
  | .response (.num n) _ =>
    if n.exponent == 0 && n.mantissa ≥ 0 then some n.mantissa.toNat else none
  | .responseError (.num n) _ _ _ =>
    if n.exponent == 0 && n.mantissa ≥ 0 then some n.mantissa.toNat else none
  | _ => none

/-- Check if a message is a response (vs request/notification). -/
def isResponse (msg : Message) : Bool :=
  match msg with
  | .response .. => true
  | .responseError .. => true
  | _ => false

end MCP.JsonRpc
