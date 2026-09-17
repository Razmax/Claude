/**
 * Flow action: move work to another queue or hand it to a named agent.
 *
 * Built for the escalation paths Customer Service and Credit ask for by name - "send it
 * to Credit", "give it to the team lead" - without anyone opening a code file.
 */
public with sharing class TransferServiceWorkItemAction {

    public class Request {
        @InvocableVariable(label='Work Item Id' required=true)
        public Id workItemId;

        @InvocableVariable(label='Target Queue Developer Name')
        public String targetQueueDeveloperName;

        @InvocableVariable(label='Target Queue Id')
        public Id targetQueueId;

        @InvocableVariable(label='Target Agent Id' description='Assign directly to this Service Agent, skipping the queue.')
        public Id targetAgentId;

        @InvocableVariable(label='Reason')
        public String reason;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Transfer Service Work Item'
        description='Moves a work item to another queue or assigns it to a specific agent.'
        category='Service Routing')
    public static List<Result> execute(List<Request> requests) {
        Map<String, Id> queueIdsByName = new Map<String, Id>();
        for (Service_Queue__c queue : [
            SELECT Id, Developer_Name__c FROM Service_Queue__c WHERE Active__c = true
        ]) {
            if (String.isNotBlank(queue.Developer_Name__c)) {
                queueIdsByName.put(queue.Developer_Name__c.toLowerCase(), queue.Id);
            }
        }

        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                Id targetQueueId = request.targetQueueId;
                if (targetQueueId == null && String.isNotBlank(request.targetQueueDeveloperName)) {
                    targetQueueId = queueIdsByName.get(request.targetQueueDeveloperName.trim().toLowerCase());
                    if (targetQueueId == null) {
                        throw new RoutingException('No active queue named ' + request.targetQueueDeveloperName + '.');
                    }
                }
                if (targetQueueId == null && request.targetAgentId == null) {
                    throw new RoutingException('Supply a target queue or a target agent.');
                }
                WorkItemService.transfer(request.workItemId, targetQueueId, request.targetAgentId, request.reason);
                result.success = true;
                result.message = 'Work item transferred.';
            } catch (Exception e) {
                result.success = false;
                result.message = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
