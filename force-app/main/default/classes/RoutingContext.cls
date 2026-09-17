/**
 * Everything a routing strategy is allowed to see when it picks an agent.
 *
 * Strategies get a pre-filtered candidate list (active, present, within capacity, skill
 * matched, not excluded) plus the projected load map, which already accounts for items
 * assigned earlier in the same transaction.
 */
public class RoutingContext {
    public Service_Work_Item__c workItem { get; set; }
    public Service_Queue__c queue { get; set; }
    public List<Service_Agent__c> candidates { get; set; }

    /** Agent Id -> capacity units already committed, including this transaction's assignments. */
    public Map<Id, Decimal> projectedLoad { get; set; }

    /** Agent Id -> skill level on this queue, from the Service_Agent_Queue__c membership. */
    public Map<Id, Decimal> skillLevelByAgent { get; set; }

    /** Agent Id -> membership priority (1 = primary queue for that agent). */
    public Map<Id, Decimal> membershipPriorityByAgent { get; set; }

    public RoutingContext() {
        this.candidates = new List<Service_Agent__c>();
        this.projectedLoad = new Map<Id, Decimal>();
        this.skillLevelByAgent = new Map<Id, Decimal>();
        this.membershipPriorityByAgent = new Map<Id, Decimal>();
    }

    public Decimal loadOf(Service_Agent__c agent) {
        Decimal load = projectedLoad.get(agent.Id);
        return load == null ? 0 : load;
    }

    public Decimal remainingCapacityOf(Service_Agent__c agent) {
        return PresenceStatusService.effectiveCapacity(agent) - loadOf(agent);
    }

    public Decimal skillLevelOf(Service_Agent__c agent) {
        Decimal level = skillLevelByAgent.get(agent.Id);
        return level == null ? 0 : level;
    }

    public Decimal membershipPriorityOf(Service_Agent__c agent) {
        Decimal p = membershipPriorityByAgent.get(agent.Id);
        return p == null ? 999 : p;
    }

    public Decimal weight() {
        return workItem.Capacity_Weight__c == null ? 1 : workItem.Capacity_Weight__c;
    }
}
