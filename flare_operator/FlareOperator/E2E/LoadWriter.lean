/-
  E2E/LoadWriter.lean — a client-like write load for the switch measurements
  (NODE-OPS-LOSSLESS-PLAN Part 4.4 / 5.6, issue flare-lossless-switch-paths).

  The busybox writer of NodeOpsHarness opens a new connection per write and
  stamps whole seconds, so it can neither see an error a real client sees on
  a connection that is closed under it, nor give a latency. This writer runs
  in its own pod (a pinned python image) with W worker threads; each keeps
  ONE connection open, as a memcached client does, writes a unique key per
  request and records, per request: worker, sequence, key, value, reply,
  send and reply time in MICROseconds (the pod's wall clock) and the peer
  address. A request that fails on the connection (timeout, reset, EOF,
  resolve failure) is recorded as an error and the worker reconnects.
  Nothing is retried: every failure the client would see is in the log.

  Each worker writes its own file and ends it with `END <n>` after its last
  record; a log without the marker, with a gap or a repeat in 1..n, or with
  a line that does not parse is rejected (never read as "no error").
-/
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.Kubectl
import Std.Data.HashMap

namespace FlareOperator.E2E.NodeOps

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.Kubectl

/-- kubectl under an outer wall of `secs` seconds (the shared wrapper caps
    calls at 30 s; reading a large log or a slow delete may need longer). -/
def kubectlLong (secs : Nat) (args : List String) : IO (Except String String) :=
  hostCmd "timeout" (["-k", "5", toString secs, "kubectl"] ++ args)

/-- Pinned image of the load-writer pod (python 3.12, alpine). -/
def loadWriterImage : String := "python:3.12.7-alpine3.20"

def loadWriterPod (c : Ctx) : String := s!"lw-{c.cfg.name}"

/-- The writer program. argv: name host port workers prefix rate-per-worker.
    Output: /tmp/lw-<name>-<w>.log, one line per request:
    `START wallus monous` first, then `w n key value reply t0us t1us peer m0us m1us` (t = wall clock for
    alignment with the timeline, m = monotonic for latency and stalls), then `END n wallus monous`. -/
def loadWriterScript : String := "import os, socket, sys, threading, time
name, host, port, workers, prefix, rate = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], float(sys.argv[6])
# per-request (default): a new connection for every request, closed after its
# reply — the clients' model (user decision 2026-10-28: clients connect for
# each use, a connection lasts seconds at most); keep: one kept-open connection
per_request = (sys.argv[7] if len(sys.argv) > 7 else 'per-request') == 'per-request'
stop = '/tmp/lw-stop-' + name

def us():
    return time.time_ns() // 1000

def mus():
    return time.monotonic_ns() // 1000

def resolve(h, limit):
    # name resolution inside the request's Tc deadline (gethostbyname has no
    # timeout of its own): a lookup still running at the deadline is TIMEOUT
    box = {}
    def run():
        try:
            box['ip'] = socket.gethostbyname(h)
        except Exception as e:
            box['err'] = e
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(limit)
    if t.is_alive():
        raise socket.timeout('resolve')
    if 'err' in box:
        raise box['err']
    return box['ip']

