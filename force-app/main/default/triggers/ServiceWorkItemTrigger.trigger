/**
 * All Service_Work_Item__c automation funnels through one handler so the order of
 * operations stays obvious when this grows.
 */
trigger ServiceWorkItemTrigger on Service_Work_Item__c (after insert, after update) {
    if (Trigger.isAfter && Trigger.isInsert) {
        ServiceWorkItemTriggerHandler.afterInsert(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        ServiceWorkItemTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
    }
}
