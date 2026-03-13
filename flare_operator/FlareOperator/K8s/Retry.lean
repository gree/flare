/-
  Retry.lean - Exponential backoff retry logic for K8s API calls

  Provides resilience against transient failures:
  - Network timeouts
  - API server temporary unavailability
  - Rate limiting
  - Transient errors
-/

namespace FlareOperator.K8s.Retry

/-! ## Retry Configuration -/

/-- Retry policy configuration -/
structure RetryConfig where
  /-- Maximum number of retry attempts (including initial try) -/
  maxAttempts : Nat := 5
  /-- Initial delay in milliseconds -/
  initialDelayMs : Nat := 100
  /-- Maximum delay in milliseconds (cap for exponential backoff) -/
  maxDelayMs : Nat := 30000
  /-- Multiplier for exponential backoff (delay *= multiplier each retry) -/
  backoffMultiplier : Float := 2.0
  /-- Whether to add random jitter to prevent thundering herd -/
  useJitter : Bool := true
  deriving Repr

/-- Default retry configuration for production use -/
def defaultRetryConfig : RetryConfig := {
  maxAttempts := 5
  initialDelayMs := 100
  maxDelayMs := 30000
  backoffMultiplier := 2.0
  useJitter := true
}

/-- Aggressive retry configuration for critical operations -/
def aggressiveRetryConfig : RetryConfig := {
  maxAttempts := 10
  initialDelayMs := 50
  maxDelayMs := 60000
  backoffMultiplier := 1.5
  useJitter := true
}

/-- Conservative retry configuration for non-critical operations -/
def conservativeRetryConfig : RetryConfig := {
  maxAttempts := 3
  initialDelayMs := 500
  maxDelayMs := 10000
  backoffMultiplier := 2.0
  useJitter := false
}

/-! ## Retry Logic -/

/-- Calculate delay for given attempt number using exponential backoff -/
private def calculateDelay (config : RetryConfig) (attemptNumber : Nat) : IO Nat := do
  -- Exponential backoff: initialDelay * multiplier^(attemptNumber - 1)
  let baseDelay := config.initialDelayMs.toFloat * (config.backoffMultiplier ^ (attemptNumber - 1).toFloat)

  -- Cap at maxDelay
  let cappedDelay := min baseDelay config.maxDelayMs.toFloat

  -- Add jitter if enabled (±25% randomness)
  let finalDelay ← if config.useJitter then do
    -- Simple pseudo-random jitter using current time
    let now ← IO.monoMsNow
    let jitterFactor := 0.75 + (now % 50).toFloat / 100.0  -- Range: 0.75 to 1.25
    pure (cappedDelay * jitterFactor)
  else
    pure cappedDelay

  pure finalDelay.toUInt64.toNat

/-- Check if string contains substring -/
private def containsSubstr (s : String) (substr : String) : Bool :=
  (s.splitOn substr).length > 1

/-- Check if error is retryable -/
private def isRetryableError (errorMsg : String) : Bool :=
  let msg := errorMsg.toLower
  -- Network errors
  containsSubstr msg "connection refused" ||
  containsSubstr msg "connection reset" ||
  containsSubstr msg "timeout" ||
  containsSubstr msg "temporary failure" ||
  containsSubstr msg "no route to host" ||
  -- K8s API errors (transient)
  containsSubstr msg "too many requests" ||
  containsSubstr msg "rate limit" ||
  containsSubstr msg "service unavailable" ||
  containsSubstr msg "internal server error" ||
  containsSubstr msg "conflict" ||
  -- kubectl errors
  containsSubstr msg "the server is currently unable" ||
  containsSubstr msg "unable to connect"

/-- Retry an IO action with exponential backoff -/
def withRetry {α : Type} (config : RetryConfig) (actionName : String) (action : IO α) : IO α := do
  let rec loop (attemptNumber : Nat) (lastError : Option String) : IO α := do
    if attemptNumber > config.maxAttempts then
      -- Exhausted all retries
      let errMsg := lastError.getD "unknown error"
      throw (IO.userError s!"[Retry] {actionName} failed after {config.maxAttempts} attempts: {errMsg}")
    else
      try
        -- Attempt the action
        if attemptNumber > 1 then
          IO.eprintln s!"[Retry] {actionName} - attempt {attemptNumber}/{config.maxAttempts}"

        action
      catch e =>
        let errorMsg := toString e

        -- Check if we should retry
        if isRetryableError errorMsg then
          if attemptNumber < config.maxAttempts then
            -- Calculate backoff delay
            let delayMs ← calculateDelay config attemptNumber
            IO.eprintln s!"[Retry] {actionName} failed (attempt {attemptNumber}): {errorMsg}"
            IO.eprintln s!"[Retry] Retrying in {delayMs}ms..."

            -- Sleep before retry
            IO.sleep delayMs.toUInt32

            -- Retry
            loop (attemptNumber + 1) (some errorMsg)
          else
            -- Last attempt failed
            throw (IO.userError s!"[Retry] {actionName} failed after {config.maxAttempts} attempts: {errorMsg}")
        else
          -- Non-retryable error, fail immediately
          IO.eprintln s!"[Retry] {actionName} failed with non-retryable error: {errorMsg}"
          throw e

  loop 1 none

/-! ## Convenience Wrappers -/

/-- Retry with default configuration -/
def retry {α : Type} (actionName : String) (action : IO α) : IO α :=
  withRetry defaultRetryConfig actionName action

/-- Retry with aggressive configuration (for critical operations) -/
def retryAggressive {α : Type} (actionName : String) (action : IO α) : IO α :=
  withRetry aggressiveRetryConfig actionName action

/-- Retry with conservative configuration (for non-critical operations) -/
def retryConservative {α : Type} (actionName : String) (action : IO α) : IO α :=
  withRetry conservativeRetryConfig actionName action

/-! ## Examples -/

#check retry
-- retry "fetch CRD" (kubectl ["get", "flarecluster", "my-cluster", "-o", "json"])

#check retryAggressive
-- retryAggressive "update leader lease" (updateLeaderLease)

#check retryConservative
-- retryConservative "list pods" (kubectl ["get", "pods"])

end FlareOperator.K8s.Retry
