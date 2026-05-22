# Factrail

> A local-first data foundation for understanding agentic workflows.

Factrail captures what agents did, used, spent, and produced — across tools, models, providers, and execution environments.

It turns heterogeneous agent logs, conversations, tool calls, artifacts, and usage records into a normalized, queryable, and attributable execution data layer.

## Why Factrail exists

Agentic workflows are spreading across coding, research, writing, operations, and other domains. Each agent or provider emits a different shape of data: conversation logs, JSONL events, tool calls, command executions, local files, token counters, model usage, or partial traces.

Without a common data layer, it is hard to answer basic questions:

- What did the agent actually do?
- Which session, turn, step, tool call, or artifact produced a result?
- How many tokens, credits, or seconds were consumed?
- Which model, provider, tool, MCP server, or sub-agent caused the cost?
- Which numbers are exact, estimated, or unknown?
- How can data from Codex, Claude Code, OpenCode, OpenClaw, and future agents be compared safely?

Factrail focuses on the underlying execution facts. Scenario-specific interpretation belongs in upper-layer skills and products.

```text
Factrail user stories = data foundation value
Upper-layer skills   = scenario value
```

## Project scope

Factrail is designed to be a provider-neutral observability and data infrastructure layer for agent execution.

It aims to capture and normalize:

- sessions, threads, turns, steps, and items
- tool calls, MCP calls, shell commands, file changes, web searches, and artifacts
- model usage, token usage, cached tokens, reasoning tokens, credits, and estimated cost
- start time, end time, duration, and execution timeline
- provider-specific fields without pretending every provider exposes the same data
- attribution between usage, time, tools, models, and execution objects
- attribution confidence: `exact`, `estimated`, or `unknown`

## Non-goals

Factrail is not intended to be:

- a coding agent
- a prompt framework
- a business-specific analytics app
- a billing-grade replacement for provider invoices
- a single-provider dashboard that only understands one log format

The goal is to produce stable, reusable facts that other tools can analyze.

## Core concepts

```text
Provider Adapter
  -> Raw Events
  -> Normalized Execution Model
  -> Usage & Cost Events
  -> Attribution Engine
  -> Local Store
  -> Query / Export / Dashboard
```

### Normalized execution model

Factrail uses a shared model across providers:

```text
Workspace
  Project
    Session / Thread
      Turn
        Item
          Tool Call
          Artifact
          Usage
          Duration
```

Typical normalized objects include:

| Object | Purpose |
| --- | --- |
| `Workspace` | Local workspace, repository, or execution root. |
| `Project` | A logical project derived from path, git root, or user mapping. |
| `Thread` / `Session` | A continuous agent conversation or execution session. |
| `Turn` | One agent interaction cycle. |
| `Item` | A reasoning block, command execution, tool call, MCP call, file change, search, or artifact event. |
| `TokenUsageEvent` | Token or credit usage associated with a thread, turn, item, model, or provider. |
| `CostEvent` | Derived cost or credit estimate based on usage and pricing data. |
| `AttributionEstimate` | Mapping from usage or duration to the object believed to have caused it, with confidence metadata. |
| `RawEvent` | Original provider event retained for replay, debugging, or schema migration. |

### Attribution confidence

Not every provider exposes item-level usage or tool-level cost. Factrail therefore treats attribution confidence as a first-class field:

| Level | Meaning |
| --- | --- |
| `exact` | Directly available from the source data. |
| `estimated` | Inferred from timing, deltas, event windows, or provider-specific heuristics. |
| `unknown` | Preserved but not force-assigned when the source data is insufficient. |

Factrail should not manufacture certainty. If usage cannot be attributed reliably, it stays in an unknown bucket.

## Provider strategy

Factrail is adapter-based. New providers should be added without changing the core data model.

Initial provider targets:

| Provider / Source | Target capability |
| --- | --- |
| Codex / OpenAI Codex CLI | Local JSONL usage scan, app-server timeline ingestion, token and cost accounting. |
| Claude Code | Usage parsing and normalized session model. |
| OpenCode | Usage parsing and normalized session model. |
| OpenClaw | Usage parsing and normalized session model. |
| Future agents | Adapter-level integration without core schema rewrites. |

Provider adapters may expose different levels of fidelity. Factrail should preserve those differences rather than flattening them away.

## Codex observability direction

For Codex-oriented workflows, the intended ingestion layers are:

```text
Layer 1: app-server live stream
  - thread / turn / item lifecycle
  - command, MCP, dynamic tool, file change, reasoning, and collaboration events

Layer 2: local JSONL scanner
  - historical usage backfill
  - token_count and turn_context parsing
  - session, model, date, and project aggregation

Layer 3: account or dashboard enrichment
  - optional credits, reset windows, and quota information
```

The important product gap is connecting usage accounting with execution tracing. Community tools already cover parts of this problem, but tool-level, MCP-level, and agent-level token attribution remains largely unsolved.

## Planned architecture

```text
factrail-core
  shared schema, normalization, attribution contracts

factrail-adapters
  provider-specific parsers and event readers

factrail-store
  local-first persistence, likely SQLite or DuckDB for MVP

factrail-cli
  scan, import, query, export, and report commands

factrail-dashboard
  local timeline, usage, cost, and attribution views
```

Potential local MVP storage tables:

```text
workspaces
projects
threads
turns
items
token_usage_events
cost_events
model_prices
attribution_estimates
raw_events
```

## Roadmap

### MVP 1: offline usage and cost dashboard

- Scan local agent session logs.
- Parse token usage and model metadata.
- Normalize input, cached input, output, and reasoning tokens.
- Aggregate by day, month, session, model, and project.
- Estimate cost from model pricing data.
- Store results locally.
- Export JSON and CSV.

### MVP 2: realtime execution timeline

- Connect to live provider event streams where available.
- Capture thread, turn, and item lifecycle events.
- Record command executions, MCP calls, dynamic tool calls, file changes, reasoning blocks, and artifacts.
- Overlay usage deltas on the timeline.

### MVP 3: tool, MCP, and agent attribution

- Attribute usage exactly where source data supports it.
- Estimate attribution from timing and event windows where exact data is unavailable.
- Preserve unknown usage explicitly.
- Expose confidence and method metadata in the schema and UI.

## Design principles

### Local-first

Agent logs may contain code, prompts, documents, credentials, or business context. Factrail should work locally by default and avoid sending raw execution content to external services.

### Metadata over content

The default extraction path should prefer structured metadata over full sensitive payloads.

### Provider-neutral core

Provider-specific adapters can evolve quickly. The core model should remain stable enough for long-term querying and upper-layer product reuse.

### No false precision

Cost, duration, and attribution fields should distinguish precise source facts from inferred estimates.

### Long-term data asset

Agent execution records should accumulate into durable, queryable data, not remain disposable logs.

## Prior art and references

Factrail is expected to learn from and integrate with existing work rather than reimplement everything from scratch:

- [`openai/codex`](https://github.com/openai/codex) as the upstream source for Codex CLI, local data, app-server protocol, and event schema.
- [`ccusage`](https://github.com/ryoppippi/ccusage) for coding-agent usage and cost accounting patterns.
- [`CodexBar`](https://github.com/steipete/CodexBar) for quota, credits, reset window, and local cost scan UX patterns.
- [`CodexMonitor`](https://github.com/Dimillian/CodexMonitor) for realtime Codex app-server, workspace, thread, and timeline UI patterns.

## Status

Factrail is in early development. The README describes the intended data model and product direction; implementation details and public APIs may change.

## License

MIT License. See [LICENSE](./LICENSE).
