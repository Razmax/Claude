@isTest
private class RoutingRuleEngineTest {

    private static Service_Routing_Rule__mdt rule(String name, Decimal order, String obj,
                                                  String field1, String op1, String value1,
                                                  String targetQueue, Boolean stop) {
        return new Service_Routing_Rule__mdt(
            DeveloperName = name, MasterLabel = name, Active__c = true, Order__c = order,
            Source_Object__c = obj, Field_1_API_Name__c = field1, Operator_1__c = op1,
            Value_1__c = value1, Target_Queue__c = targetQueue, Stop_Processing__c = stop);
    }

    @isTest
    static void firstMatchingRuleWinsAndOrderMatters() {
        ServiceRoutingTestFactory.stubSettings();
        ServiceRoutingTestFactory.stubRules(new List<Service_Routing_Rule__mdt>{
            rule('Credit', 10, 'Case', 'Type', 'Equals', 'Credit Hold', 'CREDIT_REVIEW', true),
            rule('Catch_All', 90, 'Case', null, null, null, 'CUSTOMER_SERVICE', true)
        });

        Case creditCase = new Case(Subject = 'Credit question', Type = 'Credit Hold');
        RoutingDecision decision = RoutingRuleEngine.evaluate(creditCase, 'Case');
        System.assertEquals('CREDIT_REVIEW', decision.queueDeveloperName);
        System.assertEquals('Credit', decision.matchedRule);

        Case ordinaryCase = new Case(Subject = 'Password reset', Type = 'Question');
        RoutingDecision fallback = RoutingRuleEngine.evaluate(ordinaryCase, 'Case');
        System.assertEquals('CUSTOMER_SERVICE', fallback.queueDeveloperName,
            'An empty condition acts as a catch-all');
    }

    @isTest
    static void ruleAttributesFlowIntoTheDecision() {
        ServiceRoutingTestFactory.stubSettings();
        Service_Routing_Rule__mdt r = rule('Credit', 10, 'Case', 'Type', 'Equals', 'Credit Hold', 'CREDIT_REVIEW', true);
        r.Priority__c = 2;
        r.Capacity_Weight__c = 3;
        r.Required_Skills__c = 'CREDIT';
        r.SLA_Minutes__c = 120;
        ServiceRoutingTestFactory.stubRules(new List<Service_Routing_Rule__mdt>{r});

        RoutingDecision decision = RoutingRuleEngine.evaluate(new Case(Type = 'Credit Hold'), 'Case');
        System.assertEquals(2, decision.priority.intValue());
        System.assertEquals(3, decision.capacityWeight.intValue());
        System.assertEquals('CREDIT', decision.requiredSkills);
        System.assertEquals(120, decision.slaMinutes.intValue());
        System.assert(decision.isMatched());
    }

    @isTest
    static void objectAndChannelFiltersScopeRules() {
        ServiceRoutingTestFactory.stubSettings();
        ServiceRoutingTestFactory.stubRules(new List<Service_Routing_Rule__mdt>{
            rule('Lead_Only', 10, 'Lead', null, null, null, 'SALES', true)
        });
        RoutingDecision decision = RoutingRuleEngine.evaluate(new Case(Subject = 'Hello'), 'Case');
        System.assert(!decision.isMatched(), 'A Lead rule must not match a Case');

        Service_Routing_Rule__mdt phoneRule = rule('Phone', 10, 'Case', null, null, null, 'PHONE_QUEUE', true);
        phoneRule.Channel__c = 'Phone';
        ServiceRoutingTestFactory.stubRules(new List<Service_Routing_Rule__mdt>{phoneRule});
        System.assert(!RoutingRuleEngine.evaluate(new Case(), 'Email').isMatched(),
            'A Phone rule must not match Email work');
        System.assert(RoutingRuleEngine.evaluate(new Case(), 'Phone').isMatched());
    }

    @isTest
    static void everyOperatorBehavesAsDocumented() {
        Case c = new Case(Subject = 'Billing dispute on invoice 4471', Type = 'Billing', Priority = 'High');

        System.assert(RoutingRuleEngine.conditionPasses(c, 'Type', 'Equals', 'billing'),
            'Equals is case-insensitive');
        System.assert(RoutingRuleEngine.conditionPasses(c, 'Type', 'Not Equals', 'Credit'));
        System.assert(RoutingRuleEngine.conditionPasses(c, 'Subject', 'Contains', 'invoice'));
        System.assert(RoutingRuleEngine.conditionPasses(c, 'Subject', 'Starts With', 'Billing'));
        System.assert(RoutingRuleEngine.conditionPasses(c, 'Type', 'In', 'Credit;Billing;Other'));
        System.assert(!RoutingRuleEngine.conditionPasses(c, 'Type', 'In', 'Credit;Other'));
        System.assert(RoutingRuleEngine.conditionPasses(c, 'Description', 'Is Null', null));
        System.assert(RoutingRuleEngine.conditionPasses(c, 'Subject', 'Is Not Null', null));
        System.assert(RoutingRuleEngine.conditionPasses(c, null, 'Equals', 'anything'),
            'A blank field is not a filter at all');
        System.assert(!RoutingRuleEngine.conditionPasses(c, 'Type', 'Bogus Operator', 'Billing'),
            'An unknown operator should fail closed rather than match everything');
    }

    @isTest
    static void numericComparisonsUseNumbersNotText() {
        // 9 > 10 as text, but not as a number.
        Account a = new Account(Name = 'Test', NumberOfEmployees = 9);
        System.assert(!RoutingRuleEngine.conditionPasses(a, 'NumberOfEmployees', 'Greater Than', '10'));
        System.assert(RoutingRuleEngine.conditionPasses(a, 'NumberOfEmployees', 'Less Than', '10'));
    }

    @isTest
    static void unreadableFieldsAreSkippedNotFatal() {
        Case c = new Case(Subject = 'Hello');
        System.assertEquals(null, RoutingRuleEngine.readField(c, 'No_Such_Field__c'),
            'A rule pointing at a missing field should return null, not throw');
        System.assert(!RoutingRuleEngine.conditionPasses(c, 'No_Such_Field__c', 'Equals', 'x'));
    }

    @isTest
    static void nullRecordProducesNoMatch() {
        ServiceRoutingTestFactory.stubSettings();
        RoutingDecision decision = RoutingRuleEngine.evaluate(null, 'Case');
        System.assert(!decision.isMatched());
    }
}
