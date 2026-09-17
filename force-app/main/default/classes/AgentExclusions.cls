/**
 * Declines are remembered per work item so the same agent is not handed the same item
 * again immediately. Each entry is `agentId|epochMillis`; the exclusion lapses after
 * Decline_Cooldown_Minutes__c so short-staffed queues eventually retry everyone.
 */
public with sharing class AgentExclusions {
    private static final String ENTRY_SEPARATOR = ';';
    private static final String FIELD_SEPARATOR = '|';

    public static Set<Id> activeExclusions(Service_Work_Item__c item) {
        Set<Id> excluded = new Set<Id>();
        if (item == null || String.isBlank(item.Excluded_Agent_Ids__c)) {
            return excluded;
        }
        Long cutoff = System.now().getTime() - (RoutingSettings.declineCooldownMinutes() * 60000L);
        for (String entry : item.Excluded_Agent_Ids__c.split(ENTRY_SEPARATOR)) {
            if (String.isBlank(entry)) {
                continue;
            }
            List<String> parts = entry.trim().split('\\' + FIELD_SEPARATOR);
            try {
                Id agentId = Id.valueOf(parts[0]);
                Long stamp = parts.size() > 1 ? Long.valueOf(parts[1]) : System.now().getTime();
                if (stamp >= cutoff) {
                    excluded.add(agentId);
                }
            } catch (Exception e) {
                continue; // ignore malformed entries rather than blocking routing
            }
        }
        return excluded;
    }

    /** Adds an agent to the item's exclusion list in memory. Caller owns the DML. */
    public static void exclude(Service_Work_Item__c item, Id agentId) {
        if (agentId == null) {
            return;
        }
        String entry = agentId + FIELD_SEPARATOR + System.now().getTime();
        item.Excluded_Agent_Ids__c = String.isBlank(item.Excluded_Agent_Ids__c)
            ? entry
            : (item.Excluded_Agent_Ids__c + ENTRY_SEPARATOR + entry);
        // Keep the field inside its 4000 character limit on long-lived items.
        if (item.Excluded_Agent_Ids__c.length() > 3800) {
            List<String> entries = item.Excluded_Agent_Ids__c.split(ENTRY_SEPARATOR);
            List<String> kept = new List<String>();
            for (Integer i = Math.max(0, entries.size() - 50); i < entries.size(); i++) {
                kept.add(entries[i]);
            }
            item.Excluded_Agent_Ids__c = String.join(kept, ENTRY_SEPARATOR);
        }
    }

    public static void clear(Service_Work_Item__c item) {
        item.Excluded_Agent_Ids__c = null;
    }
}