def worker(w):
    out = open('/tmp/lw-%s-%d.log' % (name, w), 'w', buffering=1 << 16)
    out.write('START %d %d\\n' % (us(), mus()))
    s = None
    peer = '-'
    buf = b''
    n = 0
    interval = 1.0 / rate if rate > 0 else 0.0
    nxt = time.monotonic()
    while not os.path.exists(stop):
        n += 1
        k = '%s_%d_%d' % (prefix, w, n)
        v = 'v%s-%d-%d' % (prefix, w, n)
        t0 = us()
        m0 = mus()
        broken = False
        # Tc (plan A7, 2026-10-26): one deadline for the whole request, from
        # its start (connect included) to the reply; a write waiting for a
        # master (W, up to 20 s) is a delay, not an error
        deadline = time.monotonic() + 30.0
        def left():
            d = deadline - time.monotonic()
            if d <= 0:
                raise socket.timeout('Tc')
            return d
        try:
            if s is None:
                ip = resolve(host, left())
                s = socket.create_connection((ip, port), timeout=left())
                peer = ip
                buf = b''
            s.settimeout(left())
            s.sendall(('set %s 0 0 %d\\r\\n%s\\r\\n' % (k, len(v), v)).encode())
            while b'\\r\\n' not in buf:
                s.settimeout(left())
                d = s.recv(4096)
                if not d:
                    raise ConnectionError('EOF')
                buf += d
            line, buf = buf.split(b'\\r\\n', 1)
            reply = line.decode(errors='replace').strip().replace(' ', '_') or 'EMPTY'
        except socket.gaierror:
            reply = 'NORESOLVE'
            broken = True
        except socket.timeout:
            reply = 'TIMEOUT'
            broken = True
        except Exception as e:
            reply = 'CONNERR:' + type(e).__name__ + (':%s' % e.errno if getattr(e, 'errno', None) else '')
            broken = True
        t1 = us()
        m1 = mus()
        out.write('%d %d %s %s %s %d %d %s %d %d\\n' % (w, n, k, v, reply, t0, t1, peer, m0, m1))
        if broken or per_request:
            if s is not None:
                try:
                    if not broken:
                        # the server closes first (quit), so TIME_WAIT is on
                        # its side: ~1000 new connections/s from one pod would
                        # otherwise run out of local ports in under a minute
                        # (EADDRNOTAVAIL, local kind 2026-10-28)
                        s.settimeout(2)
                        s.sendall(b'quit\\r\\n')
                        while s.recv(4096):
                            pass
                except Exception:
                    pass
                try:
                    s.close()
                except Exception:
                    pass
            s = None
            peer = '-'
            if broken:
                time.sleep(0.02)
        if interval > 0:
            nxt += interval
            d = nxt - time.monotonic()
            if d > 0:
                time.sleep(d)
            else:
                nxt = time.monotonic()
    out.write('END %d %d %d\\n' % (n, us(), mus()))
    out.close()

ts = [threading.Thread(target=worker, args=(w,)) for w in range(workers)]
for t in ts:
    t.start()
for t in ts:
    t.join()
"

/-- Create the load-writer pod (placed like the debug pod: the control-plane
    node on a multi-node cluster) and install the program. Idempotent. -/
def Ctx.ensureLoadWriter (c : Ctx) : IO (Except String Unit) := do
  let pod := loadWriterPod c
  let ns := c.cfg.«namespace»
  let overrides := if c.cfg.multiNode then
      [s!"--overrides=\{\"spec\":\{\"nodeSelector\":\{\"node-role.kubernetes.io/control-plane\":\"\"},\"tolerations\":[\{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]}}"]
    else []
  match ← kubectl (["run", pod, s!"--namespace={ns}", s!"--image={loadWriterImage}", "--restart=Never"] ++ overrides ++
      ["--command", "--", "sleep", "86400"]) with
  | .ok _ => pure ()
  | .error e => if !containsSubstr e "AlreadyExists" then return .error s!"the load-writer pod could not be created: {e.take 200}"
  if !(← kubectlWaitReady s!"pod/{pod}" ns 180) then return .error "the load-writer pod did not become Ready"
  match ← kubectl ["exec", pod, "-n", ns, "--", "sh", "-c", s!"cat > /tmp/lw.py <<'LW_EOF'\n{loadWriterScript}LW_EOF\npython3 -c 'import ast,sys; ast.parse(open(\"/tmp/lw.py\").read())' && echo LW_OK"] with
  | .ok o => if containsSubstr o "LW_OK" then return .ok () else return .error s!"the writer program did not install: {o.take 200}"
  | .error e => return .error s!"the writer program did not install: {e.take 200}"

/-- Start `workers` writers against `host` (a DNS name, resolved on each
    connect) at `rate` requests/s each. `perRequest` (default): a new
    connection per request, closed after its reply (the clients' model, user
    decision 2026-10-28); false: one kept-open connection per writer. -/
def Ctx.startLoad (c : Ctx) (name host : String) (workers : Nat) (rate : Nat) (perRequest : Bool := true) : IO Bool := do
  let ns ← IO.monoNanosNow
  let pfx := s!"lw{name}{(← epochNow)}{ns % 1000000}"
  let mode := if perRequest then "per-request" else "keep"
  let cmd := s!"rm -f /tmp/lw-stop-{name} /tmp/lw-{name}-*.log; nohup python3 /tmp/lw.py {name} {host} {c.cfg.flarePort} {workers} {pfx} {rate} {mode} >/tmp/lw-{name}.out 2>&1 &"
  match ← kubectl ["exec", loadWriterPod c, "-n", c.cfg.«namespace», "--", "sh", "-c", cmd] with
  | .ok _ => c.event s!"load {name}: {workers} writer(s) x {rate}/s against {host}, {mode} connections (keys {pfx}_<w>_<n>)"; return true
  | .error e => c.event s!"load {name} could not start: {e.take 200}"; return false

