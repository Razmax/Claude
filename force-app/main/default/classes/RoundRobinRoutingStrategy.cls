/**
 * Strict rotation by Last_Assigned_At__c. The agent who has gone longest without an
 * assignment takes the next item, regardless of current load - useful for teams that
 * want a visibly fair distribution of a scarce work type.
 */
public with sharing class RoundRobinRoutingStrategy implements IRoutingStrategy {
    public Service_Agent__c selectAgent(RoutingContext context) {
        Service_Agent__c best;
        for (Service_Agent__c candidate : context.candidates) {
            if (best == null || RoutingComparators.idleLongerThan(candidate, best)) {
                best = candidate;
            }
        }
        return best;
    }
}
