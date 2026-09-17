/**
 * Buffers Service_Routing_Event__c rows and writes them in one DML at the end of a
 * routing pass. The routing timeline is the first thing a supervisor asks for when they
 * say "why did this land on Dana", so every state change goes through here.
 */
public with sharing class RoutingLogger {
    private static List<Service_Routing_Event__c> buffer = new List<Service_Routing_Event__c>();

    public static void log(Id workItemId, String eventType, Id agentId, Id queueId, String detail) {
        if (!RoutingSettings.loggingEnabled()) {
            return;
        }
        buffer.add(new Service_Routing_Event__c(
            Work_Item__c = workItemId,
            Event_Type__c = eventType,
            Agent__c = agentId,
            Queue__c = queueId,
            Occurred_At__c = System.now(),
            Detail__c = detail == null ? null : detail.abbreviate(32000)
        ));
    }

    public static void verbose(Id workItemId, String eventType, Id agentId, Id queueId, String detail) {
        if (!RoutingSettings.verboseLogging()) {
            return;
        }
        log(workItemId, eventType, agentId, queueId, detail);
    }

    public static void flush() {
        if (buffer.isEmpty()) {
            return;
        }
        List<Service_Routing_Event__c> toInsert = buffer;
        buffer = new List<Service_Routing_Event__c>();
        try {
            insert toInsert;
        } catch (DmlException e) {
            // Logging must never break routing itself.
            System.debug(LoggingLevel.ERROR, 'Routing log write failed: ' + e.getMessage());
        }
    }

    @TestVisible
    private static List<Service_Routing_Event__c> pending() {
        return buffer;
    }
}
