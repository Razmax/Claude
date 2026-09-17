/**
 * Apex behind the agent console LWC. Everything the agent can do to their own work lives
 * here; supervisor-level actions live in ServiceSupervisorController.
 */
public with sharing class ServiceRoutingConsoleController {

    // ------------------------------------------------------------------ view models

    public class PresenceOption {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String category;
        @AuraEnabled public Boolean acceptsWork;
        @AuraEnabled public String color;
        @AuraEnabled public Boolean requiresReason;
    }

    public class WorkItemView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String channel;
        @AuraEnabled public Decimal priority;
        @AuraEnabled public Decimal capacityWeight;
        @AuraEnabled public String queueName;
        @AuraEnabled public Id queueId;
        @AuraEnabled public Id sourceRecordId;
        @AuraEnabled public Datetime requestedAt;
        @AuraEnabled public Datetime dueAt;
        @AuraEnabled public Datetime pushExpiresAt;
        @AuraEnabled public Boolean isOverdue;
        @AuraEnabled public Decimal waitMinutes;
        @AuraEnabled public Boolean canAccept;
        @AuraEnabled public Boolean canDecline;
        @AuraEnabled public Boolean canComplete;
    }

    public class ConsoleState {
        @AuraEnabled public Id agentId;
        @AuraEnabled public String agentName;
        @AuraEnabled public String presenceStatus;
        @AuraEnabled public String presenceLabel;
        @AuraEnabled public String presenceColor;
        @AuraEnabled public Boolean acceptsWork;
        @AuraEnabled public Decimal maxCapacity;
        @AuraEnabled public Decimal currentLoad;
        @AuraEnabled public Decimal remainingCapacity;
        @AuraEnabled public Integer activeWorkCount;
        @AuraEnabled public List<PresenceOption> presenceOptions = new List<PresenceOption>();
        @AuraEnabled public List<WorkItemView> myWork = new List<WorkItemView>();
        @AuraEnabled public List<WorkItemView> availableWork = new List<WorkItemView>();
        @AuraEnabled public Boolean routingEnabled;
    }

    // ------------------------------------------------------------------ reads

    @AuraEnabled(cacheable=true)
    public static ConsoleState getConsoleState() {
        try {
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Non-cacheable twin, called right after an action so the UI reflects the new state. */
    @AuraEnabled
    public static ConsoleState refreshConsoleState() {
        try {
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static ConsoleState buildState() {
        Service_Agent__c agent = AgentPresenceService.ensureAgent(UserInfo.getUserId());
        ConsoleState state = new ConsoleState();
        state.agentId = agent.Id;
        state.agentName = agent.Name;
        state.presenceStatus = agent.Presence_Status__c;
        state.presenceLabel = agent.Presence_Status_Label__c;
        state.acceptsWork = agent.Accepts_Work__c == true;
        state.maxCapacity = agent.Max_Capacity__c;
        state.currentLoad = agent.Current_Load__c == null ? 0 : agent.Current_Load__c;
        state.remainingCapacity = PresenceStatusService.effectiveCapacity(agent) - state.currentLoad;
        state.activeWorkCount = agent.Active_Work_Count__c == null ? 0 : Integer.valueOf(agent.Active_Work_Count__c);
        state.routingEnabled = RoutingSettings.routingEnabled();

        Service_Presence_Status__mdt current = PresenceStatusService.find(agent.Presence_Status__c);
        state.presenceColor = current == null ? '#706e6b' : current.Color__c;

        for (Service_Presence_Status__mdt status : PresenceStatusService.activeStatuses()) {
            PresenceOption option = new PresenceOption();
            option.developerName = status.DeveloperName;
            option.label = status.MasterLabel;
            option.category = status.Status_Category__c;
            option.acceptsWork = status.Accepts_Work__c == true;
            option.color = status.Color__c;
            option.requiresReason = status.Requires_Reason__c == true;
            state.presenceOptions.add(option);
        }

        state.myWork = toViews(myOpenWork(agent.Id));
        state.availableWork = toViews(pullableWork(agent.Id));
        return state;
    }

    private static List<Service_Work_Item__c> myOpenWork(Id agentId) {
        Set<String> openStatuses = RoutingEngine.OPEN_STATUSES;
        return [
            SELECT Id, Name, Subject__c, Status__c, Channel__c, Priority__c, Capacity_Weight__c,
                   Queue__c, Queue__r.Name, Source_Record_Id__c, Requested_At__c, Due_At__c,
                   Push_Expires_At__c, Is_Overdue__c, Wait_Time_Minutes__c
            FROM Service_Work_Item__c
            WHERE Assigned_Agent__c = :agentId AND Status__c IN :openStatuses
            ORDER BY Status__c, Priority__c ASC NULLS LAST, Requested_At__c ASC
            LIMIT 100
        ];
    }

    /** Work the agent could claim themselves, from queues they belong to that allow pulling. */
    private static List<Service_Work_Item__c> pullableWork(Id agentId) {
        Set<Id> pullableQueueIds = new Set<Id>();
        for (Service_Agent_Queue__c membership : [
            SELECT Queue__c FROM Service_Agent_Queue__c
            WHERE Agent__c = :agentId AND Active__c = true
                  AND Queue__r.Active__c = true AND Queue__r.Allow_Manual_Pull__c = true
        ]) {
            pullableQueueIds.add(membership.Queue__c);
        }
        if (pullableQueueIds.isEmpty()) {
            return new List<Service_Work_Item__c>();
        }
        Set<String> waitingStatuses = RoutingEngine.ROUTABLE_STATUSES;
        return [
            SELECT Id, Name, Subject__c, Status__c, Channel__c, Priority__c, Capacity_Weight__c,
                   Queue__c, Queue__r.Name, Source_Record_Id__c, Requested_At__c, Due_At__c,
                   Push_Expires_At__c, Is_Overdue__c, Wait_Time_Minutes__c
            FROM Service_Work_Item__c
            WHERE Queue__c IN :pullableQueueIds AND Status__c IN :waitingStatuses
                  AND Assigned_Agent__c = NULL
            ORDER BY Priority__c ASC NULLS LAST, Requested_At__c ASC
            LIMIT 50
        ];
    }

    private static List<WorkItemView> toViews(List<Service_Work_Item__c> items) {
        List<WorkItemView> views = new List<WorkItemView>();
        for (Service_Work_Item__c item : items) {
            WorkItemView view = new WorkItemView();
            view.id = item.Id;
            view.name = item.Name;
            view.subject = String.isBlank(item.Subject__c) ? item.Name : item.Subject__c;
            view.status = item.Status__c;
            view.channel = item.Channel__c;
            view.priority = item.Priority__c;
            view.capacityWeight = item.Capacity_Weight__c;
            view.queueId = item.Queue__c;
            view.queueName = item.Queue__r == null ? null : item.Queue__r.Name;
            view.sourceRecordId = String.isBlank(item.Source_Record_Id__c) ? null : Id.valueOf(item.Source_Record_Id__c);
            view.requestedAt = item.Requested_At__c;
            view.dueAt = item.Due_At__c;
            view.pushExpiresAt = item.Push_Expires_At__c;
            view.isOverdue = item.Is_Overdue__c;
            view.waitMinutes = item.Wait_Time_Minutes__c == null ? 0 : item.Wait_Time_Minutes__c.setScale(1);
            view.canAccept = item.Status__c == 'Assigned';
            view.canDecline = item.Status__c == 'Assigned';
            view.canComplete = RoutingEngine.OPEN_STATUSES.contains(item.Status__c) && item.Status__c != 'Assigned';
            views.add(view);
        }
        return views;
    }

    // ------------------------------------------------------------------ actions

    @AuraEnabled
    public static ConsoleState setPresence(String statusDeveloperName, String reason) {
        try {
            AgentPresenceService.setPresence(UserInfo.getUserId(), statusDeveloperName, reason);
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static ConsoleState acceptWork(Id workItemId) {
        try {
            WorkItemService.accept(workItemId, UserInfo.getUserId());
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static ConsoleState declineWork(Id workItemId, String reason) {
        try {
            WorkItemService.decline(workItemId, UserInfo.getUserId(), reason);
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static ConsoleState startWork(Id workItemId) {
        try {
            WorkItemService.startWork(workItemId, UserInfo.getUserId());
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static ConsoleState completeWork(Id workItemId, String closeReason) {
        try {
            WorkItemService.complete(workItemId, UserInfo.getUserId(), closeReason);
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Agent claims a queued item themselves. Capacity still applies. */
    @AuraEnabled
    public static ConsoleState pullWork(Id workItemId) {
        try {
            Service_Agent__c agent = AgentPresenceService.ensureAgent(UserInfo.getUserId());
            List<Service_Work_Item__c> items = [
                SELECT Id, Name, Queue__c, Status__c, Capacity_Weight__c, Assigned_Agent__c,
                       Required_Skills__c, Channel__c
                FROM Service_Work_Item__c WHERE Id = :workItemId LIMIT 1
            ];
            if (items.isEmpty()) {
                throw new RoutingException('Work item not found.');
            }
            Service_Work_Item__c item = items[0];
            if (item.Assigned_Agent__c != null) {
                throw new RoutingException('Someone already picked this up.');
            }
            Decimal weight = item.Capacity_Weight__c == null ? 1 : item.Capacity_Weight__c;
            Decimal load = agent.Current_Load__c == null ? 0 : agent.Current_Load__c;
            if (load + weight > PresenceStatusService.effectiveCapacity(agent)) {
                throw new RoutingException('You are at capacity. Complete something first.');
            }
            if (!RoutingEngine.hasRequiredSkills(agent, item.Required_Skills__c)) {
                throw new RoutingException('This work needs skills your profile does not list: ' + item.Required_Skills__c);
            }

            item.Assigned_Agent__c = agent.Id;
            item.Assigned_User__c = agent.User__c;
            item.Status__c = 'Accepted';
            item.Routed_At__c = System.now();
            item.Accepted_At__c = System.now();
            item.Push_Expires_At__c = null;

            // Capacity is recalculated explicitly below, so keep the trigger out of it.
            Boolean previous = RoutingEngine.suppressTriggerRouting;
            RoutingEngine.suppressTriggerRouting = true;
            try {
                update item;
            } finally {
                RoutingEngine.suppressTriggerRouting = previous;
            }

            agent.Last_Assigned_At__c = System.now();
            update agent;
            WorkItemService.recalculateAgentLoad(new Set<Id>{agent.Id});

            RoutingLogger.log(item.Id, 'Accepted', agent.Id, item.Queue__c, 'Pulled from queue by agent');
            RoutingLogger.flush();
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static ConsoleState transferWork(Id workItemId, Id targetQueueId, Id targetAgentId, String reason) {
        try {
            WorkItemService.transfer(workItemId, targetQueueId, targetAgentId, reason);
            return buildState();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Queues the agent can transfer into, for the transfer picker. */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getTransferQueues() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Service_Queue__c queue : [
            SELECT Id, Name FROM Service_Queue__c WHERE Active__c = true ORDER BY Name
        ]) {
            options.add(new Map<String, String>{'value' => queue.Id, 'label' => queue.Name});
        }
        return options;
    }
}