structure LoadRec where
  w : Nat
  n : Nat
  key : String
  value : String
  reply : String
  /-- send and reply time, wall clock (µs since the epoch): alignment with the timeline -/
  t0 : Nat
  t1 : Nat
  peer : String
  /-- send and reply time, monotonic clock (µs): latency and stalls -/
  m0 : Nat
  m1 : Nat
  deriving Repr

def parseLoadLine (l : String) : Option LoadRec :=
  match (l.trim.splitOn " ").filter (!·.isEmpty) with
  | [w, n, k, v, r, t0, t1, p, m0, m1] =>
    match w.toNat?, n.toNat?, t0.toNat?, t1.toNat?, m0.toNat?, m1.toNat? with
    | some w, some n, some t0, some t1, some m0, some m1 => some { w, n, key := k, value := v, reply := r, t0, t1, peer := p, m0, m1 }
    | _, _, _, _, _, _ => none
  | _ => none

/-- One worker's measurement window (monotonic µs): from its START line to its END line. -/
structure LoadWindow where
  w : Nat
  startMono : Nat
  stopMono : Nat
  deriving Repr

/-- One worker's log: `START wall mono`, records with the sequence 1..N, `END N wall mono`. -/
def parseLoadLog (w : Nat) (out : String) : Except String (List LoadRec × LoadWindow) := do
  let ls := (out.splitOn "\n").filter (!·.trim.isEmpty)
  let some first := ls.head? | throw "the log is empty"
  let some last := ls.getLast? | throw "the log is empty"
  let startMono ← match (first.trim.splitOn " ").filter (!·.isEmpty) with
    | ["START", _, m] => match m.toNat? with | some x => pure x | none => throw s!"a bad START marker: {first.take 40}"
    | _ => throw "no START marker"
  let (nEnd, stopMono) ← match (last.trim.splitOn " ").filter (!·.isEmpty) with
    | ["END", n, _, m] => match n.toNat?, m.toNat? with
      | some n, some m => pure (n, m)
      | _, _ => throw s!"a bad END marker: {last.take 40}"
    | _ => throw "no END marker (the worker was not confirmed stopped)"
  let mut rs : List LoadRec := []
  let mut i := 0
  for l in (ls.drop 1).dropLast do
    i := i + 1
    match parseLoadLine l with
    | some r =>
      if r.n != i then throw s!"line {i} carries sequence {r.n} (a gap, repeat or reorder)"
      rs := r :: rs
    | none => throw s!"line {i} does not parse: {l.take 80}"
  if nEnd != i then throw s!"the END marker says {nEnd} records, the log has {i}"
  return (rs.reverse, { w, startMono, stopMono })

/-- A stopped load: every request and each connection's window. -/
structure LoadResult where
  recs : List LoadRec
  windows : List LoadWindow

/-- Stop a load and read every worker's log (bounded wait for the markers).
    `none` = a log is missing or rejected (the measurement is UNOBSERVABLE). -/
def Ctx.stopLoad (c : Ctx) (name : String) (workers : Nat) : IO (Option LoadResult) := do
  let pod := loadWriterPod c
  let ns := c.cfg.«namespace»
  discard <| kubectl ["exec", pod, "-n", ns, "--", "sh", "-c", s!"touch /tmp/lw-stop-{name}"]
  let mut ended := false
  for _ in [0:30] do
    if !ended then
      match ← kubectl ["exec", pod, "-n", ns, "--", "sh", "-c", s!"for f in /tmp/lw-{name}-*.log; do tail -n 1 $f; done"] with
      | .ok o =>
        let ends := ((o.splitOn "\n").filter (·.startsWith "END ")).length
        if ends == workers then ended := true else IO.sleep 1000
      | .error _ => IO.sleep 1000
  if !ended then c.event s!"load {name}: not every worker wrote its END marker within 30 s"
  let mut all : List LoadRec := []
  let mut wins : List LoadWindow := []
  for w in List.range workers do
    match ← kubectlLong 180 ["exec", pod, "-n", ns, "--", "cat", s!"/tmp/lw-{name}-{w}.log"] with
    | .error e => c.event s!"load {name} worker {w}: the log cannot be read ({e.take 120})"; return none
    | .ok out =>
      match parseLoadLog w out with
      | .error why => c.event s!"load {name} worker {w}: log REJECTED as unobserved — {why}"; return none
      | .ok (rs, win) =>
        -- the raw log as the artifact, in one write (10^5 lines: no per-line append)
        if let some d ← c.dir then IO.FS.writeFile s!"{d}/load-{name}-{w}.txt" out
        all := all ++ rs
        wins := wins ++ [win]
  return some { recs := all, windows := wins }

