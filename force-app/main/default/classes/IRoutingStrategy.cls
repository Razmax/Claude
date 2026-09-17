/**
 * Implement this to add an org-specific way of choosing an agent, then either set the
 * class name on Service_Queue__c.Routing_Strategy_Class__c or make it the default in
 * Service_Routing_Setting__mdt. No change to the engine is needed.
 *
 * Return null to leave the work item queued - the engine will retry it on the next pass.
 */
public interface IRoutingStrategy {
    Service_Agent__c selectAgent(RoutingContext context);
}
