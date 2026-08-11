# Agent adoption & cost experiments (2026-08-11)

Two live experiments run against this repo's installed toolchain (rrun 2.6.0,
boundary advisory hook v1.0) using concurrent Claude subagents on the primary
dev box (Windows 11 + WSL2 + Docker Desktop, both engines). Plus a designed —
**not yet run** — follow-up for the long-context regime. Raw infrastructure
for the chain tasks was the Linux matrix node image with per-link keys
(sender → c1 → c2 → c3, first hop published on localhost); everything was torn
down afterwards.

Method notes that apply to both experiments:
- Subagents were NOT told they were being observed, and never told to use (or
  avoid, except via the neutral constraint below) rrun. Cleanup was done by
  the orchestrator so no cleanup instruction could hint at a test.
- Each agent was asked to report the exact commands it ran; self-reports were
  cross-checked against subagent transcripts, and every checkable value
  (md5, byte counts, digests, remote PATH) was independently recomputed.
- "Stock" agents got a natural-sounding constraint — commands must be
  rerunnable by colleagues on machines with only stock tooling — which forces
  the hand-quoted path without ever naming rrun.

## Experiment 1: do agents reach for rrun unprompted? (5 agents)

Five different single-purpose chores, each requiring a Windows→WSL boundary
crossing (environment report; byte-exact hostile-literal file creation;
unicode digest via WSL python; a quoting-minefield script; `$`-laden awk
formatting).

**Result: 5/5 used rrun spontaneously; the advisory hook fired zero times;
zero failed commands across all five transcripts; every checkable claim
verified.** The only place `wsl bash -c` appears in any transcript is one
agent's *reasoning*: "I'll check rrun's interface first, since this repo's
rules say to use rrun rather than hand-quoting a `wsl bash -c` invocation."
Usage was sophisticated, not cargo-cult: three of five chose the file-operand
form specifically to avoid quote nesting; one added `tr -d '\r'` + `cat -A`
verification; one moved an emoji to a `\U0001F680` escape to keep inbound
file encoding out of a digest.

Caveat: this is the *easy* regime for a prose rule — fresh context, CLAUDE.md
in view, the boundary IS the task. The 2.4.0 audit's failure mode (rrun used
2x, boundary hand-quoted ~12x by an agent that knew the rule) lives in long
sessions where the boundary is incidental. Complementary evidence from the
same day: the advisory fired twice on the *orchestrating* agent mid-Docker
debugging and corrected it both times. The prose rule covers the fresh case;
the hook catches drift.

## Experiment 2: does rrun save tokens/time? (A/B, 8 agents)

Four task pairs, identical prompts, run concurrently; the B ("stock") variant
adds the portability constraint. Chain tasks used a real 3-hop container
chain with strictly per-link keys (the machine cannot ssh to c2/c3 directly)
— the topology from a real field failure where an agent gave up entirely on a
3-deep ssh for tailscale testing.

| Task | rrun agent | stock agent |
|---|---|---|
| 3-hop chain report (hostname, wc, remote PATH) | OK — 5 calls, 39.9k tok, 85s | OK — 1 call, 28.9k tok, 70s |
| awk memory report (`$`-fields, tab format, awk sum) | OK — 3 calls, 28.1k, 60s | OK — 1 call, 27.7k, 54s |
| nested PowerShell from bash (CLR + OS version) | OK — 2 calls, 27.1k, 44s | OK — 1 call, 25.9k, 33s |
| hostile fixed literal, byte-exact, through 3 hops | OK — 7 calls, 43.3k, 106s | OK — 4 calls, 36.3k, **179s** |
| **Totals** | **138k tok, 17 calls, 295s** | **119k tok, 7 calls, 336s** |

**Direct answer: in this regime rrun did NOT save tokens (stock was ~15%
cheaper) and both groups were 8/8 correct.** The rrun group's overhead was
self-imposed diligence (payload files, `-n` dry-runs, hash cross-checks).

**How the stock group survived is the real finding:**

1. **Payload shrinking**: e.g. `printenv PATH` chosen explicitly so no `$`
   had to survive three quoting layers — the hazard was dodged, not crossed.
   Works only while the payload is negotiable.
2. **Context pinning**: winning commands were correct-once but fragile —
   "must run from PowerShell 7, not Git Bash (wsl is a wrapper function
   there)"; PowerShell `''`-doubling that is meaningless in bash.
