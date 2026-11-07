# workspace

The agent setup: Neovim panes, the WezTerm bar, agentd and the commands in `wezterm/bin` share one state, stored as one JSON file per object under `~/.local/state/workspace`.

## Features

| feature | what it covers |
| --- | --- |
| `legio/` | the milites you run, their contubernia, agentd, plan usage |
| `conversations/` | what a miles and you say to each other: transcripts, turns, threads, drafts, questions |
| `workflow/` | the work itself: expeditiones, mandata, review comments, merge requests, diff progress |
| `infra/` | docker, VMs, tailscale, ports, scripts |
| `workbench/` | the frame the features appear in: the WezTerm workspace and its panes, the sidebar, cards |
| `shared/` | the parts every feature uses. It never uses a feature |

`stored_kinds.lua` lists every stored model, so the observer and WezTerm can watch them all. `composition_root.lua` builds the application services for a store and hands them their ports. `cli/main.lua` is the one command line entry; it hands each command to a feature's inbound adapter.

## Layers inside a feature

| folder | holds | uses |
| --- | --- | --- |
| `domain/` | the models: state, rules, state machines | other domains, `shared/lib` |
| `application/` | application services (use cases) and their mappers | its domain, ports handed in by the composition root |
| `infrastructure/inbound/` | ways in: command line, the agentd bridge | application services only |
| `infrastructure/outbound/` | ways out: repositories and their record mappers, gitlab, agentd | domain, `shared` |
| `presentation/nvim/`, `presentation/wezterm/` | what you see | application services only |

Rules:

- Screens, commands and the bridge only call application services. They never require a domain model, a repository or the store.
- An application service gets its repositories and other ports (agents, messenger, git, log, clock) handed in by `composition_root.lua`; it doesn't require infrastructure.
- Repositories sit in a folder named after the storage they use: `infrastructure/outbound/filesystem/review_repository.lua`.

## One model per layer, a mapper at every boundary

