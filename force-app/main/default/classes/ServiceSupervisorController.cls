/**
 * Apex behind the supervisor LWC: queue health, who is on, and the levers to fix a
 * backlog - route now, reassign, resync capacity.
 */
public with sharing class ServiceSupervisorController {

    public class QueueStat {
        @AuraEnabled public Id queueId;
        @AuraEnabled public String queueName;
        @AuraEnabled public String routingModel;
        @AuraEnabled public Integer waiting;
        @AuraEnabled public Integer assigned;
        @AuraEnabled public Integer inProgress;
        @AuraEnabled public Integer overdue;
        @AuraEnabled public Decimal oldestWaitMinutes;
        @AuraEnabled public Integer availableAgents;
        @AuraEnabled public Boolean overThreshold;
    }

    public class AgentStat {
        @AuraEnabled public Id agentId;
        @AuraEnabled public String agentName;
        @AuraEnabled public String presenceLabel;
        @AuraEnabled public String presenceColor;
        @AuraEnabled public Boolean acceptsWork;
        @AuraEnabled public Decimal currentLoad;
        @AuraEnabled public Decimal maxCapacity;
        @AuraEnabled public Decimal utilization;
        @AuraEnabled public Integer activeWorkCount;
        @AuraEnabled public Datetime presenceSince;
    }

    public class Dashboard {
        @AuraEnabled public List<QueueStat> queues = new List<QueueStat>();
        @AuraEnabled public List<AgentStat> agents = new List<AgentStat>();
        @AuraEnabled public Integer unroutedCount;
        @AuraEnabled public Boolean routingEnabled;
        @AuraEnabled public Datetime generatedAt;
    }

    @AuraEnabled(cacheable=true)
    public static Dashboard getDashboard() {
        try {
            return buildDashboard();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Dashboard refreshDashboard() {
        try {
            return buildDashboard();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static Dashboard buildDashboard() {
        Dashboard dashboard = new Dashboard();
        dashboard.routingEnabled = RoutingSettings.routingEnabled();
        dashboard.generatedAt = System.now();

        Map<Id, QueueStat> statsByQueue = new Map<Id, QueueStat>();
        Map<Id, Service_Queue__c> queues = new Map<Id, Service_Queue__c>([
            SELECT Id, Name, Routing_Model__c, Max_Queue_Depth_Alert__c
            FROM Service_Queue__c WHERE Active__c = true ORDER BY Priority__c NULLS LAST, Name
        ]);
        for (Service_Queue__c queue : queues.values()) {
            QueueStat stat = new QueueStat();
            stat.queueId = queue.Id;
            stat.queueName = queue.Name;
            stat.routingModel = queue.Routing_Model__c;
            stat.waiting = 0;
            stat.assigned = 0;
            stat.inProgress = 0;
            stat.overdue = 0;
            stat.oldestWaitMinutes = 0;
            stat.availableAgents = 0;
            stat.overThreshold = false;
            statsByQueue.put(queue.Id, stat);
            dashboard.queues.add(stat);
        }

        Set<String> liveStatuses = new Set<String>(RoutingEngine.OPEN_STATUSES);
        liveStatuses.addAll(RoutingEngine.ROUTABLE_STATUSES);
        Datetime now = System.now();

        for (Service_Work_Item__c item : [
            SELECT Id, Queue__c, Status__c, Requested_At__c, Is_Overdue__c
            FROM Service_Work_Item__c
            WHERE Queue__c IN :queues.keySet() AND Status__c IN :liveStatuses
            LIMIT 10000
        ]) {
            QueueStat stat = statsByQueue.get(item.Queue__c);
            if (stat == null) {
                continue;
            }
            if (RoutingEngine.ROUTABLE_STATUSES.contains(item.Status__c)) {
                stat.waiting++;
                if (item.Requested_At__c != null) {
                    Decimal waited = Decimal.valueOf(now.getTime() - item.Requested_At__c.getTime()) / 60000;
                    if (waited > stat.oldestWaitMinutes) {
                        stat.oldestWaitMinutes = waited.setScale(1);
                    }
                }
            } else if (item.Status__c == 'Assigned') {
                stat.assigned++;
            } else {
                stat.inProgress++;
            }
            if (item.Is_Overdue__c == true) {
                stat.overdue++;
            }
        }

        for (Service_Agent_Queue__c membership : [
            SELECT Queue__c, Agent__c FROM Service_Agent_Queue__c
            WHERE Queue__c IN :queues.keySet() AND Active__c = true
                  AND Agent__r.Is_Active__c = true AND Agent__r.Accepts_Work__c = true
        ]) {
            QueueStat stat = statsByQueue.get(membership.Queue__c);
            if (stat != null) {
                stat.availableAgents++;
            }
        }

        for (Service_Queue__c queue : queues.values()) {
            QueueStat stat = statsByQueue.get(queue.Id);
            stat.overThreshold = queue.Max_Queue_Depth_Alert__c != null
                && stat.waiting > queue.Max_Queue_Depth_Alert__c;
        }

        for (Service_Agent__c agent : [
            SELECT Id, Name, Presence_Status__c, Presence_Status_Label__c, Presence_Since__c,
                   Accepts_Work__c, Current_Load__c, Max_Capacity__c, Active_Work_Count__c
            FROM Service_Agent__c
            WHERE Is_Active__c = true
            ORDER BY Accepts_Work__c DESC, Name
            LIMIT 500
        ]) {
            AgentStat stat = new AgentStat();
            stat.agentId = agent.Id;
            stat.agentName = agent.Name;
            stat.presenceLabel = String.isBlank(agent.Presence_Status_Label__c) ? 'Not set' : agent.Presence_Status_Label__c;
            Service_Presence_Status__mdt status = PresenceStatusService.find(agent.Presence_Status__c);
            stat.presenceColor = status == null ? '#706e6b' : status.Color__c;
            stat.acceptsWork = agent.Accepts_Work__c == true;
            stat.currentLoad = agent.Current_Load__c == null ? 0 : agent.Current_Load__c;
            stat.maxCapacity = agent.Max_Capacity__c == null ? 0 : agent.Max_Capacity__c;
            stat.utilization = 0;
            if (stat.maxCapacity > 0) {
                stat.utilization = ((stat.currentLoad / stat.maxCapacity) * 100).setScale(0);
            }
            stat.activeWorkCount = agent.Active_Work_Count__c == null ? 0 : Integer.valueOf(agent.Active_Work_Count__c);
            stat.presenceSince = agent.Presence_Since__c;
            dashboard.agents.add(stat);
        }

        dashboard.unroutedCount = [
            SELECT COUNT() FROM Service_Work_Item__c WHERE Queue__c = NULL AND Status__c = 'Pending'
        ];
        return dashboard;
    }

    @AuraEnabled
    public static String routeNow(Id queueId) {
        try {
            RoutingEngine.Result result = queueId == null
                ? RoutingEngine.routeAllPending()
                : RoutingEngine.routeQueues(new Set<Id>{queueId});
            return 'Assigned ' + result.assigned + ', still waiting ' + result.unassigned + '.';
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static String reassign(Id workItemId, Id targetQueueId, Id targetAgentId, String reason) {
        try {
            WorkItemService.transfer(workItemId, targetQueueId, targetAgentId, reason);
            return 'Work item reassigned.';
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Recomputes every active agent's load from their open work. The safety net for when
     * someone edits records directly or a job dies half way.
     */
    @AuraEnabled
    public static String resyncCapacity() {
        try {
            Set<Id> agentIds = new Map<Id, Service_Agent__c>([
                SELECT Id FROM Service_Agent__c WHERE Is_Active__c = true LIMIT 5000
            ]).keySet();
            WorkItemService.recalculateAgentLoad(agentIds);
            return 'Capacity recalculated for ' + agentIds.size() + ' agents.';
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAvailableAgents(Id queueId) {
        List<Map<String, String>> options = new List<Map<String, String>>();
        List<Service_Agent__c> agents;
        if (queueId == null) {
            agents = [
                SELECT Id, Name FROM Service_Agent__c
                WHERE Is_Active__c = true ORDER BY Name LIMIT 200
            ];
        } else {
            Set<Id> agentIds = new Set<Id>();
            for (Service_Agent_Queue__c membership : [
                SELECT Agent__c FROM Service_Agent_Queue__c
                WHERE Queue__c = :queueId AND Active__c = true
            ]) {
                agentIds.add(membership.Agent__c);
            }
            agents = [
                SELECT Id, Name FROM Service_Agent__c
                WHERE Id IN :agentIds AND Is_Active__c = true ORDER BY Name LIMIT 200
            ];
        }
        for (Service_Agent__c agent : agents) {
            options.add(new Map<String, String>{'value' => agent.Id, 'label' => agent.Name});
        }
        return options;
    }
}