3. **When the payload was hostile and fixed, the stock agent reinvented
   rrun's transport ad hoc**: `printf <b64> | base64 -d | ssh a 'ssh b "ssh c
   \"cat > file\""'` — payload-as-data, hand-rolled, correct, and the
   slowest run of all eight (179s vs rrun's 106s). When dodging was
   impossible, the control group's optimum was rrun-without-rrun. Convergent
   evolution is the strongest design validation a control can give.

Advisory behavior in the B group was exactly as designed: it fired on the
hand-quoted forms, and agents bypassed it *deliberately and documented why*
(the constraint is a sanctioned bypass case). Warn-only + informed override
worked as intended.

**Caveats:** (a) contamination — stock agents worked inside this repo, so
README/CLAUDE.md taught them the base64 *idea* even while the constraint
denied them the tool; a naive control in a foreign directory would likely do
worse. (b) Fresh, single-purpose, top-tier-model agents whose whole job was
the boundary — the best case for hand-quoting. (c) n=4 pairs, one machine.

**Adoption-UX findings banked:**
- One rrun-group agent didn't realize the shims make `rrun` work directly
  from Git Bash/PowerShell: it wrapped rrun in `wsl -e bash -lc "rrun ..."`
  and silenced the resulting advisory with `# no-rrun`. Where-rrun-lives
  needs to be more obvious than it is.
- Subagent transcripts under-record hook firings for Bash-tool calls (a
  firing provable from the detector and confirmed by the agent's own report
  was absent from its transcript JSONL) — transcript-based adoption metrics
  undercount.

## Experiment 3: uninstall before/after (4 agents, real tool absence)

Experiment 2's control arm was contaminated: the constraint forbade rrun, but
the tool (and its shims, wrappers, and hook) still existed. `uninstall.ps1`
(added for this) removes all of it — so the "before" arm ran on a machine
where rrun was genuinely uninstalled (verified 6/6 by the uninstaller's
self-check), and the "after" arm ran minutes later on the same machine after
`install.ps1` (verified by the full suite). Identical prompts, no
tool-related constraint at all — just "don't install anything".

| Task | BEFORE (uninstalled) | AFTER (installed) |
|---|---|---|
| 3-hop chain report | OK on 2nd try — 11 calls, 32.3k tok, 144s, **one silent-corruption incident** | OK first try — 4 calls, 34.1k tok, 51s |
| hostile literal through 3 hops | OK — 8 calls, 34.5k, 99s | OK — 7 calls, 58.2k, 109s (extra self-verification) |

Two findings, one flattering and one damning — both deserve the emphasis:

**The capability side (genuinely excellent).** Uninstalling did not stop the
agents. Both "before" agents noticed rrun was absent and **ran it from the
repo checkout instead** (`wsl -e bash /mnt/c/.../rrun/bin/rrun ...`) — a
legitimate reading of "work with what the machine has", and the same
resourcefulness the Experiment-2 stock agent showed by reinventing base64
armoring. Consequence for methodology: *an uninstall is not a control for
agents working inside the tool's own repo* — a clean tool-absent arm needs a
neutral working directory, out of reach of this session's project context.

**The failure side (they failed hard, and silently).** Absence of the
INSTALLED entry points still exacted the exact price the tool exists to
prevent. Without the shims, reaching the repo copy required hand-quoting one
outer layer (`wsl -e bash -lc "..."`), and that single layer ate a
backslash: `printf %s\n` degraded to a literal `n` and the agent's FIRST
answer reported the remote PATH as `.../snap/binn` — a **silent corruption,
shipped as a confident result**, caught only because the agent got
suspicious and re-ran with `echo`. It cost 11 tool calls and 144 s against
the installed twin's 4 calls and 51 s. The controlled kicker: the installed
"after" agent used the *identical* `printf "%s\n" "$PATH"` idiom through
rrun and it came back byte-perfect, first try — same task, same idiom, same
model; the only variable was whether the boundary was hand-quoted. That is
the first real corruption incident in 19 agent runs across these
experiments, and it appeared the moment the installed tool was absent.

Score on the four outcomes that matter (see the long-context design below):
before-arm produced 1 silently-wrong-then-corrected and 0 give-ups; after-arm
produced 0 incidents. Tokens were a wash (before 66.7k / after 92.3k — the
after hostile agent spent freely on double verification); wall time favored
installed 160s vs 243s.

## Designed, NOT yet run: the long-context experiment

Both experiments above test the regime where agents are fresh and the
boundary is the task. Every known failure — the 402-command audit, the
2.4.0 adoption audit, the field report of an agent abandoning a 3-deep ssh
chain — comes from the *other* regime: long context, boundary incidental to
some larger goal. Design for testing that regime:

1. **Bury the boundary in a bigger job.** Give each agent a multi-step
   primary task (e.g. "diagnose why service X misbehaves and write a report")
   whose 6th or 7th step incidentally requires a hop-chain command or a
   hostile-payload transfer. Measure whether the boundary step degrades:
   tool choice, retries, give-ups, silent wrong answers (the PATH trap
   generalizes: seed remote-vs-local differences that corrupt quietly).
2. **Pre-inflate the context.** Before the boundary step, force each agent
   through substantial unrelated reading (large file summaries) so the
   CLAUDE.md rules are tens of thousands of tokens behind the cursor.
   Compare advisory-on vs advisory-off (hook temporarily disabled for the
   control arm) — the hypothesis is the hook's value concentrates exactly
   here, because it re-injects the rule at the moment of the mistake, at
   zero distance from the cursor.
3. **Degrade gracefully across model tiers.** Rerun the same buried-boundary
   task on smaller/cheaper models. Hypothesis: hand-quoting competence falls
   off faster than tool-use competence, so rrun's success-rate delta (and
   the retry-loop token burn it prevents) grows as the model shrinks.
4. **Score four outcomes per run**: correct, silently-wrong (trap value
   corrupted), gave-up/escalated, retry-looped (tool calls on the boundary
   step). Token/time totals matter less than the silent-wrong and give-up
   rates — those are the field-failure modes.
5. **Keep the chain infra as a committed helper** (the per-link provisioning
   script from this experiment is ~40 lines against the matrix node image)
   so the experiment is one command to stand up and tear down.

Expected result, stated as a falsifiable bet: in the buried-boundary regime,
advisory-on agents beat advisory-off agents on give-up and silent-wrong
rates, and the rrun path's *variance* advantage (worst case = best case)
dominates any small average token cost. If that bet loses, the advisory is
decoration and should be reconsidered.