Each layer has its own model, and a mapper turns one into the next. DTOs, commands and view models are real types made with `shared/lib/data_class` (`CommentDto.new({ ... })` refuses fields it doesn't have), so a mapper always returns an instance of the model it names.

| layer | its model | mapper | example |
| --- | --- | --- | --- |
| storage | record (the JSON on disk) | `infrastructure/outbound/filesystem/<x>_record_mapper`: `to_domain`, `to_record` | `review_record_mapper` |
| domain | domain model | none, the repository hands it out | `Review`, `Comment` |
| application, in | command | built by the caller's mapper | `SaveCommentCommand`, `ResolveCommentCommand` |
| application, out | DTO | `application/mappers/<x>_dto_mapper`: `to_<x>_dto` | `review_dto_mapper.to_comment_dto` -> `CommentDto` |
| command line, bridge | arguments and printed lines | `infrastructure/inbound/mappers/<x>_cli_mapper`: `to_<x>_command`, `to_<x>_line` | `review_cli_mapper` |
| presentation | view model | `presentation/mappers/<x>_view_mapper`: `to_<x>_view_model`, and `to_<x>_command` for user input | `review_view_mapper.to_comment_view_model` -> `CommentViewModel` |

Queries take plain arguments (`summary(root)`). A change with several fields takes a command; a change that only needs an id takes the id (`runner:stop(miles_id)`, `questions:reply(question_id)`).

A screen maps a DTO to a view model when it reshapes it: formats, combines or renames fields for drawing (`CommentViewModel`, `SessionRowViewModel`, `MeterViewModel`). When a screen would only copy the DTO's fields, it uses the DTO itself (`MilesDto`, `ReviewSummaryDto`). A value with one field is returned as the plain value or table, not wrapped in a type (`to_card_lines` returns the lines).

`workflow`'s review (`review_process`) and `legio/` follow all of this; the other features are being moved over.

## Shared

- `shared/state/`: `store` reads and writes one object per file with locking, `observer` watches the state folder and announces each changed object, `paths` says where things live.
- `shared/providers/<name>/`: the one place that knows the agent runtime behind the sessions: its payloads (mapped to neutral session events with `moment`, `transition`, `tool_name`, `continuing`), session files, locations, env and the hidden attach link. `shared/providers` picks the provider.
- `shared/adapters/`: `nvim` (fs, json, clock, logger for a Neovim process) and `git`.
- `shared/lib/`: model base class, state machine, event bus, log, format.

## Domain language: the legion

The domain speaks Latin, after the Roman army. Code, stored folders and screens use these words; the English after each one is only there to explain it.

### Who

| unit (plural) | leader | what it is |
| --- | --- | --- |
| exercitus | you, the commander | your whole army: every legio you have raised |
| legio (legiones) | legatus: you as well | a standing body of milites with a name such as `Legio IV Obsidionalis`. You deploy a legio on an expeditio. |
| cohors (cohortes) | primus pilus | the milites working in one codebase. It forms as soon as a second miles starts in that codebase. |
| auxilium (auxilia) | the miles who called him in | a helper for one narrow job. He reports back to his caller, ends his session and earns no rank. |
| centuria (centuriae) | centurio, with an optio as second | the milites working on one expeditio |
| contubernium (contubernia) | decanus | up to eight milites working one mandatum together, each in a role |
| miles (milites) | | one agent with a Roman name (Gaius, Marcus, Lucius, Titus, Quintus…). A miles lives as long as its context: it can stop and be resumed, and it falls when its context is nearly full (see below). |

### What

| work (plural) | what it is |
| --- | --- |
| expeditio (expeditiones) | a campaign: a goal for one codebase, broken into mandata. Replaces the epic. |
| mandatum (mandata) | an objective: a title, a description and Given/when/then criteria, handed to a contubernium. Replaces the todo. |

### Rank

A miles earns experience by finishing mandata and expeditiones, and moves up the three lines of the old legion:

| rank (plural) | earned by |
| --- | --- |
| hastatus (hastati) | the starting rank |
| princeps (principes) | 3 finished mandata |
| triarius (triarii) | 10 finished mandata or 3 finished expeditiones |

Leaders (decanus, centurio, primus pilus) are picked from principes and triarii.

### Roles and models

- A miles in a contubernium has one role and only does that role: **faber** writes the code, **probator** writes and runs the tests, **censor** reviews. Its instructions say so, and it reports to its decanus.
- The model follows the position, not the rank: milites doing the work run on the smallest model (haiku), a decanus on a middle one (sonnet), a centurio, an optio and a primus pilus on the strongest (opus).

### Three legiones, three duties

Each legio has a **munus** (duty), which decides the roles it fields and what its mos maiorum collects:

| legio | munus | roles it fields |
| --- | --- | --- |
| Legio X Rapax, "the seizing": it attacks | implementing: turning mandata into working code | faber, probator, censor |
| Legio IV Obsidionalis, "of the siege": it besieges | quality: checking things work and trying to break them | probator, censor |
| Legio IX Speculatrix, "the watching": it scouts | exploring: using the computer and Chrome to test by hand, finding out and explaining how things work | explorator (scout), who reports back what he found |

The names follow the old style, a numeral and a cognomen. *Rapax* was a real legion's name; *Obsidionalis* comes from the *corona obsidionalis*, the grass crown, Rome's highest honour, given for breaking a siege; *Speculatrix* comes from the *speculatores*, the army's scouts.

### Deploying a legio

You command the exercitus and each legio yourself, and you deploy a legio on an expeditio. The legio then musters itself for it:

1. It forms a cohors in the expeditio's codebase, or joins the cohors already there.
2. A centuria takes the expeditio, with a centurio and an optio picked from its highest ranks. The legio's stopped principes and triarii are resumed for this: the first triarius becomes centurio and a second triarius optio. The principes (then any other triarii) lead the contubernia, and a veteran left over after that becomes optio. Veterans of equal rank are ordered by roman name. A place no veteran can fill goes to a new hastatus, and no veteran is left unused while a place is filled by a new miles.
3. Each mandatum goes to a contubernium: a decanus, and milites in the roles the mandatum needs (faber, probator, censor), each running the model that fits its position.
4. When the expeditio is finished, the result goes into the legio's annales. What it learned goes into its mos maiorum, and the milites who finished mandata gain rank.

A legio only takes one expeditio at a time. You pick the legio by its munus: Rapax to implement, Obsidionalis to test and break it, Speculatrix to explore and explain.

### The legio carries on

A legio outlives its milites, the way the real legions kept their name and standing for centuries:

- Its **name** (`Legio XVI`) stays, and it earns a **cognomen** (an honour name, such as *Victrix*, "victorious") after three finished expeditiones.
- Its **annales** (record) list every expeditio it fought, and every miles who served, rose in rank or fell.
- Its **mos maiorum** ("the custom of the ancestors") is what it has learned: conventions and lessons drawn from finished expeditiones and traditiones. Every new miles and every supplementum receives it with his first order.

### Falling and the handover

A miles whose context fills up is lost, as if he died in battle. So he hands over before that happens:

1. When his context reaches the handover mark (90% by default), the miles is told to write a **traditio**, a handover: the mandatum, his branch and worktree, what is done, what is left, what he was about to do, and anything he was waiting on.
2. He is then marked **fallen** and stopped. His record keeps the mandata and expeditiones he finished.
3. A **supplementum**, a replacement miles with a new name, joins his contubernium at the rank of hastatus. It starts with the traditio as its first order and takes over his role, branch and mandatum.
4. When a leader falls, his second steps up: the optio becomes centurio, and in a contubernium the highest-ranked miles becomes decanus. The supplementum fills the empty place below.

### Not yet

Other troop types come later.

### Code names

Model files use the singular (`miles.lua`, `contubernium.lua`, `centuria.lua`, `cohors.lua`, `legio.lua`, `expeditio.lua`, `mandatum.lua`); stored folders and lists use the plural (`milites/`, `contubernia/`, `expeditiones/`, `mandata/`). Old folders are moved once by a migration script (`agents/` and `teams/` by `migrate-legio.sh`; `epics/` and `todos/` by `cli/main.lua migrate-workflow`, which copies them to `expeditiones/` and `mandata/` and leaves the old folders alone; it is safe to run twice).

## Terms

- **miles** (plural **milites**): one session of a coding agent that we track (`legio/domain/miles`). It runs in a terminal or inside agentd. The milites are stored under `milites/`.
- **miles process**: what the process running a miles reports: model, context used, permission mode, whether it's still connected (`legio/domain/miles_process`).
- **session event**: something that happened in a miles' session: started, prompt sent, tool starting, turn finished, ended. `legio/application/miles_session_events` applies them.
- **session files**: the provider's list of running sessions on disk. `miles_session_repository` reads it and `miles_session_events.sync_session_files()` brings our milites in line with it.
- **agentd**: the Node daemon in `agentd/` that runs milites in-process.
- **agentd bridge**: agentd's way into the state. agentd starts `cli/main.lua bridge` and sends it session events, process reports and questions over stdin; `legio/infrastructure/inbound/agentd_bridge` handles them.
- **question**: a miles stopped and waiting for you, for a permission or a choice. `legio/application/miles_questions` opens them, records answers and dismisses open ones.
- **session row**: a row in the sidebar's session list: a running miles, an old transcript to resume, or a draft that starts a new one.
- **expeditio**: a titled group of mandata in one repo. **mandatum**: a title, a description and Given/when/then criteria, handed to a miles. Mandatum changes go through `workflow/application/mandatum_process`; merge requests through `merge_request_process` (`gitlab.lua` only talks to the GitLab API); diff progress through `diff_progress_process`. The `todo` command is still accepted as an alias of `mandatum`.
- **contubernium** (plural **contubernia**): milites working on one mandatum, led by their **decanus**. Stored under `contubernia/`; its members talk through `wezterm/bin/contubernium`. `contubernium_membership.remove_miles` hands the mandatum on when one leaves.
- **roster**: `legio/application/roster`, the queries over the milites and contubernia: who runs where, a contubernium's stack, agentd status.
- **legio process**: `legio/application/legio_process`. It raises the three standing legiones, lists them for the sidebar, deploys one on an expeditio and credits finished mandata and expeditiones (`credit_finished`). It also carries reports and orders along the chain of command.
- **muster**: `legio/domain/muster`, the plan a deploy follows: a centuria with a centurio and an optio, one contubernium per open mandatum, a roman name, post, model and first order for each miles.
- **chain of command**: `legio/domain/chain_of_command`. A miles reports to his decanus, a decanus to his optio (to his centurio only for decisions, blockers and a finished mandatum, with `--kind`), an optio to his centurio, and a centurio to the primus pilus when there is a valid one, otherwise to you in his replies. Orders go the other way.
- **handover process**: `legio/application/handover_process`. Its Stop check asks a miles with a post for his traditio at the handover mark. `hand_over` marks him fallen, steps his second up, starts the supplementum and stops the fallen miles last.
- **legio command**: `wezterm/bin/legio`, run by milites from their session. It has three subcommands: `report "<message>"`, `order <name|all> "<message>"` and `traditio "<handover>"`. `legio/infrastructure/inbound/legio_cli` handles it.
- **review**: comments on a worktree's diff (stored under `reviews/`). Everything goes through `workflow/application/review_process`.
- **workspace**: one WezTerm workspace and its panes.
- **screen state**: what a feature's screen shows right now, kept per workspace so the panes (separate Neovim processes) and the WezTerm bar agree. Each feature owns its own in its presentation folder: `conversations/presentation/conversation_screen` (selected miles and turn, open draft, question, shown mandatum or expeditio, search and pick requests), `workbench/presentation/sidebar_screen` (sections), `infra/presentation/infra_screen` (docker summary). Screen state isn't domain, so presentation saves it itself through `app.update_screen`.

## Names

- A plain noun is a model (`todo.lua`). A `_process`, `_events`, `_membership`, `_runner`, `_questions`, `_thread`, `roster` or `inquiry` file is a use case; `muster` and `chain_of_command` are domain rules, a `_repository` loads and saves, a `_cli` is a command, a `_panel`, `_view` or `_pane` is on screen.
- `hydrate(parts)` fills a model with related data loaded from other files. None of it is saved back.
- Bridge methods for incoming messages start with `on_`: `on_session_event`, `on_question`, `on_sessions_running`.
