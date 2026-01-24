# Token Counting Reference

This document describes how tokens are counted for LLM API calls, with focus on Anthropic/Claude.

## How Strings Become Token Counts

### The Fundamental Problem

**Anthropic does not publish a local tokenizer for Claude 3+ models.**

Unlike OpenAI (which provides [tiktoken](https://github.com/openai/tiktoken)), Anthropic only offers:
1. A [legacy tokenizer](https://github.com/anthropics/anthropic-tokenizer-typescript) for pre-Claude-3 models (inaccurate for current models)
2. The official [Token Counting API](https://docs.anthropic.com/en/docs/build-with-claude/token-counting) - a server-side endpoint

### Official Approach: Anthropic's countTokens API

The only accurate way to count Claude tokens is via the API:

```python
import anthropic

client = anthropic.Anthropic()
response = client.messages.count_tokens(
    model="claude-sonnet-4-5",
    system="You are a scientist",
    messages=[{"role": "user", "content": "Hello, Claude"}],
)
print(response.input_tokens)  # e.g., 14
```

**Endpoint**: `POST https://api.anthropic.com/v1/messages/count_tokens`

**Key properties**:
- Free to use (separate rate limits from message creation)
- Accepts same structure as messages API (system, messages, tools, images, PDFs)
- Returns `{ "input_tokens": N }`
- Token count is an estimate; actual usage may differ slightly
- System-added tokens (for optimizations) are not billed

### LiteLLM's Approximation

Since LiteLLM needs offline token counting, it uses OpenAI's tiktoken as an approximation:

```python
def _get_count_function(model, custom_tokenizer=None):
    # For most models, falls back to tiktoken
    # Uses "o200k_base" for GPT-4o, "cl100k_base" for others
    encoding = tiktoken.get_encoding("cl100k_base")
    return lambda text: len(encoding.encode(text, disallowed_special=()))
```

**Warning**: This is inaccurate for Claude. Tokenizers are model-specific, and Claude uses a different vocabulary than GPT models. Use this only for rough estimates.

**Source**: [litellm/litellm_core_utils/token_counter.py](https://github.com/BerriAI/litellm/blob/8ac1d96d90d32cf4203009d5e5b694d19a148b95/litellm/litellm_core_utils/token_counter.py)

---

## Anthropic Content Block Types

From [litellm/types/llms/anthropic.py](https://github.com/BerriAI/litellm/blob/8ac1d96d90d32cf4203009d5e5b694d19a148b95/litellm/types/llms/anthropic.py):

### AnthropicMessagesToolUseParam

```python
class AnthropicMessagesToolUseParam(TypedDict, total=False):
    type: Required[Literal["tool_use"]]
    id: str
    name: str
    input: dict
    cache_control: Optional[Union[dict, ChatCompletionCachedContent]]
```

### AnthropicMessagesToolResultParam

```python
class AnthropicMessagesToolResultParam(TypedDict, total=False):
    type: Required[Literal["tool_result"]]
    tool_use_id: Required[str]
    is_error: bool
    content: Union[str, Iterable[...]]
    cache_control: Optional[Union[dict, ChatCompletionCachedContent]]
```

## Validation

The `_validate_anthropic_content` function determines which TypedDict applies based on the `type` field:

```python
def _validate_anthropic_content(content: Mapping[str, Any]) -> type:
    content_type = content.get("type")
    if not content_type:
        raise ValueError("Anthropic content missing required field: 'type'")

    mapping = {
        "tool_use": AnthropicMessagesToolUseParam,
        "tool_result": AnthropicMessagesToolResultParam,
    }

    expected_cls = mapping.get(content_type)
    if expected_cls is None:
        raise ValueError(f"Unknown Anthropic content type: '{content_type}'")

    missing = [
        k for k in getattr(expected_cls, "__required_keys__", set()) if k not in content
    ]
    if missing:
        raise ValueError(
            f"Missing required fields in {content_type} block: {', '.join(missing)}"
        )

    return expected_cls
```

## Counting Anthropic Content

The `_count_anthropic_content` function counts tokens in Anthropic-specific content blocks. It uses TypedDict annotations to dynamically determine which fields to count.

**Skipped fields** (metadata that doesn't contribute to prompt tokens):
- `type`
- `id`
- `tool_use_id`
- `cache_control`
- `is_error`

```python
def _count_anthropic_content(
    content: Mapping[str, Any],
    count_function: TokenCounterFunction,
    use_default_image_token_count: bool,
    default_token_count: Optional[int],
) -> int:
    typeddict_cls = _validate_anthropic_content(content)
    type_hints = getattr(typeddict_cls, "__annotations__", {})
    tokens = 0

    skip_fields = {"type", "id", "tool_use_id", "cache_control", "is_error"}

    for field_name, field_type in type_hints.items():
        if field_name in skip_fields:
            continue

        field_value = content.get(field_name)
        if field_value is None:
            continue

        if isinstance(field_value, str):
            tokens += count_function(field_value)
        elif isinstance(field_value, list):
            tokens += _count_content_list(
                count_function, field_value,
                use_default_image_token_count, default_token_count,
            )
        elif isinstance(field_value, dict):
            tokens += count_function(str(field_value))

    return tokens
```

### Fields Counted per Block Type

| Block Type | Counted Fields | Skipped Fields |
|------------|----------------|----------------|
| `tool_use` | `name`, `input` | `type`, `id`, `cache_control` |
| `tool_result` | `content` | `type`, `tool_use_id`, `is_error`, `cache_control` |

## Content List Processing

The `_count_content_list` function routes content blocks by type:

```python
def _count_content_list(
    count_function: TokenCounterFunction,
    content_list: OpenAIMessageContent,
    use_default_image_token_count: bool,
    default_token_count: Optional[int],
) -> int:
    num_tokens = 0
    for c in content_list:
        if isinstance(c, str):
            num_tokens += count_function(c)
        elif c["type"] == "text":
            num_tokens += count_function(c.get("text", ""))
        elif c["type"] == "image_url":
            num_tokens += _count_image_tokens(image_url, use_default_image_token_count)
        elif c["type"] in ("tool_use", "tool_result"):
            num_tokens += _count_anthropic_content(
                c, count_function, use_default_image_token_count, default_token_count,
            )
        elif c["type"] == "thinking":
            # Claude extended thinking - count text, skip signature
            thinking_text = c.get("thinking", "")
            if thinking_text:
                num_tokens += count_function(thinking_text)
    return num_tokens
```

### Extended Thinking Blocks

For Claude's extended thinking feature:
- The `thinking` text field is counted
- The opaque `signature` blob is skipped
- **Important**: Thinking blocks from *previous* assistant turns are ignored and do NOT count toward input tokens
- Only the *current* assistant turn's thinking counts toward input tokens

## Tool Definition Overhead

The `_format_function_definitions` function converts tool definitions to a TypeScript-like namespace format for token counting:

```python
def _format_function_definitions(tools):
    lines = []
    lines.append("namespace functions {")
    lines.append("")
    for tool in tools:
        function = tool.get("function")
        if function_description := function.get("description"):
            lines.append(f"// {function_description}")
        function_name = function.get("name")
        parameters = function.get("parameters", {})
        properties = parameters.get("properties")
        if properties and properties.keys():
            lines.append(f"type {function_name} = (_: {{")
            lines.append(_format_object_parameters(parameters, 0))
            lines.append("}) => any;")
        else:
            lines.append(f"type {function_name} = () => any;")
        lines.append("")
    lines.append("} // namespace functions")
    return "\n".join(lines)
```

This produces output like:

```typescript
namespace functions {

// Execute a shell command
type bash = (_: {
command: string,
}) => any;

// Read a file's contents
type read_file = (_: {
path: string,
}) => any;

} // namespace functions
```

## Message-Level Overhead

Per-message token overhead is model-dependent:

| Model | tokens_per_message | tokens_per_name |
|-------|-------------------|-----------------|
| gpt-3.5-turbo-0301 | 4 | -1 |
| Other models | 3 | 1 |

## Implications for Verification

### What Can Be Modeled Locally

The *structure* of token counting is deterministic and verifiable:

1. **Field filtering**: Metadata fields (`type`, `id`, `tool_use_id`, `cache_control`, `is_error`) contribute zero tokens
2. **Structural recursion**: Content lists may contain nested tool results with their own content lists
3. **Extended thinking rules**: Previous turn thinking blocks are excluded from input count

### What Requires the API

The actual string → token count mapping is opaque:
- Claude's tokenizer vocabulary is not published
- The `countTokens` endpoint is the only source of truth
- Local approximations (tiktoken) have unknown error bounds

### Potential Invariants

- Token count is always non-negative: `∀ content, count(content) ≥ 0`
- Empty content yields zero tokens: `count("") = 0`
- Skipped fields contribute zero: `count_field("type", v) = 0`
- Monotonicity over concatenation: `count(a) + count(b) ≥ count(a ++ b)` (subword merging)
- Nested tool results are recursively counted

### Sources

- [Anthropic Token Counting Docs](https://docs.anthropic.com/en/docs/build-with-claude/token-counting)
- [LiteLLM token_counter.py](https://github.com/BerriAI/litellm/blob/8ac1d96d90d32cf4203009d5e5b694d19a148b95/litellm/litellm_core_utils/token_counter.py)
- [Anthropic TypedDicts](https://github.com/BerriAI/litellm/blob/8ac1d96d90d32cf4203009d5e5b694d19a148b95/litellm/types/llms/anthropic.py)
