# Custom Service Routing for Salesforce

A work routing engine you own end to end — the Omni-Channel model (presence, queues,
capacity, skills, push with accept/decline) rebuilt as ordinary Salesforce metadata so
Customer Service and Credit can change how it behaves without waiting on a release or
fighting a feature you can't configure.

## Why this exists

Omni-Channel works well until a team asks for something it doesn't do. Then you're stuck.
Here, every routing decision is either **custom metadata** (an admin edit), a **Flow**
(a drag-and-drop change), or an **Apex strategy class** (a small, isolated class that
implements one method). Nothing important is buried in a black box.

## What you get

| Capability | Omni-Channel | This |
| --- | --- | --- |
| Presence statuses | Fixed set-up object | Custom metadata — add "Credit Review", "Second Look", anything |
| Capacity | Units per status | Units per status, **plus per-item weight** — a credit file can count as 2, a callback as 1 |
| Routing model | Least Active / Most Available | Those two, plus Round Robin, Skill Based, or your own Apex class per queue |
| Routing rules | Setup-level, rigid | Custom metadata rules on any object and field, reorderable, two conditions each |
| Push timeout | Org-wide | Per queue |
| Decline | Limited | Per queue, with cooldown, exclusion memory and a max-declines safety valve |
| Overflow | Not really | Per queue: after N minutes, move to another queue |
| SLA escalation | Via other features | Built in — priority bumps at a configurable % of SLA |
| Changing behaviour | Support case | Edit a custom metadata record |

## Layout

```
force-app/main/default/
├── objects/              Service_Queue__c, Service_Agent__c, Service_Agent_Queue__c,
│                         Service_Work_Item__c, Service_Routing_Event__c,
│                         three custom metadata types, one platform event
├── classes/              Routing engine, strategies, lifecycle service, Flow actions, controllers
├── triggers/             One trigger on Service_Work_Item__c
├── lwc/                  serviceAgentConsole (the utility-bar widget), serviceSupervisorPanel
├── flows/                Case → create work item, Case closed → complete work item
├── customMetadata/       Sample settings, 10 presence statuses, 3 routing rules
├── permissionsets/       Service Routing - Agent, Service Routing - Supervisor
└── applications/         "Service Routing" console app with the utility bar wired up
```

## Quick start

```bash
sf project deploy start --source-dir force-app --target-org <your-org>
sf org assign permset --name Service_Routing_Supervisor --target-org <your-org>
sf apex run --file scripts/apex/create_sample_queues.apex --target-org <your-org>
```

Then read [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the post-deploy steps (scheduling
the heartbeat, adding agents) and [`docs/CUSTOMIZATION.md`](docs/CUSTOMIZATION.md) for the
"they asked for X, change Y" playbook.

## How work flows

1. Something happens — a case is created, a Flow fires, an agent clicks a button.
2. A **work item** is created and a **routing rule** picks its queue, priority, weight,
   required skills and SLA.
3. The **routing engine** finds agents who are members of that queue, present, accepting
   that channel, holding the required skills, and with capacity left.
4. A **strategy** picks one of them. Least Active by default; per queue you can choose
   Most Available, Round Robin, Skill Based, or name your own class.
5. The item is pushed to the agent's console. They **accept** or **decline**. Declines
   remember who declined so it doesn't bounce straight back.
6. No response before the queue's push timeout? It returns to the queue automatically.
7. Closing the case **completes** the work item and frees the capacity.

Every step writes a `Service_Routing_Event__c` row, so "why did this land on Dana?" is a
related list, not an investigation.

## Continuous delivery

Three GitHub Actions workflows ship with the project, using JWT auth so no browser
login or refresh token is stored anywhere:

- **Pull request** → validates against QA (compiles, runs all local tests, changes nothing)
- **Merge to `main`** → deploys to QA
- **Manual** → validates against production, waits for a named human to approve, then
  quick-deploys the already-validated payload

Setup is in [`docs/CI_SETUP.md`](docs/CI_SETUP.md) — connected apps, key pairs, secrets
and the approval gate.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the data model and the decisions behind it
- [`docs/CUSTOMIZATION.md`](docs/CUSTOMIZATION.md) — how to answer team feedback without code
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — deploy, configure, schedule, test
- [`docs/CI_SETUP.md`](docs/CI_SETUP.md) — GitHub Actions deployment to QA and production
