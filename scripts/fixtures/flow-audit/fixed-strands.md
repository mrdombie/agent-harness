# Flow-coverage audit — compliance queue

## The gaps

### GAP-01 · STRANDS · No way back to the queue
**Axis:** 7 Exit & aftermath · [CORE]
**Rows:** X-02
**The move:** open an item, finish reading it
**What happens now:** no control returns to the queue
**What should happen:** a Back to queue control is on the item
**Evidence:** item story, every click
**Fixed:** added Back to queue

### GAP-02 · ROUGH · Counter jumps on approve
**Axis:** 6 Repeat & race · [EDGE]
**The move:** approve an item
**What happens now:** the count flickers
**What should happen:** the count settles once

## Full row ledger

| # | Axis | Expected flow | Verdict | Evidence |
|---|---|---|---|---|
| E-01 | 1 Entry | Somebody opens the queue from the nav | PRESENT | queue story, nav click |
| X-02 | 7 Exit & aftermath | Somebody leaves an item and wants the queue back | PRESENT | re-check: item story, Back to queue click |
