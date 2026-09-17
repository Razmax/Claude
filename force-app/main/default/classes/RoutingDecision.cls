/** The outcome of evaluating routing rules against a source record. */
public class RoutingDecision {
    @AuraEnabled public String queueDeveloperName { get; set; }
    @AuraEnabled public Decimal priority { get; set; }
    @AuraEnabled public Decimal capacityWeight { get; set; }
    @AuraEnabled public String requiredSkills { get; set; }
    @AuraEnabled public Decimal slaMinutes { get; set; }
    @AuraEnabled public String matchedRule { get; set; }

    public Boolean isMatched() {
        return String.isNotBlank(queueDeveloperName);
    }
}
