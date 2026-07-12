# Limit Order Book & Matching Engine

A price-time priority limit order book in C++14, with a matching engine,
invariant tests, a latency/throughput benchmark under simulated realistic
order flow, and a **live Binance feed handler** that maintains a real-time
replica of the BTC/USDT depth-of-book.

## Architecture

```
                          simulated flow          live market data
                               |                        |
                        bench/benchmark        feed/binance_feed.py
                               |                (websocket + snapshot
                               v                 sync, normalization)
                    src/order_book.hpp                  | stdout pipe
                    (matching engine, L3:               v
                     individual orders,        feed/feed_consumer.cpp
                     price-time priority)               |
                                                        v
                                               src/depth_book.hpp
                                               (L2 replica: aggregate
                                                qty per price level)
```

Two book types on purpose: exchange-style **L3** (every order, matched by
the engine) and **L2** (aggregated levels from public market data). L2
updates are authoritative state, not orders — running them through the
matching engine would generate phantom trades on transiently crossed
levels, so they get their own structure.

## Design

Two interchangeable implementations of the same engine, tested against
each other by one templated suite:

**`order_book.hpp`** — the readable baseline:

```
bids:  map<Price, list<Order>, greater<Price>>   // begin() = best bid
asks:  map<Price, list<Order>, less<Price>>      // begin() = best ask
index: unordered_map<OrderId, {side, price, list::iterator}>
```

**`fast_order_book.hpp`** — the cache-friendly rewrite:

```
levels: vector<Level>            // indexed by price tick directly
pool:   vector<Node>             // all orders, contiguous, free-listed
index:  IdMap                    // open-addressing OrderId -> pool slot
```

A `Level` is just head/tail indices into an **intrusive doubly-linked
FIFO**: the prev/next links live inside the 32-byte order nodes, which
come from an **object pool** that recycles dead nodes (steady state does
zero heap traffic). Finding a level is one indexed load instead of a
red-black-tree walk; best-price cursors step linearly across the 8-byte
levels when a level empties — near the touch the next occupied level is
1–2 ticks away, and one cache line holds 8 levels. The trade-off: prices
must live in a bounded tick band (real venues enforce price bands too).
The id index (`id_map.hpp`) is a flat linear-probing hash map with
backward-shift deletion — no per-entry heap nodes, no tombstones —
because real flow is mostly add/cancel pairs hammering exactly that map.

Shared semantics:

- **Prices are integer ticks** — floating point is never used for money.
- **Matching** walks the best opposite levels while the incoming order
  crosses, filling in FIFO (time-priority) order. Trades print at the
  *maker's* price.
- **Cancels are O(1)** after the hash lookup (stable `list` iterators in
  the baseline, stable pool indices in the fast book). Real markets are
  mostly cancels, so this path matters as much as matching.
- **Cancel-replace** (`modify`): shrinking quantity at the same price
  edits in place and *keeps queue priority*; a price change or size
  increase re-enters at the back of the queue and may trade immediately.
- **Time-in-force**: GTC, IOC (remainder discarded), FOK (all-or-nothing,
  checked against crossable liquidity *before* executing, so a kill
  leaves the book untouched), and post-only (rejected rather than ever
  taking liquidity).

## Results

1M simulated ops (55% limit adds near the touch, 40% cancels, 5% market
orders, random-walking mid), single thread, `-O2`, MinGW GCC 6.3. Both
books consume the identical seeded op stream in one run — same benchmark,
same machine, back to back:

```
                 OrderBook (map+list)    FastOrderBook (array+pool+IdMap)
throughput       ~3.7M ops/sec           ~5.0M ops/sec   (~1.4x)
latency p50      200 ns                  100 ns
latency p99      700 ns                  400 ns
```

Both books finish with an identical open-order count — a free cross-check
that the rewrite matches the baseline's behavior op for op.

Timing uses `QueryPerformanceCounter` on Windows — this toolchain's
`std::chrono::high_resolution_clock` ticks at 15.6 ms, which silently
produces garbage percentiles. Verify your clock before trusting a
benchmark.

## Live feed

`feed/binance_feed.py` implements Binance's documented depth-sync
procedure (REST snapshot + diff stream stitched by update id, sequence-gap
detection with automatic resync), subscribes to the aggregate-trade stream
on the same connection, and emits a normalized text protocol;
`feed_consumer.exe` maintains the replica and reports top-of-book once per
second. Each depth event ends with an explicit boundary marker, and the
consumer only observes the book (logging, printing, cross detection) at
boundaries — mid-event the replica can be transiently crossed without
anything being wrong. The consumer exits non-zero if the book is crossed
(bid >= ask) *at a boundary*, which would indicate a real sync bug. Python (3.10+, `websockets`, `requests`)
handles TLS/websocket transport; C++ owns book maintenance.

