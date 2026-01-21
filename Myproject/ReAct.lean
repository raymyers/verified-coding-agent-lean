/-
# ReAct: Reasoning and Acting in Language Models

A formalization of the ReAct paradigm (Yao et al., 2022).

The core loop interleaves:
- **Thought**: reasoning about the current situation
- **Action**: invoking a tool/taking an action
- **Observation**: receiving feedback from the environment

This file sketches the state machine semantics and correctness properties.
-/

import Mathlib.Data.List.Basic
import Mathlib.Order.Basic

namespace ReAct

/-! ## Basic Types -/

/-- A thought is the agent's reasoning trace. -/
abbrev Thought := String

/-- An observation is the environment's response to an action. -/
abbrev Observation := String

/-- Actions the agent can take. Parameterized for extensibility. -/
inductive Action where
  | toolCall (name : String) (args : String)
  | submit (output : String)
  | requestInput (prompt : String)  -- ask the user for input
  deriving Repr, DecidableEq

/-- A single ReAct step: the atomic unit of the loop. -/
structure Step where
  thought : Thought
  action : Action
  observation : Observation
  deriving Repr

/-- The trace is a sequence of completed steps. -/
abbrev Trace := List Step

/-! ## Agent Configuration -/

/-- Resource limits for the agent. -/
structure Limits where
  maxSteps : Nat
  maxCost : Nat  -- simplified: using Nat instead of rationals
  deriving Repr

/-- Configuration for a ReAct agent. -/
structure Config where
  limits : Limits
  tools : List String  -- available tool names
  headless : Bool      -- if true, agent never requests user input
  deriving Repr

/-! ## Agent State -/

/-- Why the agent terminated. -/
inductive TermReason where
  | submitted (output : String)  -- agent declared completion
  | stepLimitReached
  | costLimitReached
  | error (msg : String)
  deriving Repr, DecidableEq

/-- The phase of the ReAct loop. -/
inductive Phase where
  | thinking                               -- awaiting LLM response
  | acting (thought : Thought) (action : Action)  -- have thought+action, awaiting execution
  | needsInput (prompt : String)           -- waiting for user input
  | done (reason : TermReason)             -- terminated
  deriving Repr, DecidableEq

/-- The complete state of a ReAct agent. -/
structure State where
  phase : Phase
  trace : Trace
  stepCount : Nat
  cost : Nat
  config : Config
  deriving Repr

/-! ## State Predicates -/

def Phase.isTerminal : Phase → Bool
  | .done _ => true
  | _ => false

def Phase.isThinking : Phase → Bool
  | .thinking => true
  | _ => false

def Phase.isNeedsInput : Phase → Bool
  | .needsInput _ => true
  | _ => false

def State.isTerminal (s : State) : Bool :=
  s.phase.isTerminal

def State.isNeedsInput (s : State) : Bool :=
  s.phase.isNeedsInput

def State.isHeadless (s : State) : Bool :=
  s.config.headless

def State.withinLimits (s : State) : Bool :=
  s.stepCount < s.config.limits.maxSteps ∧
  s.cost < s.config.limits.maxCost

/-! ## Transition Relation

The transition relation models the nondeterministic evolution of the agent.
Nondeterminism arises from:
1. The LLM's response (thought + action)
2. The environment's response (observation)
-/

/-- The result of the LLM producing a thought and action. -/
structure LLMResponse where
  thought : Thought
  action : Action
  cost : Nat  -- tokens used

/-- Transition relation for the ReAct loop. -/
inductive Transition : State → State → Prop where
  /-- Think: LLM produces thought + action (within limits). -/
  | think (s : State) (response : LLMResponse) :
      s.phase = .thinking →
      s.withinLimits →
      Transition s {
        s with
        phase := .acting response.thought response.action,
        cost := s.cost + response.cost
      }
  /-- Think but hit limits: transition to done. -/
  | thinkLimitReached (s : State) :
      s.phase = .thinking →
      ¬s.withinLimits →
      Transition s { s with phase := .done .stepLimitReached }
  /-- Act with tool call: execute and observe, then back to thinking. -/
  | actTool (s : State) (thought : Thought) (name args : String) (obs : Observation) :
      s.phase = .acting thought (.toolCall name args) →
      Transition s {
        s with
        phase := .thinking,
        trace := s.trace ++ [⟨thought, .toolCall name args, obs⟩],
        stepCount := s.stepCount + 1
      }
  /-- Act with submit: transition to done. -/
  | actSubmit (s : State) (thought : Thought) (output : String) :
      s.phase = .acting thought (.submit output) →
      Transition s { s with phase := .done (.submitted output) }
  /-- Act with requestInput: transition to needsInput (only if not headless). -/
  | actRequestInput (s : State) (thought : Thought) (prompt : String) :
      s.phase = .acting thought (.requestInput prompt) →
      ¬s.isHeadless →
      Transition s { s with phase := .needsInput prompt }
  /-- Receive user input: transition back to thinking. -/
  | receiveInput (s : State) (prompt : String) (userInput : String) :
      s.phase = .needsInput prompt →
      Transition s {
        s with
        phase := .thinking,
        trace := s.trace ++ [⟨"Received input", .requestInput prompt, userInput⟩]
      }

