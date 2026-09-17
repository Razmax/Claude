/**
 * Flow action: close a work item and free the agent's capacity.
 *
 * Typically called from the same Flow that closes the underlying Case, so capacity is
 * released the moment the real work is done rather than when someone remembers to click.
 */
public with sharing class CompleteServiceWorkItemAction {

    public class Request {
        @InvocableVariable(label='Work Item Id' description='Provide this or a Source Record Id.')
        public Id workItemId;

        @InvocableVariable(label='Source Record Id' description='Closes the open work item linked to this record.')
        public Id sourceRecordId;

        @InvocableVariable(label='Close Reason')
        public String closeReason;

        @InvocableVariable(label='Cancel Instead' description='Set true to cancel rather than complete the work.')
        public Boolean cancelInstead;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Complete Service Work Item'
        description='Completes or cancels a work item and releases the agent capacity it was holding.'
        category='Service Routing')
    public static List<Result> execute(List<Request> requests) {
        // Source_Record_Id__c is a text field, so bind strings rather than Ids.
        Set<String> sourceIds = new Set<String>();
        for (Request request : requests) {
            if (request.workItemId == null && request.sourceRecordId != null) {
                sourceIds.add(String.valueOf(request.sourceRecordId));
            }
        }
        Map<Id, Id> workItemBySource = new Map<Id, Id>();
        if (!sourceIds.isEmpty()) {
            Set<String> unresolvedStatuses = new Set<String>(RoutingEngine.OPEN_STATUSES);
            unresolvedStatuses.addAll(RoutingEngine.ROUTABLE_STATUSES);
            // Ascending so the newest open work item wins the map entry.
            for (Service_Work_Item__c item : [
                SELECT Id, Source_Record_Id__c FROM Service_Work_Item__c
                WHERE Source_Record_Id__c IN :sourceIds AND Status__c IN :unresolvedStatuses
                ORDER BY CreatedDate ASC
            ]) {
                workItemBySource.put(Id.valueOf(item.Source_Record_Id__c), item.Id);
            }
        }

        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                Id workItemId = request.workItemId != null
                    ? request.workItemId
                    : workItemBySource.get(request.sourceRecordId);
                if (workItemId == null) {
                    throw new RoutingException('No open work item found for this record.');
                }
                if (request.cancelInstead == true) {
                    WorkItemService.cancel(workItemId, request.closeReason);
                    result.message = 'Work item canceled.';
                } else {
                    WorkItemService.complete(workItemId, null, request.closeReason);
                    result.message = 'Work item completed.';
                }
                result.success = true;
            } catch (Exception e) {
                result.success = false;
                result.message = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
