/**
 * Flow action: put a record into the routing system.
 *
 * This is the normal entry point. A record-triggered Flow on Case (or Lead, or a credit
 * request object) calls this, and routing rules decide the queue - unless the Flow names
 * one explicitly, which always wins.
 */
public with sharing class CreateServiceWorkItemAction {

    public class Request {
        @InvocableVariable(label='Record Id' description='The Case, Lead or custom record this work represents.' required=false)
        public Id recordId;

        @InvocableVariable(label='Channel' description='Case, Phone, Email, Credit Review, or any value your team adds.')
        public String channel;

        @InvocableVariable(label='Queue Developer Name' description='Skips routing rules and sends the work straight to this queue.')
        public String queueDeveloperName;

        @InvocableVariable(label='Subject' description='What the agent sees in their work list. Defaults to the source record subject.')
        public String subject;

        @InvocableVariable(label='Priority' description='Lower routes first. Defaults to the rule or queue setting.')
        public Decimal priority;

        @InvocableVariable(label='Capacity Weight' description='How much agent capacity this consumes. Defaults to the queue setting.')
        public Decimal capacityWeight;

        @InvocableVariable(label='Required Skills' description='Semicolon separated, e.g. CREDIT;SPANISH.')
        public String requiredSkills;

        @InvocableVariable(label='SLA Minutes' description='Overrides the queue SLA for this item.')
        public Decimal slaMinutes;

        @InvocableVariable(label='Notes')
        public String notes;

        @InvocableVariable(label='Route Immediately' description='Default true. Set false to create the work item and route it later.')
        public Boolean routeImmediately;
    }

    public class Result {
        @InvocableVariable(label='Work Item Id')
        public Id workItemId;

        @InvocableVariable(label='Queue Id')
        public Id queueId;

        @InvocableVariable(label='Routed' description='True when the work item landed in a queue.')
        public Boolean routed;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Create Service Work Item'
        description='Creates a routable work item for a record and hands it to the routing engine.'
        category='Service Routing')
    public static List<Result> execute(List<Request> requests) {
        List<WorkItemService.WorkItemRequest> serviceRequests = new List<WorkItemService.WorkItemRequest>();
        for (Request request : requests) {
            WorkItemService.WorkItemRequest sr = new WorkItemService.WorkItemRequest();
            sr.sourceRecordId = request.recordId;
            sr.channel = request.channel;
            sr.queueDeveloperName = request.queueDeveloperName;
            sr.subject = request.subject;
            sr.priority = request.priority;
            sr.capacityWeight = request.capacityWeight;
            sr.requiredSkills = request.requiredSkills;
            sr.slaMinutes = request.slaMinutes;
            sr.notes = request.notes;
            serviceRequests.add(sr);
        }

        List<Service_Work_Item__c> created = WorkItemService.create(serviceRequests);
        List<Result> results = new List<Result>();
        Set<Id> toRoute = new Set<Id>();

        for (Integer i = 0; i < created.size(); i++) {
            Service_Work_Item__c item = created[i];
            Result result = new Result();
            result.workItemId = item.Id;
            result.queueId = item.Queue__c;
            result.routed = item.Queue__c != null;
            result.message = item.Queue__c == null
                ? 'No queue matched. Check your routing rules or pass a Queue Developer Name.'
                : 'Work item created.';
            results.add(result);

            Boolean routeNow = requests[i].routeImmediately == null || requests[i].routeImmediately;
            if (routeNow && item.Queue__c != null) {
                toRoute.add(item.Id);
            }
        }
        if (!toRoute.isEmpty()) {
            WorkItemService.routeAsync(toRoute);
        }
        return results;
    }
}
