/**
 * Presence statuses are custom metadata, so Customer Service and Credit can keep their
 * own vocabulary ("Credit Review", "Second Look", "Coaching") without touching code.
 * A status decides three things: whether the agent receives work, which channels they
 * receive, and whether their capacity is temporarily capped.
 */
public with sharing class PresenceStatusService {
    private static Map<String, Service_Presence_Status__mdt> byName;

    public static Map<String, Service_Presence_Status__mdt> statusesByName() {
        if (byName == null) {
            byName = new Map<String, Service_Presence_Status__mdt>();
            for (Service_Presence_Status__mdt s : [
                SELECT DeveloperName, MasterLabel, Active__c, Status_Category__c, Accepts_Work__c,
                       Channels__c, Capacity_Override__c, Sort_Order__c, Color__c, Requires_Reason__c
                FROM Service_Presence_Status__mdt
                WHERE Active__c = true
                ORDER BY Sort_Order__c NULLS LAST, MasterLabel
            ]) {
                byName.put(s.DeveloperName, s);
            }
        }
        return byName;
    }

    public static List<Service_Presence_Status__mdt> activeStatuses() {
        return statusesByName().values();
    }

    public static Service_Presence_Status__mdt find(String developerName) {
        return String.isBlank(developerName) ? null : statusesByName().get(developerName);
    }

    /**
     * Applies a presence status to an agent record in memory. The caller owns the DML so
     * that presence changes can be bulkified alongside routing updates.
     */
    public static void applyStatus(Service_Agent__c agent, Service_Presence_Status__mdt status) {
        agent.Presence_Status__c = status == null ? null : status.DeveloperName;
        agent.Presence_Status_Label__c = status == null ? null : status.MasterLabel;
        agent.Accepts_Work__c = status != null && status.Accepts_Work__c == true;
        agent.Presence_Since__c = System.now();
    }

    /**
     * Capacity ceiling for an agent right now: their configured maximum, unless the
     * current status caps it lower (training, ramping, part-time credit reviewers).
     */
    public static Decimal effectiveCapacity(Service_Agent__c agent) {
        Decimal configured = agent.Max_Capacity__c == null ? 0 : agent.Max_Capacity__c;
        Service_Presence_Status__mdt status = find(agent.Presence_Status__c);
        if (status != null && status.Capacity_Override__c != null) {
            return Math.min(configured, status.Capacity_Override__c);
        }
        return configured;
    }

    /** True when the agent's current status accepts the given channel. */
    public static Boolean acceptsChannel(Service_Agent__c agent, String channel) {
        Service_Presence_Status__mdt status = find(agent.Presence_Status__c);
        if (status == null || status.Accepts_Work__c != true) {
            return false;
        }
        if (String.isBlank(status.Channels__c) || String.isBlank(channel)) {
            return true; // blank channel list on the status means "everything"
        }
        for (String allowed : status.Channels__c.split(';')) {
            if (allowed.trim().equalsIgnoreCase(channel.trim())) {
                return true;
            }
        }
        return false;
    }

    @TestVisible
    private static void overrideStatuses(Map<String, Service_Presence_Status__mdt> statuses) {
        byName = statuses;
    }
}
