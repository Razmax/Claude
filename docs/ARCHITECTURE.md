# Architecture

## The data model

```
Service_Queue__c ────< Service_Agent_Queue__c >──── Service_Agent__c ──── User
       │                                                    │
       │                                                    │
       └──────────< Service_Work_Item__c >──────────────────┘
                              │
                              └──< Service_Routing_Event__c
```

**`Service_Queue__c`** — a place work waits. Carries its own routing model, push timeout,
SLA, capacity weight, overflow target and business hours. Two queues can behave completely
differently, which is the point: Credit doesn't have to accept Customer Service's rules.

**`Service_Agent__c`** — one per user. Holds presence, capacity, current load and skills.
Created automatically the first time someone opens the console, so there is no onboarding
step to forget.

**`Service_Agent_Queue__c`** — which agents serve which queues, with a skill level (1–5)
and a membership priority (1 = primary queue). Skill Based routing reads both.

**`Service_Work_Item__c`** — the unit that gets routed. Deliberately *not* the Case: work
items have their own lifecycle, can point at any object via `Source_Record_Id__c`, and can
be created, transferred and completed without touching the underlying record. One case can
generate several work items over its life (initial triage, then a credit review).

**`Service_Routing_Event__c`** — the audit trail. Every assignment, decline, timeout,
transfer and escalation.

## Configuration lives in custom metadata

Three types, all deployable and all editable by an admin in Setup:

- **`Service_Routing_Setting__mdt`** (record: `Default`) — the org-wide switches: master
  on/off, push timeout, max declines, decline cooldown, SLA escalation threshold, log level.
- **`Service_Presence_Status__mdt`** — the presence vocabulary. Each status says whether it
  accepts work, which channels it accepts, and whether it caps capacity.
- **`Service_Routing_Rule__mdt`** — ordered rules that map a source record to a queue,
  priority, weight, required skills and SLA.

Custom metadata rather than custom settings or a custom object because it deploys with the
code, versions in git, and is readable in Apex without a SOQL query against limits.

## The routing pass

`RoutingEngine.assign()` is the whole thing, and it runs the same way whether triggered by
a new case, an agent going available, a supervisor clicking Route Now, or the scheduler.

1. **Load routable work** — status Pending, Routing or Declined, with a queue, ordered by
   queue priority, then item priority, then oldest first.
2. **Load open queues** — active, and inside business hours if the queue names any.
3. **Build the candidate pool per item.** An agent is eligible only if *all* of these hold:
   active, presence accepts work, presence accepts this channel, holds every required
   skill, is a member of the queue, is not currently excluded by a decline, and has enough
   remaining capacity for this item's weight.
4. **Pick one** via the queue's strategy.
5. **Commit once** — agents, work items and platform events in a single pass, with partial
   success so one bad row can't strand the other 199.

The engine owns the hard constraints; strategies only express preference. That split is
what makes a custom strategy safe to write: you cannot accidentally overload an agent or
route to someone who lacks a required skill, because the engine never offers them.

## Strategies

`IRoutingStrategy` has one method:

```apex
Service_Agent__c selectAgent(RoutingContext context);
```

`RoutingContext` hands you the pre-filtered candidates, their projected load (including
assignments made earlier in the same transaction), their skill level on this queue and
their membership priority. Return one, or `null` to leave the item queued.

Four ship in the box — `LeastActiveRoutingStrategy`, `MostAvailableRoutingStrategy`,
`RoundRobinRoutingStrategy`, `SkillBasedRoutingStrategy` — and all four are about twenty
lines. Writing a fifth is a small job.

## Capacity is derived, not counted

`WorkItemService.recalculateAgentLoad()` recomputes an agent's load by aggregating their
open work items rather than incrementing and decrementing a counter. It costs one more
query, and in exchange a failed DML, a manual record edit or a half-finished job can never
leave someone permanently stuck at "full". The supervisor panel exposes it as a
**Resync capacity** button.

## Why routing runs asynchronously

Routing from a trigger would mean DML on the records the trigger is already holding. So
the trigger enqueues, and `RoutingEngine.suppressTriggerRouting` guards against a routing
pass triggering another routing pass. Service methods suppress the trigger entirely,
because they already recalculate capacity and decide about routing explicitly.

## Real-time updates

Assignments publish a `Service_Work_Assigned__e` platform event. The console subscribes
via `empApi` and refreshes. Streaming can drop, so the console also polls every 30 seconds
— the event makes it feel instant, the poll makes it correct.
