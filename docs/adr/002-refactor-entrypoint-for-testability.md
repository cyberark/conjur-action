# ADR-002: Refactor entrypoint.sh for testability?

## Status

Resolved / Closed

## Context

`entrypoint.sh` is a single monolithic script, and there was an open
question of whether it was worth refactoring (e.g. splitting into smaller
sourceable functions, injecting a random-source dependency, etc.) purely to
make certain edge cases easier to cover with tests - notably the
env-delimiter-collision guard in `set_secrets`, which picks a heredoc
delimiter as `EOF_$RANDOM$RANDOM$RANDOM`.

## Decision

No refactor is needed. The guard is testable today with zero production
code changes: unsetting and reassigning `$RANDOM` (`unset RANDOM; RANDOM=42`)
strips bash's special dynamic behavior for that variable for the rest of
the shell (and any subshells forked from it, including command
substitutions), making it deterministic. This lets a test force the exact
delimiter `set_secrets` will generate and assert the collision path is
rejected, without touching `entrypoint.sh`.

See `test_set_secrets_rejects_delimiter_collision` in
`test/entrypoint_test.sh` for the resulting test.

## Consequences

- The "refactor entrypoint.sh for testability" question is closed - it was
  the only concrete blocker cited for it, and it's no longer a blocker.
- No architectural changes to `entrypoint.sh` are required to reach full
  unit-test coverage of this guard.