notation s " ⟶ " s' => Transition s s'

/-! ## Multi-step Transitions -/

/-- Reflexive transitive closure of transitions. -/
inductive TransitionStar : State → State → Prop where
  | refl : TransitionStar s s
  | step : Transition s s' → TransitionStar s' s'' → TransitionStar s s''

notation s " ⟶* " s' => TransitionStar s s'

/-! ## Correctness Properties -/

section Properties

variable (s s' : State)

/-- Terminal states are absorbing: no transitions out. -/
def terminalAbsorbing : Prop :=
  s.isTerminal → ∀ s', ¬(s ⟶ s')

/-- The trace only grows (monotonicity). -/
def traceMonotonic : Prop :=
  (s ⟶ s') → s.trace <+: s'.trace

/-- Cost never decreases. -/
def costMonotonic : Prop :=
  (s ⟶ s') → s.cost ≤ s'.cost

/-- Step count never decreases. -/
def stepCountMonotonic : Prop :=
  (s ⟶ s') → s.stepCount ≤ s'.stepCount

/-- Progress: non-terminal states can always step (given oracle responses). -/
def progress : Prop :=
  ¬s.isTerminal → ∃ s', s ⟶ s'

/-- Eventual termination given finite limits. -/
def eventuallyTerminates : Prop :=
  s.config.limits.maxSteps > 0 →
  ∃ s', (s ⟶* s') ∧ s'.isTerminal

end Properties

/-! ## Theorems (Sketches) -/

/-- Terminal states have no outgoing transitions. -/
theorem terminal_no_transition (s : State) (h : s.isTerminal) :
    ∀ s', ¬(s ⟶ s') := by
  intro s' htrans
  cases htrans <;> simp_all [State.isTerminal, Phase.isTerminal]

/-- Each transition preserves or extends the trace. -/
theorem trace_monotonic (s s' : State) (h : s ⟶ s') :
    s.trace <+: s'.trace := by
  cases h <;> simp only [List.prefix_append, List.prefix_refl]

/-- Cost is monotonically non-decreasing. -/
theorem cost_monotonic (s s' : State) (h : s ⟶ s') :
    s.cost ≤ s'.cost := by
  cases h <;> simp only [Nat.le_refl, Nat.le_add_right]

/-! ## Headless Agent Property -/

/-- Configuration is preserved across transitions. -/
theorem config_preserved (s s' : State) (h : s ⟶ s') :
    s'.config = s.config := by
  cases h <;> rfl

/-- A headless agent never transitions INTO needsInput.

This is the key safety property: if config.headless = true,
then no transition can produce a state where phase = needsInput.
-/
theorem headless_never_needs_input (s s' : State) (h : s ⟶ s')
    (hHeadless : s.isHeadless) :
    ¬s'.isNeedsInput := by
  cases h with
  | think => simp [State.isNeedsInput, Phase.isNeedsInput]
  | thinkLimitReached => simp [State.isNeedsInput, Phase.isNeedsInput]
  | actTool => simp [State.isNeedsInput, Phase.isNeedsInput]
  | actSubmit => simp [State.isNeedsInput, Phase.isNeedsInput]
  | actRequestInput _ _ _ hNotHeadless =>
      -- This case is impossible: we have both hHeadless and ¬isHeadless
      simp only [State.isHeadless] at hHeadless hNotHeadless
      simp_all
  | receiveInput => simp [State.isNeedsInput, Phase.isNeedsInput]

/-- Headless property is preserved: once headless, always headless. -/
theorem headless_preserved (s s' : State) (h : s ⟶ s') :
    s.isHeadless = s'.isHeadless := by
  simp only [State.isHeadless, config_preserved s s' h]

/-- Headless agents never reach needsInput from any reachable state (multi-step).
    Requires that the initial state is not already in needsInput. -/
theorem headless_never_needs_input_star (s s' : State) (h : s ⟶* s')
    (hHeadless : s.isHeadless) (hInitNotNeedsInput : ¬s.isNeedsInput) :
    ¬s'.isNeedsInput := by
  induction h with
  | refl => exact hInitNotNeedsInput
  | step hstep _ ih =>
      have hHeadless' := (headless_preserved _ _ hstep).symm ▸ hHeadless
      have hNotNeedsInput := headless_never_needs_input _ _ hstep hHeadless
      exact ih hHeadless' hNotNeedsInput

/-! ## Coding Agent Specialization

A coding agent is a ReAct agent where:
1. Tools are software-development relevant (read, write, execute, etc.)
2. The task involves modifying code to meet a specification
-/

/-- Tools relevant to software development. -/
inductive CodingTool where
  | readFile (path : String)
  | writeFile (path : String) (content : String)
  | execute (cmd : String)
  | search (query : String)
  deriving Repr, DecidableEq

/-- A coding agent configuration. -/
structure CodingConfig extends Config where
  /-- The task specification (what success looks like). -/
  taskDescription : String
  /-- Paths the agent is allowed to modify. -/
  allowedPaths : List String

end ReAct
