# API Conformance Verification

This document explains how we verify that our LLM client conforms to the OpenAI/LiteLLM API.

## Files

```
spec/
  litellm-openapi.json       # Full OpenAPI spec (fetched from LiteLLM)
  chat-completions-subset.json  # Extracted subset we depend on

scripts/
  extract-api-spec.sh        # Extracts subset from full spec

ReActAgent/LLM/
  ApiSpec.lean              # Lean conformance checks
```

## How It Works

### 1. Extract the Spec Subset

We extract only the fields we actually use from the full OpenAPI spec:

```bash
./scripts/extract-api-spec.sh          # Extract from cached spec
./scripts/extract-api-spec.sh --update # Fetch latest spec first
```

This produces `spec/chat-completions-subset.json`:

```json
{
  "messages": {
    "user":      { "required": ["role", "content"], "role_value": "user" },
    "system":    { "required": ["role", "content"], "role_value": "system" },
    "assistant": { "required": ["role"], "optional_fields": ["content", "tool_calls"] },
    "tool":      { "required": ["role", "content", "tool_call_id"], "role_value": "tool" }
  }
}
```

### 2. Define Validators in Lean

`ReActAgent/LLM/ApiSpec.lean` defines validators matching the spec:

```lean
/-- user: required ["role", "content"], role = "user" -/
def validUserMessage (j : Json) : Bool :=
  hasFieldStr j "role" "user" && hasField j "content"

/-- tool: required ["role", "content", "tool_call_id"], role = "tool" -/
def validToolMessage (j : Json) : Bool :=
  hasFieldStr j "role" "tool" &&
  hasField j "content" &&
  hasField j "tool_call_id"
```

### 3. Compile-Time Verification

Concrete examples are verified via `native_decide`:

```lean
example : validUserMessage (toJson (ChatMessage.text "user" "hello")) := by native_decide
example : validToolMessage (toJson (ChatMessage.toolResult "id" "name" "result")) := by native_decide
```

**If serialization breaks conformance, the build fails.**

## Updating

When the upstream API changes:

1. Run `./scripts/extract-api-spec.sh --update`
2. Review changes in `spec/chat-completions-subset.json`
3. Update validators in `ApiSpec.lean` if needed
4. Build to verify: `lake build`

## Coverage

| Message Type | Required Fields | Verified |
|-------------|-----------------|----------|
| User | `role="user"`, `content` | ✓ |
| System | `role="system"`, `content` | ✓ |
| Assistant | `role="assistant"`, `content` or `tool_calls` | ✓ |
| Tool | `role="tool"`, `content`, `tool_call_id` | ✓ |
| Tool Definition | `type="function"`, `function.name` | ✓ |
