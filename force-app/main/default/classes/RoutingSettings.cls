/**
 * Single read point for Service_Routing_Setting__mdt.
 *
 * Everything the engine treats as tunable lives here so that changing behaviour for
 * Customer Service or Credit is a custom metadata edit, not a deployment. Tests can
 * swap the whole record with `RoutingSettings.override()`.
 */
public with sharing class RoutingSettings {
    @TestVisible
    private static final String DEFAULT_RECORD = 'Default';

    private static Service_Routing_Setting__mdt cached;

    public static Service_Routing_Setting__mdt get() {
        if (cached == null) {
            cached = load();
        }
        return cached;
    }

    private static Service_Routing_Setting__mdt load() {
        List<Service_Routing_Setting__mdt> found = [
            SELECT DeveloperName, Enable_Routing__c, Default_Strategy_Class__c, Push_Timeout_Seconds__c,
                   Max_Decline_Count__c, Decline_Cooldown_Minutes__c, Enable_Auto_Accept__c,
                   Requeue_On_Offline__c, Escalate_At_Percent_Of_SLA__c, Routing_Batch_Size__c, Log_Level__c
            FROM Service_Routing_Setting__mdt
            WHERE DeveloperName = :DEFAULT_RECORD
            LIMIT 1
        ];
        if (!found.isEmpty()) {
            return found[0];
        }
        // Org has not configured anything yet - fall back to safe in-memory defaults so the
        // engine still behaves predictably on a fresh deployment.
        return new Service_Routing_Setting__mdt(
            DeveloperName = DEFAULT_RECORD,
            Enable_Routing__c = true,
            Push_Timeout_Seconds__c = 30,
            Max_Decline_Count__c = 3,
            Decline_Cooldown_Minutes__c = 10,
            Enable_Auto_Accept__c = false,
            Requeue_On_Offline__c = true,
            Escalate_At_Percent_Of_SLA__c = 80,
            Routing_Batch_Size__c = 200,
            Log_Level__c = 'Standard'
        );
    }

    @TestVisible
    private static void override(Service_Routing_Setting__mdt setting) {
        cached = setting;
    }

    public static Boolean routingEnabled() {
        return get().Enable_Routing__c == true;
    }

    public static Integer maxDeclineCount() {
        return intOf(get().Max_Decline_Count__c, 3);
    }

    public static Integer declineCooldownMinutes() {
        return intOf(get().Decline_Cooldown_Minutes__c, 10);
    }

    public static Integer pushTimeoutSeconds() {
        return intOf(get().Push_Timeout_Seconds__c, 30);
    }

    public static Integer batchSize() {
        return intOf(get().Routing_Batch_Size__c, 200);
    }

    public static Integer escalateAtPercentOfSla() {
        return intOf(get().Escalate_At_Percent_Of_SLA__c, 80);
    }

    public static Boolean verboseLogging() {
        return get().Log_Level__c == 'Verbose';
    }

    public static Boolean loggingEnabled() {
        return get().Log_Level__c != 'None';
    }

    private static Integer intOf(Decimal value, Integer fallback) {
        return value == null ? fallback : Integer.valueOf(value);
    }
}
