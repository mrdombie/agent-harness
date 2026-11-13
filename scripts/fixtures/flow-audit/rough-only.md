# Flow-coverage audit — compliance queue

## The gaps

### GAP-01 · SILENT · Save gives no confirmation
**Axis:** 5 Failure · [EDGE]
**The move:** save an item
**What happens now:** nothing says it saved
**What should happen:** a short saved note

### GAP-02 · ROUGH · Counter jumps on approve
**Axis:** 6 Repeat & race · [EDGE]
**The move:** approve an item
**What happens now:** the count flickers
**What should happen:** the count settles once

## Full row ledger

| # | Axis | Expected flow | Verdict | Evidence |
|---|---|---|---|---|
| E-01 | 1 Entry | Somebody opens the queue from the nav | PRESENT | queue story, nav click |
| X-02 | 7 Exit & aftermath | Somebody leaves an item and wants the queue back | ABSENT | no control |
