# Map: <feature slug>

<!-- For tickets too big or foggy to pin down in one intent pass (skill 1-intent).
     Each session resolves the top Unknown and moves it to Decided. When Unknown
     is empty, write intent.md. The intent gate stays on intent.md, not this file. -->

- Date started: YYYY-MM-DD
- Sessions: 0   <!-- increment each session; cap 6, or 2 growing sessions in a row (skills/1-intent) -->

## Destination
<What "arrived" looks like: a spec you could write, a decision made, a behavior shipped.>

## Decided
<One line per decision, newest last. Label evidence like intent claims.>
- <decision> [verified: how | decided-by: who, when]

## Unknown
<Ordered: the top question is the next session's work. Name what would resolve
each one — a probe, research, or a human answer.>
- <open question — resolved by: <probe | research | ask human>>

## Out of scope
- <what this ticket will not do>
