/-
  StateMachine.lean - Generic state machine framework for verified Kubernetes operators
  Copied from Gungnir/StateMachine/StateMachine.lean (Anvil TLA-style framework)
-/

namespace FlareOperator.StateMachine

structure Action (State : Type) (Input : Type) (Output : Type) where
  precondition : Input → State → Prop
  transition : Input → State → State × Output

inductive ActionResult (State : Type) (Output : Type) where
  | Disabled : ActionResult State Output
  | Enabled : State → Output → ActionResult State Output

structure StateMachine (State : Type) (Input : Type) (ActionInput : Type)
    (Output : Type) (Step : Type) where
  init : State → Prop
  stepToAction : Step → Action State ActionInput Output
  actionInput : Step → Input → ActionInput

def StateMachine.next {State Input ActionInput Output Step : Type}
    (sm : StateMachine State Input ActionInput Output Step)
    (input : Input) (s s' : State) : Prop :=
  ∃ step : Step,
    (sm.stepToAction step).precondition (sm.actionInput step input) s ∧
    s' = ((sm.stepToAction step).transition (sm.actionInput step input) s).1

def Action.pre {State Input Output : Type}
    (action : Action State Input Output) (input : Input) : State → Prop :=
  fun s => action.precondition input s

def Action.forward {State Input Output : Type}
    (action : Action State Input Output) (input : Input) : State → State → Prop :=
  fun s s' =>
    action.precondition input s ∧
    s' = (action.transition input s).1

end FlareOperator.StateMachine
