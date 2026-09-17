/**
 * Highest skill level on the queue wins, then lowest load, then longest idle.
 *
 * Hard skill requirements on the work item are already enforced by the engine before a
 * strategy runs; this strategy expresses the softer preference of "send the tricky
 * credit file to the reviewer who is best at them, if they are free".
 */
public with sharing class SkillBasedRoutingStrategy implements IRoutingStrategy {
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
        Decimal candidateSkill = context.skillLevelOf(candidate);
        Decimal bestSkill = context.skillLevelOf(best);
        if (candidateSkill != bestSkill) {
            return candidateSkill > bestSkill;
        }
        Decimal candidatePriority = context.membershipPriorityOf(candidate);
        Decimal bestPriority = context.membershipPriorityOf(best);
        if (candidatePriority != bestPriority) {
            return candidatePriority < bestPriority;
        }
        Decimal candidateLoad = context.loadOf(candidate);
        Decimal bestLoad = context.loadOf(best);
        if (candidateLoad != bestLoad) {
            return candidateLoad < bestLoad;
        }
        return RoutingComparators.idleLongerThan(candidate, best);
    }
}
