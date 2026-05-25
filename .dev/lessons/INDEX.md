# Lessons index

> Lessons are re-derivable observations distinct from load-bearing
> ADRs. Promote a lesson to ADR when any of the following holds:
> - Same observation cited 3+ times
> - One path adopted, alternatives explicitly rejected
> - ROADMAP / Phase / scope decision rests on it

## Categories (populated as lessons emerge)

### Cluster A: Implementation patterns

- [`phase_deferred_scaffolds.md`](phase_deferred_scaffolds.md) —
  Phase-deferred scaffolds lose their homing path; complementary
  detection layers (check_test_reach / lazy decl ride-along /
  debt review); the aspirational-rule sibling (cross-cluster, see
  also Cluster E).

### Cluster B: Clojure semantics

(empty — see `.claude/rules/clojure_spec_citation.md` for the discipline)

### Cluster C: File size and refactor discipline

(empty — Phase 5+ expected when collections split happens)

### Cluster D: Process and documentation

(empty)

### Cluster E: Debugging and tooling

- See cross-cluster reference: `phase_deferred_scaffolds.md`
  (Cluster A) covers the test-orphan + compile-error-orphan
  diagnostic + the `check_test_reach.sh` gate that catches them.

## Lesson file format

Each lesson is `.dev/lessons/<slug>.md`:
- 100-300 lines
- Title + Date + Cluster
- Observation (3-5 sentences)
- Concrete event (commit SHA, test case if available)
- Lesson (what to do next time)
- Related ADRs (link by ID, not path)
