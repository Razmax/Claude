/**
 * Flow action: run a routing pass now.
 *
 * Useful in a scheduled Flow, on a supervisor screen Flow, or after a Flow has changed a
 * work item's queue or skills and wants it reconsidered immediately.
 */
public with sharing class RouteServiceWorkItemAction {

    public class Request {
        @InvocableVariable(label='Work Item Id' description='Route one item. Leave blank to sweep all queued work.')
        public Id workItemId;

        @InvocableVariable(label='Queue Id' description='Route everything waiting in this queue.')
        public Id queueId;
    }

    public class Result {
        @InvocableVariable(label='Assigned Count')
        public Integer assignedCount;

        @InvocableVariable(label='Unassigned Count')
        public Integer unassignedCount;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Route Service Work Items'
        description='Assigns queued work to available agents using each queue routing model.'
        category='Service Routing')
    public static List<Result> execute(List<Request> requests) {
        Set<Id> workItemIds = new Set<Id>();
        Set<Id> queueIds = new Set<Id>();
        for (Request request : requests) {
            if (request.workItemId != null) {
                workItemIds.add(request.workItemId);
            }
            if (request.queueId != null) {
                queueIds.add(request.queueId);
            }
        }

        RoutingEngine.Result engineResult;
        if (!workItemIds.isEmpty()) {
            engineResult = RoutingEngine.route(workItemIds);
        } else if (!queueIds.isEmpty()) {
            engineResult = RoutingEngine.routeQueues(queueIds);
        } else {
            engineResult = RoutingEngine.routeAllPending();
        }

        Result result = new Result();
        result.assignedCount = engineResult.assigned;
        result.unassignedCount = engineResult.unassigned;
        result.message = engineResult.messages.isEmpty()
            ? 'Assigned ' + engineResult.assigned + ', still waiting ' + engineResult.unassigned + '.'
            : String.join(engineResult.messages, ' ');

        // Flow expects one result per request row.
        List<Result> results = new List<Result>();
        for (Integer i = 0; i < requests.size(); i++) {
            results.add(result);
        }
        return results;
    }
}
