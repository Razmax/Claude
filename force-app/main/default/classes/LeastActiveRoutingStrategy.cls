/**
 * Fewest open items wins. Ties break on the agent who has been idle longest, so work
 * spreads evenly across a shift instead of piling on whoever is alphabetically first.
 */
public with sharing class LeastActiveRoutingStrategy implements IRoutingStrategy {
    public Service_Agent__c selectAgent(RoutingContext context) {
        Service_Agent__c best;
        for (Service_Agent__c candidate : context.candidates) {
            if (best == null || isBetter(candidate, best, context)) {
                best = candidate;
            }
        }
        return best;
    }

    private Boolean isBetter(Service_Agent__c candidate, Service_Agent__c best, RoutingContext context) {
        Decimal candidateCount = countOf(candidate);
        Decimal bestCount = countOf(best);
        if (candidateCount != bestCount) {
            return candidateCount < bestCount;
        }
        Decimal candidateLoad = context.loadOf(candidate);
        Decimal bestLoad = context.loadOf(best);
        if (candidateLoad != bestLoad) {
            return candidateLoad < bestLoad;
        }
        return RoutingComparators.idleLongerThan(candidate, best);
    }

    private Decimal countOf(Service_Agent__c agent) {
        return agent.Active_Work_Count__c == null ? 0 : agent.Active_Work_Count__c;
    }
}
