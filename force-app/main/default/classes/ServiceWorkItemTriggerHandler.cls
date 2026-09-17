/**
 * Keeps work item side effects in one place.
 *
 * Routing happens asynchronously on purpose: the trigger is already holding DML on the
 * records the engine needs to update, and an agent's capacity has to be recalculated
 * after the change is committed, not during it.
 */
public with sharing class ServiceWorkItemTriggerHandler {

    public static void afterInsert(List<Service_Work_Item__c> newItems) {
        if (RoutingEngine.suppressTriggerRouting) {
            return;
        }
        Set<Id> toRoute = new Set<Id>();
        for (Service_Work_Item__c item : newItems) {
            if (item.Queue__c != null && item.Assigned_Agent__c == null
                && RoutingEngine.ROUTABLE_STATUSES.contains(item.Status__c)) {
                toRoute.add(item.Id);
            }
        }
        if (!toRoute.isEmpty()) {
            WorkItemService.routeAsync(toRoute);
        }
    }

    public static void afterUpdate(List<Service_Work_Item__c> newItems, Map<Id, Service_Work_Item__c> oldMap) {
        if (RoutingEngine.suppressTriggerRouting) {
            return;
        }
        Set<Id> agentsNeedingRecalc = new Set<Id>();
        Set<Id> toRoute = new Set<Id>();

        for (Service_Work_Item__c item : newItems) {
            Service_Work_Item__c old = oldMap.get(item.Id);

            Boolean statusChanged = item.Status__c != old.Status__c;
            Boolean agentChanged = item.Assigned_Agent__c != old.Assigned_Agent__c;
            Boolean weightChanged = item.Capacity_Weight__c != old.Capacity_Weight__c;

            // Any of these can change how much capacity an agent is holding.
            if (statusChanged || agentChanged || weightChanged) {
                if (old.Assigned_Agent__c != null) {
                    agentsNeedingRecalc.add(old.Assigned_Agent__c);
                }
                if (item.Assigned_Agent__c != null) {
                    agentsNeedingRecalc.add(item.Assigned_Agent__c);
                }
            }

            // A record edited back into a waiting state, typically by a supervisor, gets re-routed.
            if (item.Assigned_Agent__c == null && item.Queue__c != null
                && RoutingEngine.ROUTABLE_STATUSES.contains(item.Status__c)
                && (statusChanged || agentChanged || item.Queue__c != old.Queue__c)) {
                toRoute.add(item.Id);
            }
        }

        if (!agentsNeedingRecalc.isEmpty()) {
            RecalculateCapacityQueueable.enqueue(agentsNeedingRecalc);
        }
        if (!toRoute.isEmpty()) {
            WorkItemService.routeAsync(toRoute);
        }
    }
}
