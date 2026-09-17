# Deployment and setup

## 1. Deploy

```bash
sf project deploy start --source-dir force-app --target-org <your-org>
```

Run the tests:

```bash
sf apex run test --target-org <your-org> --code-coverage --result-format human --wait 20
```

## 2. Assign permissions

```bash
sf org assign permset --name Service_Routing_Supervisor --target-org <your-org>
# and for each agent
sf org assign permset --name Service_Routing_Agent --target-org <your-org> --on-behalf-of <username>
```

- **Service Routing - Agent** — read queues and memberships, work their own items, set
  their own presence.
- **Service Routing - Supervisor** — full control including reassignment across the team.

## 3. Create queues

The routing rules that ship reference three queues by developer name:
`CUSTOMER_SERVICE`, `CREDIT_REVIEW` and `TIER_2_SUPPORT`. Create them with the sample
script or by hand:

```bash
sf apex run --file scripts/apex/create_sample_queues.apex --target-org <your-org>
```

**Developer Name matters.** Routing rules and Flow actions reference queues by that field,
not by record Id, so a queue can be rebuilt or moved between orgs without breaking rules.

## 4. Add agents to queues

Agent records create themselves the first time someone opens the console. What you do have
to set up is:

- **Max Capacity** — how many capacity units they can hold (default 5).
- **Skills** — semicolon separated, e.g. `CREDIT;SPANISH`.
- **Queue memberships** — a `Service_Agent_Queue__c` row per queue they serve, with a
  skill level (1–5) and membership priority (1 = primary).

```bash
sf apex run --file scripts/apex/add_agent_to_queue.apex --target-org <your-org>
```

## 5. Schedule the heartbeat

The heartbeat expires push timeouts, escalates work approaching its SLA, moves long waits
to overflow queues and sweeps anything still queued. Without it, routing still works on
every case creation and every agent action — but timeouts and escalations won't fire.

From Setup → Apex → Execute Anonymous:

```apex
RoutingScheduler.scheduleEveryQuarterHour();
```

That creates four jobs, giving a 15 minute cadence. For a faster beat, schedule more
copies at finer offsets.

## 6. Wire up the UI

The deployment includes a **Service Routing** console app with the agent console already
in its utility bar. If you'd rather add the console to an existing app:

1. Setup → App Manager → edit your app → Utility Items.
2. Add **Service Routing Console**. Panel width 380, height 560, and tick
   *Start automatically* so agents don't have to remember to open it.

The supervisor panel is available as the **Routing Dashboard** tab, or drop
**Service Routing Supervisor Panel** onto any Lightning page.

## 7. Check the sample configuration

Three routing rules ship as examples and **they will route real cases** once queues exist:

| Rule | Condition | Goes to |
| --- | --- | --- |
| `Case_Credit_Hold` | Case Type in Credit Hold / Credit Review / Credit Limit Increase | `CREDIT_REVIEW` |
| `Case_High_Priority` | Case Priority = High | `TIER_2_SUPPORT` |
| `Case_Default` | anything else | `CUSTOMER_SERVICE` |

Deactivate or edit them in Setup → Custom Metadata Types → Service Routing Rule → Manage
Records before go-live if they don't match your process.

## 8. Turn it on

`Service_Routing_Setting__mdt` → the `Default` record → **Enable Routing**.

Leaving it unticked is a good way to deploy ahead of go-live: work items are created and
queued, but nothing is assigned until you flip the switch.

## Rolling it out safely

1. Deploy with **Enable Routing** off.
2. Create queues, add a pilot group of agents, confirm memberships.
3. Turn on the two Case flows for a narrow record type or a single case type first — a
   flow entry condition is the easiest kill switch.
4. Watch the supervisor panel and the `Service_Routing_Event__c` records for a day.
5. Widen the flow criteria.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| Nothing is being assigned | Is **Enable Routing** on? Is the queue Active? Is anyone in a presence status that accepts work? |
| Work items created with no queue | No rule matched — check the supervisor panel's unrouted count, and that a catch-all rule exists |
| An agent gets nothing | Check their queue membership is Active, their skills cover the work, and their presence accepts the channel |
| An agent appears permanently full | **Resync capacity** on the supervisor panel |
| "Why did this go to Dana?" | The work item's Routing Events related list. Set Log Level to Verbose for candidate-level detail |
| Timeouts never fire | The heartbeat isn't scheduled — see step 5 |
