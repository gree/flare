/-
  FlareOperator - Core Kubernetes Types
  Adapted from Gungnir/K8s/Types.lean (Anvil-style spec types)
-/

namespace FlareOperator.K8s

abbrev Uid := Nat
abbrev ResourceVersion := Nat
abbrev Value := String

/-! ## Resource Kind -/

inductive Kind where
  | CustomResourceKind (name : String)
  | PodKind
  | ServiceKind
  deriving Repr, BEq, DecidableEq

/-! ## Object Reference -/

structure ObjectRef where
  kind : Kind
  name : String
  «namespace» : String
  deriving Repr, BEq, DecidableEq

/-! ## Object Metadata -/

structure ObjectMetaView where
  name : Option String := none
  «namespace» : Option String := none
  resourceVersion : Option ResourceVersion := none
  uid : Option Uid := none
  labels : Option (List (String × String)) := none
  annotations : Option (List (String × String)) := none
  deriving Repr

namespace ObjectMetaView

def default : ObjectMetaView := {}

def withName (meta : ObjectMetaView) (n : String) : ObjectMetaView :=
  { meta with name := some n }

def withNamespace (meta : ObjectMetaView) (ns : String) : ObjectMetaView :=
  { meta with «namespace» := some ns }

def withLabels (meta : ObjectMetaView) (ls : List (String × String)) : ObjectMetaView :=
  { meta with labels := some ls }

end ObjectMetaView

/-! ## Dynamic Object -/

structure DynamicObjectView where
  kind : Kind
  metadata : ObjectMetaView
  spec : Value
  status : Value
  deriving Repr

namespace DynamicObjectView

def objectRef (obj : DynamicObjectView) : ObjectRef :=
  { kind := obj.kind
  , name := obj.metadata.name.getD ""
  , «namespace» := obj.metadata.«namespace».getD "" }

end DynamicObjectView

/-! ## Stored State -/

abbrev StoredState := List (ObjectRef × DynamicObjectView)

end FlareOperator.K8s
