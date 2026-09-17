# Customization playbook

The point of this system is that team feedback turns into a configuration change, not a
project. This page is organised by what people actually say in a feedback session.

Legend: **Admin** = point and click, no deployment. **Flow** = Flow Builder. **Code** = a
small Apex class.

---

## Presence and availability

| They say | You change | Where | Effort |
| --- | --- | --- | --- |
| "We need a 'Credit Review' status that only takes credit work" | Add a `Service_Presence_Status__mdt` record, set Channels to `Credit Review` | Setup → Custom Metadata Types | Admin |
| "Agents in training shouldn't get three cases at once" | Set **Capacity Override** to 2 on the Training status | Same | Admin |
| "Coaching time needs a reason logged" | Tick **Requires Reason** on that status | Same | Admin |
| "Break shouldn't look available" | Set Status Category to Break and untick **Accepts Work** | Same | Admin |
| "Colour-code the statuses" | Set **Color** to a hex value; the console badge picks it up | Same | Admin |
| "When someone goes to lunch, don't strand the case on their screen" | Already the default — `Requeue On Offline` in settings. Untick to disable | Settings record | Admin |

Note the deliberate split: work an agent **accepted** stays with them when they step away
(they're mid-conversation). Work that was merely **pushed** and not accepted goes back to
the queue.

---

## Who gets what work

| They say | You change | Where | Effort |
| --- | --- | --- | --- |
| "Credit cases should go to the Credit queue" | Add a `Service_Routing_Rule__mdt`: Source Object `Case`, Field `Type`, Operator `In`, Value `Credit Hold;Credit Review`, Target Queue `CREDIT_REVIEW` | Custom Metadata Types | Admin |
| "Route on a different field" | Change **Field 1 API Name** on the rule. Parent fields work too: `Account.Industry` | Same | Admin |
| "We need two conditions" | Use the Field 2 / Operator 2 / Value 2 slots — they AND together | Same | Admin |
| "This rule should win over that one" | Change **Order**. Lower runs first, first match wins | Same | Admin |
| "More than two conditions" | Build the logic in a Flow and call **Create Service Work Item** with an explicit Queue Developer Name — that skips the rules entirely | Flow Builder | Flow |
| "Only Spanish speakers should get these" | Set **Required Skills** to `SPANISH` on the rule, and put `SPANISH` in the agent's Skills field | Custom Metadata + agent record | Admin |
| "Nothing should ever fall through" | Keep a last rule with no conditions and Order 90+ (shipped as `Case_Default`) | Custom Metadata Types | Admin |

Skills are a semicolon-separated list on `Service_Agent__c.Skills__c`, e.g.
`CREDIT;COLLECTIONS;SPANISH`. Matching ignores case and spacing. An agent must hold
**every** skill a work item requires.

---

## How work is distributed

| They say | You change | Where | Effort |
| --- | --- | --- | --- |
| "It's not spreading evenly" | Set the queue's **Routing Model** to `Round Robin` | Service Queue record | Admin |
| "Heavier cases should count for more" | Raise **Capacity Weight** on the rule or the queue's default, and use `Most Available` | Custom Metadata / queue | Admin |
| "Send the hard ones to our best people" | Set the queue to `Skill Based` and set **Skill Level** 1–5 on each membership | Queue + memberships | Admin |
| "Our rule is genuinely different from all of these" | Write a class implementing `IRoutingStrategy`, then put its name in the queue's **Routing Strategy Class** | Apex | Code |
| "Credit only works 9–5" | Put a Business Hours record name in the queue's **Business Hours Name** | Queue record | Admin |
| "Don't let anything sit in this queue more than an hour" | Set **Overflow Queue** and **Overflow After Minutes** | Queue record | Admin |

### Writing a strategy

This is the whole contract:

```apex
public with sharing class NewestCustomerFirstStrategy implements IRoutingStrategy {
    public Service_Agent__c selectAgent(RoutingContext context) {
        // context.candidates is already filtered to agents who are present, skilled,
        // in the queue, not excluded, and have capacity. Just pick one.
        return context.candidates.isEmpty() ? null : context.candidates[0];
    }
}
```

Deploy it, put `NewestCustomerFirstStrategy` in the queue's Routing Strategy Class field,
done. No other file changes. If the class name is wrong or the class throws, the engine
falls back to Least Active rather than stopping the floor.

---

## The accept / decline experience

| They say | You change | Where | Effort |
| --- | --- | --- | --- |
| "30 seconds to accept is too short" | Set **Push Timeout Seconds** on the queue | Queue record | Admin |
| "Credit shouldn't be able to decline" | Untick **Allow Decline** on the Credit queue | Queue record | Admin |
| "Just assign it, don't ask" | Tick **Auto Accept** on the queue (or org-wide in settings) | Queue / settings | Admin |
| "Work is bouncing around all afternoon" | Lower **Max Decline Count** — after that the item parks for a supervisor instead of re-routing | Settings record | Admin |
| "Someone declined and got it straight back" | Raise **Decline Cooldown Minutes** | Settings record | Admin |
| "Let agents grab work themselves" | Tick **Allow Manual Pull**; it appears in the console's Queue tab | Queue record | Admin |

---

## Urgency and SLA

| They say | You change | Where | Effort |
| --- | --- | --- | --- |
| "Credit reviews need a 4 hour SLA" | Set **SLA Minutes** on the rule or the queue | Custom Metadata / queue | Admin |
| "Escalate before we breach, not after" | Lower **Escalate At Percent Of SLA** from 80 | Settings record | Admin |
| "This queue should always be served first" | Lower the queue's **Priority** (lower runs first) | Queue record | Admin |
| "Warn us when the queue backs up" | Set **Max Queue Depth Alert**; the supervisor row turns red | Queue record | Admin |

---

## New kinds of work

Adding a channel is a picklist value — `Channel__c` on the work item is deliberately
unrestricted so teams can add their own without a metadata deployment.

To route a **new object** (say a `Credit_Request__c`):

1. Build a record-triggered Flow on that object.
2. Add the **Create Service Work Item** action. Pass `$Record.Id` as Record Id and set
   Channel to whatever the team calls it.
3. Either add routing rules with Source Object `Credit_Request__c`, or pass an explicit
   Queue Developer Name from the Flow.

No Apex. The engine reads whatever fields your rules reference, at runtime.

---

## The five Flow actions

All available in Flow Builder under the **Service Routing** category:

| Action | What it does |
| --- | --- |
| **Create Service Work Item** | Puts a record into the system. Optional explicit queue, priority, weight, skills, SLA, and a Route Immediately flag |
| **Route Service Work Items** | Runs a routing pass — one item, one queue, or everything |
| **Transfer Service Work Item** | Moves work to another queue or straight to a named agent |
| **Complete Service Work Item** | Closes the work item by Id or by source record, freeing capacity. Can cancel instead |
| **Set Agent Presence** | Changes presence, with the offline recall behaviour |

These let you build the surrounding process declaratively — end-of-shift sweeps, "flip the
team to Credit Review during a backlog push", escalation paths, post-training availability.

---

## Switches worth knowing

In the `Default` record of `Service_Routing_Setting__mdt`:

- **Enable Routing** — the master switch. Untick and everything queues up safely; nothing
  is lost, nothing is assigned. Useful during a go-live or an incident.
- **Log Level** — `None`, `Standard` (lifecycle events), `Verbose` (also logs why agents
  were passed over, which is what you want when someone asks "why didn't I get that?").
- **Routing Batch Size** — how many items one pass handles. Raise it for big backlogs.

---

## What still needs a developer

Being honest about the boundary:

- A genuinely new *selection algorithm* (a strategy class — but it's ~20 lines).
- Routing conditions needing more than two ANDed criteria **and** not expressible in a
  Flow that passes an explicit queue.
- New fields on the work item, or new objects in the model.
- Changes to the console UI itself.

Everything in the tables above is an admin or a Flow change.
