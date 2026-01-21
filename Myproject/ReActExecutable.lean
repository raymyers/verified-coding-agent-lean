/-
# Executable ReAct Agent

This file bridges the gap between the specification (ReAct.lean) and execution.

The transition relation is nondeterministic - the LLM could return anything,
the environment could return anything. To execute, we:
1. Provide "oracles" that resolve the nondeterminism
2. Define a deterministic stepper using those oracles
3. Prove the stepper respects the transition relation
4. Wire the oracles to IO for actual execution
-/

import Myproject.ReAct

namespace ReAct

/-! ## Oracles

Oracles resolve the nondeterministic choices in the transition relation.
In execution, these will be backed by real LLM calls, shell execution, etc.
-/

/-- Oracles resolve the nondeterministic choices. -/
structure Oracles where
  /-- Given current trace, produce an LLM response. -/
  llm : Trace → LLMResponse
  /-- Given tool name and args, produce an observation. -/
  env : String → String → Observation
  /-- Given a prompt, produce user input (for non-headless agents). -/
  user : String → String

/-! ## Deterministic Stepper -/

/-- Deterministic stepper: given oracles and a state, compute the next state.
    Returns none if already terminal or blocked. -/
def stepWith (o : Oracles) (s : State) : Option State :=
  match s.phase with
  | .done _ => none  -- terminal, no step
  | .thinking =>
      if s.withinLimits then
        let response := o.llm s.trace
        some { s with
          phase := .acting response.thought response.action,
          cost := s.cost + response.cost }
      else
        some { s with phase := .done .stepLimitReached }
  | .acting thought action =>
      match action with
      | .toolCall name args =>
          let obs := o.env name args
          some { s with
            phase := .thinking,
            trace := s.trace ++ [⟨thought, .toolCall name args, obs⟩],
            stepCount := s.stepCount + 1 }
      | .submit output =>
          some { s with phase := .done (.submitted output) }
      | .requestInput prompt =>
          if s.isHeadless then
            none  -- blocked: headless can't request input
          else
            some { s with phase := .needsInput prompt }
  | .needsInput prompt =>
      let input := o.user prompt
      some { s with
        phase := .thinking,
        trace := s.trace ++ [⟨"Received input", .requestInput prompt, input⟩] }

/-! ## Soundness

The stepper respects the transition relation: if stepWith returns some s',
then there exists a valid transition s ⟶ s'.
-/

/-- The stepper is sound: if it returns some s', then s ⟶ s'. -/
theorem stepWith_sound (o : Oracles) (s s' : State) (h : stepWith o s = some s') :
    s ⟶ s' := by
  unfold stepWith at h
  match hphase : s.phase with
  | .done reason =>
      simp [hphase] at h
  | .thinking =>
      simp only [hphase] at h
      split at h
      case isTrue hwl =>
        simp at h; subst h
        exact Transition.think s (o.llm s.trace) hphase hwl
      case isFalse hnwl =>
        simp at h; subst h
        exact Transition.thinkLimitReached s hphase hnwl
  | .acting thought action =>
      simp only [hphase] at h
      match action with
      | .toolCall name args =>
          simp at h; subst h
          exact Transition.actTool s thought name args (o.env name args) hphase
      | .submit output =>
          simp at h; subst h
          exact Transition.actSubmit s thought output hphase
      | .requestInput prompt =>
          simp only at h
          split at h
          case isTrue hhl => simp at h
          case isFalse hnhl =>
            simp at h; subst h
            exact Transition.actRequestInput s thought prompt hphase hnhl
  | .needsInput prompt =>
      simp only [hphase] at h
      simp at h; subst h
      exact Transition.receiveInput s prompt (o.user prompt) hphase

/-! ## Inherited Properties

Because stepWith is sound w.r.t. Transition, we inherit all properties
proven about the abstract transition relation.
-/

/-- Headless property transfers to executable: stepWith never produces needsInput. -/
theorem stepWith_headless (o : Oracles) (s s' : State)
    (hStep : stepWith o s = some s') (hHeadless : s.isHeadless) :
    ¬s'.isNeedsInput :=
  headless_never_needs_input s s' (stepWith_sound o s s' hStep) hHeadless

/-- Config is preserved by stepWith. -/
theorem stepWith_config_preserved (o : Oracles) (s s' : State)
    (hStep : stepWith o s = some s') :
    s'.config = s.config :=
  config_preserved s s' (stepWith_sound o s s' hStep)

/-- Trace monotonicity transfers to executable. -/
theorem stepWith_trace_monotonic (o : Oracles) (s s' : State)
    (hStep : stepWith o s = some s') :
    s.trace <+: s'.trace :=
  trace_monotonic s s' (stepWith_sound o s s' hStep)

/-! ## Execution

Run the agent by repeatedly stepping until terminal or blocked.
-/

/-- Run the agent to completion, returning the final state. -/
partial def runWith (o : Oracles) (s : State) : State :=
  match stepWith o s with
  | none => s
  | some s' => runWith o s'

/-! ## IO Wiring

To actually run with an LLM, we need IO-based oracles.
-/

/-- IO-based oracles for real execution. -/
structure IOOracles where
  /-- Query the LLM. -/
  llm : Trace → IO LLMResponse
  /-- Execute a tool. -/
  env : String → String → IO Observation
  /-- Get user input. -/
  user : String → IO String

/-- Single step with IO oracles. -/
def stepIO (o : IOOracles) (s : State) : IO (Option State) := do
  match s.phase with
  | .done _ => return none
  | .thinking =>
      if s.withinLimits then
        let response ← o.llm s.trace
        return some { s with
          phase := .acting response.thought response.action,
          cost := s.cost + response.cost }
      else
        return some { s with phase := .done .stepLimitReached }
  | .acting thought action =>
      match action with
      | .toolCall name args =>
          let obs ← o.env name args
          return some { s with
            phase := .thinking,
            trace := s.trace ++ [⟨thought, .toolCall name args, obs⟩],
            stepCount := s.stepCount + 1 }
      | .submit output =>
          return some { s with phase := .done (.submitted output) }
      | .requestInput prompt =>
          if s.isHeadless then
            return none
          else
            return some { s with phase := .needsInput prompt }
  | .needsInput prompt =>
      let input ← o.user prompt
      return some { s with
        phase := .thinking,
        trace := s.trace ++ [⟨"Received input", .requestInput prompt, input⟩] }

/-- Run the agent to completion with IO. -/
partial def runIO (o : IOOracles) (s : State) : IO State := do
  match ← stepIO o s with
  | none => return s
  | some s' => runIO o s'

/-! ## Example: Mock Oracles for Testing -/

/-- A simple mock LLM that always submits after one step. -/
def mockLLM : Trace → LLMResponse := fun _ =>
  { thought := "I should submit now"
    action := .submit "Done!"
    cost := 1 }

/-- A mock environment that echoes the command. -/
def mockEnv : String → String → Observation := fun name args =>
  s!"Executed {name} with {args}"

/-- Mock user input. -/
def mockUser : String → String := fun prompt =>
  s!"User response to: {prompt}"

/-- Mock oracles for testing. -/
def mockOracles : Oracles :=
  { llm := mockLLM
    env := mockEnv
    user := mockUser }

/-- Example initial state. -/
def exampleInitialState : State :=
  { phase := .thinking
    trace := []
    stepCount := 0
    cost := 0
    config := { limits := { maxSteps := 10, maxCost := 100 }
                tools := ["bash", "read", "write"]
                headless := true } }

#eval stepWith mockOracles exampleInitialState
#eval runWith mockOracles exampleInitialState

end ReAct
