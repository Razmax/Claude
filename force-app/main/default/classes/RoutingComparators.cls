/** Shared tie-breakers so every strategy breaks ties the same way. */
public with sharing class RoutingComparators {
    /**
     * True when `candidate` has waited longer for work than `best`. An agent who has
     * never been assigned anything always wins - that is the newly-available agent.
     */
    public static Boolean idleLongerThan(Service_Agent__c candidate, Service_Agent__c best) {
        if (candidate.Last_Assigned_At__c == null) {
            return best.Last_Assigned_At__c != null;
        }
        if (best.Last_Assigned_At__c == null) {
            return false;
        }
        return candidate.Last_Assigned_At__c < best.Last_Assigned_At__c;
    }
}
