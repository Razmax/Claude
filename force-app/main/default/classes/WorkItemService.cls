/**
 * Lifecycle operations on Service_Work_Item__c. The console, the Flow actions and the
 * scheduler all go through here so that state transitions, capacity and the audit trail
 * stay consistent no matter where the change came from.
 */
public with sharing class WorkItemService {

    /** What a caller supplies to put a piece of work into the system. */
    public class WorkItemRequest {
        public Id sourceRecordId;
        public String channel;
        public String queueDeveloperName;
        public String subject;
        public Decimal priority;
        public Decimal capacityWeight;
        public String requiredSkills;
        public Decimal slaMinutes;
        public Id assignToAgentId;
        public String notes;
    }

    // ------------------------------------------------------------------ creation

    public static List<Service_Work_Item__c> create(List<WorkItemRequest> requests) {
        List<Service_Work_Item__c> items = new List<Service_Work_Item__c>();
        Map<String, Service_Queue__c> queuesByName = queuesByDeveloperName();
        Datetime now = System.now();

        for (WorkItemRequest request : requests) {
            SObject source = request.sourceRecordId == null ? null : SourceRecordLoader.load(request.sourceRecordId);
            RoutingDecision decision = RoutingRuleEngine.evaluate(source, request.channel);

            String queueName = String.isNotBlank(request.queueDeveloperName)
                ? request.queueDeveloperName.trim()
                : decision.queueDeveloperName;
            Service_Queue__c queue = String.isBlank(queueName) ? null : queuesByName.get(queueName.toLowerCase());

            Service_Work_Item__c item = new Service_Work_Item__c(
                Status__c = 'Pending',
                Requested_At__c = now,
                Channel__c = String.isBlank(request.channel) ? 'Manual' : request.channel,
                Subject__c = subjectFor(request, source),
                Notes__c = request.notes,
                Decline_Count__c = 0,
                Routing_Attempts__c = 0
            );

            if (request.sourceRecordId != null) {
                item.Source_Record_Id__c = request.sourceRecordId;
                item.Source_Object__c = String.valueOf(request.sourceRecordId.getSObjectType());
                linkKnownParents(item, source, request.sourceRecordId);
            }
            if (queue != null) {
                item.Queue__c = queue.Id;
            }

            item.Priority__c = firstNonNull(request.priority, decision.priority,
                queue == null ? null : queue.Priority__c, 5);
            item.Capacity_Weight__c = firstNonNull(request.capacityWeight, decision.capacityWeight,
                queue == null ? null : queue.Default_Capacity_Weight__c, 1);
            item.Required_Skills__c = String.isNotBlank(request.requiredSkills)
                ? request.requiredSkills : decision.requiredSkills;

            Decimal sla = firstNonNull(request.slaMinutes, decision.slaMinutes,
                queue == null ? null : queue.SLA_Minutes__c, null);
            if (sla != null && sla > 0) {
                item.Due_At__c = now.addMinutes(Integer.valueOf(sla));
            }
            if (queue == null) {
                item.Last_Routing_Error__c = String.isBlank(queueName)
                    ? 'No routing rule matched and no queue was supplied'
                    : 'Queue not found: ' + queueName;
            }
            items.add(item);
        }

        // The caller decides whether to route (the Flow action exposes Route Immediately),
        // so the trigger stays out of it for service-created work.
        Boolean previousSuppression = RoutingEngine.suppressTriggerRouting;
        RoutingEngine.suppressTriggerRouting = true;
        try {
            insert items;
        } finally {
            RoutingEngine.suppressTriggerRouting = previousSuppression;
        }
        for (Service_Work_Item__c item : items) {
            RoutingLogger.log(item.Id, 'Created', null, item.Queue__c,
                'Channel ' + item.Channel__c + (item.Queue__c == null ? ' (unrouted)' : ''));
        }
        RoutingLogger.flush();
        return items;
    }

    private static String subjectFor(WorkItemRequest request, SObject source) {
        if (String.isNotBlank(request.subject)) {
            return request.subject.abbreviate(255);
        }
        if (source == null) {
            return null;
        }
        for (String field : new List<String>{'Subject', 'Name', 'CaseNumber'}) {
            try {
                Object value = source.get(field);
                if (value != null && String.isNotBlank(String.valueOf(value))) {
                    return String.valueOf(value).abbreviate(255);
                }
            } catch (Exception e) {
                continue;
            }
        }
        return null;
    }

    /** Populate the convenience lookups so reports and related lists work out of the box. */
    private static void linkKnownParents(Service_Work_Item__c item, SObject source, Id sourceRecordId) {
        String objectName = String.valueOf(sourceRecordId.getSObjectType());
        if (objectName == 'Case') {
            item.Case__c = sourceRecordId;
        }
        if (source == null) {
            return;
        }
        try {
            Object accountId = source.get('AccountId');
            if (accountId != null) {
                item.Account__c = (Id) accountId;
            }
        } catch (Exception e) {
            // object has no AccountId - nothing to link
        }
        try {
            Object contactId = source.get('ContactId');
            if (contactId != null) {
                item.Contact__c = (Id) contactId;
            }
        } catch (Exception e) {
            // object has no ContactId - nothing to link
        }
    }

    // ------------------------------------------------------------------ agent actions

    public static void accept(Id workItemId, Id userId) {
        Service_Work_Item__c item = load(workItemId);
        assertOwnedBy(item, userId);
        if (item.Status__c != 'Assigned') {
            throw new RoutingException('This work item is no longer waiting to be accepted.');
        }
        item.Status__c = 'Accepted';
        item.Accepted_At__c = System.now();
        item.Push_Expires_At__c = null;
        saveSuppressed(item);
        RoutingLogger.log(item.Id, 'Accepted', item.Assigned_Agent__c, item.Queue__c, null);
        RoutingLogger.flush();
    }

    public static void startWork(Id workItemId, Id userId) {
        Service_Work_Item__c item = load(workItemId);
        assertOwnedBy(item, userId);
        item.Status__c = 'In Progress';
        if (item.Accepted_At__c == null) {
            item.Accepted_At__c = System.now();
        }
        item.Push_Expires_At__c = null;
        saveSuppressed(item);
    }

    /**
     * Declining hands the item back to the queue and remembers the agent so they are not
     * offered it again until the cooldown lapses. After Max_Decline_Count__c declines the
     * item stops auto-routing and waits for a supervisor - a stuck item is better than an
     * item bouncing around the floor all afternoon.
     */
    public static void decline(Id workItemId, Id userId, String reason) {
        Service_Work_Item__c item = load(workItemId);
        assertOwnedBy(item, userId);
        Id declinedBy = item.Assigned_Agent__c;

        item.Decline_Count__c = (item.Decline_Count__c == null ? 0 : item.Decline_Count__c) + 1;
        AgentExclusions.exclude(item, declinedBy);
        releaseFromAgent(item);

        Boolean exhausted = item.Decline_Count__c >= RoutingSettings.maxDeclineCount();
        item.Status__c = exhausted ? 'Pending' : 'Declined';
        item.Last_Routing_Error__c = exhausted
            ? 'Declined ' + item.Decline_Count__c + ' times - needs supervisor attention'
            : null;

        saveSuppressed(item);
        recalculateAgentLoad(new Set<Id>{declinedBy});
        RoutingLogger.log(item.Id, 'Declined', declinedBy, item.Queue__c, reason);
        RoutingLogger.flush();

        if (!exhausted) {
            routeAsync(new Set<Id>{item.Id});
        }
    }

    public static void complete(Id workItemId, Id userId, String closeReason) {
        Service_Work_Item__c item = load(workItemId);
        assertOwnedBy(item, userId);
        Id agentId = item.Assigned_Agent__c;

        item.Status__c = 'Completed';
        item.Completed_At__c = System.now();
        item.Push_Expires_At__c = null;
        if (String.isNotBlank(closeReason)) {
            item.Close_Reason__c = closeReason;
        }
        saveSuppressed(item);

        recalculateAgentLoad(new Set<Id>{agentId});
        RoutingLogger.log(item.Id, 'Completed', agentId, item.Queue__c, closeReason);
        RoutingLogger.flush();
        // Freed capacity - see whether anything is waiting for it.
        routeAsync(null);
    }

    public static void cancel(Id workItemId, String reason) {
        Service_Work_Item__c item = load(workItemId);
        Id agentId = item.Assigned_Agent__c;
        item.Status__c = 'Canceled';
        item.Completed_At__c = System.now();
        item.Push_Expires_At__c = null;
        saveSuppressed(item);
        if (agentId != null) {
            recalculateAgentLoad(new Set<Id>{agentId});
        }
        RoutingLogger.log(item.Id, 'Canceled', agentId, item.Queue__c, reason);
        RoutingLogger.flush();
    }

    // ------------------------------------------------------------------ transfers

    /** Move work to another queue (targetAgentId null) or straight to a named agent. */
    public static void transfer(Id workItemId, Id targetQueueId, Id targetAgentId, String reason) {
        Service_Work_Item__c item = load(workItemId);
        Id previousAgent = item.Assigned_Agent__c;

        if (targetQueueId != null) {
            item.Queue__c = targetQueueId;
        }
        item.Transfer_Reason__c = reason;
        releaseFromAgent(item);

        if (targetAgentId != null) {
            List<Service_Agent__c> agents = [
                SELECT Id, User__c, Current_Load__c, Active_Work_Count__c
                FROM Service_Agent__c WHERE Id = :targetAgentId LIMIT 1
            ];
            if (agents.isEmpty()) {
                throw new RoutingException('Target agent not found.');
            }
            item.Assigned_Agent__c = targetAgentId;
            item.Assigned_User__c = agents[0].User__c;
            item.Status__c = 'Assigned';
            item.Routed_At__c = System.now();
            Integer timeout = RoutingSettings.pushTimeoutSeconds();
            item.Push_Expires_At__c = timeout > 0 ? System.now().addSeconds(timeout) : null;
        } else {
            item.Status__c = 'Pending';
            AgentExclusions.clear(item); // a queue transfer is a fresh start
        }

        saveSuppressed(item);
        Set<Id> toRecalculate = new Set<Id>{previousAgent, targetAgentId};
        toRecalculate.remove(null);
        recalculateAgentLoad(toRecalculate);

        RoutingLogger.log(item.Id, 'Transferred', targetAgentId, item.Queue__c, reason);
        RoutingLogger.flush();

        if (targetAgentId != null) {
            EventBus.publish(new Service_Work_Assigned__e(
                Work_Item_Id__c = item.Id, Work_Item_Number__c = item.Name,
                User_Id__c = item.Assigned_User__c, Queue_Id__c = item.Queue__c, Action__c = 'Assigned'));
        } else {
            routeAsync(new Set<Id>{item.Id});
        }
    }

    /** Puts assigned-but-not-accepted work back in the queue, e.g. when an agent goes offline. */
    public static Integer requeueUnaccepted(Set<Id> agentIds, String reason) {
        List<Service_Work_Item__c> items = [
            SELECT Id, Name, Queue__c, Status__c, Assigned_Agent__c, Assigned_User__c,
                   Excluded_Agent_Ids__c, Decline_Count__c
            FROM Service_Work_Item__c
            WHERE Assigned_Agent__c IN :agentIds AND Status__c = 'Assigned'
        ];
        if (items.isEmpty()) {
            return 0;
        }
        Set<Id> affectedAgents = new Set<Id>();
        List<Service_Work_Assigned__e> events = new List<Service_Work_Assigned__e>();
        for (Service_Work_Item__c item : items) {
            affectedAgents.add(item.Assigned_Agent__c);
            events.add(new Service_Work_Assigned__e(
                Work_Item_Id__c = item.Id, Work_Item_Number__c = item.Name,
                User_Id__c = item.Assigned_User__c, Queue_Id__c = item.Queue__c, Action__c = 'Recalled'));
            RoutingLogger.log(item.Id, 'Requeued', item.Assigned_Agent__c, item.Queue__c, reason);
            releaseFromAgent(item);
            item.Status__c = 'Pending';
        }
        saveSuppressed(items);
        recalculateAgentLoad(affectedAgents);
        EventBus.publish(events);
        RoutingLogger.flush();
        routeAsync(null);
        return items.size();
    }

    /** Auto-decline work an agent never responded to, then re-route it. */
    public static Integer expirePushTimeouts() {
        Datetime now = System.now();
        List<Service_Work_Item__c> expired = [
            SELECT Id, Name, Queue__c, Status__c, Assigned_Agent__c, Assigned_User__c,
                   Excluded_Agent_Ids__c, Decline_Count__c
            FROM Service_Work_Item__c
            WHERE Status__c = 'Assigned' AND Push_Expires_At__c != NULL AND Push_Expires_At__c < :now
            LIMIT 200
        ];
        if (expired.isEmpty()) {
            return 0;
        }
        Set<Id> affectedAgents = new Set<Id>();
        Set<Id> toReroute = new Set<Id>();
        List<Service_Work_Assigned__e> events = new List<Service_Work_Assigned__e>();
        Integer maxDeclines = RoutingSettings.maxDeclineCount();

        for (Service_Work_Item__c item : expired) {
            affectedAgents.add(item.Assigned_Agent__c);
            AgentExclusions.exclude(item, item.Assigned_Agent__c);
            item.Decline_Count__c = (item.Decline_Count__c == null ? 0 : item.Decline_Count__c) + 1;
            RoutingLogger.log(item.Id, 'Timed Out', item.Assigned_Agent__c, item.Queue__c,
                'No response before the push timeout');
            events.add(new Service_Work_Assigned__e(
                Work_Item_Id__c = item.Id, Work_Item_Number__c = item.Name,
                User_Id__c = item.Assigned_User__c, Queue_Id__c = item.Queue__c, Action__c = 'Recalled'));
            releaseFromAgent(item);
            Boolean exhausted = item.Decline_Count__c >= maxDeclines;
            item.Status__c = exhausted ? 'Pending' : 'Declined';
            if (exhausted) {
                item.Last_Routing_Error__c = 'Timed out ' + item.Decline_Count__c + ' times - needs supervisor attention';
            } else {
                toReroute.add(item.Id);
            }
        }
        saveSuppressed(expired);
        recalculateAgentLoad(affectedAgents);
        EventBus.publish(events);
        RoutingLogger.flush();
        if (!toReroute.isEmpty()) {
            RoutingEngine.route(toReroute);
        }
        return expired.size();
    }

    // ------------------------------------------------------------------ capacity

    /**
     * Recomputes load from the work items themselves rather than incrementing counters.
     * Slightly more expensive, but it means a failed DML or a manual record edit cannot
     * leave an agent permanently "full" - the number is always derivable from the data.
     */
    public static void recalculateAgentLoad(Set<Id> agentIds) {
        if (agentIds == null || agentIds.isEmpty()) {
            return;
        }
        Map<Id, Service_Agent__c> agents = new Map<Id, Service_Agent__c>([
            SELECT Id, Current_Load__c, Active_Work_Count__c FROM Service_Agent__c WHERE Id IN :agentIds
        ]);
        for (Service_Agent__c agent : agents.values()) {
            agent.Current_Load__c = 0;
            agent.Active_Work_Count__c = 0;
        }
        Set<String> openStatuses = RoutingEngine.OPEN_STATUSES;
        for (AggregateResult row : [
            SELECT Assigned_Agent__c agentId, SUM(Capacity_Weight__c) totalLoad, COUNT(Id) itemCount
            FROM Service_Work_Item__c
            WHERE Assigned_Agent__c IN :agentIds AND Status__c IN :openStatuses
            GROUP BY Assigned_Agent__c
        ]) {
            Service_Agent__c agent = agents.get((Id) row.get('agentId'));
            if (agent == null) {
                continue;
            }
            Decimal totalLoad = (Decimal) row.get('totalLoad');
            agent.Current_Load__c = totalLoad == null ? 0 : totalLoad;
            agent.Active_Work_Count__c = (Integer) row.get('itemCount');
        }
        update agents.values();
    }

    private static void releaseFromAgent(Service_Work_Item__c item) {
        item.Assigned_Agent__c = null;
        item.Assigned_User__c = null;
        item.Push_Expires_At__c = null;
        item.Accepted_At__c = null;
    }

    // ------------------------------------------------------------------ helpers

    public static void routeAsync(Set<Id> workItemIds) {
        if (System.isBatch() || System.isFuture() || System.isQueueable()) {
            // Already async - route inline rather than chaining another job.
            if (workItemIds == null) {
                RoutingEngine.routeAllPending();
            } else {
                RoutingEngine.route(workItemIds);
            }
            return;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }
        System.enqueueJob(new RoutingDispatchQueueable(workItemIds));
    }

    /**
     * Saves without re-entering the work item trigger.
     *
     * Every service method below already recalculates capacity and decides about routing
     * explicitly, so letting the trigger queue that work again would both duplicate the
     * effort and burn the transaction's queueable slots.
     */
    private static void saveSuppressed(List<SObject> records) {
        Boolean previous = RoutingEngine.suppressTriggerRouting;
        RoutingEngine.suppressTriggerRouting = true;
        try {
            update records;
        } finally {
            RoutingEngine.suppressTriggerRouting = previous;
        }
    }

    private static void saveSuppressed(SObject record) {
        saveSuppressed(new List<SObject>{record});
    }

    private static Service_Work_Item__c load(Id workItemId) {
        List<Service_Work_Item__c> items = [
            SELECT Id, Name, Queue__c, Status__c, Assigned_Agent__c, Assigned_User__c, Accepted_At__c,
                   Decline_Count__c, Excluded_Agent_Ids__c, Capacity_Weight__c, Push_Expires_At__c,
                   Close_Reason__c, Transfer_Reason__c, Last_Routing_Error__c
            FROM Service_Work_Item__c WHERE Id = :workItemId LIMIT 1
        ];
        if (items.isEmpty()) {
            throw new RoutingException('Work item not found.');
        }
        return items[0];
    }

    /**
     * Agents may only act on their own work. Supervisors reassign through transfer(),
     * which deliberately does not carry this check.
     */
    private static void assertOwnedBy(Service_Work_Item__c item, Id userId) {
        if (userId != null && item.Assigned_User__c != null && item.Assigned_User__c != userId) {
            throw new RoutingException('This work item is assigned to someone else.');
        }
    }

    private static Map<String, Service_Queue__c> queuesByDeveloperName() {
        Map<String, Service_Queue__c> byName = new Map<String, Service_Queue__c>();
        for (Service_Queue__c queue : [
            SELECT Id, Name, Developer_Name__c, Priority__c, Default_Capacity_Weight__c, SLA_Minutes__c, Active__c
            FROM Service_Queue__c WHERE Active__c = true
        ]) {
            if (String.isNotBlank(queue.Developer_Name__c)) {
                byName.put(queue.Developer_Name__c.toLowerCase(), queue);
            }
        }
        return byName;
    }

    private static Decimal firstNonNull(Decimal a, Decimal b, Decimal c, Decimal d) {
        if (a != null) { return a; }
        if (b != null) { return b; }
        if (c != null) { return c; }
        return d;
    }
}
