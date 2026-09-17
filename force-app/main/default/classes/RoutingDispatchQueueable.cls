/**
 * Runs a routing pass out of the caller's transaction.
 *
 * Routing after a trigger has to be async: the trigger is already holding DML on the very
 * records the engine wants to update.
 */
public with sharing class RoutingDispatchQueueable implements Queueable {
    private Set<Id> workItemIds;

    public RoutingDispatchQueueable(Set<Id> workItemIds) {
        this.workItemIds = workItemIds;
    }

    public void execute(QueueableContext context) {
        if (workItemIds == null) {
            RoutingEngine.routeAllPending();
        } else {
            RoutingEngine.route(workItemIds);
        }
    }
}
