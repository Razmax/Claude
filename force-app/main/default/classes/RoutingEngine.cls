/**
 * The core of the routing system: takes queued work items and puts them on agents.
 *
 * The engine owns the rules that must always hold (capacity, presence, skills, queue
 * membership, declines, business hours). *Which* eligible agent wins is delegated to an
 * IRoutingStrategy, so teams can change selection behaviour without touching this class.
 */
public with sharing class RoutingEngine {

    /** Statuses that mean "this item still needs an owner". */
    public static final Set<String> ROUTABLE_STATUSES = new Set<String>{'Pending', 'Routing', 'Declined'};

    /** Statuses that still consume an agent's capacity. */
    public static final Set<String> OPEN_STATUSES = new Set<String>{
        'Assigned', 'Accepted', 'In Progress', 'On Hold', 'Transferring'
    };

    /** Prevents a routing pass triggered from within a routing pass. */
    public static Boolean suppressTriggerRouting = false;

    public class Result {
        @AuraEnabled public Integer assigned = 0;
        @AuraEnabled public Integer unassigned = 0;
        @AuraEnabled public List<String> messages = new List<String>();
    }

    // ------------------------------------------------------------------ entry points

    public static Result route(Set<Id> workItemIds) {
        return assign(queryRoutable(workItemIds, null));
    }

    public static Result routeQueues(Set<Id> queueIds) {
        return assign(queryRoutable(null, queueIds));
    }

    /** Sweeps every queue. Used by the scheduler and the supervisor "Route Now" button. */
    public static Result routeAllPending() {
        return assign(queryRoutable(null, null));
    }

    // ------------------------------------------------------------------ assignment

    private static Result assign(List<Service_Work_Item__c> items) {
        Result result = new Result();
        if (!RoutingSettings.routingEnabled()) {
            result.messages.add('Routing is disabled in Service Routing Settings.');
            return result;
        }
        if (items.isEmpty()) {
            return result;
        }

        Set<Id> queueIds = new Set<Id>();
        for (Service_Work_Item__c item : items) {
            queueIds.add(item.Queue__c);
        }
        Map<Id, Service_Queue__c> queues = queuesOpenForRouting(queueIds);
        if (queues.isEmpty()) {
            result.messages.add('No active queue is currently open for routing.');
            result.unassigned = items.size();
            return result;
        }

        Map<Id, Service_Agent__c> agentsById = new Map<Id, Service_Agent__c>();
        Map<Id, List<Service_Agent_Queue__c>> membershipsByQueue = memberships(queues.keySet(), agentsById);
        Map<Id, Decimal> projectedLoad = new Map<Id, Decimal>();
        for (Service_Agent__c agent : agentsById.values()) {
            projectedLoad.put(agent.Id, agent.Current_Load__c == null ? 0 : agent.Current_Load__c);
        }

        Map<Id, Service_Agent__c> agentsToUpdate = new Map<Id, Service_Agent__c>();
        List<Service_Work_Item__c> itemsToUpdate = new List<Service_Work_Item__c>();
        List<Service_Work_Assigned__e> events = new List<Service_Work_Assigned__e>();

        for (Service_Work_Item__c item : items) {
            Service_Queue__c queue = queues.get(item.Queue__c);
            if (queue == null) {
                result.unassigned++;
                continue;
            }
            RoutingContext context = buildContext(item, queue, membershipsByQueue.get(queue.Id), agentsById, projectedLoad);
            if (context.candidates.isEmpty()) {
                item.Status__c = 'Pending';
                item.Routing_Attempts__c = (item.Routing_Attempts__c == null ? 0 : item.Routing_Attempts__c) + 1;
                item.Last_Routing_Error__c = 'No eligible agent available';
                itemsToUpdate.add(item);
                result.unassigned++;
                RoutingLogger.verbose(item.Id, 'Routed', null, queue.Id, 'No eligible agent for queue ' + queue.Name);
                continue;
            }

            Service_Agent__c chosen;
            try {
                chosen = RoutingStrategyFactory.forQueue(queue).selectAgent(context);
            } catch (Exception e) {
                RoutingLogger.log(item.Id, 'Error', null, queue.Id,
                    'Strategy ' + queue.Routing_Model__c + ' failed: ' + e.getMessage());
            }
            if (chosen == null) {
                item.Status__c = 'Pending';
                item.Last_Routing_Error__c = 'Strategy returned no agent';
                itemsToUpdate.add(item);
                result.unassigned++;
                continue;
            }

            applyAssignment(item, queue, chosen, projectedLoad);
            agentsToUpdate.put(chosen.Id, chosen);
            itemsToUpdate.add(item);
            events.add(assignmentEvent(item, chosen, 'Assigned'));
            result.assigned++;
            RoutingLogger.log(item.Id, 'Assigned', chosen.Id, queue.Id,
                'Assigned to ' + chosen.Name + ' via ' + (String.isNotBlank(queue.Routing_Strategy_Class__c)
                    ? queue.Routing_Strategy_Class__c : queue.Routing_Model__c));
        }

        commitWork(itemsToUpdate, agentsToUpdate.values(), events);
        return result;
    }

    private static void applyAssignment(Service_Work_Item__c item, Service_Queue__c queue,
                                        Service_Agent__c agent, Map<Id, Decimal> projectedLoad) {
        Decimal weight = item.Capacity_Weight__c == null ? 1 : item.Capacity_Weight__c;
        Datetime now = System.now();

        item.Assigned_Agent__c = agent.Id;
        item.Assigned_User__c = agent.User__c;
        item.Routed_At__c = now;
        item.Routing_Attempts__c = (item.Routing_Attempts__c == null ? 0 : item.Routing_Attempts__c) + 1;
        item.Last_Routing_Error__c = null;

        Boolean autoAccept = queue.Auto_Accept__c == true || RoutingSettings.get().Enable_Auto_Accept__c == true;
        if (autoAccept) {
            item.Status__c = 'Accepted';
            item.Accepted_At__c = now;
            item.Push_Expires_At__c = null;
        } else {
            item.Status__c = 'Assigned';
            Integer timeout = queue.Push_Timeout_Seconds__c == null
                ? RoutingSettings.pushTimeoutSeconds()
                : Integer.valueOf(queue.Push_Timeout_Seconds__c);
            item.Push_Expires_At__c = timeout > 0 ? now.addSeconds(timeout) : null;
        }

        agent.Current_Load__c = (agent.Current_Load__c == null ? 0 : agent.Current_Load__c) + weight;
        agent.Active_Work_Count__c = (agent.Active_Work_Count__c == null ? 0 : agent.Active_Work_Count__c) + 1;
        agent.Last_Assigned_At__c = now;
        projectedLoad.put(agent.Id, agent.Current_Load__c);
    }

    // ------------------------------------------------------------------ candidates

    @TestVisible
    private static RoutingContext buildContext(Service_Work_Item__c item, Service_Queue__c queue,
                                               List<Service_Agent_Queue__c> queueMemberships,
                                               Map<Id, Service_Agent__c> agentsById,
                                               Map<Id, Decimal> projectedLoad) {
        RoutingContext context = new RoutingContext();
        context.workItem = item;
        context.queue = queue;
        context.projectedLoad = projectedLoad;
        if (queueMemberships == null) {
            return context;
        }
        Set<Id> excluded = AgentExclusions.activeExclusions(item);
        Decimal weight = context.weight();

        for (Service_Agent_Queue__c membership : queueMemberships) {
            Service_Agent__c agent = agentsById.get(membership.Agent__c);
            if (agent == null || excluded.contains(agent.Id)) {
                continue;
            }
            if (agent.Is_Active__c != true || agent.Accepts_Work__c != true) {
                continue;
            }
            if (!PresenceStatusService.acceptsChannel(agent, item.Channel__c)) {
                continue;
            }
            if (!hasRequiredSkills(agent, item.Required_Skills__c)) {
                continue;
            }
            Decimal committed = projectedLoad.containsKey(agent.Id) ? projectedLoad.get(agent.Id) : 0;
            if (committed + weight > PresenceStatusService.effectiveCapacity(agent)) {
                continue;
            }
            context.candidates.add(agent);
            context.skillLevelByAgent.put(agent.Id, membership.Skill_Level__c);
            context.membershipPriorityByAgent.put(agent.Id, membership.Priority__c);
        }
        return context;
    }

    /** An agent must hold every skill the work item demands. */
    public static Boolean hasRequiredSkills(Service_Agent__c agent, String requiredSkills) {
        if (String.isBlank(requiredSkills)) {
            return true;
        }
        if (String.isBlank(agent.Skills__c)) {
            return false;
        }
        Set<String> held = new Set<String>();
        for (String skill : agent.Skills__c.split(';')) {
            if (String.isNotBlank(skill)) {
                held.add(skill.trim().toUpperCase());
            }
        }
        for (String required : requiredSkills.split(';')) {
            if (String.isNotBlank(required) && !held.contains(required.trim().toUpperCase())) {
                return false;
            }
        }
        return true;
    }

    // ------------------------------------------------------------------ queries

    @TestVisible
    private static List<Service_Work_Item__c> queryRoutable(Set<Id> workItemIds, Set<Id> queueIds) {
        Set<String> statuses = ROUTABLE_STATUSES;
        Integer limitSize = RoutingSettings.batchSize();
        if (workItemIds != null) {
            return [
                SELECT Id, Name, Queue__c, Status__c, Priority__c, Channel__c, Capacity_Weight__c,
                       Required_Skills__c, Requested_At__c, Routing_Attempts__c, Decline_Count__c,
                       Excluded_Agent_Ids__c, Assigned_Agent__c, Due_At__c, Source_Record_Id__c, Subject__c
                FROM Service_Work_Item__c
                WHERE Id IN :workItemIds AND Status__c IN :statuses AND Queue__c != NULL
                ORDER BY Queue__r.Priority__c ASC NULLS LAST, Priority__c ASC NULLS LAST,
                         Requested_At__c ASC NULLS FIRST
                LIMIT :limitSize
            ];
        }
        if (queueIds != null) {
            return [
                SELECT Id, Name, Queue__c, Status__c, Priority__c, Channel__c, Capacity_Weight__c,
                       Required_Skills__c, Requested_At__c, Routing_Attempts__c, Decline_Count__c,
                       Excluded_Agent_Ids__c, Assigned_Agent__c, Due_At__c, Source_Record_Id__c, Subject__c
                FROM Service_Work_Item__c
                WHERE Queue__c IN :queueIds AND Status__c IN :statuses
                ORDER BY Queue__r.Priority__c ASC NULLS LAST, Priority__c ASC NULLS LAST,
                         Requested_At__c ASC NULLS FIRST
                LIMIT :limitSize
            ];
        }
        return [
            SELECT Id, Name, Queue__c, Status__c, Priority__c, Channel__c, Capacity_Weight__c,
                   Required_Skills__c, Requested_At__c, Routing_Attempts__c, Decline_Count__c,
                   Excluded_Agent_Ids__c, Assigned_Agent__c, Due_At__c, Source_Record_Id__c, Subject__c
            FROM Service_Work_Item__c
            WHERE Status__c IN :statuses AND Queue__c != NULL
            ORDER BY Queue__r.Priority__c ASC NULLS LAST, Priority__c ASC NULLS LAST,
                     Requested_At__c ASC NULLS FIRST
            LIMIT :limitSize
        ];
    }

    /** Active queues, minus any that are outside their business hours right now. */
    @TestVisible
    private static Map<Id, Service_Queue__c> queuesOpenForRouting(Set<Id> queueIds) {
        Map<Id, Service_Queue__c> queues = new Map<Id, Service_Queue__c>([
            SELECT Id, Name, Developer_Name__c, Active__c, Priority__c, Routing_Model__c,
                   Routing_Strategy_Class__c, Default_Capacity_Weight__c, SLA_Minutes__c,
                   Push_Timeout_Seconds__c, Allow_Manual_Pull__c, Allow_Decline__c, Auto_Accept__c,
                   Overflow_Queue__c, Overflow_After_Minutes__c, Business_Hours_Name__c
            FROM Service_Queue__c
            WHERE Id IN :queueIds AND Active__c = true
        ]);
        Set<String> businessHoursNames = new Set<String>();
        for (Service_Queue__c queue : queues.values()) {
            if (String.isNotBlank(queue.Business_Hours_Name__c)) {
                businessHoursNames.add(queue.Business_Hours_Name__c);
            }
        }
        if (businessHoursNames.isEmpty()) {
            return queues;
        }
        Map<String, Id> hoursByName = new Map<String, Id>();
        for (BusinessHours bh : [SELECT Id, Name FROM BusinessHours WHERE Name IN :businessHoursNames]) {
            hoursByName.put(bh.Name, bh.Id);
        }
        Datetime now = System.now();
        for (Id queueId : new List<Id>(queues.keySet())) {
            Service_Queue__c queue = queues.get(queueId);
            if (String.isBlank(queue.Business_Hours_Name__c)) {
                continue;
            }
            Id hoursId = hoursByName.get(queue.Business_Hours_Name__c);
            if (hoursId != null && !BusinessHours.isWithin(hoursId, now)) {
                queues.remove(queueId);
            }
        }
        return queues;
    }

    private static Map<Id, List<Service_Agent_Queue__c>> memberships(Set<Id> queueIds,
                                                                     Map<Id, Service_Agent__c> agentsOut) {
        Map<Id, List<Service_Agent_Queue__c>> byQueue = new Map<Id, List<Service_Agent_Queue__c>>();
        for (Service_Agent_Queue__c membership : [
            SELECT Id, Agent__c, Queue__c, Priority__c, Skill_Level__c,
                   Agent__r.Id, Agent__r.Name, Agent__r.User__c, Agent__r.Is_Active__c,
                   Agent__r.Accepts_Work__c, Agent__r.Presence_Status__c, Agent__r.Max_Capacity__c,
                   Agent__r.Current_Load__c, Agent__r.Active_Work_Count__c, Agent__r.Last_Assigned_At__c,
                   Agent__r.Skills__c
            FROM Service_Agent_Queue__c
            WHERE Queue__c IN :queueIds AND Active__c = true AND Agent__r.Is_Active__c = true
                  AND Agent__r.Accepts_Work__c = true
        ]) {
            if (!byQueue.containsKey(membership.Queue__c)) {
                byQueue.put(membership.Queue__c, new List<Service_Agent_Queue__c>());
            }
            byQueue.get(membership.Queue__c).add(membership);
            if (!agentsOut.containsKey(membership.Agent__c)) {
                agentsOut.put(membership.Agent__c, membership.Agent__r);
            }
        }
        return byQueue;
    }

    // ------------------------------------------------------------------ persistence

    @TestVisible
    private static Service_Work_Assigned__e assignmentEvent(Service_Work_Item__c item,
                                                            Service_Agent__c agent, String action) {
        return new Service_Work_Assigned__e(
            Work_Item_Id__c = item.Id,
            Work_Item_Number__c = item.Name,
            User_Id__c = agent == null ? null : agent.User__c,
            Queue_Id__c = item.Queue__c,
            Action__c = action,
            Payload__c = JSON.serialize(new Map<String, Object>{
                'subject' => item.Subject__c,
                'channel' => item.Channel__c,
                'priority' => item.Priority__c,
                'status' => item.Status__c,
                'pushExpiresAt' => item.Push_Expires_At__c
            })
        );
    }

    /**
     * One save point for the whole pass. Partial success is deliberate: one bad work item
     * should not strand the other 199 in a bulk load.
     */
    public static void commitWork(List<Service_Work_Item__c> items, List<Service_Agent__c> agents,
                                  List<Service_Work_Assigned__e> events) {
        Boolean previous = suppressTriggerRouting;
        suppressTriggerRouting = true;
        try {
            if (agents != null && !agents.isEmpty()) {
                for (Database.SaveResult sr : Database.update(agents, false)) {
                    logDmlFailure(sr, 'Service_Agent__c');
                }
            }
            if (items != null && !items.isEmpty()) {
                for (Database.SaveResult sr : Database.update(items, false)) {
                    logDmlFailure(sr, 'Service_Work_Item__c');
                }
            }
            if (events != null && !events.isEmpty()) {
                EventBus.publish(events);
            }
        } finally {
            suppressTriggerRouting = previous;
            RoutingLogger.flush();
        }
    }

    private static void logDmlFailure(Database.SaveResult sr, String objectName) {
        if (sr.isSuccess()) {
            return;
        }
        String detail = '';
        for (Database.Error err : sr.getErrors()) {
            detail += err.getStatusCode() + ': ' + err.getMessage() + ' ';
        }
        System.debug(LoggingLevel.ERROR, 'Routing save failed on ' + objectName + ' - ' + detail);
    }
}
