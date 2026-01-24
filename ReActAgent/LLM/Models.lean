/-
# LLM Model Specifications

Token limits and properties for various LLM models.
Context windows are the total input + output token limit.
-/

import ReActAgent.Tokenizer.ApproxCount

namespace LLM

/-- Model specification with token limits -/
structure ModelSpec where
  /-- Model identifier string (e.g., "claude-sonnet-4-20250514") -/
  id : String
  /-- Total context window (input + output) -/
  contextWindow : Nat
  /-- Maximum output tokens (if different from context) -/
  maxOutput : Nat
  /-- Default max output if not specified -/
  defaultMaxOutput : Nat := 4096
  deriving Repr

/-- Calculate max input tokens given desired output reservation -/
def ModelSpec.maxInput (m : ModelSpec) (reserveOutput : Nat := m.defaultMaxOutput) : Nat :=
  m.contextWindow - reserveOutput

/-- Check if content fits in model's input budget -/
def ModelSpec.fitsInput (m : ModelSpec) (content : String) (reserveOutput : Nat := m.defaultMaxOutput) : Bool :=
  Tokenizer.approxTokenCount content ≤ m.maxInput reserveOutput

/-! ## Anthropic Claude Models -/

def claude_sonnet_4 : ModelSpec :=
  { id := "claude-sonnet-4-20250514"
    contextWindow := 200000
    maxOutput := 16000
    defaultMaxOutput := 8192 }

def claude_opus_4 : ModelSpec :=
  { id := "claude-opus-4-20250514"
    contextWindow := 200000
    maxOutput := 32000
    defaultMaxOutput := 8192 }

def claude_haiku_35 : ModelSpec :=
  { id := "claude-3-5-haiku-20241022"
    contextWindow := 200000
    maxOutput := 8192
    defaultMaxOutput := 4096 }

/-! ## OpenAI Models -/

def gpt4o : ModelSpec :=
  { id := "gpt-4o"
    contextWindow := 128000
    maxOutput := 16384
    defaultMaxOutput := 4096 }

def gpt4o_mini : ModelSpec :=
  { id := "gpt-4o-mini"
    contextWindow := 128000
    maxOutput := 16384
    defaultMaxOutput := 4096 }

def gpt4_turbo : ModelSpec :=
  { id := "gpt-4-turbo"
    contextWindow := 128000
    maxOutput := 4096
    defaultMaxOutput := 4096 }

def o1 : ModelSpec :=
  { id := "o1"
    contextWindow := 200000
    maxOutput := 100000
    defaultMaxOutput := 16000 }

def o1_mini : ModelSpec :=
  { id := "o1-mini"
    contextWindow := 128000
    maxOutput := 65536
    defaultMaxOutput := 8000 }

def o3_mini : ModelSpec :=
  { id := "o3-mini"
    contextWindow := 200000
    maxOutput := 100000
    defaultMaxOutput := 16000 }

/-! ## Model Lookup -/

/-- Known models by ID prefix -/
def knownModels : List ModelSpec :=
  [ claude_sonnet_4, claude_opus_4, claude_haiku_35
  , gpt4o, gpt4o_mini, gpt4_turbo
  , o1, o1_mini, o3_mini ]

/-- Find model spec by ID (exact match) -/
def findModel (id : String) : Option ModelSpec :=
  knownModels.find? (·.id == id)

/-- Find model spec by ID prefix (for versioned models) -/
def findModelByPrefix (id : String) : Option ModelSpec :=
  knownModels.find? (id.startsWith ·.id) <|>
  knownModels.find? (·.id.startsWith id)

/-- Default model spec for unknown models (conservative estimate) -/
def defaultModelSpec (id : String) : ModelSpec :=
  { id := id
    contextWindow := 8192    -- Conservative default
    maxOutput := 4096
    defaultMaxOutput := 2048 }

/-- Get model spec, falling back to default for unknown models -/
def getModelSpec (id : String) : ModelSpec :=
  findModelByPrefix id |>.getD (defaultModelSpec id)

/-! ## Examples -/

#eval claude_sonnet_4.maxInput        -- 191808 (200k - 8192)
#eval claude_sonnet_4.maxInput 16000  -- 184000 (200k - 16000)
#eval gpt4o.contextWindow             -- 128000

#eval (getModelSpec "claude-sonnet-4-20250514").contextWindow  -- 200000
#eval (getModelSpec "gpt-4o").contextWindow                    -- 128000
#eval (getModelSpec "unknown-model").contextWindow             -- 8192 (default)

-- Check if content fits
#eval claude_sonnet_4.fitsInput "Hello world"  -- true
#eval (defaultModelSpec "tiny").fitsInput (String.ofList (List.replicate 50000 'a'))  -- false

end LLM