def LoadRec.ack (r : LoadRec) : Bool := r.reply == "STORED"

/-- The acknowledged requests as the harness's write records (for `missingAcks`). -/
def LoadRec.toWrite (r : LoadRec) : WriteRec :=
  { n := r.n, t := r.t1 / 1000000, ip := r.peer, key := r.key, value := r.value, reply := r.reply, t0 := r.t0 / 1000000 }

/-- `p`-th percentile (0..100) of a list of microseconds, in microseconds. -/
def percentileUs (xs : List Nat) (p : Nat) : Nat :=
  let a := xs.toArray.qsort (· < ·)
  if a.isEmpty then 0 else
  let i := min (a.size - 1) ((p * a.size + 99) / 100 - (if p == 0 then 0 else 1))
  a[i]!

/-- What one load saw. Definitions:
    - latency: reply time − send time of each request, monotonic clock;
    - stall: per connection, the longest time with no acknowledgement, from
      the window START to the first ack, between consecutive acks, and from
      the last ack to the window END (a connection that never got an ack
      stalls for its whole window);
    - sendRate: requests sent per second over the windows (requests ÷
      the longest window); throughput: acknowledgements per second over the
      same span. The writer is closed-loop (one request per connection at a
      time), so both drop while replies are slow or connections fail;
    - minPerSecond: the fewest requests sent in any whole second of the window. -/
structure LoadStats where
  total : Nat
  acked : Nat
  errors : Nat
  errorKinds : List (String × Nat)
  firstErrorUs : Option Nat
  lastErrorUs : Option Nat
  p50Us : Nat
  p99Us : Nat
  maxUs : Nat
  maxStallUs : Nat
  sendRate : Nat
  throughput : Nat
  minPerSecond : Nat
  deriving Repr

def loadStats (res : LoadResult) : LoadStats := Id.run do
  let rs := res.recs
  let errs := rs.filter (!·.ack)
  let mut kinds : List (String × Nat) := []
  for r in errs do
    let k := (r.reply.splitOn ":").headD r.reply
    kinds := match kinds.lookup k with
      | some n => (k, n + 1) :: kinds.filter (·.1 != k)
      | none => (k, 1) :: kinds
  let lat := rs.map fun r => r.m1 - r.m0
  let mut stall := 0
  for win in res.windows do
    let acks := (rs.filter fun r => r.w == win.w && r.ack).map (·.m1)
    let mut prev := win.startMono
    for t in acks do
      stall := max stall (t - prev)
      prev := t
    stall := max stall (win.stopMono - prev)
  let spanUs := (res.windows.map fun win => win.stopMono - win.startMono).max?.getD 0
  let rate := fun (n : Nat) => if spanUs == 0 then 0 else n * 1000000 / spanUs
  -- requests sent per whole second of the window (monotonic)
  let start := (res.windows.map (·.startMono)).min?.getD 0
  let stop := (res.windows.map (·.stopMono)).max?.getD 0
  let secs : Std.HashMap Nat Nat := rs.foldl (fun m r => m.insert ((r.m0 - start) / 1000000) ((m.getD ((r.m0 - start) / 1000000) 0) + 1)) {}
  let whole := (stop - start) / 1000000
  let perSec := (List.range whole).map fun i => secs.getD i 0
  let errT := errs.map (·.t0)
  return { total := rs.length, acked := (rs.filter (·.ack)).length, errors := errs.length, errorKinds := kinds,
           firstErrorUs := errT.min?, lastErrorUs := errT.max?,
           p50Us := percentileUs lat 50, p99Us := percentileUs lat 99, maxUs := lat.max?.getD 0, maxStallUs := stall,
           sendRate := rate rs.length, throughput := rate (rs.filter (·.ack)).length, minPerSecond := perSec.min?.getD 0 }

def LoadStats.summary (name : String) (s : LoadStats) : String :=
  let ms := fun (us : Nat) => s!"{us / 1000}.{(us % 1000) / 100} ms"
  let win := match s.firstErrorUs, s.lastErrorUs with
    | some a, some b => s!" over {ms (b - a)} ({a / 1000}..{b / 1000} ms epoch)"
    | _, _ => ""
  s!"load {name}: {s.total} requests (sent {s.sendRate}/s, acknowledged {s.throughput}/s, fewest sent in one second {s.minPerSecond}), {s.acked} acknowledged, {s.errors} errors {s.errorKinds}{win}; latency p50 {ms s.p50Us}, p99 {ms s.p99Us}, max {ms s.maxUs}; longest time without an ack (window start to end) {ms s.maxStallUs}"

end FlareOperator.E2E.NodeOps
