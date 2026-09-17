/**
 * Most spare capacity wins. Differs from Least Active when work items carry different
 * weights - a credit reviewer holding one heavy file is busier than a rep holding three
 * quick callbacks, and this strategy respects that.
 */
public with sharing class MostAvailableRoutingStrategy implements IRoutingStrategy {
    public Service_Agent__c selectAgent(RoutingContext context) {
        Service_Agent__c best;
        Decimal bestRemaining;
        for (Service_Agent__c candidate : context.candidates) {
            Decimal remaining = context.remainingCapacityOf(candidate);
            if (best == null || remaining > bestRemaining ||
                (remaining == bestRemaining && RoutingComparators.idleLongerThan(candidate, best))) {
                best = candidate;
                bestRemaining = remaining;
            }
        }
        return best;
    }
}
