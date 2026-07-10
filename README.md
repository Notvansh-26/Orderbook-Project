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

```
bids:  map<Price, list<Order>, greater<Price>>   // begin() = best bid
asks:  map<Price, list<Order>, less<Price>>      // begin() = best ask
index: unordered_map<OrderId, {side, price, list::iterator}>
```

- **Prices are integer ticks** — floating point is never used for money.
- **Matching** walks the best opposite levels while the incoming order
  crosses, filling in FIFO (time-priority) order. Trades print at the
  *maker's* price.
- **Cancels are O(1)** after the hash lookup: `std::list` iterators remain
  valid under erasure of other elements, so the index can point straight
  at the resting order. Real markets are mostly cancels, so this path
  matters as much as matching.

Complexity: add/match is O(log L) to locate a level (L = live price
levels) plus O(1) per fill; cancel is O(1) amortized.

## Results

1M simulated ops (55% limit adds near the touch, 40% cancels, 5% market
orders, random-walking mid), single thread, `-O2`, MinGW GCC 6.3:

```
throughput     : ~3.7M ops/sec
latency p50    : 200 ns
latency p99    : 700 ns
latency p99.9  : 1.7 us
```

Timing uses `QueryPerformanceCounter` on Windows — this toolchain's
`std::chrono::high_resolution_clock` ticks at 15.6 ms, which silently
produces garbage percentiles. Verify your clock before trusting a
benchmark.

## Live feed

`feed/binance_feed.py` implements Binance's documented depth-sync
procedure (REST snapshot + diff stream stitched by update id, sequence-gap
detection with automatic resync) and emits a normalized text protocol;
`feed_consumer.exe` maintains the replica and reports top-of-book once per
second. The consumer exits non-zero if the book ever crosses (bid >= ask),
which would indicate a sync bug. Python (3.10+, `websockets`, `requests`)
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

## Research: order book imbalance

`run_feed.cmd btcusdt research\quotes.csv` records every top-of-book
change. `research/imbalance_study.py` then tests whether top-of-book
imbalance — `bid_qty / (bid_qty + ask_qty)` — predicts the direction of
the mid-price move over the next N seconds: chronological 70/30
train/test split, tail-threshold signals calibrated on train only,
hit rates reported against the test-set base rate.

```
python research/imbalance_study.py research/quotes.csv --horizon 5
```

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
- [ ] Replace `map`/`list` with cache-friendly structures (price-indexed
      array of levels, intrusive lists, object pools) and measure the delta
- [ ] Order modify (cancel-replace) with correct queue-priority semantics
- [ ] IOC / FOK / post-only order types
- [ ] Longer data collection sessions + trade-stream (aggressor) data for
      the imbalance study