```
run_feed.cmd btcusdt                                  # Windows
python feed/binance_feed.py btcusdt | ./feed_consumer # Unix shells / cmd.exe

bid 63302.42 x 1.66366 | ask 63302.43 x 4.22483 | spread 0.01 | 2407 upd/s | levels 994/992
bid 63302.42 x 1.79881 | ask 63302.43 x 3.95141 | spread 0.01 |   88 upd/s | levels 995/999
```

**Windows note:** don't pipe the two programs together directly in
PowerShell 5.1 — its pipeline re-encodes text and injects a UTF-8 BOM,
corrupting the stream. `run_feed.cmd` routes the pipe through cmd.exe,
which passes raw bytes. (The consumer also strips a leading BOM and
reports unrecognized lines on stderr, so protocol corruption is loud
rather than silent.)

## Ladder view

`run_ladder.cmd btcusdt` renders the top 10 levels per side as a live
terminal ladder (asks in red above the spread, bids in green below,
quantity bars, 4 Hz refresh) via ANSI escape codes.

## Live candles

`run_candles.cmd btcusdt` opens a chart window with live-forming
mid-price candlesticks (5s per candle by default). The viewer spawns the
feed pipeline itself, tails the consumer's flush-per-row CSV log, and
redraws twice a second; close the window to shut everything down.
`research/candles.py` renders static candles from a recorded session.

## Research: order book imbalance & trade flow

`run_feed.cmd btcusdt research\quotes.csv research\trades.csv` records
every top-of-book change plus every trade tagged with its **aggressor
side** (who crossed the spread). Both CSVs share one monotonic clock, so
they join on `ts_ns`. `research/imbalance_study.py` then evaluates two
signals with the same methodology — chronological 70/30 train/test split,
tail thresholds calibrated on train only, hit rates reported against the
test-set base rate:

- **book imbalance** `bid_qty / (bid_qty + ask_qty)` — who is *queued*;
- **trade flow** (with `--trades`): net signed aggressor volume over a
  trailing window, normalized to [-1, 1] — who is actually *trading*.

```
python research/imbalance_study.py research/quotes.csv --horizon 5 ^
       --trades research/trades.csv --flow-window 10
```

For results that aren't anecdotal, record a session of an hour or more:
event-driven rows accumulate fast (a few thousand quote changes and
hundreds of trades per minute on BTC/USDT), and short sessions are easily
dominated by one directional move.

Prices/quantities are parsed straight into 1e8-scaled `int64`
(`src/fixed_point.hpp`) — market data never touches floating point.

## Build & run

```
g++ -std=c++14 -O2 -Wall -Wextra -Isrc test/test_order_book.cpp -o test_order_book
g++ -std=c++14 -O2 -Wall -Wextra -Isrc test/test_depth_book.cpp -o test_depth_book
g++ -std=c++14 -O2 -Wall -Wextra -Isrc bench/benchmark.cpp -o benchmark
g++ -std=c++14 -O2 -Wall -Wextra -Isrc feed/feed_consumer.cpp -o feed_consumer
./test_order_book && ./test_depth_book
./benchmark 1000000
run_feed.cmd btcusdt
```

## Roadmap

- [x] Consume real market data (live Binance L2 depth feed)
- [x] Terminal "ladder" visualization of the live book
- [x] Top-of-book recording + imbalance research study
- [x] Replace `map`/`list` with cache-friendly structures (price-indexed
      array of levels, intrusive lists, object pools) and measure the delta
      — `src/fast_order_book.hpp`: p50 200→100 ns, ~1.25x throughput
- [x] Order modify (cancel-replace) with correct queue-priority semantics
- [x] IOC / FOK / post-only order types
- [x] Trade-stream (aggressor) data: recorded via `--trades`, evaluated as
      a trailing-flow signal alongside book imbalance
- [x] Custom open-addressing id→order map (`src/id_map.hpp`; linear
      probing + backward-shift deletion; total delta now ~1.4x, p99
      700→400 ns) — verified by a 200k-op differential fuzz that demands
      identical behavior from both books at every step
- [ ] Record a 1–2 hour session and re-run the study on it (in progress)
