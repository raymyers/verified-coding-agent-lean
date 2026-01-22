#!/bin/bash
# Extract the relevant subset of the OpenAPI spec for our chat completions client.
# This creates spec/chat-completions-subset.json which documents what fields we depend on.
#
# Usage:
#   ./scripts/extract-api-spec.sh                    # Use cached full spec
#   ./scripts/extract-api-spec.sh --update           # Fetch latest spec first
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_DIR="$SCRIPT_DIR/../spec"
FULL_SPEC="$SPEC_DIR/litellm-openapi.json"
SUBSET_SPEC="$SPEC_DIR/chat-completions-subset.json"

mkdir -p "$SPEC_DIR"

# Update full spec if requested
if [ "$1" = "--update" ]; then
    echo "Fetching latest OpenAPI spec..."
    curl -s https://litellm-api.up.railway.app/openapi.json > "$FULL_SPEC"
    echo "Saved to: $FULL_SPEC"
fi

if [ ! -f "$FULL_SPEC" ]; then
    echo "Full spec not found. Fetching..."
    curl -s https://litellm-api.up.railway.app/openapi.json > "$FULL_SPEC"
fi

echo "Extracting chat completions subset..."

jq '{
  spec_version: .info.version,
  source: "https://litellm-api.up.railway.app/openapi.json",
  extracted: (now | strftime("%Y-%m-%d")),

  request: {
    required: ["model", "messages"],
    optional_we_use: ["tools", "tool_choice"]
  },

  messages: {
    user: {
      required: .components.schemas.ChatCompletionUserMessage.required,
      role_value: .components.schemas.ChatCompletionUserMessage.properties.role.const
    },
    system: {
      required: .components.schemas.ChatCompletionSystemMessage.required,
      role_value: .components.schemas.ChatCompletionSystemMessage.properties.role.const
    },
    assistant: {
      required: .components.schemas.ChatCompletionAssistantMessage.required,
      role_value: .components.schemas.ChatCompletionAssistantMessage.properties.role.const,
      optional_fields: ["content", "tool_calls"]
    },
    tool: {
      required: .components.schemas.ChatCompletionToolMessage.required,
      role_value: .components.schemas.ChatCompletionToolMessage.properties.role.const
    }
  }
}' "$FULL_SPEC" > "$SUBSET_SPEC"

echo "Saved to: $SUBSET_SPEC"
echo ""
cat "$SUBSET_SPEC"
